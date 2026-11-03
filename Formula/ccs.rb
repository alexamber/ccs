class Ccs < Formula
  desc "Browse, switch, and resume Claude Code sessions in a terminal tree"
  homepage "https://github.com/alexamber/ccs"
  license "MIT"
  head "https://github.com/alexamber/ccs.git", branch: "main"

  depends_on :macos
  depends_on "python@3.14"

  def install
    bin.install "ccs"
    inreplace bin/"ccs", "#!/usr/bin/env python3", "#!#{Formula["python@3.14"].opt_bin}/python3.14"
    (pkgshare/"hammerspoon").install "hammerspoon/ccs.lua"
  end

  test do
    assert_match "Browse Claude Code sessions", shell_output("#{bin}/ccs --help")
    assert_empty shell_output("HOME=#{testpath} #{bin}/ccs --list")
  end
end
