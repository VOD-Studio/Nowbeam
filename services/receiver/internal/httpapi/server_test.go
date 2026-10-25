package httpapi_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"nowbeam.local/receiver/internal/httpapi"
	"nowbeam.local/receiver/internal/presence"
	"nowbeam.local/receiver/internal/storage"
	"nowbeam.local/receiver/internal/wire"
)

const bootstrap = "test-bootstrap-only-0123456789abcdef0123456789"

type harness struct {
	server  *httptest.Server
	api     *httpapi.Server
	manager *presence.Manager
	owner   string
	token   string
	device  storage.Device
}

func start(t *testing.T) *harness {
	t.Helper()
	return startWithHandler(t, func(handler http.Handler) http.Handler { return handler })
}

func startWithHandler(t *testing.T, wrap func(http.Handler) http.Handler) *harness {
	t.Helper()
	store, err := storage.Open(filepath.Join(t.TempDir(), "private", "receiver.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	manager, err := presence.New(store, bootstrap, nil)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	go manager.Run(ctx)
	api := httpapi.New(manager)
	h := &harness{server: httptest.NewTLSServer(wrap(api)), api: api, manager: manager}
	h.server.Client().CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	t.Cleanup(func() {
		cancel()
		ctx, done := context.WithTimeout(context.Background(), 10*time.Second)
		defer done()
		_ = api.Shutdown(ctx)
		h.server.Close()
		_ = store.Close()
	})
	var setup struct {
		OwnerToken string `json:"ownerToken"`
	}
	h.request(t, "POST", "/api/v1/setup", bootstrap, `{}`, 201, &setup)
	h.owner = setup.OwnerToken
	var created struct {
		Device     storage.Device `json:"device"`
		Token      string         `json:"token"`
		IngestPath string         `json:"ingestPath"`
	}
	h.request(t, "POST", "/api/v1/admin/devices", h.owner, `{"displayName":"虚构设备"}`, 201, &created)
	h.device, h.token = created.Device, created.Token
	if created.IngestPath != "/api/v1/ingest" {
		t.Fatal("incorrect ingest path")
	}
	return h
}
func (h *harness) request(t *testing.T, method, path, token, body string, expected int, out any) http.Header {
	t.Helper()
	r, err := http.NewRequest(method, h.server.URL+path, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	if body != "" {
		r.Header.Set("Content-Type", "application/json")
	}
	response, err := h.server.Client().Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != expected {
		t.Fatalf("%s %s: status %d, expected %d", method, path, response.StatusCode, expected)
	}
	if response.Header.Get("Cache-Control") != "no-store" {
		t.Fatal("missing no-store")
	}
	if out != nil {
		if err := json.NewDecoder(response.Body).Decode(out); err != nil {
			t.Fatal(err)
		}
	}
	return response.Header
}
func (h *harness) connect(t *testing.T) (*websocket.Conn, wire.Welcome) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, "wss"+strings.TrimPrefix(h.server.URL, "https")+"/api/v1/ingest", &websocket.DialOptions{
		HTTPClient: h.server.Client(), HTTPHeader: http.Header{"Authorization": []string{"Bearer " + h.token}},
		Subprotocols: []string{"nowbeam.v1"}, CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.CloseNow() })
	if conn.Subprotocol() != "nowbeam.v1" {
		t.Fatal("subprotocol not selected")
	}
	var welcome wire.Welcome
	readMessage(t, conn, &welcome)
	if welcome.Type != "welcome" || welcome.DeviceID != h.device.ID || !wire.ValidID(welcome.ConnectionID) || welcome.LeaseDurationMS != 45000 || welcome.HeartbeatIntervalMS != 15000 || welcome.MaxMessageBytes != 65536 {
		t.Fatal("invalid welcome")
	}
	return conn, welcome
}
func readMessage(t *testing.T, conn *websocket.Conn, value any) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	kind, data, err := conn.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if kind != websocket.MessageText {
		t.Fatal("non-text server message")
	}
	if err := json.Unmarshal(data, value); err != nil {
		t.Fatal(err)
	}
}
func sendSnapshot(t *testing.T, conn *websocket.Conn, welcome wire.Welcome, seq int64, title string) wire.Ack {
	t.Helper()
	sources := wire.Sources{}
	if title != "" {
		sources.Window = &wire.Window{Title: title}
	}
	data, err := json.Marshal(wire.Snapshot{ProtocolVersion: 1, Type: "snapshot", ConnectionID: welcome.ConnectionID, Sequence: seq, ObservedAt: "2026-10-25T12:00:00Z", Sources: sources})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
		t.Fatal(err)
	}
	var ack wire.Ack
	readMessage(t, conn, &ack)
	if ack.Type != "ack" || ack.ConnectionID != welcome.ConnectionID || ack.Sequence != seq {
		t.Fatal("incorrect ACK")
	}
	return ack
}

func TestHTTPSPermissionsSettingsAndStrictBodies(t *testing.T) {
	h := start(t)
	h.request(t, "POST", "/api/v1/setup", bootstrap, `{}`, 409, nil)
	h.request(t, "GET", "/api/v1/presence", "", "", 403, nil)
	h.request(t, "GET", "/api/v1/presence", h.owner, "", 200, nil)
	h.request(t, "GET", "/api/v1/admin/settings", h.token, "", 403, nil)
	h.request(t, "GET", "/api/v1/admin/devices", "not-valid", "", 401, nil)
	for _, body := range []string{
		`{"publicReadEnabled":true}`, `{"publicReadEnabled":null,"allowedOrigins":[]}`,
		`{"publicReadEnabled":true,"allowedOrigins":null}`, `{"publicReadEnabled":true,"allowedOrigins":["*"]}`,
		`{"publicReadEnabled":true,"allowedOrigins":[],"extra":1}`,
		`{"publicReadEnabled":false,"publicReadEnabled":true,"allowedOrigins":[]}`,
	} {
		h.request(t, "PUT", "/api/v1/admin/settings", h.owner, body, 400, nil)
	}
	h.request(t, "POST", "/api/v1/admin/devices", h.owner, `{"displayName":null}`, 400, nil)
	h.request(t, "POST", "/api/v1/admin/devices", h.owner, `{"displayName":"\u202esecret"}`, 400, nil)
	h.request(t, "POST", "/api/v1/admin/devices", h.owner, `{"displayName":"`+strings.Repeat("a", 17000)+`"}`, 413, nil)
	h.request(t, "PUT", "/api/v1/admin/settings", h.owner, `{"publicReadEnabled":true,"allowedOrigins":["https://consumer.example"]}`, 200, nil)
	h.request(t, "GET", "/api/v1/presence", "", "", 200, nil)
	for _, origin := range []string{"https://consumer.example", "https://untrusted.example"} {
		r, _ := http.NewRequest("GET", h.server.URL+"/api/v1/presence", nil)
		r.Header.Set("Origin", origin)
		response, err := h.server.Client().Do(r)
		if err != nil {
			t.Fatal(err)
		}
		_ = response.Body.Close()
		if origin == "https://consumer.example" {
			if response.StatusCode != 200 || response.Header.Get("Access-Control-Allow-Origin") != origin {
				t.Fatal("allowed CORS failed")
			}
		} else if response.StatusCode != 403 || response.Header.Get("Access-Control-Allow-Origin") != "" {
			t.Fatal("unexpected origin allowed")
		}
	}
}

func TestWSSSnapshotDuplicateTakeoverAndRevoke(t *testing.T) {
	h := start(t)
	first, welcome := h.connect(t)
	ack := sendSnapshot(t, first, welcome, 1, "虚构窗口")
	if duplicate := sendSnapshot(t, first, welcome, 1, "虚构窗口"); duplicate != ack {
		t.Fatal("duplicate renewed lease")
	}
	probe, _ := h.connect(t)
	_ = probe.Close(websocket.StatusNormalClosure, "probe_complete")
	var projection presence.Projection
	h.request(t, "GET", "/api/v1/presence", h.owner, "", 200, &projection)
	if !projection.Devices[0].Online || projection.Devices[0].Sources.Window.Title != "虚构窗口" {
		t.Fatal("probe changed current presence")
	}
	second, next := h.connect(t)
	sendSnapshot(t, second, next, 1, "新虚构窗口")
	var replaced wire.Error
	readMessage(t, first, &replaced)
	if replaced.Code != "session_replaced" {
		t.Fatal("old connection not replaced")
	}
	expectClose(t, first, 4002)
	_ = first.CloseNow()
	h.request(t, "GET", "/api/v1/presence", h.owner, "", 200, &projection)
	if projection.Devices[0].Sources.Window.Title != "新虚构窗口" {
		t.Fatal("old close removed new snapshot")
	}
	candidate, _ := h.connect(t)
	h.request(t, "DELETE", "/api/v1/admin/devices/"+h.device.ID, h.owner, "", 204, nil)
	for _, conn := range []*websocket.Conn{second, candidate} {
		var revoked wire.Error
		readMessage(t, conn, &revoked)
		if revoked.Code != "credential_revoked" {
			t.Fatal("candidate or current survived revoke")
		}
		expectClose(t, conn, 4001)
	}
	h.request(t, "GET", "/api/v1/presence", h.owner, "", 200, &projection)
	if len(projection.Devices) != 0 {
		t.Fatal("revoked device still exposed")
	}
	h.request(t, "GET", "/api/v1/ingest", h.token, "", 401, nil)
}

func expectClose(t *testing.T, conn *websocket.Conn, code websocket.StatusCode) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	_, _, err := conn.Read(ctx)
	if websocket.CloseStatus(err) != code {
		t.Fatalf("close status %d, expected %d", websocket.CloseStatus(err), code)
	}
}

func TestTwoIndependentReceiversAndCertificateTrust(t *testing.T) {
	one, two := start(t), start(t)
	if one.device.ID == two.device.ID || one.token == two.token {
		t.Fatal("receiver identities reused")
	}
	first, welcome := one.connect(t)
	second, other := two.connect(t)
	sendSnapshot(t, first, welcome, 1, "第一实例")
	sendSnapshot(t, second, other, 1, "第二实例")
	one.request(t, "DELETE", "/api/v1/admin/devices/"+one.device.ID, one.owner, "", 204, nil)
	sendSnapshot(t, second, other, 2, "仍然独立")
	var projection presence.Projection
	two.request(t, "GET", "/api/v1/presence", two.owner, "", 200, &projection)
	if projection.Devices[0].Sources.Window.Title != "仍然独立" {
		t.Fatal("one receiver affected another")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, response, err := websocket.Dial(ctx, "wss"+strings.TrimPrefix(two.server.URL, "https")+"/api/v1/ingest", &websocket.DialOptions{Subprotocols: []string{"nowbeam.v1"}, HTTPHeader: http.Header{"Authorization": []string{"Bearer " + two.token}}})
	if conn != nil {
		_ = conn.CloseNow()
	}
	if response != nil {
		_ = response.Body.Close()
	}
	if err == nil {
		t.Fatal("untrusted TLS certificate accepted")
	}
}

func TestPublicResponseDoesNotDiscloseCredentialsOrConnectionIdentity(t *testing.T) {
	h := start(t)
	conn, welcome := h.connect(t)
	sendSnapshot(t, conn, welcome, 1, "")
	r, _ := http.NewRequest("GET", h.server.URL+"/api/v1/presence", nil)
	r.Header.Set("Authorization", "Bearer "+h.owner)
	response, err := h.server.Client().Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	data, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{h.token, h.owner, bootstrap, welcome.ConnectionID, "observedAt", "token_hash"} {
		if bytes.Contains(data, []byte(secret)) {
			t.Fatal("private field leaked in public projection")
		}
	}
	var projection presence.Projection
	if err := json.Unmarshal(data, &projection); err != nil {
		t.Fatal(err)
	}
	if !projection.Devices[0].Online || projection.Devices[0].Sources != (wire.Sources{}) {
		t.Fatal("online empty snapshot misrepresented")
	}
}
