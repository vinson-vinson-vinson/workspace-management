# Packaging: a private Homebrew tap

This ships `workspace-management` to the anny team via Homebrew, so people can:

```bash
brew install vinson-vinson-vinson/tap/workspace-management
brew upgrade workspace-management
brew uninstall workspace-management
```

You only ever made git repos before — good news: **a Homebrew tap is just a git
repo** with one Ruby file in it. There's no registry to publish to, no account to
create, no build step. The whole thing is two git repos:

| Repo | What it is | Public/Private |
| --- | --- | --- |
| `workspace-management` (this one) | the actual scripts | private |
| `homebrew-tap` (new, you create it) | one formula file pointing at releases of this repo | private |

The formula (`packaging/workspace-management.rb` here) is the recipe: "clone this
tag, drop the scripts in, link them onto PATH." The canonical copy lives in this
repo; the *live* copy lives in the tap.

---

## One-time setup

### 1. Cut a release of THIS repo

Homebrew installs a fixed version, not "whatever's on main," so you tag a release.

```bash
cd workspace-management
git tag v0.1.0
git push origin v0.1.0

# Grab the commit the tag points at — the formula pins it for integrity:
git rev-list -n1 v0.1.0
```

### 2. Fill in the formula

Edit `packaging/workspace-management.rb`:
- `tag:` → `"v0.1.0"`
- `revision:` → the 40-char SHA from `git rev-list -n1 v0.1.0`
- `version` → `"0.1.0"`

(`homepage`/`url` already point at `vinson-vinson-vinson/workspace-management` —
change the owner if the repo moves to an org.)

### 3. Create the tap repo

A tap repo MUST be named `homebrew-<something>`. The `homebrew-` prefix is magic
and gets stripped in commands, so `homebrew-tap` → you refer to it as `tap`.

```bash
# On GitHub: create a PRIVATE repo named  homebrew-tap  under your account/org.
# Then locally:
mkdir homebrew-tap && cd homebrew-tap
git init
mkdir Formula
cp ../workspace-management/packaging/workspace-management.rb Formula/
git add . && git commit -m "Add workspace-management formula"
git branch -M main
git remote add origin git@github.com:vinson-vinson-vinson/homebrew-tap.git
git push -u origin main
```

### 4. Tap it and install (each teammate does this once)

Because the tap is **private**, teammates tap it by its git URL (so Homebrew uses
their SSH credentials) rather than the short name:

```bash
brew tap vinson-vinson-vinson/tap git@github.com:vinson-vinson-vinson/homebrew-tap.git
brew install vinson-vinson-vinson/tap/workspace-management
```

The source repo is private too — the formula clones it over git, so each person
needs read access to `workspace-management` (SSH key on GitHub). That's the only
auth requirement; there are no tokens to distribute.

Then the one-time config step Homebrew prints in its caveats:

```bash
mkdir -p ~/.config/workspace-management
cp "$(brew --prefix)/share/workspace-management/config.example.sh" \
   ~/.config/workspace-management/config.sh
$EDITOR ~/.config/workspace-management/config.sh
```

---

## Shipping an update later

```bash
# 1. In workspace-management: tag the new release.
git tag v0.2.0 && git push origin v0.2.0
git rev-list -n1 v0.2.0            # copy the SHA

# 2. Update packaging/workspace-management.rb (tag, revision, version), commit.

# 3. Copy it into the tap and push.
cp packaging/workspace-management.rb ../homebrew-tap/Formula/
cd ../homebrew-tap && git commit -am "workspace-management 0.2.0" && git push

# 4. Teammates get it with:
brew update && brew upgrade workspace-management
```

---

## Testing the formula before you publish

You don't need the tap repo to test — point brew at the local file:

```bash
brew install --build-from-source ./packaging/workspace-management.rb
brew test workspace-management
brew audit --strict --formula ./packaging/workspace-management.rb   # style/lint
```

For fast iteration on `main` without tagging, the formula has a `head` block:

```bash
brew install --HEAD vinson-vinson-vinson/tap/workspace-management
```

---

## Why a tap and not npm / brew-core

- **npm** is for JavaScript; this is macOS-only Bash. Shipping shell through npm
  works but is unidiomatic and drags Node in for no benefit.
- **homebrew-core** (plain `brew install workspace-management`) only accepts
  notable, general-purpose tools — not internal team tooling. A private tap is
  the supported path for exactly this case.
