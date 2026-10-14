# wt: a git worktree manager

`wt` keeps one folder per branch, side by side, so you can switch branches by changing folders instead of stashing and checking out:

```
~/code/my-repo/          <- the "collection" folder
├── main/                <- the main worktree (a normal clone)
├── feature_login/       <- branch feature/login
└── fix_TICKET-12_typo/  <- branch fix/TICKET-12/typo
```

`wt add <branch>` creates a worktree for a branch and moves you into it, `wt ls` shows the state of every worktree, and `wt clean` removes the ones whose PRs are finished. Folder names are the branch name with `/` replaced by `_`.

These scripts are part of [github.com/alisonhall/dotfiles](https://github.com/alisonhall/dotfiles), but don't depend on anything else in it. You can download just this folder.

## Requirements

| | Needed for |
| --- | --- |
| bash, git | Everything. Your interactive shell can be bash or zsh |
| [gh](https://cli.github.com), logged in (`gh auth login`) | `wt clean` (required). Optional for `wt add`/`wt cd`, to recover a branch whose PR was squash-merged and deleted |
| node 14.18 or later | Optional. Only for monorepos with npm/yarn workspaces (see [Node projects](#node-projects)) |

Written for macOS and Linux. It also runs in Git Bash on Windows, with [some limits](#windows).

## Install

### 1. Download the scripts

Either download this folder once:

```sh
mkdir -p ~/.local/share/wt
curl -fsSL https://github.com/alisonhall/dotfiles/archive/refs/heads/main.tar.gz |
	tar -xz --strip-components=3 -C ~/.local/share/wt dotfiles-main/git/wt
```

Or clone just this folder with git, so you can update it later with `git -C ~/.local/share/wt-repo pull`:

```sh
git clone --depth 1 --filter=blob:none --sparse https://github.com/alisonhall/dotfiles.git ~/.local/share/wt-repo
git -C ~/.local/share/wt-repo sparse-checkout set git/wt
```

The scripts are then in `~/.local/share/wt-repo/git/wt` instead of `~/.local/share/wt`. Use that path in the next step.

### 2. Load `wt` in your shell

Add this to `~/.zshrc` or `~/.bashrc`:

```sh
. ~/.local/share/wt/wt.sh
```

This defines a `wt` shell function. It has to be a function rather than a script on your `PATH`, because a script can't change your shell's current folder, and `wt add`, `wt cd` and `wt main` do.

### 3. Tell `wt` where your repo is

`wt` reads its settings from environment variables, so it can manage several repos. Give each repo an alias in the same file:

```sh
alias my-repo-wt='WT_WORKTREE_REPO_LOCATION="$HOME/code/my-repo" WT_REPO_SLUG=owner/my-repo wt'
```

Then use `my-repo-wt ls`, `my-repo-wt add feature/login` and so on. If you only use `wt` with one repo, you can `export` the variables instead and run `wt` directly.

### 4. Set up the collection folder

`wt` expects the main worktree to be a folder named `main` inside the collection folder, even if your default branch has another name. For a fresh start:

```sh
mkdir -p ~/code/my-repo
git clone git@github.com:owner/my-repo.git ~/code/my-repo/main
```

To use a clone you already have, move it to `<collection folder>/main`. A bare-repo layout (`my-repo/.bare` with a `my-repo/main` worktree) also works.

Open a new terminal and run `wt help` to check it's loaded.

## Commands

| Command | What it does |
| --- | --- |
| `wt add <branch>` | Creates a worktree for the branch and moves into it. Tracks the remote branch if it exists; otherwise creates a new branch from `CURRENT_DEV_BRANCH` (`main` by default). If the folder already exists, just moves into it |
| `wt cd <branch>` | Moves into the branch's worktree and fetches its remote branch (it doesn't merge or pull). Runs `wt add` first if the worktree doesn't exist |
| `wt main` | Moves into the main worktree |
| `wt ls [--no-fetch]` | For every worktree: its branch, whether its remote branch still exists, uncommitted and untracked changes, and how far ahead/behind it is. Read-only. `--no-fetch` skips the `git fetch` and works offline |
| `wt clean [--apply] [--keep-branch] [--older-than 30d]` | Removes worktrees whose PRs are closed or merged. A dry run unless you pass `--apply`. See [what `wt clean` keeps](#what-wt-clean-keeps) |
| `wt rm <branch>` | Deletes the branch's worktree folder and prunes git's record of it. **This doesn't check anything first**: uncommitted changes in that folder are lost. `wt clean` is the safe way to tidy up |
| `wt link [<branch> \| --all] [--check] [--no-workspaces]` | Checks and repairs a worktree's symlinks to `main` (see [Shared files](#shared-files-node_modules-env)) |
| `wt help` | Lists the commands and settings |

`wt add` and `wt cd` take the branch name as it is on the remote (`feature/login`), not the folder name.

### What `wt clean` keeps

`wt clean` checks the PR state with `gh`, because squash merges leave nothing in git's history that shows a branch was merged. It only removes a worktree when all of these are true:

1. Its PR is closed or merged.
2. The branch was pushed at some point.
3. It has no commits that aren't on the remote branch (or, once that's deleted, on the PR).
4. It has no uncommitted changes, and no untracked or ignored files other than symlinks and build output (`node_modules`, `dist`, `build`, `coverage` and the like).
5. It has no stashes.

Anything it keeps is listed with the reason. With `--apply` it also deletes the local branch, unless you pass `--keep-branch`. Branches in `WT_PROTECTED_BRANCHES` are never removed.

## Settings

| Variable | Default | |
| --- | --- | --- |
| `WT_WORKTREE_REPO_LOCATION` | (required) | The collection folder, which contains `main/` |
| `WT_REPO_SLUG` | (required for `wt clean`) | The GitHub repo, as `owner/repo` |
| `CURRENT_DEV_BRANCH` | `main` | The branch new branches start from |
| `CURRENT_REMOTE_NAME` | `origin` | The remote to compare against |
| `WT_PROTECTED_BRANCHES` | `main` | Branches `wt clean` never removes, separated by spaces |
| `WT_SAFE_ARTIFACTS` | | More files or folders that `wt clean` may delete along with a worktree, separated by spaces (e.g. `.cache bundle-analysis.html`) |
| `WT_SYMLINK_PAIRS` | | Paths each new worktree links to the same path in `main`, separated by spaces (e.g. `.env .cache`) |

## Shared files (node_modules, .env)

New worktrees get a `node_modules` symlink to `main/node_modules`, so you don't have to reinstall dependencies for every branch. Add other files that should be shared rather than copied, like `.env`, to `WT_SYMLINK_PAIRS`. `wt link --check --all` shows which worktrees have missing or broken links, and `wt link --all` fixes them. It reports, but never replaces, a real file or folder in place of a link, since that may hold real content.

In a repo with no `main/node_modules`, the `node_modules` link points at nothing. It's harmless, and on Windows `ln` prints an error instead.

### Node projects

In a monorepo with npm/yarn `workspaces`, the shared `node_modules` would make imports of your own packages (`@scope/pkg`) load `main`'s copy of them. With node installed, `wt add` and `wt link` add small links (via `link-workspaces.mjs`) so those imports load the current worktree's code instead. Other repos aren't affected.

## Windows

`wt` runs in Git Bash, with these limits:

- **Symlinks:** Git Bash's `ln -s` copies the folder instead of linking it, so each worktree gets its own copy of `node_modules`. For real symlinks, turn on Windows Developer Mode and set `MSYS=winsymlinks:nativestrict` (for example in `~/.bashrc`).
- **`wt ls`** marks every worktree `[outside]` because Git Bash writes the same folder in two forms (like `/c/Users/...` and `C:/Users/...`). The rest of its report is right.

## Uninstall

Remove the lines you added to `~/.zshrc` or `~/.bashrc`, and delete `~/.local/share/wt` (or `~/.local/share/wt-repo`). Your worktrees are ordinary git worktrees, so `git worktree list` and `git worktree remove` still work without `wt`.
