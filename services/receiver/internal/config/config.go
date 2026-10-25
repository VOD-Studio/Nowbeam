package config

import (
	"errors"
	"io"
	"net"
	"os"
	"strings"
)

type Config struct {
	ListenAddr     string
	DatabasePath   string
	BootstrapToken string
	TLSCertFile    string
	TLSKeyFile     string
}

func Load() (Config, error) {
	c := Config{
		ListenAddr:     os.Getenv("NOWBEAM_LISTEN_ADDR"),
		DatabasePath:   os.Getenv("NOWBEAM_DATABASE_PATH"),
		BootstrapToken: os.Getenv("NOWBEAM_BOOTSTRAP_TOKEN"),
		TLSCertFile:    os.Getenv("NOWBEAM_TLS_CERT_FILE"),
		TLSKeyFile:     os.Getenv("NOWBEAM_TLS_KEY_FILE"),
	}
	if c.ListenAddr == "" {
		c.ListenAddr = "127.0.0.1:8787"
	}
	if c.DatabasePath == "" {
		c.DatabasePath = "data/nowbeam.sqlite"
	}
	if _, _, err := net.SplitHostPort(c.ListenAddr); err != nil {
		return Config{}, errors.New("invalid NOWBEAM_LISTEN_ADDR")
	}
	if (c.TLSCertFile == "") != (c.TLSKeyFile == "") {
		return Config{}, errors.New("TLS certificate and key must be configured together")
	}
	if path := os.Getenv("NOWBEAM_BOOTSTRAP_TOKEN_FILE"); path != "" {
		if c.BootstrapToken != "" {
			return Config{}, errors.New("configure bootstrap token or token file, not both")
		}
		f, err := os.Open(path)
		if err != nil {
			return Config{}, errors.New("cannot open bootstrap token file")
		}
		data, err := io.ReadAll(io.LimitReader(f, 515))
		_ = f.Close()
		if err != nil || len(data) > 514 {
			return Config{}, errors.New("invalid bootstrap token file")
		}
		c.BootstrapToken = strings.TrimSuffix(strings.TrimSuffix(string(data), "\n"), "\r")
	}
	if c.BootstrapToken != "" {
		if len(c.BootstrapToken) < 32 || len(c.BootstrapToken) > 512 {
			return Config{}, errors.New("bootstrap token must contain 32–512 random characters")
		}
		for _, r := range c.BootstrapToken {
			if r <= 0x20 || r >= 0x7f {
				return Config{}, errors.New("bootstrap token must be printable ASCII without spaces")
			}
		}
	}
	return c, nil
}
