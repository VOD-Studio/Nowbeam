package presence

import (
	"context"
	"errors"
	"sync"
	"time"

	"nowbeam.local/receiver/internal/storage"
	"nowbeam.local/receiver/internal/wire"
)

type Fault string

func (f Fault) Error() string { return string(f) }

const (
	Unauthorized Fault = "unauthorized"
	Forbidden    Fault = "forbidden"
	Unavailable  Fault = "unavailable"
)

type Manager struct {
	mu          sync.Mutex
	store       *storage.Store
	now         func() time.Time
	bootstrap   [32]byte
	initialized bool
	closed      bool
	sessions    map[string]*Session
	current     map[string]*Session
}

// 所有持久化授权变更与连接注册共用同一把锁，撤销提交后不可能注册旧凭证。
func New(store *storage.Store, bootstrap string, now func() time.Time) (*Manager, error) {
	initialized, err := store.Initialized(context.Background())
	if err != nil {
		return nil, err
	}
	if !initialized && len(bootstrap) < 32 {
		return nil, errors.New("bootstrap token must contain at least 32 random characters")
	}
	if now == nil {
		now = time.Now
	}
	m := &Manager{store: store, now: now, initialized: initialized, sessions: make(map[string]*Session), current: make(map[string]*Session)}
	if !initialized {
		m.bootstrap = storage.Hash(bootstrap)
	}
	return m, nil
}

func (m *Manager) Setup(ctx context.Context, token string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return "", Unavailable
	}
	if m.initialized {
		return "", storage.ErrInitialized
	}
	if !storage.EqualHash(m.bootstrap[:], token) {
		return "", Unauthorized
	}
	owner := storage.NewToken()
	if err := m.store.Setup(ctx, owner); err != nil {
		return "", err
	}
	m.initialized = true
	m.bootstrap = [32]byte{}
	return owner, nil
}

func (m *Manager) requireOwner(ctx context.Context, token string) error {
	if m.closed {
		return Unavailable
	}
	owner, err := m.store.Owner(ctx, token)
	if err != nil {
		return err
	}
	if owner {
		return nil
	}
	_, device, err := m.store.DeviceForToken(ctx, token)
	if err != nil {
		return err
	}
	if device {
		return Forbidden
	}
	return Unauthorized
}

func (m *Manager) Settings(ctx context.Context, token string) (storage.Settings, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.requireOwner(ctx, token); err != nil {
		return storage.Settings{}, err
	}
	return m.store.Settings(ctx)
}
func (m *Manager) UpdateSettings(ctx context.Context, token string, settings storage.Settings) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.requireOwner(ctx, token); err != nil {
		return err
	}
	return m.store.UpdateSettings(ctx, settings)
}
func (m *Manager) Devices(ctx context.Context, token string) ([]storage.Device, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.requireOwner(ctx, token); err != nil {
		return nil, err
	}
	return m.store.Devices(ctx)
}
func (m *Manager) CreateDevice(ctx context.Context, token, name string) (storage.Device, string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.requireOwner(ctx, token); err != nil {
		return storage.Device{}, "", err
	}
	d := storage.Device{ID: wire.NewID(), DisplayName: name, CreatedAt: wire.Time(m.now())}
	secret := storage.NewToken()
	err := m.store.CreateDevice(ctx, d, secret)
	return d, secret, err
}
func (m *Manager) Revoke(ctx context.Context, token, deviceID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.requireOwner(ctx, token); err != nil {
		return err
	}
	if err := m.store.DeleteDevice(ctx, deviceID); err != nil {
		return err
	}
	for _, session := range m.sessions {
		if session.DeviceID == deviceID {
			m.stop(session, 4001, "credential_revoked", nil)
		}
	}
	return nil
}

func (m *Manager) Register(ctx context.Context, token string) (*Session, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return nil, Unavailable
	}
	device, valid, err := m.store.DeviceForToken(ctx, token)
	if err != nil {
		return nil, err
	}
	if !valid {
		owner, err := m.store.Owner(ctx, token)
		if err != nil {
			return nil, err
		}
		if owner {
			return nil, Forbidden
		}
		return nil, Unauthorized
	}
	s := &Session{ID: wire.NewID(), DeviceID: device.ID, done: make(chan struct{})}
	m.sessions[s.ID] = s
	return s, nil
}

// Activate 在 welcome 成功写出之后启动首次快照期限，不授予写入权。
func (m *Manager) Activate(s *Session) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.sessions[s.ID] != s || s.ended {
		return false
	}
	if !s.started {
		s.started = true
		s.deadline = m.now().Add(wire.InitialTimeout)
	}
	return true
}

func (m *Manager) Shutdown() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.closed = true
	for _, s := range m.sessions {
		m.stop(s, 1001, "going_away", nil)
	}
}
