cask "ccs" do
  version "1.3.1"
  sha256 "57bbfcd658674803c116ee4dc1415f39657fb19e6f5fd25c2f6c314cbeb63c81"
  url "https://github.com/alexamber/ccs/releases/download/v#{version}/CCS-#{version}-macos-universal.dmg"
  name "CCS"
  desc "Native macOS and terminal picker for Claude Code and Codex"
  homepage "https://github.com/alexamber/ccs"
  depends_on macos: :sonoma
  app "CCS.app"
  binary "#{appdir}/CCS.app/Contents/MacOS/ccs"
end
