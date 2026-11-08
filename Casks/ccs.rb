cask "ccs" do
  version "1.0.1"
  sha256 "e5d5143afc0df51f3a3d2826b44ba04a24f871ae745330dded451b610b390ca6"
  url "https://github.com/alexamber/ccs/releases/download/v#{version}/CCS-#{version}-macos-universal.dmg"
  name "CCS"
  desc "Native macOS and terminal picker for Claude Code and Codex"
  homepage "https://github.com/alexamber/ccs"
  depends_on macos: :sonoma
  app "CCS.app"
  binary "#{appdir}/CCS.app/Contents/MacOS/ccs"
end
