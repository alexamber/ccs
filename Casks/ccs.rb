cask "ccs" do
  version "1.1.0"
  sha256 "b38250daa1e4c352a6151dd0dcf1fa05c69f37bc8b81f7f46fb67af2975e6a57"
  url "https://github.com/alexamber/ccs/releases/download/v#{version}/CCS-#{version}-macos-universal.dmg"
  name "CCS"
  desc "Native macOS and terminal picker for Claude Code and Codex"
  homepage "https://github.com/alexamber/ccs"
  depends_on macos: :sonoma
  app "CCS.app"
  binary "#{appdir}/CCS.app/Contents/MacOS/ccs"
end
