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

- adds a small block to `~/.bashrc`, `~/.bash_profile` and `~/.zshrc` that loads `shell/` from this repo, creating the files if needed. If the block is already there but out of date (e.g. you moved the repo), it's updated in place. `~/.bash_profile` is skipped if it, or `~/.profile` on Linux, already loads `~/.bashrc`
- adds an include for `git/gitconfig` to the top of `~/.gitconfig` and backs up the original first, removing includes of a dotfiles gitconfig that no longer exists
- creates `~/.shell_local` from [local.example.sh](local.example.sh)
- on macOS, points iTerm at `config/iterm` for its settings
- installs gitleaks if it's missing (see [Committing](#committing))
- before changing anything, stops if it's run as root, git is missing, or the repo's shell files have syntax errors or Windows line endings
- finally, starts a new bash (and zsh) shell and checks that it loads this repo, and that git loads the shared config

## What goes where

| | Shared (in this repo) | This machine only (not in the repo) |
| --- | --- | --- |
| Shell | `shell/` (see below) | `~/.shell_local` |
| Git | `git/gitconfig`, `git/gitignore_global` | `~/.gitconfig` (below the include) |
| Prompt (zsh) | `config/p10k.zsh` | `~/.p10k.zsh`, if present, is used instead |
| iTerm (macOS) | `config/iterm/` | |
| Scripts | `bin/` (added to `PATH`) | |

Put anything personal, work-specific or specific to one computer in the local files, such as emails, server addresses or tool paths. They load after the shared files, so they override them.

### Shell files

| File | Contents |
| --- | --- |
| `shell/bashrc.sh`, `shell/zshrc.sh` | Shell-specific setup (oh-my-zsh, prompt, completion); each loads `common.sh` |
| `shell/common.sh` | Environment, `PATH`, tool setup (nvm/fnm, jenv, pyenv, rbenv, z) |
| `shell/common/*.sh` | Aliases and functions for both shells: terminal, system, dev, git |
| `shell/os/mac.sh`, `shell/os/windows.sh` | OS-specific versions, loaded last on that OS only |

Run `showa <text>` to find where an alias or function is defined.

Tools that edit your shell config themselves (conda, nvm and similar) write to `~/.zshrc` / `~/.bashrc` and not to this repo, which is what you want.

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
