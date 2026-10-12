"""Build validated native releases and generate their Homebrew cask."""

import argparse
import hashlib
import os
import platform
import plistlib
import re
import struct
import subprocess
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ARCHITECTURES = {"arm64": 0x0100000C, "x86_64": 0x01000007}


def version_for(tag):
    if not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag):
        raise ValueError("Release tag must be vMAJOR.MINOR.PATCH, without leading zeroes or suffixes")
    return tag[1:]


def asset_name(tag, arch):
    version = version_for(tag)
    if arch not in ARCHITECTURES:
        raise ValueError("Unsupported release architecture")
    return f"ccode-{version}-macos-{arch}.zip"


def checksum(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_archive(path, tag, arch):
    version = version_for(tag)
    asset_name(tag, arch)
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        prefix = "ccode.app/Contents/"
        if any("AnthropicSans" in name or "/.build/" in name or "/.git/" in name for name in names):
            raise ValueError("Archive contains a private or development-only resource")
        info = plistlib.loads(archive.read(prefix + "Info.plist"))
        expected = {"CFBundleIdentifier": "dev.ccode.native", "CFBundleExecutable": "ccode",
                    "CFBundleShortVersionString": version, "CFBundleVersion": version,
                    "LSMinimumSystemVersion": "14.0"}
        if any(info.get(key) != value for key, value in expected.items()) or "CCodeDevelopmentRoot" in info:
            raise ValueError("Archive has incorrect release metadata")
        with archive.open(prefix + "MacOS/ccode") as executable:
            header = executable.read(32)
        if len(header) != 32:
            raise ValueError("Missing Mach-O executable header")
        magic, cpu, _, kind, *_ = struct.unpack("<8I", header)
        if (magic, cpu, kind) != (0xFEEDFACF, ARCHITECTURES[arch], 2):
            raise ValueError("Archive executable does not match its declared architecture")
        for name in ("Inter-Regular.otf", "Inter-LICENSE.txt"):
            if not archive.read(prefix + "Resources/" + name):
                raise ValueError("Missing licensed sidebar font resource")


def build(tag, arch):
    version = version_for(tag)
    name = asset_name(tag, arch)
    if platform.system() != "Darwin" or platform.machine() != arch:
        raise ValueError("Build each architecture on its matching native macOS runner")
    subprocess.run(["sh", "scripts/build-app.sh"], cwd=ROOT, check=True)
    app = ROOT / "dist/ccode.app"
    metadata = app / "Contents/Info.plist"
    info = plistlib.loads(metadata.read_bytes())
    info.update(CFBundleShortVersionString=version, CFBundleVersion=version)
    info.pop("CCodeDevelopmentRoot", None)
    metadata.write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    actual = subprocess.check_output(["lipo", "-archs", str(app / "Contents/MacOS/ccode")], text=True).strip()
    if actual != arch:
        raise ValueError("Native build produced the wrong architecture")
    destination = ROOT / "dist" / name
    destination.unlink(missing_ok=True)
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(destination)], check=True)
    validate_archive(destination, tag, arch)
    destination.with_suffix(".zip.sha256").write_text(checksum(destination) + "  " + name + "\n")
    print(destination)


def write_cask(tag, archives, output):
    version = version_for(tag)
    hashes = {}
    for arch in ARCHITECTURES:
        path = archives / asset_name(tag, arch)
        validate_archive(path, tag, arch)
        hashes[arch] = checksum(path)
    if output.exists():
        current = re.search(r'^  version "([0-9.]+)"$', output.read_text(), re.MULTILINE)
        if not current:
            raise ValueError("Existing cask has no recognized version")
        if tuple(map(int, current.group(1).split("."))) > tuple(map(int, version.split("."))):
            raise ValueError("An older release cannot downgrade the Homebrew cask")
    text = f'''cask "ccode" do
  arch arm: "arm64", intel: "x86_64"

  version "{version}"
  sha256 arm:   "{hashes['arm64']}",
         intel: "{hashes['x86_64']}"

  url "https://github.com/akhil-gautam/ccode/releases/download/v#{{version}}/ccode-#{{version}}-macos-#{{arch}}.zip"
  name "ccode"
  desc "Native macOS workspace for ACP coding agents"
  homepage "https://github.com/akhil-gautam/ccode"

  depends_on macos: ">= :sonoma"
  depends_on formula: "node"

  app "ccode.app"
end
'''
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=output.parent, delete=False) as temporary:
        temporary.write(text)
        temporary_path = Path(temporary.name)
    temporary_path.replace(output)
    print(f"Updated {output} for {tag}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    native = commands.add_parser("build")
    native.add_argument("tag")
    native.add_argument("arch", choices=ARCHITECTURES)
    cask = commands.add_parser("cask")
    cask.add_argument("tag")
    cask.add_argument("archives", type=Path)
    cask.add_argument("output", type=Path)
    validate = commands.add_parser("version")
    validate.add_argument("tag")
    args = parser.parse_args()
    if args.command == "build":
        build(args.tag, args.arch)
    elif args.command == "cask":
        write_cask(args.tag, args.archives, args.output)
    else:
        print(version_for(args.tag))


if __name__ == "__main__":
    main()
