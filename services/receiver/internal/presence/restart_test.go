package presence

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"nowbeam.local/receiver/internal/storage"
)

func TestRestartKeepsAuthorizationButNeverRestoresActivity(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "private", "receiver.sqlite")
	store, err := storage.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if other, err := storage.Open(path); err == nil {
		_ = other.Close()
		t.Fatal("second process opened same database")
	}
	manager, err := New(store, "bootstrap-test-0123456789abcdef0123456789", nil)
	if err != nil {
		t.Fatal(err)
	}
	owner, err := manager.Setup(ctx, "bootstrap-test-0123456789abcdef0123456789")
	if err != nil {
		t.Fatal(err)
	}
	device, token, err := manager.CreateDevice(ctx, owner, "虚构设备")
	if err != nil {
		t.Fatal(err)
	}
	settings := storage.Settings{PublicReadEnabled: true, AllowedOrigins: []string{"https://consumer.example"}}
	if err := manager.UpdateSettings(ctx, owner, settings); err != nil {
		t.Fatal(err)
	}
	session, err := manager.Register(ctx, token)
	if err != nil {
		t.Fatal(err)
	}
	manager.Activate(session)
	value, fingerprint := snapshot(t, session, 1, "不应持久化的虚构活动-abcdef")
	if _, ok := manager.Submit(session, value, fingerprint); !ok {
		t.Fatal("snapshot rejected")
	}
	manager.Shutdown()
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("unsafe database permissions")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{owner, token, "bootstrap-test-0123456789abcdef0123456789", "不应持久化的虚构活动-abcdef"} {
		if bytes.Contains(data, []byte(secret)) {
			t.Fatal("database persisted plaintext secret or activity")
		}
	}
	store, err = storage.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	manager, err = New(store, "", nil)
	if err != nil {
		t.Fatal("initialized database unexpectedly requires bootstrap")
	}
	defer manager.Shutdown()
	if _, err := manager.Setup(ctx, "bootstrap-test-0123456789abcdef0123456789"); !errors.Is(err, storage.ErrInitialized) {
		t.Fatal("setup reset after restart")
	}
	got, err := manager.Settings(ctx, owner)
	if err != nil || !got.PublicReadEnabled || len(got.AllowedOrigins) != 1 || got.AllowedOrigins[0] != "https://consumer.example" {
		t.Fatal("settings did not persist")
	}
	projection, _, err := manager.Read(ctx, "")
	if err != nil || len(projection.Devices) != 1 || projection.Devices[0].DeviceID != device.ID || projection.Devices[0].Online || projection.Devices[0].Sources.Window != nil {
		t.Fatal("restart recovered stale activity")
	}
	if _, err := manager.Register(ctx, token); err != nil {
		t.Fatal("device authorization did not persist")
	}
	if err := manager.Revoke(ctx, owner, device.ID); err != nil {
		t.Fatal(err)
	}
	manager.Shutdown()
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store, err = storage.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	manager, err = New(store, "", time.Now)
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Shutdown()
	if _, err := manager.Register(ctx, token); !errors.Is(err, Unauthorized) {
		t.Fatal("revoked device recovered after restart")
	}
}
