package httpapi

import (
	"net/http"
	"net/url"
	"strings"

	"nowbeam.local/receiver/internal/storage"
	"nowbeam.local/receiver/internal/wire"
)

func (s *Server) settings(w http.ResponseWriter, r *http.Request) {
	if !method(w, r, "GET", "PUT") {
		return
	}
	if r.Method == "GET" {
		settings, err := s.manager.Settings(r.Context(), bearer(r))
		if err != nil {
			failure(w, err)
			return
		}
		respond(w, 200, settings)
		return
	}
	m, ok := body(w, r)
	if !ok {
		return
	}
	m, ok = wire.Object(m, "publicReadEnabled", "allowedOrigins")
	if !ok {
		fail(w, 400, "invalid_request")
		return
	}
	enabled, ok := m["publicReadEnabled"].(bool)
	if !ok {
		fail(w, 400, "invalid_request")
		return
	}
	origins, ok := m["allowedOrigins"].([]any)
	if !ok {
		fail(w, 400, "invalid_request")
		return
	}
	settings := storage.Settings{PublicReadEnabled: enabled, AllowedOrigins: make([]string, 0, len(origins))}
	for _, value := range origins {
		origin, ok := value.(string)
		if !ok || !validOrigin(origin) {
			fail(w, 400, "invalid_request")
			return
		}
		settings.AllowedOrigins = append(settings.AllowedOrigins, origin)
	}
	if err := s.manager.UpdateSettings(r.Context(), bearer(r), settings); err != nil {
		failure(w, err)
		return
	}
	respond(w, 200, settings)
}

func validOrigin(origin string) bool {
	if len(origin) > 2048 || strings.ContainsAny(origin, "\r\n\t *") {
		return false
	}
	u, err := url.Parse(origin)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || u.Hostname() == "" {
		return false
	}
	return u.User == nil && u.Path == "" && u.RawQuery == "" && !u.ForceQuery && u.Fragment == "" && origin == u.Scheme+"://"+u.Host
}

func allowOrigin(w http.ResponseWriter, r *http.Request, settings storage.Settings) bool {
	values := r.Header.Values("Origin")
	if len(values) == 0 {
		return true
	}
	if len(values) != 1 || values[0] == "" {
		return false
	}
	for _, allowed := range settings.AllowedOrigins {
		if values[0] == allowed {
			w.Header().Set("Access-Control-Allow-Origin", allowed)
			return true
		}
	}
	return false
}

func (s *Server) public(w http.ResponseWriter, r *http.Request) {
	w.Header().Add("Vary", "Origin")
	if !method(w, r, "GET", "OPTIONS") {
		return
	}
	if r.Method == "OPTIONS" {
		settings, err := s.manager.PublicSettings(r.Context())
		if err != nil {
			failure(w, err)
			return
		}
		if !allowOrigin(w, r, settings) {
			fail(w, 403, "origin_forbidden")
			return
		}
		if r.Header.Get("Origin") == "" || r.Header.Get("Access-Control-Request-Method") != "GET" {
			fail(w, 400, "invalid_request")
			return
		}
		if headers := r.Header.Get("Access-Control-Request-Headers"); headers != "" && !strings.EqualFold(strings.TrimSpace(headers), "authorization") {
			fail(w, 403, "headers_forbidden")
			return
		}
		w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Authorization")
		w.WriteHeader(204)
		return
	}
	projection, settings, err := s.manager.Read(r.Context(), bearer(r))
	if !allowOrigin(w, r, settings) {
		fail(w, 403, "origin_forbidden")
		return
	}
	if err != nil {
		failure(w, err)
		return
	}
	respond(w, 200, projection)
}
