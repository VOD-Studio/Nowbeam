package main

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"nowbeam.local/receiver/internal/config"
	"nowbeam.local/receiver/internal/httpapi"
	"nowbeam.local/receiver/internal/presence"
	"nowbeam.local/receiver/internal/storage"
)

func main() {
	if err := run(); err != nil {
		// 不输出底层异常，避免路径、数据库数据或握手内容进入日志。
		log.Print("Nowbeam receiver stopped: startup_or_runtime_error")
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	store, err := storage.Open(cfg.DatabasePath)
	if err != nil {
		return err
	}
	defer store.Close()
	manager, err := presence.New(store, cfg.BootstrapToken, nil)
	if err != nil {
		return err
	}
	cfg.BootstrapToken = ""
	defer manager.Shutdown()
	listener, err := net.Listen("tcp", cfg.ListenAddr)
	if err != nil {
		return err
	}
	defer listener.Close()
	if cfg.TLSCertFile != "" {
		certificate, err := tls.LoadX509KeyPair(cfg.TLSCertFile, cfg.TLSKeyFile)
		if err != nil {
			return err
		}
		listener = tls.NewListener(listener, &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{certificate}, NextProtos: []string{"http/1.1"}})
	}
	api := httpapi.New(manager)
	server := &http.Server{
		Handler:           api,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16384,
		// 标准库默认错误可能带请求数据，活动与认证内容不进日志。
		ErrorLog: log.New(io.Discard, "", 0),
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go manager.Run(ctx)
	result := make(chan error, 1)
	go func() { result <- server.Serve(listener) }()
	log.Print("Nowbeam receiver ready")
	select {
	case err := <-result:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	case <-ctx.Done():
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	socketResult := make(chan error, 1)
	go func() { socketResult <- api.Shutdown(shutdown) }()
	if err := server.Shutdown(shutdown); err != nil {
		_ = server.Close()
		return err
	}
	return <-socketResult
}
