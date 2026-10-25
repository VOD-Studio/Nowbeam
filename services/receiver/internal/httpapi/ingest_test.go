package httpapi_test

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"nowbeam.local/receiver/internal/presence"
	"nowbeam.local/receiver/internal/wire"
)

func TestUpgradeAuthenticationVersionAndOrigin(t *testing.T) {
	h := start(t)
	for _, test := range []struct {
		name, token, protocol, version, origin, path string
		status                                       int
	}{
		{"missing auth", "", "nowbeam.v1", "13", "", "/api/v1/ingest", 401},
		{"owner forbidden", h.owner, "nowbeam.v1", "13", "", "/api/v1/ingest", 403},
		{"missing protocol", h.token, "", "13", "", "/api/v1/ingest", 400},
		{"wrong protocol case", h.token, "NOWBEAM.V1", "13", "", "/api/v1/ingest", 400},
		{"old websocket", h.token, "nowbeam.v1", "12", "", "/api/v1/ingest", 426},
		{"native origin required", h.token, "nowbeam.v1", "13", h.server.URL, "/api/v1/ingest", 403},
		{"unknown route", h.token, "nowbeam.v1", "13", "", "/other", 404},
		{"query credential forbidden", h.token, "nowbeam.v1", "13", "", "/api/v1/ingest?token=not-a-secret", 400},
	} {
		t.Run(test.name, func(t *testing.T) {
			r, _ := http.NewRequest("GET", h.server.URL+test.path, nil)
			if test.token != "" {
				r.Header.Set("Authorization", "Bearer "+test.token)
			}
			r.Header.Set("Connection", "Upgrade")
			r.Header.Set("Upgrade", "websocket")
			r.Header.Set("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")
			r.Header.Set("Sec-WebSocket-Version", test.version)
			if test.protocol != "" {
				r.Header.Set("Sec-WebSocket-Protocol", test.protocol)
			}
			if test.origin != "" {
				r.Header.Set("Origin", test.origin)
			}
			response, err := h.server.Client().Do(r)
			if err != nil {
				t.Fatal(err)
			}
			defer response.Body.Close()
			if response.StatusCode != test.status {
				t.Fatalf("status %d, expected %d", response.StatusCode, test.status)
			}
			if test.status == 426 && response.Header.Get("Sec-WebSocket-Version") != "13" {
				t.Fatal("missing supported version")
			}
		})
	}
}

func TestInvalidMessagesCloseAndClearCurrentPresence(t *testing.T) {
	for _, test := range []struct {
		name    string
		kind    websocket.MessageType
		data    string
		code    websocket.StatusCode
		message string
	}{
		{"unknown fields", websocket.MessageText, `{"extra":"not-public"}`, 1008, "invalid_message"},
		{"binary", websocket.MessageBinary, "binary", 1003, ""},
		{"invalid utf8", websocket.MessageText, string([]byte{0xff}), 1007, ""},
	} {
		t.Run(test.name, func(t *testing.T) {
			h := start(t)
			conn, welcome := h.connect(t)
			sendSnapshot(t, conn, welcome, 1, "必须清除")
			ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
			defer cancel()
			if err := conn.Write(ctx, test.kind, []byte(test.data)); err != nil {
				t.Fatal(err)
			}
			if test.message != "" {
				var message wire.Error
				readMessage(t, conn, &message)
				if message.Code != test.message || message.Sequence != nil {
					t.Fatal("invalid error response")
				}
			}
			expectClose(t, conn, test.code)
			var projection presence.Projection
			h.request(t, "GET", "/api/v1/presence", h.owner, "", 200, &projection)
			if projection.Devices[0].Online || projection.Devices[0].Sources.Window != nil {
				t.Fatal("invalid message retained old presence")
			}
		})
	}
}

func TestFragmentedMessageLimitIsAggregate(t *testing.T) {
	h := start(t)
	conn, welcome := h.connect(t)
	sendSnapshot(t, conn, welcome, 1, "必须清除")
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	writer, err := conn.Writer(ctx, websocket.MessageText)
	if err != nil {
		t.Fatal(err)
	}
	chunk := []byte(strings.Repeat(" ", 8192))
	for range 9 {
		if _, err = writer.Write(chunk); err != nil {
			break
		}
	}
	_ = writer.Close()
	expectClose(t, conn, 1009)
	var projection presence.Projection
	h.request(t, "GET", "/api/v1/presence", h.owner, "", 200, &projection)
	if projection.Devices[0].Online {
		t.Fatal("oversized writer retained presence")
	}
}

func TestCORSPreflightDoesNotGrantReadPermission(t *testing.T) {
	h := start(t)
	h.request(t, "PUT", "/api/v1/admin/settings", h.owner, `{"publicReadEnabled":false,"allowedOrigins":["https://consumer.example"]}`, 200, nil)
	r, _ := http.NewRequest("OPTIONS", h.server.URL+"/api/v1/presence", nil)
	r.Header.Set("Origin", "https://consumer.example")
	r.Header.Set("Access-Control-Request-Method", "GET")
	r.Header.Set("Access-Control-Request-Headers", "authorization")
	response, err := h.server.Client().Do(r)
	if err != nil {
		t.Fatal(err)
	}
	_ = response.Body.Close()
	if response.StatusCode != 204 || response.Header.Get("Access-Control-Allow-Origin") != "https://consumer.example" {
		t.Fatal("preflight failed")
	}
	h.request(t, "GET", "/api/v1/presence", "", "", 403, nil)
}
