# dotfiles

[![Test](https://github.com/alisonhall/dotfiles/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/alisonhall/dotfiles/actions/workflows/test.yml)

Shell (bash/zsh) and git config shared across machines. Works on macOS, Linux and Git Bash on Windows.

## Install

```sh
git clone <this repo> ~/dotfiles   # anywhere is fine
~/dotfiles/install.sh
```

Then open a new terminal. Re-running `install.sh` is safe, and repairs anything that's out of date.

### Where to put it

Anywhere permanent, called anything. `install.sh` works out where it is and points your shell and git at that folder, so:

- **Don't leave it in Downloads or a temporary folder,** and avoid cloud-synced folders (OneDrive, Dropbox, iCloud). Windows often syncs Desktop and Documents to OneDrive. `~/dotfiles` is a good choice. `install.sh` warns about these.
- **If you move or rename it later, run `install.sh` from the new location.** Until you do, new terminals print a message saying they can't find it.
- **Use `git clone`, not "Download ZIP".** A ZIP copy works, but can't be updated with `update-dotfiles` or committed from.
- **Only one copy is used at a time:** whichever you last ran `install.sh` from.

`install.sh` prints the repo and home folders it's using. On Windows it shows both forms, e.g. `/c/Users/you (C:\Users\you)`. In Git Bash, `~` is your Windows user folder (`C:\Users\<you>`) unless a `HOME` environment variable says otherwise. WSL is a separate Linux system with its own home folder, so clone and install there separately if you use it.

To check a machine without changing anything:

```sh
~/dotfiles/install.sh --check
```

Both report `PROBLEM`s (something is broken; exits with an error), `WARNING`s (likely to cause trouble, such as old config that still runs alongside the dotfiles, errors or slowness when a new shell starts, or `~/.gitconfig` overriding the shared settings) and `NOTE`s (reminders).

The installer doesn't replace your existing config files. Anything it does change or move (`~/.gitconfig`, a startup file's out-of-date block, a symlink it moves aside...) is backed up first, under its original path, to `local/backups/<date and time of the run>/` - for example `local/backups/20261022143000/HOME/.gitconfig`. One folder per run, all kept (they're small) until you delete them; never committed, since `local/` is gitignored here, and `install.sh` keeps `backups/` out of `local/`'s own git too (in `.git/info/exclude`, if `local/` is a repo whose `.gitignore` doesn't cover it). If `local/` has its own `install.sh`, it's told the same folder for its backups. It:

- adds a small block to `~/.bashrc`, `~/.bash_profile` and `~/.zshrc` that loads `shell/` from this repo, creating the files if needed. If the block is already there but out of date (e.g. you moved the repo), it's updated in place. If a file has two blocks, or a block with a missing marker line, it stops and asks you to fix it by hand rather than risk deleting your own lines. `~/.bash_profile` is skipped if it, or `~/.profile` on Linux, already loads `~/.bashrc`
- adds an include for `git/gitconfig` to the top of `~/.gitconfig` and backs up the original first, removing includes of a dotfiles gitconfig that no longer exists. If the include has been moved further down (where it would override your settings above it), it's moved back to the top
- creates `local/` (see below), asking first whether to set it up as its own git repo (defaulting to yes), and creates `local/shell_local.sh` from [local.example.sh](local.example.sh) if there's nothing to move yet
- moves an existing `~/.shell_local` and `~/.dotfiles_blocklist` into `local/` automatically; asks first before moving an existing `~/.p10k.zsh` or the settings below the include in `~/.gitconfig` (defaulting to yes). Say no (or just leave the file where it is) and everything keeps working from its original location - see [Local setup](#local-setup)
- on macOS, points iTerm at `config/iterm` for its settings
- on macOS, applies the settings in `config/macos/defaults` (Dock, Finder, trackpad...) that differ, after listing them and asking - see [macOS settings](#macos-settings)
- for zsh, installs oh-my-zsh (cloned to `~/.oh-my-zsh`; `shell/zshrc.sh` loads it and its plugins) and, where there's Homebrew, zsh-completions, plus powerlevel10k and its font for the prompt
- adds the settings VS Code needs (e.g. the terminal font for the prompt's icons) to VS Code's user settings, if they're missing - see [VS Code](#vs-code)
- installs gitleaks if it's missing (see [Committing](#committing))
- before changing anything, stops if it's run as root, git is missing, or the repo's shell files have syntax errors or Windows line endings
- finally, starts a new bash (and zsh) shell and checks that it loads this repo, and that git loads the shared config

## What goes where

| | Shared (in this repo) | This machine only (not in this repo - see [Local setup](#local-setup)) |
| --- | --- | --- |
| Shell | `shell/` (see below) | `local/shell_local.sh`, or `~/.shell_local` if you'd rather keep it there |
| Git | `git/gitconfig`, `git/gitignore_global`, `git/` tools (see below) | `local/gitconfig`, or directly in `~/.gitconfig` (below the include) |
| Prompt (zsh) | `config/p10k.zsh` | `local/p10k.zsh` or `~/.p10k.zsh` - whichever exists is used instead |
| npm/yarn | | `local/npmrc` (linked from `~/.npmrc`), if this machine needs a custom registry - most don't |
| Maven | | `local/m2-settings.xml` (linked from `~/.m2/settings.xml`), if this machine needs one - most don't |
| iTerm (macOS) | `config/iterm/` | |
| macOS settings | `config/macos/defaults` | |
| VS Code | `config/vscode/` (not applied automatically - see below) | |
| Scripts | `bin/` (added to `PATH`) | |

Put anything personal, work-specific or specific to one computer in the local files, such as emails, server addresses or tool paths. They load after the shared files, so they override them.

### Local setup

`local/` is an optional place to keep everything from the table above that's specific to this machine - shell settings, git identity, the commit-blocklist, an optional prompt override - together (it's ignored by this repo, via `.gitignore`). Normally it's its own git repo too, so it can be versioned, diffed and even backed up to your own private remote, independently of this shared repo.

**Sharing it across your machines:** `local/` can be a clone of your own private repo (`git clone <your private repo> ~/dotfiles/local`, before running `install.sh`). Keep what's specific to one machine out of that repo with its own `.gitignore` - at least `secrets.sh`, plus anything like a machine-only settings file. If `local/` has an `install.sh`, this repo's `install.sh` runs it after setting up git (so `~/.gitconfig` already includes `local/gitconfig`) and before linking `~/.npmrc` and `~/.m2/settings.xml` - so a private repo can do its own setup, such as picking between work and personal settings. `install.sh --check` runs it with `--check` too. Its problems show up as a warning rather than stopping `install.sh`.

`install.sh` never overwrites a file that's already in `local/` - your repo's own `shell_local.sh`, `README.md`, `gitconfig` and so on stay as they are, and it only adds what's missing (`secrets.sh`, the pre-commit hook, the `secrets.sh` line in `.gitignore`). When it commits in `local/`, it commits only the files it created or changed itself, never your own work in progress. If you have other changes staged there, it leaves its own uncommitted too, and says so.

Nothing requires using it, though: `shell/bashrc.sh` and `shell/zshrc.sh` check `local/shell_local.sh` first and fall back to `~/.shell_local` if that's what you have; `shell/zshrc.sh` does the same for `local/p10k.zsh` vs `~/.p10k.zsh`; and `.githooks/pre-commit` checks `local/dotfiles_blocklist` before falling back to `~/.dotfiles_blocklist`. A gitconfig setting (`user.name`, `user.email`, anything else) works identically whether it's in `local/gitconfig` or directly in `~/.gitconfig` below the include - git doesn't care which. If it's in both with different values, the one in `~/.gitconfig` wins, since it's read after the include; `install.sh --check` warns when that happens.

`local/npmrc` and `local/m2-settings.xml` are only for machines that need a custom npm/yarn registry or Maven settings, so `install.sh` never creates them. When one exists, `install.sh` links the place the tool looks (`~/.npmrc`, `~/.m2/settings.xml`) to it, so the terminal, scripts and IDEs all use it - an environment variable or shell function would only reach programs started from a terminal. If you already have `~/.npmrc` or `~/.m2/settings.xml`, it asks to move it into `local/` and link it back (defaulting to yes); if both exist and differ, it warns and leaves both alone. A file that looks like it holds passwords or tokens is added to `local/.gitignore`, like `secrets.sh`: still linked and used, never committed. On Windows the links need Developer Mode (or admin rights), otherwise `install.sh` says so and leaves things as they are.

`install.sh` creates `local/` the first time it runs, asking first whether to set it up as its own git repo (defaulting to yes). **Answering no doesn't break anything** - every file in `local/` still works exactly the same; it just isn't versioned, diffed or backed up on its own, since there's no repo there to do that. Either way, `local/README.md`, `local/.gitignore`, `local/secrets.sh` and `local/.githooks/pre-commit` are created too, so it's ready to become a repo later - just run `git init` in it yourself, then `git config core.hooksPath .githooks` to turn its pre-commit hook on (or re-run `install.sh`, which does that for you).

Real secrets (API tokens, credentials) go in `local/secrets.sh`, not `local/shell_local.sh`: it's listed in `local/.gitignore`, so it's never staged, committed or scanned - `local/`'s pre-commit hook only checks it for shell syntax errors. `shell_local.sh` sources it automatically, before everything else in that file, so values set there (`ARTIFACTORY_AUTH_TOKEN`, etc.) are available to the rest of it. `install.sh` adds that sourcing line to `shell_local.sh` itself if it's missing - whether `shell_local.sh` just came from [local.example.sh](local.example.sh) (which already has it) or already existed before `secrets.sh` did.

It moves an existing `~/.shell_local` and `~/.dotfiles_blocklist` into `local/` automatically (there's no real downside to that move, so it doesn't ask); for `~/.p10k.zsh` and whatever's below the include in `~/.gitconfig`, it asks first, defaulting to yes. **Answering no doesn't break anything** here either - the shell and git fallbacks above mean that file keeps working exactly as before, from its original location. The only difference is that it isn't versioned, diffed or backed up alongside everything else in `local/`.

`install.sh` adds a second include for `local/gitconfig` to `~/.gitconfig`, right after the shared one (so it still overrides it), whether or not you accept moving anything into it.

A remote for `local/`'s own history is entirely up to you - `install.sh` never sets one, so push/pull across your machines stays a manual step. `local/secrets.sh` itself is gitignored, so it never reaches that remote either way - but `local/gitconfig` and `local/shell_local.sh` can still end up with personal details (email, server addresses) if you put them there; treat any remote you push `local/` to with the same care.

### Shell files

| File | Contents |
| --- | --- |
| `shell/bashrc.sh`, `shell/zshrc.sh` | Shell-specific setup (oh-my-zsh, prompt, completion); each loads `common.sh` |
| `shell/common.sh` | Environment, `PATH`, tool setup (Homebrew, nvm/fnm, jenv, pyenv, rbenv, z) |
| `shell/common/*.sh` | Aliases and functions for both shells: terminal, system, dev, git |
| `shell/os/mac.sh`, `shell/os/linux.sh`, `shell/os/windows.sh` | OS-specific versions, loaded last on that OS only |

Run `showa <text>` to find where an alias or function is defined.

Tools that edit your shell config themselves (conda, nvm and similar) write to `~/.zshrc` / `~/.bashrc` and not to this repo, which is what you want.

### Git tools

These live in `git/` rather than `bin/` because you run them through a git alias or shell function, not by name, so they don't need to be on `PATH`:

| File | Contents |
| --- | --- |
| `git/branch-report.sh` | Richer branch status report: remote/PR state (via `gh`), worktree awareness, and squash-merge-aware "in base" detection. Run it with `git branch-report` (`git branch-status` runs `bin/git-branch-status`) |
| `git/wt/` | A git worktree manager, run as `wt`. Configure it per-repo with a `WT_*`-exporting alias in `local/shell_local.sh` (or `~/.shell_local`). See [git/wt/README.md](git/wt/README.md), which also covers installing it on its own |

### VS Code

Unlike the shell and git config, `config/vscode/` isn't linked in automatically by `install.sh` - VS Code edits its own settings file all the time, so a link would turn every change into an edit to this repo. It's a reference copy of portable editor settings and snippets:

| File | Contents |
| --- | --- |
| `config/vscode/settings.json` | User settings: the terminal font, formatter/ESLint/import-organizing on save, GitLens graph options, Jest run mode |
| `config/vscode/global.code-snippets` | Global snippets (JS/TS/React scaffolding) |

To use them, copy or symlink `config/vscode/settings.json` to VS Code's user `settings.json` (`code --locate-shell-integration-path` or Cmd+Shift+P → "Preferences: Open User Settings (JSON)" shows the path), and `config/vscode/global.code-snippets` into the same folder's `snippets/`. Merge rather than overwrite if you already have machine- or work-specific settings there.

**Settings `install.sh` adds:** a few settings VS Code needs for the dotfiles to look right are added to VS Code's own user settings by `install.sh`, if they're missing (the list is `VSCODE_SETTINGS` in `install.sh`). Anything you've already set - even to a different value - is left as it is and noted, the rest of the file isn't touched, and it's backed up first. It only does this where VS Code has been used (its settings folder exists); `install.sh --check` notes what's missing. For now the list is just the terminal font: the zsh prompt's icons need an icon font, but VS Code's terminal doesn't use iTerm's settings, so `install.sh` sets `"terminal.integrated.fontFamily": "MesloLGS NF"` - the font it installs for the prompt, and the one `config/iterm` uses.

## macOS settings

`config/macos/defaults` lists Dock, Finder, trackpad and other settings, one per line: `<domain> <key> <type> <value>`, the arguments to `defaults write`. On macOS, `install.sh` lists the ones this Mac has set differently and asks before applying them; `install.sh --check` only lists them. The old values are saved as a script that puts them back, in that run's backups folder (`local/backups/<date and time>/macos-defaults-restore.sh`). Without a terminal to ask in (e.g. in CI), nothing is changed.

To add one, find its domain and key by comparing `defaults read <domain>` before and after changing it in System Settings. Some (like scrolling direction and tap to click) only take effect after logging out and back in.

## Scripts

Everything in `bin/` is on your `PATH`.

| Script | What it does |
| --- | --- |
| `colours_and_formatting.sh` | Reference for terminal colour and formatting codes (`-a` for everything) |
| `timestamps.sh` | Common `date` formats, with their output right now |
| `format-git-objects.sh` | Source it to get `$allFormatOptions`, a list of every `git for-each-ref --format` field |
| `git-branch-status` | How far each branch is ahead of or behind its upstream ([upstream project](https://github.com/bill-auger/git-branch-status), GPLv3) |
| `remove-merged-branches` | Delete local branches merged into the current one, after you review the list |
| `screenshots-of-urls` | Screenshot a page at several widths with Firefox: `screenshots-of-urls <url> [folder] [widths...]` |
| `createpdf.sh`, `createallpdfs.sh` | Make a PDF from the images in a folder (or each subfolder). Needs ImageMagick and exiftool |
| `combinepdfs.sh` | Combine the PDFs in a folder into one. Needs Ghostscript and exiftool |
| `cleanjpgfilenames.sh` | Remove anything after `.jpg` in file names (e.g. `photo.jpg?w=800`) |
| `getimagesfromlist.sh` | Download every image URL listed in a published Google Sheet (`IMAGE_LIST_CSV_URL` in `local/shell_local.sh` or `~/.shell_local`) |
| `my-debug-env` | Bash debugging helpers: `TRACE=1 BASH_ENV=my-debug-env ./some-script` |

## Committing

`install.sh` turns on a pre-commit hook that blocks commits containing:

- secrets, found by [gitleaks](https://github.com/gitleaks/gitleaks), which you need to install
- any string listed in `local/dotfiles_blocklist` (or `~/.dotfiles_blocklist`), a local list of your own emails, hostnames and similar, checked by `tools/check-blocklist.sh`. Each line is matched anywhere, ignoring case. A line starting with `re:` is an extended regular expression instead, such as `re:PROJ-[0-9]{4,}` for every ticket number like `PROJ-1234`. Links to this repo on GitHub (from its `origin` remote) are allowed, even though they contain your user name. Commit messages are public too, so a commit-msg hook checks them against the same list
- shell syntax errors or Windows line endings, checked by `tools/check-syntax.sh`
- paths that only work on one machine, checked by `tools/check-paths.sh`: this repo's own location, absolute paths to its files (use `"$DOTFILES/bin/..."` instead), or a home folder with a user name in it (use `$HOME` or `~`). To allow a line on purpose, add a comment containing `path-check: ignore`
- things that work on one OS but not another, checked by `tools/check-portability.sh`:
  - file names Windows can't create (`?`, `:`, `CON.md`, a trailing dot...), or names differing only in case
  - very long paths, symlinks, and scripts missing their executable bit (easy to lose when committing from Windows)
  - unquoted path variables, which break on paths with spaces (`C:\Users\Jane Doe`, `/Library/Application Support`)
  - backslash Windows paths in shell code
  - Mac- or Windows-only paths outside `shell/os/` without an OS or exists check
- broken or OS-specific aliases, checked by `tools/check-aliases.sh`:
  - shell aliases with syntax errors in their bodies, names a shell rejects, or double quotes that expand `$VAR` too early
  - commands an OS doesn't have (e.g. `pbcopy`, `clip`, `lsof` in Git Bash) without a version in `shell/os/` for that OS
  - options only in the GNU (Linux, Git Bash) or BSD (macOS) version of a tool, like `sed -i`, `date --utc` or `grep -P`
  - git aliases git can't run (`git ...` inside an alias, built-in names, loops), and `!` aliases with syntax errors or bash-only syntax (git runs them with `sh`, which is `dash` on Ubuntu and WSL)

  To allow a line on purpose, add a comment containing `alias-check: ignore`.

`local/` gets its own, smaller pre-commit hook if it's a git repo (see [Local setup](#local-setup)): secrets (gitleaks) and shell syntax errors in `shell_local.sh`, `secrets.sh`, `p10k.zsh` and any other staged `.sh` file (e.g. a private repo's own shell files), since that folder isn't public - no blocklist or cross-OS checks. `install.sh` creates the hook only if `local/` doesn't have one, so an older copy keeps working as it was until you update it. `secrets.sh` is gitignored, so gitleaks never actually sees it; that's where real tokens and credentials belong instead of in `shell_local.sh`.

## Tests

Tests live in `__test__` folders next to the code they test (e.g. `__test__/install.bats` tests `install.sh`), and use [bats-core](https://github.com/bats-core/bats-core). Run them all with:

```sh
tools/run-tests.sh                      # or: tools/run-tests.sh --filter setup_git
```

What's tested:

| Folder | Tests |
| --- | --- |
| `__test__/` | `install.sh`: the shell blocks it manages, and the order of `~/.gitconfig` |
| `tools/__test__/` | Each `check-*.sh` flags a bad example and passes a good one, in a throwaway git repo |
| `shell/__test__/` | `path_add` and the Homebrew setup in `shell/common.sh` |
| `git/__test__/` | The `bclean`, `m`, `co-wip`/`coa-wip` and `merge-no-commit` git aliases, and `git/branch-report.sh` |
| `shell/common/__test__/` | `git_dev_branch`, which `dev`, `sprint`, `gmerge-dev` and others use |

Install bats with `brew install bats-core` (macOS), `sudo apt install bats` (Linux) or `npm install -g bats` (Git Bash). CI runs the tests on macOS (including its built-in bash 3.2), Linux and Windows. The commit hook doesn't, so commits stay fast and work without bats.

When writing tests, end every `[[ ... ]]` check with `|| false`, and check that something fails with `run ! command` rather than `! command`. macOS's bash 3.2 doesn't fail a test on a false `[[ ]]` unless it's the last line, and no bash fails one on `! command`, so those checks would silently pass.

Each test uses its own empty fake home folder, so running them never touches your real config. `install.sh` only runs when it's executed, so tests can `source` it to call its functions one at a time.
