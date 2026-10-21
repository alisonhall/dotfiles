# Git shortcuts. Loaded by shell/common.sh (bash and zsh).
# Most git aliases live in git/gitconfig - run `g aliases` to list them.
#
# CURRENT_REMOTE_NAME (default: origin) and CURRENT_DEV_BRANCH (default: the remote's
# default branch, e.g. main) can be set in local/shell_local.sh.

alias g='git'

git_repository_url () {
	git config --get "remote.$CURRENT_REMOTE_NAME.url"
}
parse_git_branch () {
	git branch 2> /dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/\1/'
}
# The branch work gets merged into: $CURRENT_DEV_BRANCH if set, otherwise the remote's default branch
git_dev_branch () {
	if [ -n "${CURRENT_DEV_BRANCH:-}" ]; then
		echo "$CURRENT_DEV_BRANCH"
		return
	fi
	local remote_head
	remote_head="$(git symbolic-ref --quiet --short "refs/remotes/$CURRENT_REMOTE_NAME/HEAD" 2>/dev/null)"
	echo "${remote_head#"$CURRENT_REMOTE_NAME"/}" | sed 's/^$/main/'
}

alias gs='git status'                                   # gs
alias gadd='git add -A'                                 # gadd      # git add all
gcom () { git commit -m "$*"; }                         # gcom      # git commit with the rest of the line as the message
alias gpush='git push'                                  # gpush     # git push
alias gpushv='git push --no-verify'                     # gpushv
alias gpush-reset='git push "$CURRENT_REMOTE_NAME" "$(parse_git_branch)" --force'
alias gpull='git pull'                                  # gpull

gcherry-pick-no-commit () { git cherry-pick --no-commit "$@"; }
gcherry-pick-commit () { git cherry-pick "$@"; }
gcherry-pick-edit-commit () { git cherry-pick --edit "$@"; }
gcommit-changes () { git diff "$1^!"; }                 # gcommit-changes <commit>: Changes made in one commit
gcommit-compare () { git diff "$1" "$2"; }
gcommit-changes-print () { git diff-tree -p "$1"; }

gshow () { git show "$@"; }
gshow-file-names () { git show --pretty="" --name-only "$@"; }
gshow-file-names2 () { git diff-tree --no-commit-id --name-only -r "$@"; }

alias g-='git checkout -'                               # g-        # checkout the previous branch
g-n () { git checkout "@{-$1}"; }                       # g-n       # checkout the nth previous branch

gforce-push () { git push "$CURRENT_REMOTE_NAME" "+$1"; }   # force local branch to override server branch named
gstash-staged () {
	#Stash everything temporarily.  Keep staged files, discard everything else after stashing.
	git stash --keep-index

	#Stash everything that remains (only the staged files should remain)  This is the stash we want to keep, so give it a name.
	git stash save "$1"

	#Apply the original stash to get us back to where we started.
	git stash apply stash@{1}

	#Create a temporary patch to reverse the originally staged changes and apply it
	git stash show -p | git apply -R

	#Delete the temporary stash
	git stash drop stash@{1}
}
gbranch-range () { git rev-list --simplify-by-decoration -2 "$@"; }    # enter the branch name
gbranch-range-here () { git rev-list --simplify-by-decoration -2 HEAD; }

gcommits-on-branch () {                                 # enter the branch name
	local commit_range
	commit_range="$(gbranch-range "$@")"
	git log --oneline --decorate --graph "${commit_range//$'\n'/...}"
}
gcommits-on-branch-here () {
	local commit_range
	commit_range="$(gbranch-range-here)"
	git log --oneline --decorate --graph "${commit_range//$'\n'/...}"
}
gdiff-on-branch () { git diff $(gbranch-range "$@"); }  # enter the branch name
gdiff-on-branch-here () { git diff $(gbranch-range-here); }
alias gdiff-dev='git diff "$(git_dev_branch)"'

gfile-history () { git log --follow "$@"; }             # enter the path to the file

alias sprint='git checkout "$(git_dev_branch)"'                                     # sprint
alias dev='git checkout "$(git_dev_branch)"'                                        # dev
alias gpull-dev='git pull "$CURRENT_REMOTE_NAME" "$(git_dev_branch):$(git_dev_branch)" --verbose'    # gpull-dev
alias gmerge-dev='git merge "$(git_dev_branch)"'                                    # gmerge-dev

alias gb-notmerged='git branch --no-merged "$(git_dev_branch)"'
alias gb-remove-merged='git branch --merged | grep -Ev "(^\*|main|master|$(git_dev_branch))" | xargs git branch -d'
alias gprune='git remote prune "$CURRENT_REMOTE_NAME"'
gb-compare-to-dev () { git log "$1" --not "$(git_dev_branch)" --stat; }
alias gb-not-merged-to-dev='git branch --no-merged "$(git_dev_branch)"'
alias gmerge-no-commit='git merge --no-commit --no-ff'

create-temp-worktree () {
	git worktree add -b temporary-branch ../temporary-worktree "$(git_dev_branch)" &&
		pushd ../temporary-worktree
}
remove-temp-worktree () {
	popd
	git worktree remove ../temporary-worktree
}

# wt: git worktree manager (git/wt/) for a collection of worktrees checked out
# side by side. Project/user-agnostic - it reads WT_* env vars instead of
# hardcoding anything. There are no shared WT_* defaults here: each repo you
# manage worktrees for gets its own alias in local/shell_local.sh that passes its
# WT_* values to the `wt` function, e.g.:
#   alias my-repo-wt="WT_WORKTREE_REPO_LOCATION=\$HOME/Sites/my-repo-worktrees WT_REPO_SLUG=owner/repo wt"
# `wt help` lists every command and all the WT_* variables.
WT_DIR="$DOTFILES/git/wt"
[ -f "$WT_DIR/wt.sh" ] && . "$WT_DIR/wt.sh"

#   ---------------------------------------
#   GIT ALIAS COMPLETIONS
#   ---------------------------------------

# Tab completion for the git aliases in git/gitconfig.
# Inner functions listed here: https://github.com/git/git/blob/master/contrib/completion/git-completion.bash

_git_com () { _git_commit; }
_git_pu () { _git_push; }
_git_m () { _git_merge; }
_git_log-branch () { _git_branch; }
_git_rename-remote-branch () { _git_branch; }
_git_rename-local-and-remote-branch () { _git_branch; }

# zsh's native `_git` dispatches a `!` shell-function alias's argument to a
# `_git-<alias>` (dash) function, via `compdef`. Bash has no `compdef`, so this
# block only runs under zsh, even though this file is also loaded by bash.
if [ -n "$ZSH_VERSION" ]; then
	# compdef only exists once zsh's completion system is set up (oh-my-zsh does that)
	command -v compdef >/dev/null 2>&1 && compdef _git g=git

	# Branch-name completion (arg = local branch)
	_git-bclean () { __git_branch_names; }
	_git-m () { __git_branch_names; }
	_git-log-branch () { __git_branch_names; }
	_git-rename-remote-branch () { __git_branch_names; }
	_git-rename-local-and-remote-branch () { __git_branch_names; }
	_git-f () { __git_branch_names; }
	_git-commit-changes () { __git_branch_names; }
	_git-delete-merged-local-branches () { __git_branch_names; }
	_git-differences-in-commits-between-branches () { __git_branch_names; }

	# Revision completion (arg = branch OR commit)
	_git-commit-compare () { __git_revisions; }
	_git-differences-in-commits-between-branches3 () { __git_revisions; }

	# Commit/SHA completion (arg = commit)
	_git-current-branch-contains-commit () { __git_commits; }
	_git-undo-pushed-merge () { __git_commits; }

	# Stash completion (arg = stash index, stash@{N})
	_git-shs () { __git_stashes; }
	_git-shd () { __git_stashes; }
	_git-sha () { __git_stashes; }
fi
