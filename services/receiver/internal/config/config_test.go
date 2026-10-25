package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBootstrapFileLengthAndLineEndings(t *testing.T) {
	for _, test := range []struct {
		name     string
		length   int
		ending   string
		accepted bool
	}{
		{"maximum_with_lf", 512, "\n", true},
		{"maximum_with_crlf", 512, "\r\n", true},
		{"oversized_without_newline", 513, "", false},
		{"oversized_with_crlf", 513, "\r\n", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "bootstrap")
			if err := os.WriteFile(path, []byte(strings.Repeat("x", test.length)+test.ending), 0600); err != nil {
				t.Fatal(err)
			}
			t.Setenv("NOWBEAM_BOOTSTRAP_TOKEN", "")
			t.Setenv("NOWBEAM_BOOTSTRAP_TOKEN_FILE", path)
			t.Setenv("NOWBEAM_LISTEN_ADDR", "127.0.0.1:0")
			t.Setenv("NOWBEAM_DATABASE_PATH", filepath.Join(t.TempDir(), "state.sqlite"))
			t.Setenv("NOWBEAM_TLS_CERT_FILE", "")
			t.Setenv("NOWBEAM_TLS_KEY_FILE", "")
			configuration, err := Load()
			if !test.accepted {
				if err == nil {
					t.Fatal("oversized bootstrap credential accepted")
				}
				return
			}
			if err != nil {
				t.Fatalf("valid credential file rejected: %v", err)
			}
			if len(configuration.BootstrapToken) != test.length || strings.ContainsAny(configuration.BootstrapToken, "\r\n") {
				t.Fatal("credential line ending was not normalized correctly")
			}
		})
	}
}
