"""构建独立 macOS 软件；只使用项目内缓存，不修改系统配置或签名身份。"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / ".build"
COMMIT = "0e82bf1c44ec39554fbfc402ec88a48c6ae2a0fd"
ARCHIVE_SHA256 = "9e31b154dc7be207a42b7bb1ba1b161bfdee541a15d692cba1c37740f13b23e2"
ARCHIVE_URL = f"https://codeload.github.com/ungive/mediaremote-adapter/tar.gz/{COMMIT}"


def run(*command: str | Path, capture: bool = False) -> str:
    result = subprocess.run(
        [str(value) for value in command], cwd=ROOT, check=True,
        text=True, stdout=subprocess.PIPE if capture else None,
    )
    return result.stdout.strip() if capture else ""


def build_media() -> Path:
    cache = BUILD / "third-party"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / "mediaremote-adapter.tar.gz"
    if not archive.exists():
        temporary = archive.with_suffix(".download")
        run("curl", "--fail", "--location", "--proto", "=https", "--tlsv1.2", "--max-time", "120", "--output", temporary, ARCHIVE_URL)
        temporary.replace(archive)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != ARCHIVE_SHA256:
        raise RuntimeError("媒体依赖归档校验失败；不会构建来源不符的代码。")
    source = cache / f"mediaremote-adapter-{COMMIT}"
    if not source.is_dir():
        with tarfile.open(archive) as package:
            package.extractall(cache, filter="data")
    cmake = ROOT / ".venv/bin/cmake"
    if not cmake.is_file():
        raise RuntimeError("缺少项目内 CMake；先运行 make setup。")
    native_build = BUILD / "media-adapter"
    run(cmake, "-S", source, "-B", native_build, "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0")
    run(cmake, "--build", native_build, "--target", "MediaRemoteAdapter", "--parallel", "2")
    resources = BUILD / "native-media"
    resources.mkdir(parents=True, exist_ok=True)
    framework = resources / "MediaRemoteAdapter.framework"
    if framework.exists():
        shutil.rmtree(framework)
    shutil.copytree(native_build / "MediaRemoteAdapter.framework", framework, symlinks=True)
    binary = framework / "Versions/A/MediaRemoteAdapter"
    thin = resources / "adapter-arm64"
    run("lipo", binary, "-thin", "arm64", "-output", thin)
    thin.replace(binary)
    run("codesign", "--force", "--sign", "-", framework)
    gate = resources / "NowbeamMediaGate.dylib"
    run("xcrun", "clang", "-arch", "arm64", "-mmacosx-version-min=15.0", "-dynamiclib", "-fobjc-arc",
        "-framework", "Foundation", "-framework", "AppKit", ROOT / "apps/macos/MediaSupport/NowbeamMediaGate.m", "-o", gate)
    run("codesign", "--force", "--sign", "-", gate)
    shutil.copy2(ROOT / "apps/macos/MediaSupport/media-host.pl", resources / "media-host.pl")
    shutil.copy2(source / "LICENSE", resources / "mediaremote-adapter-LICENSE.txt")
    (resources / "provenance.json").write_text(json.dumps({"repository": "https://github.com/ungive/mediaremote-adapter", "commit": COMMIT, "archiveSha256": digest}, indent=2) + "\n")
    return resources


def main() -> None:
    parser = argparse.ArgumentParser(description="构建 Nowbeam .app / 开发 DMG，不执行发布或公证")
    parser.add_argument("--configuration", choices=("debug", "release"), default="release")
    parser.add_argument("--media-only", action="store_true")
    parser.add_argument("--skip-dmg", action="store_true")
    parser.add_argument("--bundle-id", default="local.nowbeam.development")
    parser.add_argument("--sign-identity", default="-")
    args = parser.parse_args()
    if sys.platform != "darwin" or os.uname().machine != "arm64":
        parser.error("原生打包需要 Apple Silicon macOS。")
    if args.sign_identity != "-" and args.bundle_id.startswith("local."):
        parser.error("使用正式身份前，必须显式提供维护者授权的 --bundle-id。")
    resources = build_media()
    if args.media_only:
        print(f"只读媒体资源已构建：{resources}")
        return
    package = ROOT / "apps/macos"
    run("swift", "build", "--package-path", package, "--configuration", args.configuration, "--arch", "arm64")
    binary_directory = Path(run("swift", "build", "--package-path", package, "--configuration", args.configuration, "--arch", "arm64", "--show-bin-path", capture=True))
    destination = ROOT / "dist"
    destination.mkdir(exist_ok=True)
    application = destination / "Nowbeam.app"
    if application.exists():
        shutil.rmtree(application)
    contents = application / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Resources").mkdir()
    shutil.copy2(binary_directory / "Nowbeam", contents / "MacOS/Nowbeam")
    shutil.copytree(resources, contents / "Resources/MediaRemote", symlinks=True)
    information = {
        "CFBundleExecutable": "Nowbeam", "CFBundleName": "Nowbeam", "CFBundleDisplayName": "Nowbeam",
        "CFBundleIdentifier": args.bundle_id, "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "15.0", "LSUIElement": True,
        "NSSupportsAutomaticTermination": False, "NSSupportsSuddenTermination": False,
    }
    if args.configuration == "debug":
        information["NSAppTransportSecurity"] = {"NSAllowsLocalNetworking": True}
    (contents / "Info.plist").write_bytes(plistlib.dumps(information, sort_keys=True))
    for nested in [contents / "Resources/MediaRemote/MediaRemoteAdapter.framework", contents / "Resources/MediaRemote/NowbeamMediaGate.dylib"]:
        run("codesign", "--force", "--sign", args.sign_identity, nested)
    run("codesign", "--force", "--sign", args.sign_identity, "--options", "runtime", application)
    run("codesign", "--verify", "--deep", "--strict", application)
    print(f"已构建应用：{application}")
    if not args.skip_dmg:
        with tempfile.TemporaryDirectory(prefix="dmg-", dir=BUILD) as temporary:
            staging = Path(temporary)
            shutil.copytree(application, staging / "Nowbeam.app", symlinks=True)
            (staging / "Applications").symlink_to("/Applications")
            image = destination / "Nowbeam.dmg"
            run("hdiutil", "create", "-volname", "Nowbeam", "-srcfolder", staging, "-ov", "-format", "UDZO", image)
            print(f"已构建磁盘映像：{image}")
    print("签名模式：本地开发 ad-hoc，未公证。" if args.sign_identity == "-" else "使用显式指定的签名身份；尚未公证或发布。")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"打包失败：{error}", file=sys.stderr)
        sys.exit(1)
