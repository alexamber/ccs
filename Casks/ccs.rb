cask "ccs" do
  version "1.3.3"
  sha256 "947a755dd20190e4217b8c9a51f074c32b9b5e22c3e0191586c0154d01852564"
  url "https://github.com/alexamber/ccs/releases/download/v#{version}/CCS-#{version}-macos-universal.dmg"
  name "CCS"
  desc "Native macOS and terminal picker for Claude Code and Codex"
  homepage "https://github.com/alexamber/ccs"
  depends_on macos: :sonoma
  app "CCS.app"
  binary "#{appdir}/CCS.app/Contents/MacOS/ccs"
end
