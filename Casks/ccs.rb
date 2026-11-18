cask "ccs" do
  version "1.2.0"
  sha256 "79f9b5f50c3d84fbf756aca93a4fef9b7f1895366498ebf5a7577069c5e3b3c3"
  url "https://github.com/alexamber/ccs/releases/download/v#{version}/CCS-#{version}-macos-universal.dmg"
  name "CCS"
  desc "Native macOS and terminal picker for Claude Code and Codex"
  homepage "https://github.com/alexamber/ccs"
  depends_on macos: :sonoma
  app "CCS.app"
  binary "#{appdir}/CCS.app/Contents/MacOS/ccs"
end
