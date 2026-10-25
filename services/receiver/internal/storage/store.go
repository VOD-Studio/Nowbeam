package storage

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"syscall"

	_ "modernc.org/sqlite"
)

var ErrInitialized = errors.New("already_initialized")
var ErrNotFound = errors.New("not_found")

type Settings struct {
	PublicReadEnabled bool     `json:"publicReadEnabled"`
	AllowedOrigins    []string `json:"allowedOrigins"`
}
type Device struct {
	ID          string `json:"id"`
	DisplayName string `json:"displayName"`
	CreatedAt   string `json:"createdAt"`
}
type Store struct {
	db   *sql.DB
	lock *os.File
}

func Open(path string) (*Store, error) {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return nil, err
	}
	dir := filepath.Dir(absolute)
	if err = os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	info, err := os.Lstat(dir)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return nil, errors.New("database directory must be private (0700)")
	}
	lock, err := privateFile(absolute + ".lock")
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = lock.Close()
		return nil, errors.New("database already in use")
	}
	file, err := privateFile(absolute)
	if err != nil {
		_ = lock.Close()
		return nil, err
	}
	_ = file.Close()
	u := url.URL{Scheme: "file", Path: absolute}
	q := u.Query()
	q.Add("_pragma", "busy_timeout(5000)")
	q.Add("_pragma", "foreign_keys(1)")
	q.Add("_pragma", "journal_mode(DELETE)")
	u.RawQuery = q.Encode()
	db, err := sql.Open("sqlite", u.String())
	if err != nil {
		_ = lock.Close()
		return nil, err
	}
	db.SetMaxOpenConns(1)
	s := &Store{db: db, lock: lock}
	_, err = db.Exec(`CREATE TABLE IF NOT EXISTS instance (
		id INTEGER PRIMARY KEY CHECK (id = 1),
		owner_hash BLOB NOT NULL CHECK (length(owner_hash) = 32),
		public_read INTEGER NOT NULL DEFAULT 0,
		origins TEXT NOT NULL DEFAULT '[]'
	);
	CREATE TABLE IF NOT EXISTS devices (
		id TEXT PRIMARY KEY,
		display_name TEXT NOT NULL,
		created_at TEXT NOT NULL,
		token_hash BLOB NOT NULL UNIQUE CHECK (length(token_hash) = 32)
	);`)
	if err != nil {
		_ = s.Close()
		return nil, err
	}
	return s, nil
}

func privateFile(path string) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, err
	}
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() {
		_ = f.Close()
		return nil, errors.New("database path must be a regular file")
	}
	if err = f.Chmod(0600); err != nil {
		_ = f.Close()
		return nil, err
	}
	return f, nil
}

func (s *Store) Close() error {
	err := s.db.Close()
	if lockErr := s.lock.Close(); err == nil {
		err = lockErr
	}
	return err
}

func NewToken() string {
	var b [32]byte
	_, _ = rand.Read(b[:])
	return base64.RawURLEncoding.EncodeToString(b[:])
}
func Hash(token string) [32]byte { return sha256.Sum256([]byte(token)) }
func EqualHash(stored []byte, token string) bool {
	hash := Hash(token)
	return subtle.ConstantTimeCompare(stored, hash[:]) == 1
}

func (s *Store) Initialized(ctx context.Context) (bool, error) {
	var count int
	err := s.db.QueryRowContext(ctx, "SELECT count(*) FROM instance").Scan(&count)
	return count == 1, err
}
func (s *Store) Setup(ctx context.Context, token string) error {
	hash := Hash(token)
	result, err := s.db.ExecContext(ctx, "INSERT OR IGNORE INTO instance (id, owner_hash) VALUES (1, ?)", hash[:])
	if err != nil {
		return err
	}
	n, err := result.RowsAffected()
	if err == nil && n == 0 {
		return ErrInitialized
	}
	return err
}
func (s *Store) Owner(ctx context.Context, token string) (bool, error) {
	var hash []byte
	err := s.db.QueryRowContext(ctx, "SELECT owner_hash FROM instance WHERE id = 1").Scan(&hash)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return EqualHash(hash, token), nil
}
func (s *Store) DeviceForToken(ctx context.Context, token string) (Device, bool, error) {
	hash := Hash(token)
	var stored []byte
	var device Device
	err := s.db.QueryRowContext(ctx, "SELECT id, display_name, created_at, token_hash FROM devices WHERE token_hash = ?", hash[:]).Scan(&device.ID, &device.DisplayName, &device.CreatedAt, &stored)
	if errors.Is(err, sql.ErrNoRows) {
		return device, false, nil
	}
	if err != nil {
		return device, false, err
	}
	return device, EqualHash(stored, token), nil
}
func (s *Store) Devices(ctx context.Context) ([]Device, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT id, display_name, created_at FROM devices ORDER BY created_at, id")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	devices := make([]Device, 0)
	for rows.Next() {
		var d Device
		if err = rows.Scan(&d.ID, &d.DisplayName, &d.CreatedAt); err != nil {
			return nil, err
		}
		devices = append(devices, d)
	}
	return devices, rows.Err()
}
func (s *Store) CreateDevice(ctx context.Context, d Device, token string) error {
	hash := Hash(token)
	_, err := s.db.ExecContext(ctx, "INSERT INTO devices (id, display_name, created_at, token_hash) VALUES (?, ?, ?, ?)", d.ID, d.DisplayName, d.CreatedAt, hash[:])
	return err
}
func (s *Store) DeleteDevice(ctx context.Context, id string) error {
	result, err := s.db.ExecContext(ctx, "DELETE FROM devices WHERE id = ?", id)
	if err != nil {
		return err
	}
	n, err := result.RowsAffected()
	if err == nil && n == 0 {
		return ErrNotFound
	}
	return err
}
func (s *Store) Settings(ctx context.Context) (Settings, error) {
	settings := Settings{AllowedOrigins: []string{}}
	var origins string
	err := s.db.QueryRowContext(ctx, "SELECT public_read, origins FROM instance WHERE id = 1").Scan(&settings.PublicReadEnabled, &origins)
	if errors.Is(err, sql.ErrNoRows) {
		return settings, nil
	}
	if err != nil {
		return settings, err
	}
	err = json.Unmarshal([]byte(origins), &settings.AllowedOrigins)
	return settings, err
}
func (s *Store) UpdateSettings(ctx context.Context, settings Settings) error {
	origins, err := json.Marshal(settings.AllowedOrigins)
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, "UPDATE instance SET public_read = ?, origins = ? WHERE id = 1", settings.PublicReadEnabled, string(origins))
	return err
}
