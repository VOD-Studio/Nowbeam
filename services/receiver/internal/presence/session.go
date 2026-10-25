package presence

import (
	"context"
	"time"

	"nowbeam.local/receiver/internal/storage"
	"nowbeam.local/receiver/internal/wire"
)

type Termination struct {
	CloseCode int
	Code      string
	Sequence  *int64
}
type Session struct {
	ID          string
	DeviceID    string
	done        chan struct{}
	termination Termination
	started     bool
	ended       bool
	accepted    bool
	deadline    time.Time
	sequence    int64
	fingerprint [32]byte
	ack         wire.Ack
	sources     wire.Sources
}

func (s *Session) Done() <-chan struct{} { return s.done }

// 只有 Done 关闭后才读取终止结果；channel 为这些不可变值提供同步。
func (s *Session) Termination() Termination { <-s.done; return s.termination }

func (m *Manager) stop(s *Session, code int, reason string, sequence *int64) {
	if s.ended {
		return
	}
	s.ended = true
	s.termination = Termination{code, reason, sequence}
	if m.current[s.DeviceID] == s {
		delete(m.current, s.DeviceID)
	}
	delete(m.sessions, s.ID)
	s.sources = wire.Sources{}
	close(s.done)
}

func (m *Manager) Disconnect(s *Session) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.stop(s, 1000, "normal_closure", nil)
}
func (m *Manager) Reject(s *Session, closeCode int, reason string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.stop(s, closeCode, reason, nil)
}

func (m *Manager) Submit(s *Session, snapshot wire.Snapshot, fingerprint [32]byte) (wire.Ack, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if s.ended || m.sessions[s.ID] != s {
		return wire.Ack{}, false
	}
	now := m.now()
	if !s.started || !now.Before(s.deadline) {
		m.stop(s, 4003, "session_expired", nil)
		return wire.Ack{}, false
	}
	sequence := snapshot.Sequence
	if snapshot.ConnectionID != s.ID {
		m.stop(s, 1008, "invalid_message", &sequence)
		return wire.Ack{}, false
	}
	if s.accepted {
		if m.current[s.DeviceID] != s {
			m.stop(s, 4002, "session_replaced", &sequence)
			return wire.Ack{}, false
		}
		if sequence == s.sequence {
			if fingerprint == s.fingerprint {
				return s.ack, true
			}
			m.stop(s, 1008, "sequence_conflict", &sequence)
			return wire.Ack{}, false
		}
		if sequence != s.sequence+1 {
			m.stop(s, 1008, "out_of_order", &sequence)
			return wire.Ack{}, false
		}
	} else {
		if sequence != 1 {
			m.stop(s, 1008, "out_of_order", &sequence)
			return wire.Ack{}, false
		}
		if previous := m.current[s.DeviceID]; previous != nil {
			m.stop(previous, 4002, "session_replaced", nil)
		}
		s.accepted = true
		m.current[s.DeviceID] = s
	}
	s.sequence = sequence
	s.fingerprint = fingerprint
	s.sources = snapshot.Sources
	s.deadline = now.Add(wire.Lease)
	s.ack = wire.Ack{ProtocolVersion: 1, Type: "ack", ConnectionID: s.ID, Sequence: sequence, ReceivedAt: wire.Time(now), ExpiresAt: wire.Time(s.deadline)}
	return s.ack, true
}

func (m *Manager) expire(now time.Time) {
	for _, s := range m.sessions {
		if s.started && !now.Before(s.deadline) {
			m.stop(s, 4003, "session_expired", nil)
		}
	}
}
func (m *Manager) Sweep() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.expire(m.now())
}
func (m *Manager) Run(ctx context.Context) {
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			m.Sweep()
		}
	}
}

type DevicePresence struct {
	DeviceID    string       `json:"deviceId"`
	DisplayName string       `json:"displayName"`
	Online      bool         `json:"online"`
	UpdatedAt   *string      `json:"updatedAt"`
	ExpiresAt   *string      `json:"expiresAt"`
	Sources     wire.Sources `json:"sources"`
}
type Projection struct {
	GeneratedAt string           `json:"generatedAt"`
	Devices     []DevicePresence `json:"devices"`
}

// Read 同步检查租约，不依赖调度器是否已经执行；公开授权与投影在同一锁内。
func (m *Manager) Read(ctx context.Context, ownerToken string) (Projection, storage.Settings, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return Projection{}, storage.Settings{}, Unavailable
	}
	settings, err := m.store.Settings(ctx)
	if err != nil {
		return Projection{}, settings, err
	}
	if !settings.PublicReadEnabled {
		owner, err := m.store.Owner(ctx, ownerToken)
		if err != nil {
			return Projection{}, settings, err
		}
		if !owner {
			return Projection{}, settings, Forbidden
		}
	}
	devices, err := m.store.Devices(ctx)
	if err != nil {
		return Projection{}, settings, err
	}
	now := m.now()
	m.expire(now)
	projection := Projection{GeneratedAt: wire.Time(now), Devices: make([]DevicePresence, 0, len(devices))}
	for _, d := range devices {
		p := DevicePresence{DeviceID: d.ID, DisplayName: d.DisplayName}
		if s := m.current[d.ID]; s != nil {
			p.Online = true
			received, expires := s.ack.ReceivedAt, s.ack.ExpiresAt
			p.UpdatedAt, p.ExpiresAt, p.Sources = &received, &expires, s.sources
		}
		projection.Devices = append(projection.Devices, p)
	}
	return projection, settings, nil
}

func (m *Manager) PublicSettings(ctx context.Context) (storage.Settings, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.store.Settings(ctx)
}
