cask "ccs" do
  version "0.2.0"
  sha256 "7b414e3103418eec1de92c0bfa9ce683334cb6916ca3564aa52049f2d62d981a"
  url "https://github.com/alexamber/ccs/releases/download/v#{version}/CCS-#{version}-macos-universal.dmg"
  name "CCS"
  desc "Native macOS and terminal picker for Claude Code sessions"
  homepage "https://github.com/alexamber/ccs"
  depends_on macos: :sonoma
  app "CCS.app"
  binary "#{appdir}/CCS.app/Contents/MacOS/ccs"
end
