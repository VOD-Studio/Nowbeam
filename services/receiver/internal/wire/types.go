package wire

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"regexp"
	"time"
)

const (
	MaxMessageBytes       = 65536
	MaxSequence     int64 = 9007199254740991
	Lease                 = 45 * time.Second
	InitialTimeout        = 10 * time.Second
)

var uuidPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
var timestampPattern = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-5][0-9](\.[0-9]{1,3})?Z$`)

func ValidID(s string) bool { return uuidPattern.MatchString(s) }

func NewID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:])
}

func Time(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05.000Z") }

func ValidTime(s string) bool {
	if !timestampPattern.MatchString(s) {
		return false
	}
	parsed, err := time.Parse(time.RFC3339Nano, s)
	return err == nil && parsed.Year() > 0
}

type Application struct {
	DisplayName string `json:"displayName"`
}
type Window struct {
	Title string `json:"title"`
}
type Playback struct {
	State      string       `json:"state"`
	DurationMS *int64       `json:"durationMs"`
	PositionMS *int64       `json:"positionMs"`
	Rate       *json.Number `json:"rate"`
}
type Media struct {
	SessionID  string   `json:"sessionId"`
	PlayerName string   `json:"playerName"`
	Title      string   `json:"title"`
	Artist     *string  `json:"artist"`
	Album      *string  `json:"album"`
	Playback   Playback `json:"playback"`
}
type Sources struct {
	Application *Application `json:"application"`
	Window      *Window      `json:"window"`
	Media       *Media       `json:"media"`
}
type Snapshot struct {
	ProtocolVersion int     `json:"protocolVersion"`
	Type            string  `json:"type"`
	ConnectionID    string  `json:"connectionId"`
	Sequence        int64   `json:"sequence"`
	ObservedAt      string  `json:"observedAt"`
	Sources         Sources `json:"sources"`
}
type Welcome struct {
	ProtocolVersion     int    `json:"protocolVersion"`
	Type                string `json:"type"`
	ConnectionID        string `json:"connectionId"`
	DeviceID            string `json:"deviceId"`
	ServerTime          string `json:"serverTime"`
	HeartbeatIntervalMS int    `json:"heartbeatIntervalMs"`
	LeaseDurationMS     int    `json:"leaseDurationMs"`
	MaxMessageBytes     int    `json:"maxMessageBytes"`
}

func NewWelcome(connectionID, deviceID string, now time.Time) Welcome {
	return Welcome{1, "welcome", connectionID, deviceID, Time(now), 15000, 45000, MaxMessageBytes}
}

type Ack struct {
	ProtocolVersion int    `json:"protocolVersion"`
	Type            string `json:"type"`
	ConnectionID    string `json:"connectionId"`
	Sequence        int64  `json:"sequence"`
	ReceivedAt      string `json:"receivedAt"`
	ExpiresAt       string `json:"expiresAt"`
}
type Error struct {
	ProtocolVersion int    `json:"protocolVersion"`
	Type            string `json:"type"`
	ConnectionID    string `json:"connectionId"`
	Sequence        *int64 `json:"sequence"`
	Code            string `json:"code"`
}
