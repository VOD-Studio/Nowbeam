package wire

import (
	"crypto/sha256"
	"encoding/json"
)

func ParseSnapshot(data []byte) (Snapshot, [32]byte, error) {
	var snapshot Snapshot
	var empty [32]byte
	if len(data) > MaxMessageBytes {
		return snapshot, empty, ErrInvalid
	}
	v, err := DecodeObject(data)
	if err != nil {
		return snapshot, empty, err
	}
	m, ok := Object(v, "protocolVersion", "type", "connectionId", "sequence", "observedAt", "sources")
	if !ok {
		return snapshot, empty, ErrInvalid
	}
	version, ok := Integer(m["protocolVersion"], 1, 1)
	if !ok || m["type"] != "snapshot" {
		return snapshot, empty, ErrInvalid
	}
	id, ok := m["connectionId"].(string)
	if !ok || !ValidID(id) {
		return snapshot, empty, ErrInvalid
	}
	sequence, ok := Integer(m["sequence"], 1, MaxSequence)
	if !ok {
		return snapshot, empty, ErrInvalid
	}
	observed, ok := m["observedAt"].(string)
	if !ok || !ValidTime(observed) {
		return snapshot, empty, ErrInvalid
	}
	sources, ok := parseSources(m["sources"])
	if !ok {
		return snapshot, empty, ErrInvalid
	}
	snapshot = Snapshot{int(version), "snapshot", id, sequence, observed, sources}
	canonical, err := json.Marshal(snapshot)
	if err != nil {
		return Snapshot{}, empty, ErrInvalid
	}
	return snapshot, sha256.Sum256(canonical), nil
}

func parseSources(v any) (Sources, bool) {
	var sources Sources
	m, ok := Object(v, "application", "window", "media")
	if !ok {
		return sources, false
	}
	if m["application"] != nil {
		a, ok := Object(m["application"], "displayName")
		if !ok {
			return sources, false
		}
		name, ok := Text(a["displayName"], 128)
		if !ok {
			return sources, false
		}
		sources.Application = &Application{name}
	}
	if m["window"] != nil {
		w, ok := Object(m["window"], "title")
		if !ok {
			return sources, false
		}
		title, ok := Text(w["title"], 1024)
		if !ok {
			return sources, false
		}
		sources.Window = &Window{title}
	}
	if m["media"] != nil {
		media, ok := parseMedia(m["media"])
		if !ok {
			return sources, false
		}
		sources.Media = &media
	}
	return sources, true
}

func nullableText(v any) (*string, bool) {
	if v == nil {
		return nil, true
	}
	s, ok := Text(v, 512)
	return &s, ok
}
func nullableInteger(v any, min int64) (*int64, bool) {
	if v == nil {
		return nil, true
	}
	n, ok := Integer(v, min, MaxSequence)
	return &n, ok
}

func parseMedia(v any) (Media, bool) {
	var media Media
	m, ok := Object(v, "sessionId", "playerName", "title", "artist", "album", "playback")
	if !ok {
		return media, false
	}
	media.SessionID, ok = m["sessionId"].(string)
	if !ok || !ValidID(media.SessionID) {
		return media, false
	}
	media.PlayerName, ok = Text(m["playerName"], 128)
	if !ok {
		return media, false
	}
	media.Title, ok = Text(m["title"], 512)
	if !ok {
		return media, false
	}
	media.Artist, ok = nullableText(m["artist"])
	if !ok {
		return media, false
	}
	media.Album, ok = nullableText(m["album"])
	if !ok {
		return media, false
	}
	media.Playback, ok = parsePlayback(m["playback"])
	return media, ok
}

func parsePlayback(v any) (Playback, bool) {
	var playback Playback
	m, ok := Object(v, "state", "durationMs", "positionMs", "rate")
	if !ok {
		return playback, false
	}
	playback.State, ok = m["state"].(string)
	if !ok || (playback.State != "playing" && playback.State != "paused") {
		return playback, false
	}
	playback.DurationMS, ok = nullableInteger(m["durationMs"], 1)
	if !ok {
		return playback, false
	}
	playback.PositionMS, ok = nullableInteger(m["positionMs"], 0)
	if !ok {
		return playback, false
	}
	if playback.DurationMS != nil && playback.PositionMS != nil && *playback.PositionMS > *playback.DurationMS {
		return playback, false
	}
	if m["rate"] != nil {
		rate, ok := parseRate(m["rate"])
		if !ok {
			return playback, false
		}
		playback.Rate = &rate
	}
	if playback.State == "paused" {
		return playback, playback.Rate != nil && *playback.Rate == "0"
	}
	return playback, playback.Rate == nil || *playback.Rate != "0"
}
