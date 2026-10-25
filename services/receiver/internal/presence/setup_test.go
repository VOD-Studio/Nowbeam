package presence

import (
	"context"
	"errors"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"

	"nowbeam.local/receiver/internal/storage"
)

func TestInitializationIsAuthenticatedAtomicAndOneShot(t *testing.T) {
	store, err := storage.Open(filepath.Join(t.TempDir(), "private", "receiver.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if _, err := New(store, "", nil); err == nil {
		t.Fatal("uninitialized database accepted missing bootstrap")
	}
	manager, err := New(store, "bootstrap-test-0123456789abcdef0123456789", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Shutdown()
	if _, err := manager.Setup(context.Background(), "first-visitor-cannot-claim"); !errors.Is(err, Unauthorized) {
		t.Fatal("invalid bootstrap claimed owner")
	}
	var winners atomic.Int32
	var owner string
	var wg sync.WaitGroup
	for range 16 {
		wg.Go(func() {
			token, err := manager.Setup(context.Background(), "bootstrap-test-0123456789abcdef0123456789")
			if err == nil {
				winners.Add(1)
				owner = token
			} else if !errors.Is(err, storage.ErrInitialized) {
				t.Error(err)
			}
		})
	}
	wg.Wait()
	if winners.Load() != 1 || owner == "" {
		t.Fatal("setup was not one-shot")
	}
	if _, err := manager.Settings(context.Background(), owner); err != nil {
		t.Fatal("issued owner credential rejected")
	}
	if _, err := manager.Settings(context.Background(), "bootstrap-test-0123456789abcdef0123456789"); !errors.Is(err, Unauthorized) {
		t.Fatal("bootstrap retained login authority")
	}
}
