cask "ccs" do
  version "1.3.4"
  sha256 "d4681da19690cb908676ae2a8868c6413a7f33aef93abb9a6804e9c1a3d2f291"
  url "https://github.com/alexamber/ccs/releases/download/v#{version}/CCS-#{version}-macos-universal.dmg"
  name "CCS"
  desc "Native macOS and terminal picker for Claude Code and Codex"
  homepage "https://github.com/alexamber/ccs"
  auto_updates true
  depends_on macos: :sonoma
  app "CCS.app"
  binary "#{appdir}/CCS.app/Contents/MacOS/ccs"
end
