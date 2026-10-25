package httpapi_test

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"sync"
	"testing"
	"time"

	"nowbeam.local/receiver/internal/presence"
	"nowbeam.local/receiver/internal/wire"
)

const rawSocketTimeout = 4 * time.Second

func TestIngestShutdownReclaimsTransportAndHandler(t *testing.T) {
	for _, test := range []struct {
		name      string
		opcode    byte
		closeCode uint16
		errorCode string
	}{
		{"incomplete binary", 2, 1003, ""},
		{"revoked incomplete text", 1, 4001, "credential_revoked"},
		{"replaced incomplete text", 1, 4002, "session_replaced"},
		{"shutdown incomplete text", 1, 1001, ""},
		{"shutdown healthy socket", 0, 1001, ""},
	} {
		t.Run(test.name, func(t *testing.T) {
			returned := make(chan struct{})
			var returnedOnce sync.Once
			h := startWithHandler(t, func(handler http.Handler) http.Handler {
				return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					if r.URL.Path == "/api/v1/ingest" {
						defer returnedOnce.Do(func() { close(returned) })
					}
					handler.ServeHTTP(w, r)
				})
			})
			h.server.Client().Timeout = rawSocketTimeout
			socket, welcome := dialRawIngest(t, h)
			socket.snapshot(t, welcome)
			if err := socket.conn.SetDeadline(time.Now().Add(rawSocketTimeout)); err != nil {
				t.Fatal(err)
			}
			if test.opcode != 0 {
				// 声明一个字节但永不补齐，不让测试清理替服务端完成关闭。
				if _, err := socket.conn.Write([]byte{0x80 | test.opcode, 0x81, 0, 0, 0, 0}); err != nil {
					t.Fatal(err)
				}
			}

			var shutdown <-chan error
			switch test.closeCode {
			case 4001:
				h.request(t, "DELETE", "/api/v1/admin/devices/"+h.device.ID, h.owner, "", 204, nil)
			case 4002:
				next, nextWelcome := h.connect(t)
				sendSnapshot(t, next, nextWelcome, 1, "新连接状态")
			case 1001:
				done := make(chan error, 1)
				shutdown = done
				go func() {
					ctx, cancel := context.WithTimeout(context.Background(), rawSocketTimeout)
					defer cancel()
					done <- h.api.Shutdown(ctx)
				}()
			}

			if test.errorCode != "" {
				var message wire.Error
				socket.readMessage(t, &message)
				if message.Type != "error" || message.Code != test.errorCode || message.ConnectionID != welcome.ConnectionID || message.Sequence != nil {
					t.Fatal("incorrect termination error")
				}
			}
			opcode, payload := socket.readFrame(t)
			if opcode != 8 || len(payload) < 2 || binary.BigEndian.Uint16(payload[:2]) != test.closeCode {
				t.Fatalf("expected close frame with code %d, received opcode %d", test.closeCode, opcode)
			}
			if _, err := socket.reader.ReadByte(); !errors.Is(err, io.EOF) {
				t.Fatalf("transport did not reach EOF after close frame: %v", err)
			}
			select {
			case <-returned:
			case <-time.After(rawSocketTimeout):
				t.Fatal("ingest handler remained blocked after transport close")
			}
			if shutdown != nil {
				select {
				case err := <-shutdown:
					if err != nil {
						t.Fatalf("shutdown did not reclaim ingest handler: %v", err)
					}
				case <-time.After(rawSocketTimeout):
					t.Fatal("shutdown remained blocked")
				}
				return
			}

			var projection presence.Projection
			h.request(t, "GET", "/api/v1/presence", h.owner, "", 200, &projection)
			switch test.closeCode {
			case 4001:
				if len(projection.Devices) != 0 {
					t.Fatal("revoked device survived transport shutdown")
				}
			case 4002:
				if len(projection.Devices) != 1 || !projection.Devices[0].Online || projection.Devices[0].Sources.Window == nil || projection.Devices[0].Sources.Window.Title != "新连接状态" {
					t.Fatal("old handler cleanup removed replacement presence")
				}
			default:
				if len(projection.Devices) != 1 || projection.Devices[0].Online || projection.Devices[0].Sources != (wire.Sources{}) {
					t.Fatal("rejected incomplete frame retained presence")
				}
			}
		})
	}
}

type rawIngestSocket struct {
	conn   *tls.Conn
	reader *bufio.Reader
}

func dialRawIngest(t *testing.T, h *harness) (*rawIngestSocket, wire.Welcome) {
	t.Helper()
	// 复用 httptest 的专用证书信任池，保持证书和主机名校验。
	config := h.server.Client().Transport.(*http.Transport).TLSClientConfig.Clone()
	conn, err := tls.DialWithDialer(&net.Dialer{Timeout: rawSocketTimeout}, "tcp", h.server.Listener.Addr().String(), config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		// 红灯回归也必须先解阻服务器，不能在 TLS close_notify 上再次等待。
		_ = conn.NetConn().Close()
		_ = conn.Close()
	})
	if err := conn.SetDeadline(time.Now().Add(rawSocketTimeout)); err != nil {
		t.Fatal(err)
	}
	request, err := http.NewRequest("GET", h.server.URL+"/api/v1/ingest", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+h.token)
	request.Header.Set("Connection", "Upgrade")
	request.Header.Set("Upgrade", "websocket")
	request.Header.Set("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")
	request.Header.Set("Sec-WebSocket-Version", "13")
	request.Header.Set("Sec-WebSocket-Protocol", "nowbeam.v1")
	if err := request.Write(conn); err != nil {
		t.Fatal(err)
	}
	socket := &rawIngestSocket{conn: conn, reader: bufio.NewReader(conn)}
	response, err := http.ReadResponse(socket.reader, request)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusSwitchingProtocols || response.Header.Get("Sec-WebSocket-Protocol") != "nowbeam.v1" {
		t.Fatalf("WebSocket upgrade failed: status %d", response.StatusCode)
	}
	var welcome wire.Welcome
	socket.readMessage(t, &welcome)
	if welcome.Type != "welcome" || welcome.DeviceID != h.device.ID || !wire.ValidID(welcome.ConnectionID) {
		t.Fatal("invalid welcome")
	}
	return socket, welcome
}

func (s *rawIngestSocket) readFrame(t *testing.T) (byte, []byte) {
	t.Helper()
	var header [2]byte
	if _, err := io.ReadFull(s.reader, header[:]); err != nil {
		t.Fatal(err)
	}
	if header[0]&0xf0 != 0x80 || header[1]&0x80 != 0 {
		t.Fatal("expected an unmasked, unfragmented server frame")
	}
	length := uint64(header[1])
	switch length {
	case 126:
		var size [2]byte
		if _, err := io.ReadFull(s.reader, size[:]); err != nil {
			t.Fatal(err)
		}
		length = uint64(binary.BigEndian.Uint16(size[:]))
	case 127:
		var size [8]byte
		if _, err := io.ReadFull(s.reader, size[:]); err != nil {
			t.Fatal(err)
		}
		length = binary.BigEndian.Uint64(size[:])
	}
	if length > wire.MaxMessageBytes {
		t.Fatal("oversized server frame")
	}
	payload := make([]byte, int(length))
	if _, err := io.ReadFull(s.reader, payload); err != nil {
		t.Fatal(err)
	}
	return header[0] & 0x0f, payload
}

func (s *rawIngestSocket) readMessage(t *testing.T, value any) {
	t.Helper()
	opcode, payload := s.readFrame(t)
	if opcode != 1 {
		t.Fatalf("expected text message, received opcode %d", opcode)
	}
	if err := json.Unmarshal(payload, value); err != nil {
		t.Fatal(err)
	}
}

func (s *rawIngestSocket) snapshot(t *testing.T, welcome wire.Welcome) {
	t.Helper()
	payload, err := json.Marshal(wire.Snapshot{
		ProtocolVersion: 1, Type: "snapshot", ConnectionID: welcome.ConnectionID,
		Sequence: 1, ObservedAt: "2026-10-25T12:00:00Z",
		Sources: wire.Sources{Window: &wire.Window{Title: "关闭时必须清除"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(payload) < 126 || len(payload) > 65535 {
		t.Fatal("snapshot fixture must use a 16-bit frame length")
	}
	frame := make([]byte, 8+len(payload))
	frame[0], frame[1] = 0x81, 0xfe
	binary.BigEndian.PutUint16(frame[2:4], uint16(len(payload)))
	copy(frame[8:], payload)
	if _, err := s.conn.Write(frame); err != nil {
		t.Fatal(err)
	}
	var ack wire.Ack
	s.readMessage(t, &ack)
	if ack.Type != "ack" || ack.ConnectionID != welcome.ConnectionID || ack.Sequence != 1 {
		t.Fatal("incorrect ACK")
	}
}
