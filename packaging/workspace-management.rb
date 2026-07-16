# Homebrew formula for workspace-management.
#
# This is the CANONICAL copy. The live copy lives in the tap repo at
# `Formula/workspace-management.rb` (see PACKAGING.md). When you cut a release,
# bump `tag`/`revision`/`version` here, then copy this file into the tap.
#
# Source repo is private, so `url` uses git over SSH (not a release tarball):
# Homebrew shells out to `git`, which clones with each user's own SSH key. No
# token is embedded and nothing secret is committed — access rides entirely on
# the teammate's existing GitHub SSH access. (`brew audit --strict` prefers an
# HTTPS URL, but that convention targets public homebrew-core submissions and is
# irrelevant for a private, all-SSH tap.) `homepage` stays HTTPS: it's just a
# clickable link, never cloned.
class WorkspaceManagement < Formula
  desc "Per-task git worktree dev workspaces with subdomain serving (macOS/Valet)"
  homepage "https://github.com/vinson-vinson-vinson/workspace-management"
  url "git@github.com:vinson-vinson-vinson/workspace-management.git",
      using:    :git,
      tag:      "v1.2.0",
      revision: "fded0ce5f5ff8f946d2be10caffc0c43f7f9fc1e"
  version "1.2.0"
  license "MIT"

  # Install the newest main with:  brew install --HEAD <tap>/workspace-management
  head "git@github.com:vinson-vinson-vinson/workspace-management.git", branch: "main"

  depends_on :macos
  depends_on "git"

  def install
    # The dispatcher resolves its own real dir (symlink-following) to find lib/,
    # so `workspaces` + lib/ live together in libexec and both command names are
    # symlinked onto PATH pointing back here.
    libexec.install "workspaces", "lib"
    bin.install_symlink libexec/"workspaces" => "workspaces"
    bin.install_symlink libexec/"workspaces" => "ws"

    # A packaged install has no writable config.sh next to the command, so ship
    # the template somewhere users can copy it from (see caveats).
    pkgshare.install "config.example.sh"
  end

  def caveats
    <<~EOS
      One-time setup — create your machine config:

        mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/workspace-management"
        cp #{opt_pkgshare}/config.example.sh \\
           "${XDG_CONFIG_HOME:-$HOME/.config}/workspace-management/config.sh"
        $EDITOR "${XDG_CONFIG_HOME:-$HOME/.config}/workspace-management/config.sh"

      Then run:  ws help

      `ws` finds that config automatically. To keep it elsewhere, point
      WSM_CONFIG at it.

      Runtime tools NOT installed by brew (checked at runtime):
        - Laravel Valet (nginx + a wildcard cert)  — only for `ws serve`
        - the `code` CLI  (VS Code → "Shell Command: Install 'code' command")
        - yarn  (frontend dependency installs)
    EOS
  end

  test do
    # `ws help` / --version need no config, so they're the cleanest smoke test.
    assert_match "WORKSPACE MANAGEMENT", shell_output("#{bin}/workspaces help")
    assert_match version.to_s, shell_output("#{bin}/ws --version")
  end
end
