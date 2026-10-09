# dotfiles

Shell (bash/zsh) and git config shared across machines. Works on macOS, Linux and Git Bash on Windows.

## Install

```sh
git clone <this repo> ~/dotfiles   # anywhere is fine
~/dotfiles/install.sh
```

Then open a new terminal. Re-running `install.sh` is safe.

The installer doesn't replace your existing config files. It:

- adds a small block to `~/.bashrc`, `~/.bash_profile` and `~/.zshrc` that loads `shell/` from this repo
- adds an include for `git/gitconfig` to the top of `~/.gitconfig` and backs up the original first
- creates `~/.shell_local` from [local.example.sh](local.example.sh)

## What goes where

| | Shared (in this repo) | This machine only (not in the repo) |
|---|---|---|
| Shell | `shell/` (see below) | `~/.shell_local` |
| Git | `git/gitconfig`, `git/gitignore_global` | `~/.gitconfig` (below the include) |
| Prompt (zsh) | `config/p10k.zsh` | `~/.p10k.zsh`, if present, is used instead |
| Scripts | `bin/` (added to `PATH`) | |

Put anything personal, work-specific or specific to one computer in the local files, such as emails, server addresses or tool paths. They load after the shared files, so they override them.

### Shell files

| File | Contents |
|---|---|
| `shell/bashrc.sh`, `shell/zshrc.sh` | Shell-specific setup (oh-my-zsh, prompt, completion); each loads `common.sh` |
| `shell/common.sh` | Environment, `PATH`, tool setup (nvm/fnm, jenv, pyenv, rbenv, z) |
| `shell/common/*.sh` | Aliases and functions for both shells: terminal, system, dev, git |
| `shell/os/mac.sh`, `shell/os/windows.sh` | OS-specific versions, loaded last on that OS only |

Run `showa <text>` to find where an alias or function is defined.

Tools that edit your shell config themselves (conda, nvm and similar) write to `~/.zshrc` / `~/.bashrc` and not to this repo, which is what you want.

## Committing

`install.sh` turns on a pre-commit hook that blocks commits containing:

- secrets, found by [gitleaks](https://github.com/gitleaks/gitleaks), which you need to install
- any string listed in `~/.dotfiles_blocklist`, a local list of your own emails, hostnames and similar
