#!/usr/bin/env bash
# wt-add.sh — create a new git worktree from a remote branch name.
# Invoked by the wt function (git/wt/wt.sh), sourced from shell/common/git.sh.
# The wrapper handles the interactive-shell cd; this script does the git work.

# Shared helpers (wt_not_configured, find_merged_pr, fetch_pr_head, link_workspaces,
# setup_worktree_symlinks)
source "$(cd "$(dirname "$0")" && pwd)/wt-common.sh"

[ -n "${WT_WORKTREE_REPO_LOCATION:-}" ] || wt_not_configured wt-add
CURRENT_REMOTE_NAME="${CURRENT_REMOTE_NAME:-origin}"
CURRENT_DEV_BRANCH="${CURRENT_DEV_BRANCH:-main}"

# --strict: only a branch that's on the remote (or a merged PR's head, below) - never a new branch
# from CURRENT_DEV_BRANCH, for a tool that wants a PR's branch and would otherwise get an empty
# one. (No branch name starts with -, so anything that does is an option.)
#
# --pr <number>: the pull request's branch, whatever it's called - its own branch when it's this
# repo's (as --strict would), or for a fork's, its pull ref (refs/pull/<number>/head) in a branch
# and folder named pr-<number> tracking it, as gh pr checkout does. So a tool can check out any
# PR with one command, and a fork's branch name is never taken for this repo's.
STRICT=0
REMOTE_BRANCH_NAME=""
PR_NUMBER=""
usage() {
	echo "Usage: wt add [--strict] <branch-name>, or wt add --pr <number>" >&2
	echo "wt-add: ${1:-give one branch name, or --pr <number>.}" >&2
	exit 2
}
while [ $# -gt 0 ]; do
	case "$1" in
		--strict) STRICT=1 ;;
		--pr)
			[ $# -ge 2 ] || usage "--pr takes a pull request's number."
			PR_NUMBER="$2"
			shift
			case "$PR_NUMBER" in
				'' | *[!0-9]*)
					echo "wt-add: --pr takes a pull request's number, not '$PR_NUMBER'." >&2
					exit 2
					;;
			esac
			;;
		-*)
			usage "unknown option $1."
			;;
		*)
			[ -z "$REMOTE_BRANCH_NAME" ] || usage "give one branch name, not '$REMOTE_BRANCH_NAME' and '$1'."
			REMOTE_BRANCH_NAME="$1"
			;;
	esac
	shift
done
if [ -n "$PR_NUMBER" ] && [ -n "$REMOTE_BRANCH_NAME" ]; then
	echo "wt-add: give a branch or --pr <number>, not both." >&2
	exit 2
fi
[ -n "$REMOTE_BRANCH_NAME" ] || [ -n "$PR_NUMBER" ] || usage

# refuse_new_branch <code> <why>: With --strict, stop here, having made nothing - exit 3 when the
# branch isn't on the remote, 4 when that couldn't be found out (so a tool can tell a gone branch
# from a network problem). (With --pr, a gone branch has already gone to its pull ref.)
refuse_new_branch() {
	[ "$STRICT" = 1 ] || return 0
	if [ -n "$PR_NUMBER" ]; then
		echo "wt-add: $2 - the branch of PR #$PR_NUMBER, so nothing was made." >&2
	else
		echo "wt-add: $2 - with --strict, no new branch is made. (Without it, wt add makes '$REMOTE_BRANCH_NAME' from $CURRENT_DEV_BRANCH.)" >&2
	fi
	exit "$1"
}

# Anchor all central git operations on the main worktree. The worktree
# collection folder is NOT itself a git repo in the normal-repo-at-main layout
# (the git home lives at main/.git), so bare `git` from the collection folder
# fails there. main is a valid worktree in BOTH layouts (bare-repo and
# normal-repo-at-main), so `git -C main` works everywhere.
MAIN_WT="$WT_WORKTREE_REPO_LOCATION/main"

cd "$WT_WORKTREE_REPO_LOCATION" || exit 1

# worktree_add_failed <branch>: After git worktree add failed (git said why, above)
worktree_add_failed() {
	echo "error: wt-add: git couldn't make the worktree for $1 (its message is above), so nothing was made." >&2
	exit 1
}

# add_pull_ref: PR_NUMBER's pull ref in pr-<number>, a branch tracking it (as gh pr checkout sets up
# a fork's PR, so git pull and wt ls follow the PR), checked out in a folder of that name with the
# shared links. Exit 3 when the remote has no such pull ref, 4 when it can't be asked.
add_pull_ref() {
	local name="pr-$PR_NUMBER" ref="refs/pull/$PR_NUMBER/head" folder found sha held
	folder="$WT_WORKTREE_REPO_LOCATION/$name"
	if [ -e "$folder/.git" ]; then
		if held="$(other_branch_in "$folder" "$name")"; then
			echo "wt-add: the folder $name already holds branch $held, not $name, so nothing was made. Remove it (wt rm $held) or use that branch." >&2
			exit 1
		fi
		echo "Worktree folder $name already exists. Switching to it..."
		tell_folder "$folder"
		exit 0
	fi
	if [ -e "$folder" ]; then
		echo "wt-add: $folder already exists but isn't a worktree, so nothing was made (it would be overwritten). Move or delete it, then run this again." >&2
		exit 1
	fi
	if ! found="$(git -C "$MAIN_WT" ls-remote "$CURRENT_REMOTE_NAME" "$ref")"; then
		echo "wt-add: couldn't ask $CURRENT_REMOTE_NAME for $ref, PR #$PR_NUMBER's head, so nothing was made." >&2
		exit 4
	fi
	if [ -z "$found" ]; then
		echo "wt-add: $CURRENT_REMOTE_NAME has no $ref - is #$PR_NUMBER a pull request of this repo? Nothing was made." >&2
		exit 3
	fi
	if ! sha="$(fetch_pr_head "$PR_NUMBER")"; then
		echo "wt-add: couldn't fetch $ref, PR #$PR_NUMBER's head, so nothing was made." >&2
		exit 4
	fi
	if git -C "$MAIN_WT" show-ref --verify --quiet "refs/heads/$name"; then
		# Made before (its folder since removed): checked out as it is, as for a branch's name
		echo "Branch $name already exists. Creating its worktree..."
		git -C "$MAIN_WT" worktree add "$folder" "$name" || worktree_add_failed "$name"
	else
		echo "Creating $name from PR #$PR_NUMBER's head (${sha:0:7}), tracking $ref on $CURRENT_REMOTE_NAME..."
		git -C "$MAIN_WT" worktree add --no-track -b "$name" "$folder" "$sha" || worktree_add_failed "$name"
		git -C "$MAIN_WT" config "branch.$name.remote" "$CURRENT_REMOTE_NAME"
		git -C "$MAIN_WT" config "branch.$name.merge" "$ref"
	fi
	cd "$folder" || exit 1
	echo "Worktree folder $name created and PR #$PR_NUMBER checked out."
	push_hint
	tell_folder "$folder"
	setup_worktree_symlinks
	exit 0
}

# fork_url <owner/repo>: The fork's address, written like the remote's (https, ssh:// or
# git@host:owner/repo), so git pushes to it the way it pushes to the remote. (As set, not after any
# url.<x>.insteadOf rewrite - git rewrites the fork's the same way when pushing.)
fork_url() {
	local url
	url="$(git -C "$MAIN_WT" config --get "remote.$CURRENT_REMOTE_NAME.url" 2>/dev/null)" || return 1
	url="${url%/}"
	url="${url%.git}"
	case "$url" in
		*://*) printf '%s/%s.git' "${url%/*/*}" "$1" ;;
		*:*) printf '%s:%s.git' "${url%%:*}" "$1" ;;
		*) return 1 ;;
	esac
}

# push_hint: For a fork's PR whose author lets maintainers push to it, how to add commits to the
# PR - pushing pr-<number> to the fork's branch. (Not set up for git push itself: that needs the
# fork as a remote, with a push mapping per PR, as pr-<number> isn't the fork's branch name.)
push_hint() {
	local url
	[ "${pr_can_modify:-}" = true ] && [ -n "${pr_head_repo:-}" ] || return 0
	url="$(fork_url "$pr_head_repo")" || return 0
	echo "PR #$PR_NUMBER's author lets maintainers push to it. To add your commits to the PR:"
	echo "  git push $url HEAD:refs/heads/$pr_head"
}

# --pr: ask gh which branch the PR is from, and whether it's a fork's. One from a branch named as
# its base (a fork's main into main) is a fork's too: this repo's branch of that name is the base.
# A number GitHub has no pull request for is exit 3, like a branch that isn't there; gh failing
# otherwise (offline, not logged in) is 4. (gh's message is kept to tell them apart, and shown.)
if [ -n "$PR_NUMBER" ]; then
	gh_error="$(mktemp "${TMPDIR:-/tmp}/wt-gh.XXXXXX")" || exit 1
	# Removed however this ends, Ctrl-C too
	trap 'rm -f "$gh_error"' EXIT
	trap 'exit 130' INT
	# No / in --jq: Git Bash takes an argument with one for a path when starting a Windows program
	# like gh, and turns its \ into /, so the fork's owner and name come apart and are joined below.
	# Split at : (in no branch, owner or repo name), not tabs, which read would run together when
	# the fork's gone and both are empty.
	pr_info="$(cd "$MAIN_WT" && {
		if [ -n "${WT_REPO_SLUG:-}" ]; then set -- --repo "$WT_REPO_SLUG"; else set --; fi
		gh pr view "$PR_NUMBER" "$@" \
			--json isCrossRepository,baseRefName,maintainerCanModify,headRepositoryOwner,headRepository,headRefName \
			--jq '"\(.isCrossRepository):\(.baseRefName):\(.maintainerCanModify):\(.headRepositoryOwner.login // ""):\(.headRepository.name // ""):\(.headRefName)"' \
			2>"$gh_error"
	})" || pr_info=""
	cat "$gh_error" >&2
	if [ -z "$pr_info" ]; then
		if grep -q "Could not resolve to a PullRequest" "$gh_error"; then
			echo "wt-add: GitHub has no pull request #$PR_NUMBER in this repo, so nothing was made." >&2
			exit 3
		fi
		echo "wt-add: couldn't ask gh about PR #$PR_NUMBER (above), so nothing was made." >&2
		exit 4
	fi
	rm -f "$gh_error"
	IFS=: read -r pr_fork pr_base pr_can_modify pr_head_owner pr_head_name pr_head <<< "$pr_info"
	pr_head_repo=""
	[ -n "$pr_head_owner" ] && [ -n "$pr_head_name" ] && pr_head_repo="$pr_head_owner/$pr_head_name"
	if [ "$pr_fork" = true ] || [ -z "$pr_head" ] || [ "$pr_head" = "$pr_base" ]; then
		add_pull_ref
	fi
	# This repo's branch: as wt add --strict <branch>, but to the pull ref if the branch is gone
	REMOTE_BRANCH_NAME="$pr_head"
	STRICT=1
fi
LOCAL_BRANCH_NAME="${REMOTE_BRANCH_NAME//\//_}"

# Guard: if the worktree folder already exists, don't try to re-create it
# (git worktree add -b would fail with "branch already exists" and then
# cascade into cd/ln errors). Re-run = switch into it; stray folder = abort.
worktree_path="$WT_WORKTREE_REPO_LOCATION/$LOCAL_BRANCH_NAME"
if [ -e "$worktree_path/.git" ]; then
	if held="$(other_branch_in "$worktree_path" "$REMOTE_BRANCH_NAME")"; then
		echo "wt-add: / becomes _ in folder names, so $REMOTE_BRANCH_NAME and $held would share a folder." >&2
		echo "wt-add: the folder $LOCAL_BRANCH_NAME already holds branch $held, not $REMOTE_BRANCH_NAME, so nothing was made. Remove it (wt rm $held) first." >&2
		exit 1
	fi
	echo "Worktree folder $LOCAL_BRANCH_NAME already exists. Switching to it..."
	tell_folder "$worktree_path"
	exit 0
fi
if [ -e "$worktree_path" ]; then
	echo "wt-add: $worktree_path already exists but isn't a worktree, so nothing was made (it would be overwritten). Move or delete it, then run this again." >&2
	exit 1
fi

# Check whether the branch already exists on the remote. (The full ref: ls-remote matches a
# pattern against the end of each ref name, so "login" alone would also match feature/login.)
# A remote that can't be asked looks like one without the branch, so --strict stops there too.
if ! remote_head="$(git -C "$MAIN_WT" ls-remote --heads "$CURRENT_REMOTE_NAME" "refs/heads/$REMOTE_BRANCH_NAME")"; then
	refuse_new_branch 4 "couldn't ask $CURRENT_REMOTE_NAME whether it has '$REMOTE_BRANCH_NAME'"
	remote_head=""
fi
if [ -n "$remote_head" ]; then
	echo "Remote branch '$REMOTE_BRANCH_NAME' found on $CURRENT_REMOTE_NAME. Creating worktree tracking it..."
	# Fetch the branch so the local remote-tracking ref ($CURRENT_REMOTE_NAME/$REMOTE_BRANCH_NAME)
	# exists; git worktree add cannot resolve a remote branch that has not been fetched yet.
	git -C "$MAIN_WT" fetch "$CURRENT_REMOTE_NAME" "$REMOTE_BRANCH_NAME"
	if git -C "$MAIN_WT" show-ref --verify --quiet "refs/heads/$REMOTE_BRANCH_NAME"; then
		# Local branch already exists (e.g. the folder was removed) — check it out, don't re-create it.
		git -C "$MAIN_WT" worktree add "$worktree_path" "$REMOTE_BRANCH_NAME" || worktree_add_failed "$REMOTE_BRANCH_NAME"
	else
		# Create a local branch named exactly like the remote branch, tracking it, in the underscore-named folder.
		git -C "$MAIN_WT" worktree add --track -b "$REMOTE_BRANCH_NAME" "$worktree_path" "$CURRENT_REMOTE_NAME/$REMOTE_BRANCH_NAME" || worktree_add_failed "$REMOTE_BRANCH_NAME"
	fi
else
	# With --pr, a branch deleted after its PR was merged or closed: its pull ref
	[ -n "$PR_NUMBER" ] && add_pull_ref
	# Branch not on the remote. Before creating a fresh local branch, check
	# whether it was a previously-merged PR (deleted after squash merge). If so,
	# recover the PR head commit in a detached worktree for review.
	pr_number="$(find_merged_pr)"
	if [ -n "$pr_number" ]; then
		echo "Remote branch '$REMOTE_BRANCH_NAME' not found on $CURRENT_REMOTE_NAME, but merged PR #$pr_number had this head. Recovering PR head..."
		# fetch_pr_head returns the full commit SHA (not FETCH_HEAD, which is
		# per-worktree). The SHA resolves from any worktree via the shared
		# object store.
		if pr_head_sha="$(fetch_pr_head "$pr_number")"; then
			git -C "$MAIN_WT" worktree add --detach "$worktree_path" "$pr_head_sha" || worktree_add_failed "$REMOTE_BRANCH_NAME"
			echo "Checked out PR #$pr_number head (${pr_head_sha:0:7}) in $LOCAL_BRANCH_NAME for review."
			cd "$WT_WORKTREE_REPO_LOCATION/$LOCAL_BRANCH_NAME"
			tell_folder "$worktree_path"
			setup_worktree_symlinks
			exit 0
		else
			refuse_new_branch 4 "couldn't fetch refs/pull/$pr_number/head, the head of merged PR #$pr_number"
			echo "wt-add: failed to fetch refs/pull/$pr_number/head; falling back to new local branch." >&2
		fi
	fi
	refuse_new_branch 3 "branch '$REMOTE_BRANCH_NAME' isn't on $CURRENT_REMOTE_NAME"

	echo "Remote branch '$REMOTE_BRANCH_NAME' not found on $CURRENT_REMOTE_NAME. Creating a new local branch '$REMOTE_BRANCH_NAME' from $CURRENT_DEV_BRANCH..."
	if git -C "$MAIN_WT" show-ref --verify --quiet "refs/heads/$REMOTE_BRANCH_NAME"; then
		# Local branch already exists — check it out, don't re-create it.
		git -C "$MAIN_WT" worktree add "$worktree_path" "$REMOTE_BRANCH_NAME" || worktree_add_failed "$REMOTE_BRANCH_NAME"
	else
		git -C "$MAIN_WT" worktree add -b "$REMOTE_BRANCH_NAME" "$worktree_path" "$CURRENT_DEV_BRANCH" || worktree_add_failed "$REMOTE_BRANCH_NAME"
	fi
fi

[ -d "$worktree_path" ] || worktree_add_failed "$REMOTE_BRANCH_NAME"
cd "$WT_WORKTREE_REPO_LOCATION/$LOCAL_BRANCH_NAME"
echo "Worktree folder $LOCAL_BRANCH_NAME created and branch checked out."
tell_folder "$worktree_path"
setup_worktree_symlinks
