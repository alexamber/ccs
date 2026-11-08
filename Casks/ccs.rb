cask "ccs" do
  version "0.2.0"
  sha256 "78d74976b23daed7c827e1592e0326d51c560b1af9a946ba6ff769dab759581a"
  url "https://github.com/alexamber/ccs/releases/download/v#{version}/CCS-#{version}-macos-universal.dmg"
  name "CCS"
  desc "Native macOS and terminal picker for Claude Code sessions"
  homepage "https://github.com/alexamber/ccs"
  depends_on macos: :sonoma
  app "CCS.app"
  binary "#{appdir}/CCS.app/Contents/MacOS/ccs"
end
