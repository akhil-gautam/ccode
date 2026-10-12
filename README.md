# ccode

A native macOS workspace for coding agents, built with Swift, AppKit and SwiftUI. It connects to agents over [ACP](https://agentclientprotocol.com/), with Claude Code as the primary integration.

## Why

I wanted the familiar coding-agent workflow in a native app: fast navigation, local conversation history, and less overhead than a browser-based shell. Transcripts appear before the agent connects, and the agent runs in its own process. Memory use and feature parity are still being improved; this is an experimental app.

## Install

Requires macOS 14 or later. Apple Silicon and Intel releases are available.

```sh
brew tap akhil-gautam/ccode https://github.com/akhil-gautam/ccode
brew install --cask akhil-gautam/ccode/ccode
```

Or download the appropriate ZIP from [Releases](https://github.com/akhil-gautam/ccode/releases). Releases are currently ad hoc signed, **not notarized**. macOS may require approval in System Settings → Privacy & Security before opening the app.

## Connect an agent

Homebrew installs Node.js for the Claude adapter. Install and authenticate the adapter separately using your own Claude account:

```sh
npm install -g @agentclientprotocol/claude-agent-acp@0.84.0
claude-agent-acp --cli auth login
```

In **Customize**, select the absolute path to `claude-agent-acp` and leave arguments as `[]`. Create a session, choose a project folder and send a message; sending connects the agent automatically. Other ACP v1 stdio agents can be configured in the same place. Provider-specific features depend on the adapter's advertised capabilities.

## What works

- Chat, streamed replies, expandable tools, permissions, cancellation and session resume.
- Local Claude history, session search with ⌘K, and project pinning, ordering and collapsing.
- Files, terminal, Git changes, browser previews and attachments alongside the conversation.
- SSH workspaces and capability-gated computer and simulator workflows.

Not every Claude app feature is implemented. Agent authentication, usage and billing belong to your provider. Chats and drafts are stored locally in `~/Library/Application Support/ccode`; agent settings use macOS preferences.

## Build

Requires Swift 6 and full Xcode, including the Metal toolchain.

```sh
sh scripts/swift-check.sh test --build-system native
python3 scripts/test-release.py
sh scripts/build-app.sh
open dist/ccode.app
```

Tagged releases build and verify both architectures, publish ZIPs and checksums, and update the Homebrew cask in this repository. See [releasing](docs/releasing.md).

ccode is independent of Anthropic. It bundles [Inter](https://github.com/rsms/inter) under the SIL Open Font License and [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) under the MIT license; their notices are included with the app.
