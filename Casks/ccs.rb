cask "ccs" do
  version "0.3.1"
  sha256 "715d3918a538431ca8d0e87fa9bbb05c7c59ec2d1bc2e1389c923c98732f1cc0"
  url "https://github.com/alexamber/ccs/releases/download/v#{version}/CCS-#{version}-macos-universal.dmg"
  name "CCS"
  desc "Native macOS and terminal picker for Claude Code and Codex"
  homepage "https://github.com/alexamber/ccs"
  depends_on macos: :sonoma
  app "CCS.app"
  binary "#{appdir}/CCS.app/Contents/MacOS/ccs"
end
