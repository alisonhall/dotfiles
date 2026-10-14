# dotfiles

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

The installer doesn't replace your existing config files. It:

- adds a small block to `~/.bashrc`, `~/.bash_profile` and `~/.zshrc` that loads `shell/` from this repo, creating the files if needed. If the block is already there but out of date (e.g. you moved the repo), it's updated in place. If a file has two blocks, or a block with a missing marker line, it stops and asks you to fix it by hand rather than risk deleting your own lines. `~/.bash_profile` is skipped if it, or `~/.profile` on Linux, already loads `~/.bashrc`
- adds an include for `git/gitconfig` to the top of `~/.gitconfig` and backs up the original first, removing includes of a dotfiles gitconfig that no longer exists. If the include has been moved further down (where it would override your settings above it), it's moved back to the top
- creates `~/.shell_local` from [local.example.sh](local.example.sh)
- on macOS, points iTerm at `config/iterm` for its settings
- installs gitleaks if it's missing (see [Committing](#committing))
- before changing anything, stops if it's run as root, git is missing, or the repo's shell files have syntax errors or Windows line endings
- finally, starts a new bash (and zsh) shell and checks that it loads this repo, and that git loads the shared config

## What goes where

| | Shared (in this repo) | This machine only (not in the repo) |
| --- | --- | --- |
| Shell | `shell/` (see below) | `~/.shell_local` |
| Git | `git/gitconfig`, `git/gitignore_global`, `git/` tools (see below) | `~/.gitconfig` (below the include) |
| Prompt (zsh) | `config/p10k.zsh` | `~/.p10k.zsh`, if present, is used instead |
| iTerm (macOS) | `config/iterm/` | |
| VS Code | `config/vscode/` (not applied automatically - see below) | |
| Scripts | `bin/` (added to `PATH`) | |

Put anything personal, work-specific or specific to one computer in the local files, such as emails, server addresses or tool paths. They load after the shared files, so they override them.

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
| `git/branch-status.sh` | Richer branch status report: remote/PR state (via `gh`), worktree awareness, and squash-merge-aware "in base" detection. Run it with `git branch-report` (`git branch-status` runs `bin/git-branch-status`) |
| `git/wt/` | A git worktree manager, run as `wt` (see `wt help` once a shell has loaded this repo). Configure it per-repo with a `WT_*`-exporting alias in `~/.shell_local` (`wt help` documents the variables) |

### VS Code

Unlike the shell and git config, `config/vscode/` isn't linked in automatically by `install.sh`. It's a reference copy of portable editor settings and snippets:

| File | Contents |
| --- | --- |
| `config/vscode/settings.json` | User settings: formatter/ESLint/import-organizing on save, GitLens graph options, Jest run mode |
| `config/vscode/global.code-snippets` | Global snippets (JS/TS/React scaffolding) |

To use them, copy or symlink `config/vscode/settings.json` to VS Code's user `settings.json` (`code --locate-shell-integration-path` or Cmd+Shift+P → "Preferences: Open User Settings (JSON)" shows the path), and `config/vscode/global.code-snippets` into the same folder's `snippets/`. Merge rather than overwrite if you already have machine- or work-specific settings there.

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
| `getimagesfromlist.sh` | Download every image URL listed in a published Google Sheet (`IMAGE_LIST_CSV_URL` in `~/.shell_local`) |
| `my-debug-env` | Bash debugging helpers: `TRACE=1 BASH_ENV=my-debug-env ./some-script` |

## Committing

`install.sh` turns on a pre-commit hook that blocks commits containing:

- secrets, found by [gitleaks](https://github.com/gitleaks/gitleaks), which you need to install
- any string listed in `~/.dotfiles_blocklist`, a local list of your own emails, hostnames and similar
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
| `git/__test__/` | The `bclean`, `m`, `co-wip`/`coa-wip` and `merge-no-commit` git aliases, and `git/branch-status.sh` |
| `shell/common/__test__/` | `git_dev_branch`, which `dev`, `sprint`, `gmerge-dev` and others use |

Install bats with `brew install bats-core` (macOS), `sudo apt install bats` (Linux) or `npm install -g bats` (Git Bash). CI runs the tests on macOS (including its built-in bash 3.2), Linux and Windows. The commit hook doesn't, so commits stay fast and work without bats.

When writing tests, end every `[[ ... ]]` check with `|| false`, and check that something fails with `run ! command` rather than `! command`. macOS's bash 3.2 doesn't fail a test on a false `[[ ]]` unless it's the last line, and no bash fails one on `! command`, so those checks would silently pass.

Each test uses its own empty fake home folder, so running them never touches your real config. `install.sh` only runs when it's executed, so tests can `source` it to call its functions one at a time.
