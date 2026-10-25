#!/bin/sh
set -eu

# 由构建阶段运行；只收集锁定模块的原始许可，不替 Nowbeam 指定许可证。
destination=${1:?usage: collect-licenses.sh destination}
mkdir -p "$destination"
go list -m -f '{{if .Dir}}{{.Path}} {{.Version}} {{.Dir}}{{end}}' all |
while read -r module version directory; do
    case "$module" in
        nowbeam.local/receiver|'') continue ;;
    esac
    target="$destination/$module@$version"
    mkdir -p "$target"
    find "$directory" -maxdepth 1 -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \) -exec cp '{}' "$target/" \;
done
mkdir -p "$destination/go-runtime"
cp "$(go env GOROOT)/LICENSE" "$destination/go-runtime/LICENSE"
