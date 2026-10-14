// SPDX-License-Identifier: Apache-2.0

package httpapi

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// failingReader fails the first read, as a client that drops mid-body does.
type failingReader struct{}

func (failingReader) Read([]byte) (int, error) { return 0, errors.New("connection reset") }

func TestBodyLimitMiddleware(t *testing.T) {
	tests := []struct {
		name          string
		body          io.Reader
		contentLength int64 // -1: unknown length, as with a chunked body
		wantStatus    int
		wantSlug      string
		wantRead      int
	}{
		{"empty body", http.NoBody, 0, http.StatusOK, "", 0},
		{"small body", strings.NewReader(`{"passed":1}`), 12, http.StatusOK, "", 12},
		{"exactly the limit", bytes.NewReader(make([]byte, maxRequestBodyBytes)), maxRequestBodyBytes, http.StatusOK, "", maxRequestBodyBytes},
		{"declared over the limit", bytes.NewReader(make([]byte, maxRequestBodyBytes+1)), maxRequestBodyBytes + 1, http.StatusRequestEntityTooLarge, "request_too_large", -1},
		{"chunked over the limit", bytes.NewReader(make([]byte, maxRequestBodyBytes+1)), -1, http.StatusRequestEntityTooLarge, "request_too_large", -1},
		{"unreadable body", failingReader{}, -1, http.StatusBadRequest, "invalid_request", -1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			read := -1
			h := bodyLimitMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				b, err := io.ReadAll(r.Body)
				if err != nil {
					t.Errorf("handler read: %v", err)
				}
				read = len(b)
				w.WriteHeader(http.StatusOK)
			}))
			req := httptest.NewRequest(http.MethodPost, "/api/v2/challenges/complete", tt.body)
			req.ContentLength = tt.contentLength
			w := httptest.NewRecorder()
			h.ServeHTTP(w, req)

			if w.Code != tt.wantStatus {
				t.Fatalf("status: got %d, want %d", w.Code, tt.wantStatus)
			}
			if read != tt.wantRead {
				t.Errorf("handler read %d bytes, want %d (-1: handler not called)", read, tt.wantRead)
			}
			if tt.wantSlug != "" {
				assertProblemSlug(t, w, tt.wantSlug)
			}
		})
	}
}

// Every /api/v2 route that takes a body answers 413 for an oversized one,
// before its handler runs.
func TestBodyLimit_AppliesToRoutesWithABody(t *testing.T) {
	routes := []string{
		"/api/v2/auth/login",
		"/api/v2/challenges/complete",
		"/api/v2/learn/paths/demo/complete",
		"/api/v2/scenarios/demo/up",
		"/api/v2/traffic/start",
	}
	s := newChallengeServer(t)
	s.setupRoutes()

	for _, route := range routes {
		t.Run(route, func(t *testing.T) {
			big := `{"pad":"` + strings.Repeat("x", maxRequestBodyBytes) + `"}`
			req := httptest.NewRequest(http.MethodPost, route, strings.NewReader(big))
			w := httptest.NewRecorder()
			s.router.ServeHTTP(w, req)

			if w.Code != http.StatusRequestEntityTooLarge {
				t.Fatalf("POST %s with a %d-byte body: got %d, want 413", route, len(big), w.Code)
			}
			assertProblemSlug(t, w, "request_too_large")
		})
	}

	// A body under the limit reaches the handler: login with auth off says so.
	req := httptest.NewRequest(http.MethodPost, "/api/v2/auth/login", strings.NewReader(`{"username":"a","password":"b"}`))
	w := httptest.NewRecorder()
	s.router.ServeHTTP(w, req)
	assertProblemSlug(t, w, "auth_disabled")
}

func assertProblemSlug(t *testing.T, w *httptest.ResponseRecorder, slug string) {
	t.Helper()
	if ct := w.Header().Get("Content-Type"); ct != problemContentType {
		t.Errorf("Content-Type: got %q, want %q", ct, problemContentType)
	}
	var p problemDetail
	if err := json.Unmarshal(w.Body.Bytes(), &p); err != nil {
		t.Fatalf("decoding problem body %q: %v", w.Body.String(), err)
	}
	if p.Type != problemType(slug) {
		t.Errorf("type: got %q, want %q", p.Type, problemType(slug))
	}
}
