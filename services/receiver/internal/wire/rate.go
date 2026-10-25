package wire

import (
	"encoding/json"
	"strconv"
	"strings"
)

// 十进制精确校验，避免 4.000000000000000001 被 float64 舍入后错误放行。
// 规范化用于消息指纹，保证 1、1.0、1e0 的重复快照得到同一个 ACK。
func parseRate(v any) (json.Number, bool) {
	n, ok := v.(json.Number)
	if !ok {
		return "", false
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
		return json.Number("0"), true
	}
	if negative {
		return "", false
	}
	e, err := strconv.ParseInt(exponentText, 10, 32)
	if err != nil {
		return "", false
	}
	exponent += e
	for strings.HasSuffix(s, "0") {
		s = s[:len(s)-1]
		exponent++
	}
	magnitude := int64(len(s)) + exponent
	if magnitude > 1 || (magnitude == 1 && (s[0] > '4' || (s[0] == '4' && len(s) > 1))) {
		return "", false
	}
	return json.Number(s + "e" + strconv.FormatInt(exponent, 10)), true
}
