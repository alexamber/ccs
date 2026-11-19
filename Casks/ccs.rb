cask "ccs" do
  version "1.2.1"
  sha256 "e36aaf04e435d79b9a4ae9b340303a335e4f5659aa44146fc6d5a2d38f2a4f6a"
  url "https://github.com/alexamber/ccs/releases/download/v#{version}/CCS-#{version}-macos-universal.dmg"
  name "CCS"
  desc "Native macOS and terminal picker for Claude Code and Codex"
  homepage "https://github.com/alexamber/ccs"
  depends_on macos: :sonoma
  app "CCS.app"
  binary "#{appdir}/CCS.app/Contents/MacOS/ccs"
end
