package presence

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"nowbeam.local/receiver/internal/storage"
	"nowbeam.local/receiver/internal/wire"
)

type fixture struct {
	manager *Manager
	store   *storage.Store
	owner   string
	token   string
	device  storage.Device
	now     time.Time
}

func setup(t *testing.T) *fixture {
	t.Helper()
	store, err := storage.Open(filepath.Join(t.TempDir(), "private", "state.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	f := &fixture{store: store, now: time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC)}
	f.manager, err = New(store, "bootstrap-token-for-test-only-0123456789", func() time.Time { return f.now })
	if err != nil {
		t.Fatal(err)
	}
	f.owner, err = f.manager.Setup(context.Background(), "bootstrap-token-for-test-only-0123456789")
	if err != nil {
		t.Fatal(err)
	}
	f.device, f.token, err = f.manager.CreateDevice(context.Background(), f.owner, "虚构设备")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.manager.Shutdown(); _ = store.Close() })
	return f
}
func (f *fixture) connect(t *testing.T) *Session {
	t.Helper()
	s, err := f.manager.Register(context.Background(), f.token)
	if err != nil {
		t.Fatal(err)
	}
	if !f.manager.Activate(s) {
		t.Fatal("activation failed")
	}
	return s
}
func snapshot(t *testing.T, s *Session, sequence int64, title string) (wire.Snapshot, [32]byte) {
	t.Helper()
	sources := wire.Sources{}
	if title != "" {
		sources.Window = &wire.Window{Title: title}
	}
	data, err := json.Marshal(wire.Snapshot{ProtocolVersion: 1, Type: "snapshot", ConnectionID: s.ID, Sequence: sequence, ObservedAt: "2099-01-01T00:00:00Z", Sources: sources})
	if err != nil {
		t.Fatal(err)
	}
	parsed, fingerprint, err := wire.ParseSnapshot(data)
	if err != nil {
		t.Fatal(err)
	}
	return parsed, fingerprint
}
func (f *fixture) submit(t *testing.T, s *Session, seq int64, title string) (wire.Ack, bool) {
	t.Helper()
	value, hash := snapshot(t, s, seq, title)
	return f.manager.Submit(s, value, hash)
}
func (f *fixture) read(t *testing.T) Projection {
	t.Helper()
	value, _, err := f.manager.Read(context.Background(), f.owner)
	if err != nil {
		t.Fatal(err)
	}
	return value
}

func TestCandidateDoesNotTakeOverAndOldCleanupCannotClearNewState(t *testing.T) {
	f := setup(t)
	first := f.connect(t)
	if _, ok := f.submit(t, first, 1, "旧窗口"); !ok {
		t.Fatal("first snapshot rejected")
	}
	probe := f.connect(t)
	f.manager.Disconnect(probe)
	if got := f.read(t).Devices[0]; !got.Online || got.Sources.Window.Title != "旧窗口" {
		t.Fatal("probe cleared current writer")
	}
	bad := f.connect(t)
	if _, ok := f.submit(t, bad, 2, "错误候选"); ok {
		t.Fatal("candidate skipped first sequence")
	}
	if got := f.read(t).Devices[0]; !got.Online || got.Sources.Window.Title != "旧窗口" {
		t.Fatal("invalid candidate changed current state")
	}
	replacement := f.connect(t)
	if _, ok := f.submit(t, replacement, 1, "新窗口"); !ok {
		t.Fatal("replacement rejected")
	}
	if end := first.Termination(); end.CloseCode != 4002 {
		t.Fatal("old writer not isolated")
	}
	f.manager.Disconnect(first)
	if _, ok := f.submit(t, first, 2, "迟到窗口"); ok {
		t.Fatal("old writer accepted")
	}
	if got := f.read(t).Devices[0]; !got.Online || got.Sources.Window.Title != "新窗口" {
		t.Fatal("old writer changed new state")
	}
}

func TestDuplicateCannotExtendLeaseAndExpiredConnectionCannotRevive(t *testing.T) {
	f := setup(t)
	s := f.connect(t)
	ack, ok := f.submit(t, s, 1, "原窗口")
	if !ok || ack.ReceivedAt != "2026-10-25T12:00:00.000Z" || ack.ExpiresAt != "2026-10-25T12:00:45.000Z" {
		t.Fatal("incorrect receiver lease")
	}
	f.now = f.now.Add(44 * time.Second)
	duplicate, ok := f.submit(t, s, 1, "原窗口")
	if !ok || duplicate != ack {
		t.Fatal("duplicate changed ACK")
	}
	f.now = f.now.Add(time.Second)
	if got := f.read(t).Devices[0]; got.Online || got.Sources.Window != nil || got.UpdatedAt != nil || got.ExpiresAt != nil {
		t.Fatal("read exposed expired snapshot")
	}
	if _, ok := f.submit(t, s, 2, "迟到窗口"); ok {
		t.Fatal("expired connection revived")
	}
	if s.Termination().CloseCode != 4003 {
		t.Fatal("wrong expiry close")
	}
}

func TestSubmitChecksExpiryWithoutSchedulerOrRead(t *testing.T) {
	f := setup(t)
	s := f.connect(t)
	f.submit(t, s, 1, "原窗口")
	f.now = f.now.Add(wire.Lease)
	if _, ok := f.submit(t, s, 2, "迟到窗口"); ok {
		t.Fatal("submit renewed expired lease")
	}
	if f.read(t).Devices[0].Online {
		t.Fatal("expired writer still online")
	}
}

func TestInitialDeadlineAndSweepDoNotClearHealthyWriter(t *testing.T) {
	f := setup(t)
	current := f.connect(t)
	f.submit(t, current, 1, "原窗口")
	candidate := f.connect(t)
	f.now = f.now.Add(wire.InitialTimeout)
	f.manager.Sweep()
	if candidate.Termination().CloseCode != 4003 {
		t.Fatal("candidate survived deadline")
	}
	if _, ok := f.submit(t, candidate, 1, "迟到候选"); ok {
		t.Fatal("expired candidate revived")
	}
	if !f.read(t).Devices[0].Online {
		t.Fatal("candidate expiry cleared healthy writer")
	}
}

func TestSequenceFailuresClearOnlyCurrentWriter(t *testing.T) {
	for _, test := range []struct {
		name     string
		sequence int64
		title    string
		code     string
	}{
		{"conflict", 1, "改写", "sequence_conflict"}, {"gap", 3, "原窗口", "out_of_order"},
	} {
		t.Run(test.name, func(t *testing.T) {
			f := setup(t)
			s := f.connect(t)
			f.submit(t, s, 1, "原窗口")
			if _, ok := f.submit(t, s, test.sequence, test.title); ok {
				t.Fatal("invalid ordering accepted")
			}
			if s.Termination().Code != test.code {
				t.Fatal("wrong error code")
			}
			if f.read(t).Devices[0].Online {
				t.Fatal("rejected writer retained presence")
			}
		})
	}
}

func TestFullReplacementAllowsOnlineEmptyState(t *testing.T) {
	f := setup(t)
	s := f.connect(t)
	f.submit(t, s, 1, "原窗口")
	f.submit(t, s, 2, "")
	got := f.read(t).Devices[0]
	if !got.Online || got.Sources != (wire.Sources{}) {
		t.Fatal("null snapshot did not replace all sources")
	}
	f.manager.Disconnect(s)
	if f.read(t).Devices[0].Online {
		t.Fatal("disconnect did not clear immediately")
	}
}

func TestRevocationIsAtomicWithCandidateRegistration(t *testing.T) {
	f := setup(t)
	current := f.connect(t)
	f.submit(t, current, 1, "原窗口")
	candidate, err := f.manager.Register(context.Background(), f.token)
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for range 24 {
		wg.Go(func() {
			s, err := f.manager.Register(context.Background(), f.token)
			if err == nil {
				f.manager.Activate(s)
			} else if !errors.Is(err, Unauthorized) {
				t.Error(err)
			}
		})
	}
	if err := f.manager.Revoke(context.Background(), f.owner, f.device.ID); err != nil {
		t.Fatal(err)
	}
	wg.Wait()
	if f.manager.Activate(candidate) {
		t.Fatal("revoked candidate activated after upgrade")
	}
	if current.Termination().CloseCode != 4001 || candidate.Termination().CloseCode != 4001 {
		t.Fatal("revocation failed to terminate all candidates")
	}
	if _, err := f.manager.Register(context.Background(), f.token); !errors.Is(err, Unauthorized) {
		t.Fatal("revoked token registered again")
	}
	if len(f.read(t).Devices) != 0 {
		t.Fatal("revoked device still public")
	}
}

func TestPublicPermissionAndDevicePrivilegeSeparation(t *testing.T) {
	f := setup(t)
	if _, _, err := f.manager.Read(context.Background(), ""); !errors.Is(err, Forbidden) {
		t.Fatal("anonymous read enabled by default")
	}
	if _, err := f.manager.Settings(context.Background(), f.token); !errors.Is(err, Forbidden) {
		t.Fatal("device token managed settings")
	}
	if _, err := f.manager.Register(context.Background(), f.owner); !errors.Is(err, Forbidden) {
		t.Fatal("owner token used as device")
	}
	if err := f.manager.UpdateSettings(context.Background(), f.owner, storage.Settings{PublicReadEnabled: true, AllowedOrigins: []string{}}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := f.manager.Read(context.Background(), ""); err != nil {
		t.Fatal("explicit public read failed")
	}
}
