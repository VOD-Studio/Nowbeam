package wire

import (
	"encoding/json"
	"strings"
	"testing"
)

const sample = `{"protocolVersion":1,"type":"snapshot","connectionId":"01234567-89ab-4cde-8fab-0123456789ab","sequence":1,"observedAt":"2026-10-25T12:30:00.123Z","sources":{"application":{"displayName":"示例应用"},"window":{"title":"示例窗口"},"media":{"sessionId":"11234567-89ab-4cde-8fab-0123456789ab","playerName":"示例播放器","title":"虚构曲目","artist":null,"album":null,"playback":{"state":"playing","durationMs":10000,"positionMs":500,"rate":1}}}}`

func TestSnapshotRejectsAmbiguousAndInvalidJSON(t *testing.T) {
	cases := map[string]string{
		"duplicate":                 strings.Replace(sample, `"sequence":1`, `"sequence":1,"sequence":1`, 1),
		"escaped duplicate":         strings.Replace(sample, `"sequence":1`, `"sequence":1,"sequen\u0063e":1`, 1),
		"unknown":                   strings.Replace(sample, `"sequence":1`, `"sequence":1,"secret":"x"`, 1),
		"case insensitive key":      strings.Replace(sample, `"sequence"`, `"Sequence"`, 1),
		"nested unknown":            strings.Replace(sample, `"displayName":"示例应用"`, `"displayName":"示例应用","pid":1`, 1),
		"missing source":            strings.Replace(sample, `"application":{"displayName":"示例应用"},`, "", 1),
		"null sources":              strings.Replace(sample, `"sources":`, `"sources":null,"ignored":`, 1),
		"null scalar":               strings.Replace(sample, `"sequence":1`, `"sequence":null`, 1),
		"unsafe integer":            strings.Replace(sample, `"sequence":1`, `"sequence":9007199254740992`, 1),
		"rounded integer":           strings.Replace(sample, `"sequence":1`, `"sequence":9007199254740991.1`, 1),
		"fraction":                  strings.Replace(sample, `"sequence":1`, `"sequence":1.1`, 1),
		"NaN":                       strings.Replace(sample, `"rate":1`, `"rate":NaN`, 1),
		"infinity":                  strings.Replace(sample, `"rate":1`, `"rate":1e999`, 1),
		"rounded upper rate":        strings.Replace(sample, `"rate":1`, `"rate":4.000000000000000001`, 1),
		"negative rate":             strings.Replace(sample, `"rate":1`, `"rate":-0.00000001`, 1),
		"playing zero":              strings.Replace(sample, `"rate":1`, `"rate":0`, 1),
		"paused nonzero":            strings.Replace(sample, `"state":"playing"`, `"state":"paused"`, 1),
		"position exceeds duration": strings.Replace(sample, `"positionMs":500`, `"positionMs":10001`, 1),
		"missing artist":            strings.Replace(sample, `"artist":null,`, "", 1),
		"zero duration":             strings.Replace(sample, `"durationMs":10000`, `"durationMs":0`, 1),
		"bad UUID":                  strings.Replace(sample, "01234567-89ab-4cde", "01234567-89ab-1cde", 1),
		"timezone offset":           strings.Replace(sample, "12:30:00.123Z", "12:30:00+00:00", 1),
		"invalid calendar":          strings.Replace(sample, "2026-10-25", "2026-02-30", 1),
		"leap second":               strings.Replace(sample, "12:30:00.123Z", "12:30:60Z", 1),
		"too many milliseconds":     strings.Replace(sample, ".123Z", ".1234Z", 1),
		"control text":              strings.Replace(sample, "示例应用", `hello\nworld`, 1),
		"blank text":                strings.Replace(sample, "示例应用", "  ", 1),
		"long text":                 strings.Replace(sample, "示例应用", strings.Repeat("字", 129), 1),
		"surrogate high":            strings.Replace(sample, "示例应用", `\ud800`, 1),
		"surrogate low":             strings.Replace(sample, "示例应用", `\udc00`, 1),
		"surrogate pair reversed":   strings.Replace(sample, "示例应用", `\udc00\ud800`, 1),
		"invalid UTF8":              strings.Replace(sample, "示例应用", string([]byte{0xff}), 1),
		"trailing JSON":             sample + `{}`,
		"too large":                 sample + strings.Repeat(" ", MaxMessageBytes),
	}
	for name, data := range cases {
		t.Run(name, func(t *testing.T) {
			if _, _, err := ParseSnapshot([]byte(data)); err == nil {
				t.Fatal("invalid snapshot accepted")
			}
		})
	}
}

func TestEveryRequiredFieldAndNullBoundary(t *testing.T) {
	paths := [][]string{
		{}, {"sources"}, {"sources", "application"}, {"sources", "window"},
		{"sources", "media"}, {"sources", "media", "playback"},
	}
	for _, path := range paths {
		original, err := DecodeObject([]byte(sample))
		if err != nil {
			t.Fatal(err)
		}
		object := original
		for _, part := range path {
			object = object[part].(map[string]any)
		}
		for key := range object {
			t.Run(strings.Join(append(append([]string{}, path...), key), "/"), func(t *testing.T) {
				copy, _ := DecodeObject([]byte(sample))
				at := copy
				for _, part := range path {
					at = at[part].(map[string]any)
				}
				delete(at, key)
				data, _ := json.Marshal(copy)
				if _, _, err := ParseSnapshot(data); err == nil {
					t.Fatal("missing field accepted")
				}
				at[key] = nil
				data, _ = json.Marshal(copy)
				nullable := (len(path) == 1 && path[0] == "sources") || (len(path) == 2 && path[1] == "media" && (key == "artist" || key == "album")) || (len(path) == 3 && (key == "rate" || key == "positionMs" || key == "durationMs"))
				_, _, err = ParseSnapshot(data)
				if (err == nil) != nullable {
					t.Fatalf("wrong nullability for field %s", key)
				}
			})
		}
	}
}

func TestCanonicalFingerprintAndUnicodeLength(t *testing.T) {
	_, expected, err := ParseSnapshot([]byte(sample))
	if err != nil {
		t.Fatal(err)
	}
	object, _ := DecodeObject([]byte(sample))
	reordered, _ := json.MarshalIndent(object, "", "  ")
	data := strings.Replace(string(reordered), `"rate": 1`, `"rate": 10e-1`, 1)
	data = strings.Replace(data, `"sequence": 1`, `"sequence": 1.0`, 1)
	_, actual, err := ParseSnapshot([]byte(data))
	if err != nil || actual != expected {
		t.Fatal("semantic duplicate changed fingerprint")
	}
	for _, text := range []string{strings.Repeat("😀", 128), `\ud83d\ude00`, `literal\\ud800`} {
		if _, _, err := ParseSnapshot([]byte(strings.Replace(sample, "示例应用", text, 1))); err != nil {
			t.Fatal("valid unicode text rejected")
		}
	}
	for _, rate := range []string{"null", "4", "1e-1000"} {
		if _, _, err := ParseSnapshot([]byte(strings.Replace(sample, `"rate":1`, `"rate":`+rate, 1))); err != nil {
			t.Fatal("valid playback rate rejected")
		}
	}
}
