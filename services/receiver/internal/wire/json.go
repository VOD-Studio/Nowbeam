package wire

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"math"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

var ErrInvalid = errors.New("invalid_message")

// DecodeObject 保留数字原文，拒绝重复键、孤立代理码点和过深嵌套。
func DecodeObject(data []byte) (map[string]any, error) {
	if !utf8.Valid(data) || !validEscapes(data) {
		return nil, ErrInvalid
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	v, err := decodeValue(d, 0)
	if err != nil {
		return nil, ErrInvalid
	}
	if _, err = d.Token(); err != io.EOF {
		return nil, ErrInvalid
	}
	m, ok := v.(map[string]any)
	if !ok {
		return nil, ErrInvalid
	}
	return m, nil
}

func decodeValue(d *json.Decoder, depth int) (any, error) {
	if depth > 16 {
		return nil, ErrInvalid
	}
	t, err := d.Token()
	if err != nil {
		return nil, err
	}
	if delim, ok := t.(json.Delim); ok {
		switch delim {
		case '{':
			m := make(map[string]any)
			for d.More() {
				k, err := d.Token()
				if err != nil {
					return nil, err
				}
				key, ok := k.(string)
				if !ok {
					return nil, ErrInvalid
				}
				if _, exists := m[key]; exists {
					return nil, ErrInvalid
				}
				v, err := decodeValue(d, depth+1)
				if err != nil {
					return nil, err
				}
				m[key] = v
			}
			end, err := d.Token()
			if err != nil || end != json.Delim('}') {
				return nil, ErrInvalid
			}
			return m, nil
		case '[':
			a := make([]any, 0)
			for d.More() {
				v, err := decodeValue(d, depth+1)
				if err != nil {
					return nil, err
				}
				a = append(a, v)
			}
			end, err := d.Token()
			if err != nil || end != json.Delim(']') {
				return nil, ErrInvalid
			}
			return a, nil
		default:
			return nil, ErrInvalid
		}
	}
	if n, ok := t.(json.Number); ok {
		f, err := n.Float64()
		if err != nil || math.IsNaN(f) || math.IsInf(f, 0) {
			return nil, ErrInvalid
		}
	}
	return t, nil
}

func validEscapes(b []byte) bool {
	inString := false
	for i := 0; i < len(b); i++ {
		if b[i] == '"' {
			inString = !inString
			continue
		}
		if !inString || b[i] != '\\' {
			continue
		}
		i++
		if i >= len(b) {
			return false
		}
		if b[i] != 'u' {
			continue
		}
		if i+4 >= len(b) {
			return false
		}
		v, err := strconv.ParseUint(string(b[i+1:i+5]), 16, 16)
		if err != nil {
			return false
		}
		i += 4
		if v >= 0xdc00 && v <= 0xdfff {
			return false
		}
		if v < 0xd800 || v > 0xdbff {
			continue
		}
		if i+6 >= len(b) || b[i+1] != '\\' || b[i+2] != 'u' {
			return false
		}
		low, err := strconv.ParseUint(string(b[i+3:i+7]), 16, 16)
		if err != nil || low < 0xdc00 || low > 0xdfff {
			return false
		}
		i += 6
	}
	return true
}

func Object(v any, fields ...string) (map[string]any, bool) {
	m, ok := v.(map[string]any)
	if !ok || len(m) != len(fields) {
		return nil, false
	}
	for _, field := range fields {
		if _, ok := m[field]; !ok {
			return nil, false
		}
	}
	return m, true
}

func Text(v any, max int) (string, bool) {
	s, ok := v.(string)
	if !ok || utf8.RuneCountInString(s) > max || strings.TrimSpace(s) == "" {
		return "", false
	}
	for _, r := range s {
		if r < 0x20 || r == 0x7f {
			return "", false
		}
	}
	return s, true
}

// Integer 避免 float64 在安全整数上界附近舍入，且不按巨大指数分配内存。
func Integer(v any, min, max int64) (int64, bool) {
	n, ok := v.(json.Number)
	if !ok {
		return 0, false
	}
	s := n.String()
	negative := strings.HasPrefix(s, "-")
	s = strings.TrimPrefix(s, "-")
	exponent := int64(0)
	exponentText := "0"
	if i := strings.IndexAny(s, "eE"); i >= 0 {
		exponentText, s = s[i+1:], s[:i]
	}
	if i := strings.IndexByte(s, '.'); i >= 0 {
		exponent -= int64(len(s) - i - 1)
		s = s[:i] + s[i+1:]
	}
	s = strings.TrimLeft(s, "0")
	if s == "" {
		return 0, min <= 0 && max >= 0
	}
	e, err := strconv.ParseInt(exponentText, 10, 32)
	if err != nil {
		return 0, false
	}
	exponent += e
	for strings.HasSuffix(s, "0") {
		s = s[:len(s)-1]
		exponent++
	}
	if exponent < 0 || exponent > 16 || int64(len(s))+exponent > 16 {
		return 0, false
	}
	s += strings.Repeat("0", int(exponent))
	if negative {
		s = "-" + s
	}
	value, err := strconv.ParseInt(s, 10, 64)
	return value, err == nil && value >= min && value <= max
}

func SanitizedLabel(v any) (string, bool) {
	s, ok := Text(v, 128)
	if !ok {
		return "", false
	}
	// 拒绝不可见格式控制；仅收敛用户明确提供名称的首尾空格。
	for _, r := range s {
		if unicode.Is(unicode.Cf, r) {
			return "", false
		}
	}
	return strings.TrimSpace(s), true
}
