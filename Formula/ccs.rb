class Ccs < Formula
  desc "Native macOS and terminal picker for Claude Code sessions"
  homepage "https://github.com/alexamber/ccs"
  license "MIT"
  head "https://github.com/alexamber/ccs.git", branch: "main"

  depends_on :macos
  depends_on xcode: ["15.0", :build]

  def install
    ENV["CCS_BUILD_ARCHS"] = Hardware::CPU.arm? ? "arm64" : "x86_64"
    system "bash", "scripts/build-app.sh", "--development", "--app-only"
    prefix.install "build/CCS.app"
    bin.install_symlink prefix/"CCS.app/Contents/MacOS/ccs"
  end

  test do
    assert_match "Browse Claude Code sessions", shell_output("#{bin}/ccs --help")
    assert_empty shell_output("HOME=#{testpath} #{bin}/ccs --list")
  end
end
