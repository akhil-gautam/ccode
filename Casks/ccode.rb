# frozen_string_literal: true

cask "ccode" do
  arch arm: "arm64", intel: "x86_64"

  version "0.1.1"
  sha256 arm:   "f85ea0dae0d68a548fe0ab2b69f8a3141574adf355d1a2222fed075406410bb5",
         intel: "dfbae0a837e8468baa5940dda550864338e5871caecb25d48dd108b9db22962f"

  url "https://github.com/akhil-gautam/ccode/releases/download/v#{version}/ccode-#{version}-macos-#{arch}.zip"
  name "ccode"
  desc "Native workspace for ACP coding agents"
  homepage "https://github.com/akhil-gautam/ccode"

  depends_on formula: "node"
  depends_on macos: :sonoma

  app "ccode.app"
end
