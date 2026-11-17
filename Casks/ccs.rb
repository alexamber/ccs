cask "ccs" do
  version "1.1.0"
  sha256 "ce8d3597767a3027ede3cb013c3507e34e971c43b85466b8d984b25b3de96f6a"
  url "https://github.com/alexamber/ccs/releases/download/v#{version}/CCS-#{version}-macos-universal.dmg"
  name "CCS"
  desc "Native macOS and terminal picker for Claude Code and Codex"
  homepage "https://github.com/alexamber/ccs"
  depends_on macos: :sonoma
  app "CCS.app"
  binary "#{appdir}/CCS.app/Contents/MacOS/ccs"
end
