# Homebrew formula for workspace-management.
#
# This is the CANONICAL copy. The live copy lives in the tap repo at
# `Formula/workspace-management.rb` (see PACKAGING.md). When you cut a release,
# bump `tag`/`revision`/`version` here, then copy this file into the tap.
#
# Source repo is private, so `url` uses git (not a release tarball): Homebrew
# clones it with the user's own git credentials, which is what you want for an
# internal tool.
class WorkspaceManagement < Formula
  desc "Per-task git worktree dev workspaces with subdomain serving (macOS/Valet)"
  homepage "https://github.com/vinson-vinson-vinson/workspace-management"
  url "https://github.com/vinson-vinson-vinson/workspace-management.git",
      using:    :git,
      tag:      "v0.1.0",
      revision: "14971d9eed4960b507575f486f8dda5934a21108"
  version "0.1.0"
  license "MIT"

  # Install the newest main with:  brew install --HEAD <tap>/workspace-management
  head "https://github.com/vinson-vinson-vinson/workspace-management.git", branch: "main"

  depends_on :macos
  depends_on "git"

  def install
    scripts = %w[
      create-workspace.sh
      remove-workspace.sh
      list-workspaces.sh
      serve-workspace.sh
    ]

    # The scripts stay together in libexec (they resolve their real dir via
    # symlink-following, so a bin/ symlink still points them back here). Each is
    # exposed on PATH under its name minus the `.sh`.
    libexec.install scripts
    scripts.each do |s|
      cmd = s.sub(/\.sh$/, "")
      bin.install_symlink libexec/s => cmd
    end

    # A packaged install has no writable config.sh next to the scripts, so ship
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

      The commands find that file automatically. To keep it elsewhere, point
      WSM_CONFIG at it.

      Runtime tools NOT installed by brew (checked at runtime by the scripts):
        - Laravel Valet (nginx + a wildcard cert)  — only for serve-workspace
        - the `code` CLI  (VS Code → "Shell Command: Install 'code' command")
        - yarn  (frontend dependency installs)
    EOS
  end

  test do
    # Sourcing config happens at load time, so point at the shipped template and
    # assert the usage banner prints. --help exits 0.
    ENV["WSM_CONFIG"] = "#{pkgshare}/config.example.sh"
    assert_match "Usage", shell_output("#{bin}/create-workspace --help")
  end
end
