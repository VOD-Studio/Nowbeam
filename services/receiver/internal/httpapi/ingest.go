package httpapi

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/coder/websocket"

	"nowbeam.local/receiver/internal/presence"
	"nowbeam.local/receiver/internal/wire"
)

func (s *Server) ingest(w http.ResponseWriter, r *http.Request) {
	if !s.beginSocket() {
		fail(w, 503, "unavailable")
		return
	}
	defer s.sockets.Done()
	if !method(w, r, "GET") {
		return
	}
	// 注册与鉴权是同一操作：即使撤销发生在 Upgrade 期间，候选连接也已被隔离。
	session, err := s.manager.Register(r.Context(), bearer(r))
	if err != nil {
		failure(w, err)
		return
	}
	defer s.manager.Disconnect(session)
	if len(r.Header.Values("Origin")) != 0 {
		fail(w, 403, "origin_forbidden")
		return
	}
	if !containsToken(r.Header.Values("Sec-WebSocket-Protocol"), "nowbeam.v1", false) {
		fail(w, 400, "unsupported_protocol")
		return
	}
	if r.Header.Get("Sec-WebSocket-Version") != "13" {
		w.Header().Set("Sec-WebSocket-Version", "13")
		fail(w, 426, "unsupported_websocket_version")
		return
	}
	if !r.ProtoAtLeast(1, 1) || !containsToken(r.Header.Values("Upgrade"), "websocket", true) || !containsToken(r.Header.Values("Connection"), "upgrade", true) {
		fail(w, 400, "invalid_upgrade")
		return
	}
	keys := r.Header.Values("Sec-WebSocket-Key")
	if len(keys) != 1 {
		fail(w, 400, "invalid_upgrade")
		return
	}
	key, err := base64.StdEncoding.DecodeString(strings.TrimSpace(keys[0]))
	if err != nil || len(key) != 16 {
		fail(w, 400, "invalid_upgrade")
		return
	}
	// 上游库对子协议大小写宽松；仅把已经精确匹配的协议交给协商器。
	r.Header.Set("Sec-WebSocket-Protocol", "nowbeam.v1")
	response := &ingestResponseWriter{ResponseWriter: w}
	connection, err := websocket.Accept(response, r, &websocket.AcceptOptions{
		Subprotocols: []string{"nowbeam.v1"}, CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		return
	}
	defer func() {
		// 必须先解阻真实传输；CloseNow 在已有关闭握手时只会等待，不会强制断开。
		_ = response.transport.Close()
		_ = connection.CloseNow()
	}()
	// 额外一字节仅作溢出哨兵，应用层先清除状态再发固定原因的 1009。
	connection.SetReadLimit(wire.MaxMessageBytes + 1)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	select {
	case <-session.Done():
		terminate(ctx, connection, response.transport, session)
		return
	default:
	}
	if err := send(ctx, connection, wire.NewWelcome(session.ID, session.DeviceID, time.Now())); err != nil {
		return
	}
	if !s.manager.Activate(session) {
		terminate(ctx, connection, response.transport, session)
		return
	}
	closed := make(chan struct{})
	go func() {
		defer close(closed)
		select {
		case <-session.Done():
			terminate(ctx, connection, response.transport, session)
		case <-ctx.Done():
		}
		cancel()
	}()
	defer func() {
		s.manager.Disconnect(session)
		<-closed
	}()
	for {
		kind, reader, err := connection.Reader(ctx)
		if err != nil {
			return
		}
		if kind != websocket.MessageText {
			s.manager.Reject(session, 1003, "unsupported_data")
			<-closed
			return
		}
		data, err := io.ReadAll(io.LimitReader(reader, wire.MaxMessageBytes+1))
		if err != nil {
			return
		}
		if len(data) > wire.MaxMessageBytes {
			s.manager.Reject(session, 1009, "message_too_large")
			<-closed
			return
		}
		if !utf8.Valid(data) {
			s.manager.Reject(session, 1007, "invalid_utf8")
			<-closed
			return
		}
		snapshot, fingerprint, err := wire.ParseSnapshot(data)
		if err != nil {
			s.manager.Reject(session, 1008, "invalid_message")
			<-closed
			return
		}
		ack, accepted := s.manager.Submit(session, snapshot, fingerprint)
		if !accepted {
			<-closed
			return
		}
		if err := send(ctx, connection, ack); err != nil {
			return
		}
	}
}

type ingestResponseWriter struct {
	http.ResponseWriter
	transport net.Conn
}

func (w *ingestResponseWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	connection, buffered, err := http.NewResponseController(w.ResponseWriter).Hijack()
	if err != nil {
		return nil, nil, err
	}
	w.transport = connection
	if secure, ok := connection.(*tls.Conn); ok {
		// TLS Close 会尝试 close_notify 并重设写期限；兜底必须直接关闭底层 socket。
		w.transport = secure.NetConn()
	}
	return connection, buffered, nil
}

func containsToken(values []string, expected string, fold bool) bool {
	for _, value := range values {
		for _, token := range strings.Split(value, ",") {
			token = strings.TrimSpace(token)
			if token == expected || (fold && strings.EqualFold(token, expected)) {
				return true
			}
		}
	}
	return false
}
func send(ctx context.Context, connection *websocket.Conn, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	writeCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	return connection.Write(writeCtx, websocket.MessageText, data)
}
func terminate(ctx context.Context, connection *websocket.Conn, transport net.Conn, session *presence.Session) {
	// 库的关闭握手会无 context 地排空未完成帧，独立看门狗覆盖 error、Close 和 TLS 清理。
	forced := make(chan struct{})
	timer := time.AfterFunc(time.Second, func() {
		_ = transport.Close()
		close(forced)
	})
	defer func() {
		if !timer.Stop() {
			<-forced
		}
	}()
	end := session.Termination()
	switch end.Code {
	case "invalid_message", "out_of_order", "sequence_conflict", "credential_revoked", "session_replaced", "internal_error":
		_ = send(ctx, connection, wire.Error{ProtocolVersion: 1, Type: "error", ConnectionID: session.ID, Sequence: end.Sequence, Code: end.Code})
	}
	_ = connection.Close(websocket.StatusCode(end.CloseCode), end.Code)
}
