"""校验公开契约与仓库约定，不模拟产品运行或连接状态机。"""

from __future__ import annotations

import copy
import json
import os
import re
import sys
from datetime import datetime, timedelta
from pathlib import Path
from urllib.parse import unquote, urlsplit

from jsonschema import Draft202012Validator, FormatChecker, ValidationError

ROOT = Path(__file__).resolve().parents[1]
MAX_MESSAGE_BYTES = 65536
SKIP_DIRECTORIES = {
    ".git", ".venv", "__pycache__", ".build", ".swiftpm", "DerivedData",
    "build", "dist", "coverage", "bin", "xcuserdata",
}
SKIP_DIRECTORY_SUFFIXES = {".app", ".xcarchive"}
TEXT_SUFFIXES = {
    ".md", ".json", ".py", ".yml", ".yaml", ".txt", ".swift", ".go", ".toml", ".sh",
    ".m", ".pl", ".dockerignore",
}
TEXT_NAMES = {
    "Makefile", ".editorconfig", ".gitignore", ".gitattributes",
    "Dockerfile", ".dockerignore", "go.mod", "go.sum", "VERSION",
}
DELETE = object()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"JSON 重复键：{key}")
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError(f"JSON 不允许非有限数字：{value}")


def parse_json(raw: bytes):
    return json.loads(
        raw.decode("utf-8"),
        object_pairs_hook=unique_object,
        parse_constant=reject_constant,
    )


def check_unicode(value):
    if isinstance(value, str):
        value.encode("utf-8", errors="strict")
    elif isinstance(value, dict):
        for key, child in value.items():
            check_unicode(key)
            check_unicode(child)
    elif isinstance(value, list):
        for child in value:
            check_unicode(child)


def validate_wire(raw: bytes, validator):
    if len(raw) > MAX_MESSAGE_BYTES:
        raise ValueError("完整消息超过 64 KiB")
    message = parse_json(raw)
    check_unicode(message)
    validator.validate(message)
    if message["type"] == "snapshot" and message["sources"]["media"] is not None:
        playback = message["sources"]["media"]["playback"]
        duration = playback["durationMs"]
        position = playback["positionMs"]
        if duration is not None and position is not None and position > duration:
            raise ValueError("媒体位置超过已知时长")
    if message["type"] == "ack":
        received = datetime.fromisoformat(message["receivedAt"].replace("Z", "+00:00"))
        expires = datetime.fromisoformat(message["expiresAt"].replace("Z", "+00:00"))
        if expires - received != timedelta(seconds=45):
            raise ValueError("ACK 租约不是从接收时间起 45 秒")
    return message


def encode(message):
    return json.dumps(message, ensure_ascii=True, allow_nan=False).encode("utf-8")


def changed(example, path, value):
    message = copy.deepcopy(example)
    target = message
    for key in path[:-1]:
        target = target[key]
    if value is DELETE:
        del target[path[-1]]
    else:
        target[path[-1]] = value
    return message


def check_contract():
    schema = parse_json((ROOT / "protocol/v1/message.schema.json").read_bytes())
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    examples = parse_json((ROOT / "protocol/v1/examples.json").read_bytes())
    accepted = 0
    rejected = 0

    def accepts(name, raw):
        nonlocal accepted
        try:
            validate_wire(raw, validator)
        except (ValidationError, ValueError) as error:
            raise AssertionError(f"应接受的场景被拒绝：{name}；{error}") from error
        accepted += 1

    def rejects(name, raw):
        nonlocal rejected
        try:
            validate_wire(raw, validator)
        except (ValidationError, ValueError):
            rejected += 1
            return
        raise AssertionError(f"应拒绝的场景被接受：{name}")

    for name, message in examples.items():
        accepts(name, encode(message))

    valid_edges = [
        ("序号安全整数上界", "emptySnapshot", ("sequence",), 9007199254740991),
        ("窗口标题长度上界", "applicationSnapshot", ("sources", "window", "title"), "例" * 1024),
        ("位置等于已知时长", "mediaSnapshot", ("sources", "media", "playback", "positionMs"), 180000),
        ("客户端墙钟不决定租约", "emptySnapshot", ("observedAt",), "2099-01-01T00:00:00Z"),
    ]
    for name, base, path, value in valid_edges:
        accepts(name, encode(changed(examples[base], path, value)))

    invalid_edges = [
        ("遗漏来源不能代替清除", "emptySnapshot", ("sources", "media"), DELETE),
        ("拒绝额外原始来源", "emptySnapshot", ("sources", "screen"), None),
        ("拒绝泄露 bundle ID", "applicationSnapshot", ("sources", "application", "bundleId"), "example.private"),
        ("拒绝正文中的凭证", "emptySnapshot", ("token",), "fictional-invalid-token"),
        ("版本不匹配", "emptySnapshot", ("protocolVersion",), 2),
        ("拒绝远程指令消息", "emptySnapshot", ("type",), "command"),
        ("无连接身份", "emptySnapshot", ("connectionId",), DELETE),
        ("连接身份不是随机 UUID", "emptySnapshot", ("connectionId",), "local-hostname"),
        ("序号不能为零", "emptySnapshot", ("sequence",), 0),
        ("序号不能是布尔值", "emptySnapshot", ("sequence",), True),
        ("序号不能有小数", "emptySnapshot", ("sequence",), 1.5),
        ("拒绝不安全整数", "emptySnapshot", ("sequence",), 9007199254740992),
        ("必须检查日期格式", "emptySnapshot", ("observedAt",), "not-a-dateZ"),
        ("无效日历日期", "emptySnapshot", ("observedAt",), "2026-02-30T00:00:00Z"),
        ("时间必须为 UTC", "emptySnapshot", ("observedAt",), "2026-01-01T08:00:00+08:00"),
        ("空白应用名称", "applicationSnapshot", ("sources", "application", "displayName"), "   "),
        ("窗口标题越界", "applicationSnapshot", ("sources", "window", "title"), "例" * 1025),
        ("标题不允许结尾控制字符", "applicationSnapshot", ("sources", "window", "title"), "示例\n"),
        ("标题不允许空字符", "applicationSnapshot", ("sources", "window", "title"), "示例\u0000"),
        ("媒体结束必须清空对象", "mediaSnapshot", ("sources", "media", "playback", "state"), "stopped"),
        ("暂停不能推进", "pausedMediaSnapshot", ("sources", "media", "playback", "rate"), 1),
        ("暂停速率确定为零", "pausedMediaSnapshot", ("sources", "media", "playback", "rate"), None),
        ("播放速率不能为零", "mediaSnapshot", ("sources", "media", "playback", "rate"), 0),
        ("拒绝负位置", "mediaSnapshot", ("sources", "media", "playback", "positionMs"), -1),
        ("未知时长应为空而非零", "mediaSnapshot", ("sources", "media", "playback", "durationMs"), 0),
        ("位置不能超过时长", "mediaSnapshot", ("sources", "media", "playback", "positionMs"), 180001),
        ("未知艺人应为空而非空串", "mediaSnapshot", ("sources", "media", "artist"), ""),
        ("拒绝孤立代理码点", "mediaSnapshot", ("sources", "media", "title"), "\ud800"),
        ("ACK 不能延长规定租约", "ack", ("expiresAt",), "2026-01-01T00:00:46Z"),
        ("拒绝未协商错误类型", "error", ("code",), "execute_shell"),
    ]
    for name, base, path, value in invalid_edges:
        rejects(name, encode(changed(examples[base], path, value)))

    raw = encode(examples["emptySnapshot"])
    padded = raw + b" " * (MAX_MESSAGE_BYTES - len(raw))
    accepts("完整消息字节上界", padded)
    rejects("完整消息超出一个字节", padded + b" ")
    rejects("重复 JSON 键", raw.replace(b'"sequence": 1', b'"sequence": 1, "sequence": 2'))
    rejects("非有限数字", raw.replace(b'"sequence": 1', b'"sequence": NaN'))
    rejects("非 UTF-8 文本", b"\xff")
    rejects("一条消息包含两个对象", raw + raw)
    print(f"协议校验通过：{accepted} 个有效场景，{rejected} 个拒绝场景；包含 Schema 与跨字段约束。")


def repository_files():
    for directory, subdirectories, files in os.walk(ROOT):
        subdirectories[:] = sorted(
            name for name in subdirectories
            if name not in SKIP_DIRECTORIES and Path(name).suffix not in SKIP_DIRECTORY_SUFFIXES
        )
        for name in sorted(files):
            path = Path(directory) / name
            if path.suffix in TEXT_SUFFIXES or name in TEXT_NAMES:
                yield path


def check_repository():
    files = list(repository_files())
    agents = [path for path in files if path.name == "AGENTS.md"]
    links = 0
    for path in files:
        raw = path.read_bytes()
        text = raw.decode("utf-8")
        relative = path.relative_to(ROOT)
        if b"\r" in raw or (raw and not raw.endswith(b"\n")):
            raise ValueError(f"文件须为 LF 且保留结尾换行：{relative}")
        for number, line in enumerate(text.splitlines(), 1):
            if line.rstrip() != line:
                raise ValueError(f"存在行尾空白：{relative}:{number}")
        if path.suffix != ".md":
            continue
        for target in re.findall(r"\[[^\]\n]+\]\(([^\s)]+)\)", text):
            parsed = urlsplit(target)
            if parsed.scheme or not parsed.path:
                continue
            destination = (path.parent / unquote(parsed.path)).resolve()
            if not destination.is_relative_to(ROOT) or not destination.exists():
                raise ValueError(f"失效或越界的相对链接：{relative} → {target}")
            links += 1
    for path in agents:
        parent = re.search(r"^<!-- Parent: (.+?) -->$", path.read_text(), re.MULTILINE)
        if path.parent == ROOT:
            if parent:
                raise ValueError("根 AGENTS.md 不应有父引用")
            continue
        if not parent:
            raise ValueError(f"缺少父指令引用：{path.relative_to(ROOT)}")
        destination = (path.parent / parent.group(1)).resolve()
        if destination.name != "AGENTS.md" or not destination.is_file() or destination.parent not in path.parents:
            raise ValueError(f"无效父指令引用：{path.relative_to(ROOT)}")
    if not re.fullmatch(r"\d+\.\d+\.\d+\n", (ROOT / "VERSION").read_text()):
        raise ValueError("VERSION 必须只含一行 主.次.修订，例如 0.1.0")
    directories = {path.parent for path in files}
    for directory in directories:
        if not (directory / "AGENTS.md").is_file():
            raise ValueError(f"缺少目录指令：{directory.relative_to(ROOT)}")
    print(f"仓库校验通过：{len(files)} 个文本文件，{len(agents)} 份 AGENTS.md，{links} 个相对链接。")


def main():
    try:
        check_contract()
        check_repository()
    except (AssertionError, ValidationError, ValueError, OSError) as error:
        print(f"检查失败：{error}", file=sys.stderr)
        return 1
    print("这些结果不代表真实 WSS、桌面 UI 或媒体采集已经验收。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
