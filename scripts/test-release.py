import hashlib
import plistlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

import release


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.cask = self.root / "Casks/ccode.rb"

    def tearDown(self):
        self.temporary.cleanup()

    def archive(self, tag, arch, *, binary_arch=None, development_root=False):
        version = release.version_for(tag)
        path = self.root / release.asset_name(tag, arch)
        cpu = {"arm64": 0x0100000C, "x86_64": 0x01000007}[binary_arch or arch]
        info = {"CFBundleIdentifier": "dev.ccode.native", "CFBundleExecutable": "ccode",
                "CFBundleShortVersionString": version, "CFBundleVersion": version,
                "LSMinimumSystemVersion": "14.0"}
        if development_root:
            info["CCodeDevelopmentRoot"] = "/private/build/checkout"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("ccode.app/Contents/Info.plist", plistlib.dumps(info))
            archive.writestr("ccode.app/Contents/MacOS/ccode", struct.pack("<8I", 0xFEEDFACF, cpu, 0, 2, 0, 0, 0, 0))
            archive.writestr("ccode.app/Contents/Resources/Inter-Regular.otf", b"font fixture")
            archive.writestr("ccode.app/Contents/Resources/Inter-LICENSE.txt", "SIL OPEN FONT LICENSE")
        return path

    def pair(self, tag="v0.1.0"):
        return [self.archive(tag, arch) for arch in ("arm64", "x86_64")]

    def test_versions_and_architectures_are_strict(self):
        self.assertEqual(release.version_for("v0.1.0"), "0.1.0")
        for tag in ("0.1.0", "v01.0.0", "v1.0", "v1.0.0-rc1", "v1.0.0\n", 'v1.0.0"; echo bad', "v../../app"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.version_for(tag)
        with self.assertRaises(ValueError):
            release.asset_name("v0.1.0", "ppc")

    def test_cask_has_independent_checksums_and_versioned_urls(self):
        archives = self.pair()
        release.write_cask("v0.1.0", self.root, self.cask)
        text = self.cask.read_text()
        for archive in archives:
            self.assertIn(hashlib.sha256(archive.read_bytes()).hexdigest(), text)
        self.assertIn('arch arm: "arm64", intel: "x86_64"', text)
        self.assertIn('version "0.1.0"', text)
        self.assertIn('/releases/download/v#{version}/ccode-#{version}-macos-#{arch}.zip', text)
        self.assertIn('app "ccode.app"', text)
        self.assertNotIn("no_check", text)

    def test_missing_or_invalid_archive_preserves_existing_cask(self):
        self.pair()
        release.write_cask("v0.1.0", self.root, self.cask)
        original = self.cask.read_bytes()
        intel = self.root / release.asset_name("v0.1.0", "x86_64")
        intel.unlink()
        with self.assertRaises((ValueError, FileNotFoundError)):
            release.write_cask("v0.1.0", self.root, self.cask)
        self.assertEqual(self.cask.read_bytes(), original)
        intel.write_bytes(b"not a zip")
        with self.assertRaises((ValueError, zipfile.BadZipFile)):
            release.write_cask("v0.1.0", self.root, self.cask)
        self.assertEqual(self.cask.read_bytes(), original)

    def test_architecture_and_metadata_mismatches_are_rejected(self):
        path = self.archive("v0.1.0", "arm64", binary_arch="x86_64")
        with self.assertRaises(ValueError):
            release.validate_archive(path, "v0.1.0", "arm64")
        path = self.archive("v0.1.0", "arm64", development_root=True)
        with self.assertRaises(ValueError):
            release.validate_archive(path, "v0.1.0", "arm64")
        path = self.archive("v0.1.0", "arm64")
        with self.assertRaises(ValueError):
            release.validate_archive(path, "v0.2.0", "arm64")
        with zipfile.ZipFile(path, "a") as archive:
            archive.writestr("ccode.app/Contents/Resources/AnthropicSans-Roman.woff2", b"copied asset")
        with self.assertRaises(ValueError):
            release.validate_archive(path, "v0.1.0", "arm64")

    def test_retry_is_idempotent_and_older_versions_cannot_downgrade(self):
        self.pair("v0.2.0")
        release.write_cask("v0.2.0", self.root, self.cask)
        original = self.cask.read_bytes()
        release.write_cask("v0.2.0", self.root, self.cask)
        self.assertEqual(self.cask.read_bytes(), original)
        self.pair("v0.1.0")
        with self.assertRaises(ValueError):
            release.write_cask("v0.1.0", self.root, self.cask)
        self.assertEqual(self.cask.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
