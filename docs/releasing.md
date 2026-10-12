# Releases

This repository doubles as the Homebrew tap. Users must supply its URL when tapping because its name is `ccode`, rather than `homebrew-ccode`.

## Publish

After CI passes on `main`, tag the desired commit and push the tag:

```sh
git tag v0.1.0
git push origin v0.1.0
```

Tags must be `vMAJOR.MINOR.PATCH`, without suffixes or leading zeroes. The release workflow uses native macOS runners and Xcode 26.3 to test and build separate Apple Silicon and Intel apps. Each archive contains versioned release metadata, bundled helper scripts and third-party notices. The executable's architecture and signature are checked before uploading.

The publish job creates a draft GitHub release, uploads both ZIPs and SHA-256 files, validates the archives, then publishes the release and commits `Casks/ccode.rb` to `main`. It uses the repository's built-in Actions token; no extra publishing credential is needed.

To retry an existing tag, run the **Release** workflow manually with that tag. A published release's original assets are reused. Older versions cannot replace a newer cask. Do not move published tags or replace published downloads.

## Signing

Current builds are ad hoc signed and are not notarized. Gatekeeper remains enabled, so downloaded apps may need user approval in macOS Privacy & Security. Developer ID signing and notarization require an Apple Developer identity and are not configured in this pipeline.

## Verify locally

```sh
python3 scripts/test-release.py
python3 scripts/release.py build v0.1.0 arm64
```

Use `x86_64` on an Intel Mac. After downloading both release ZIPs into `dist`, regenerate and validate the cask with:

```sh
python3 scripts/release.py cask v0.1.0 dist Casks/ccode.rb
```

Homebrew upgrades preserve chats and settings. The cask has no destructive `zap` stanza.
