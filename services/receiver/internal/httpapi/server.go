package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"strings"
	"sync"

	"nowbeam.local/receiver/internal/presence"
	"nowbeam.local/receiver/internal/storage"
	"nowbeam.local/receiver/internal/wire"
)

type Server struct {
	manager *presence.Manager
	mu      sync.Mutex
	closing bool
	sockets sync.WaitGroup
}

func New(manager *presence.Manager) *Server { return &Server{manager: manager} }

func (s *Server) Shutdown(ctx context.Context) error {
	s.mu.Lock()
	s.closing = true
	s.mu.Unlock()
	s.manager.Shutdown()
	done := make(chan struct{})
	go func() { s.sockets.Wait(); close(done) }()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (s *Server) beginSocket() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closing {
		return false
	}
	s.sockets.Add(1)
	return true
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if r.URL.RawQuery != "" || r.URL.ForceQuery {
		fail(w, 400, "invalid_request")
		return
	}
	if r.ContentLength > 16384 {
		fail(w, 413, "request_too_large")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 16384)
	switch r.URL.Path {
	case "/healthz":
		if !method(w, r, "GET") {
			return
		}
		respond(w, 200, map[string]string{"status": "ok"})
	case "/api/v1/setup":
		s.setup(w, r)
	case "/api/v1/admin/settings":
		s.settings(w, r)
	case "/api/v1/admin/devices":
		s.devices(w, r)
	case "/api/v1/presence":
		s.public(w, r)
	case "/api/v1/ingest":
		s.ingest(w, r)
	default:
		if strings.HasPrefix(r.URL.Path, "/api/v1/admin/devices/") {
			s.revoke(w, r)
			return
		}
		fail(w, 404, "not_found")
	}
}

func bearer(r *http.Request) string {
	values := r.Header.Values("Authorization")
	if len(values) != 1 {
		return ""
	}
	kind, token, ok := strings.Cut(values[0], " ")
	if !ok || !strings.EqualFold(kind, "Bearer") || len(token) > 512 || token == "" {
		return ""
	}
	for _, c := range token {
		if c <= 0x20 || c >= 0x7f {
			return ""
		}
	}
	return token
}
func method(w http.ResponseWriter, r *http.Request, methods ...string) bool {
	for _, allowed := range methods {
		if r.Method == allowed {
			return true
		}
	}
	w.Header().Set("Allow", strings.Join(methods, ", "))
	fail(w, 405, "method_not_allowed")
	return false
}
func body(w http.ResponseWriter, r *http.Request) (map[string]any, bool) {
	media, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || media != "application/json" {
		fail(w, 415, "unsupported_media_type")
		return nil, false
	}
	data, err := io.ReadAll(r.Body)
	if err != nil {
		var size *http.MaxBytesError
		if errors.As(err, &size) {
			fail(w, 413, "request_too_large")
		} else {
			fail(w, 400, "invalid_request")
		}
		return nil, false
	}
	m, err := wire.DecodeObject(data)
	if err != nil {
		fail(w, 400, "invalid_request")
		return nil, false
	}
	return m, true
}
func respond(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
func fail(w http.ResponseWriter, status int, code string) {
	if status == 401 {
		w.Header().Set("WWW-Authenticate", "Bearer")
	}
	respond(w, status, map[string]string{"code": code})
}
func failure(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, presence.Unauthorized):
		fail(w, 401, "unauthorized")
	case errors.Is(err, presence.Forbidden):
		fail(w, 403, "forbidden")
	case errors.Is(err, presence.Unavailable):
		fail(w, 503, "unavailable")
	case errors.Is(err, storage.ErrInitialized):
		fail(w, 409, "already_initialized")
	case errors.Is(err, storage.ErrNotFound):
		fail(w, 404, "not_found")
	default:
		fail(w, 500, "internal_error")
	}
}

func (s *Server) setup(w http.ResponseWriter, r *http.Request) {
	if !method(w, r, "POST") {
		return
	}
	m, ok := body(w, r)
	if !ok {
		return
	}
	if len(m) != 0 {
		fail(w, 400, "invalid_request")
		return
	}
	token, err := s.manager.Setup(r.Context(), bearer(r))
	if err != nil {
		failure(w, err)
		return
	}
	respond(w, 201, map[string]string{"ownerToken": token})
}
func (s *Server) devices(w http.ResponseWriter, r *http.Request) {
	if !method(w, r, "GET", "POST") {
		return
	}
	if r.Method == "GET" {
		devices, err := s.manager.Devices(r.Context(), bearer(r))
		if err != nil {
			failure(w, err)
			return
		}
		respond(w, 200, struct {
			Devices []storage.Device `json:"devices"`
		}{devices})
		return
	}
	m, ok := body(w, r)
	if !ok {
		return
	}
	m, ok = wire.Object(m, "displayName")
	if !ok {
		fail(w, 400, "invalid_request")
		return
	}
	name, ok := wire.SanitizedLabel(m["displayName"])
	if !ok {
		fail(w, 400, "invalid_request")
		return
	}
	device, token, err := s.manager.CreateDevice(r.Context(), bearer(r), name)
	if err != nil {
		failure(w, err)
		return
	}
	respond(w, 201, struct {
		Device     storage.Device `json:"device"`
		Token      string         `json:"token"`
		IngestPath string         `json:"ingestPath"`
	}{device, token, "/api/v1/ingest"})
}
func (s *Server) revoke(w http.ResponseWriter, r *http.Request) {
	if !method(w, r, "DELETE") {
		return
	}
	id := strings.TrimPrefix(r.URL.Path, "/api/v1/admin/devices/")
	if !wire.ValidID(id) {
		fail(w, 404, "not_found")
		return
	}
	if err := s.manager.Revoke(r.Context(), bearer(r), id); err != nil {
		failure(w, err)
		return
	}
	w.WriteHeader(204)
}
