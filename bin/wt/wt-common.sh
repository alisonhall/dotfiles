#!/usr/bin/env bash
# wt-common.sh — shared helpers for the wt-*.sh scripts.
# Sourced (not executed) by wt-add.sh and wt-cd.sh.
#
# These helpers read globals set by the calling script before they are invoked:
#   WT_WORKTREE_REPO_LOCATION, CURRENT_REMOTE_NAME, REMOTE_BRANCH_NAME,
#   LOCAL_BRANCH_NAME

# Echo the number of a merged PR whose head was $REMOTE_BRANCH_NAME, or nothing
# (when gh is unavailable or no such PR matches). GitHub keeps every PR's head
# at refs/pull/<n>/head even after the branch is deleted, so the number alone is
# enough to recover the change set.
find_merged_pr() {
	command -v gh >/dev/null 2>&1 || return 0
	gh pr list --state merged --head "$REMOTE_BRANCH_NAME" \
		--json number,headRefName \
		--jq '.[] | select(.headRefName == "'"$REMOTE_BRANCH_NAME"'") | .number' 2>/dev/null | head -n 1
}

# Fetch the head commit of merged PR <pr_number> and echo its FULL SHA on
# success; returns non-zero if the fetch fails.
#
# Two layout-agnostic details:
#   * The fetch is anchored on $MAIN_WT (the main worktree) rather than the
#     CWD: the worktree collection folder is NOT itself a git repo in the
#     normal-repo-at-main layout (the git home lives at main/.git), so bare
#     `git` from the collection folder fails there. main is a valid worktree in
#     both layouts, so `git -C main` works everywhere.
#   * We return the full commit SHA, not FETCH_HEAD. FETCH_HEAD is PER-WORKTREE
#     (each worktree has its own), so a fetch done via `git -C main` writes it
#     to main's context and is invisible to a later `git checkout FETCH_HEAD`
#     run from a different worktree. The commit object itself lives in the
#     shared object store, so its SHA resolves from any worktree.
fetch_pr_head() {
	if git -C "$MAIN_WT" fetch "$CURRENT_REMOTE_NAME" "refs/pull/$1/head"; then
		git -C "$MAIN_WT" rev-parse FETCH_HEAD
		return 0
	fi
	return 1
}

# Re-point the @scope/* workspace packages to THIS worktree's source (the root
# node_modules symlink still serves third-party deps). Best-effort: a missing
# node binary or a non-workspace repo should not fail worktree creation.
link_workspaces() {
	local link_workspaces_script
	link_workspaces_script="$(cd "$(dirname "$0")" && pwd)/link-workspaces.mjs"
	if command -v node >/dev/null 2>&1 && [ -f "$link_workspaces_script" ]; then
		echo "Linking workspace packages to this worktree's source..."
		node "$link_workspaces_script" "$WT_WORKTREE_REPO_LOCATION/$LOCAL_BRANCH_NAME" --relative || \
			echo "wt: warning: link-workspaces.mjs failed; @scope/* imports may resolve to main."
	else
		echo "wt: skipping workspace linking (node or link-workspaces.mjs not found)."
	fi
}

# The symlinks every non-main worktree should have, as "relpath<TAB>main-relpath"
# pairs (relpath relative to the worktree root, main-relpath relative to the main
# worktree root). Single source of truth shared by setup_worktree_symlinks and
# wt-link.sh.
#
# The universal set (node_modules) is always emitted. Project-specific
# symlinks — including .cache, which not every repo shares — are supplied via
# WT_SYMLINK_PAIRS (space-separated rel paths, exported from
# ~/.shell_local); each points at main/<rel>. This keeps the script
# agnostic — no project paths are hardcoded here.
worktree_symlink_pairs() {
	local rel
	for rel in node_modules; do
		printf '%s\tmain/%s\n' "$rel" "$rel"
	done
	if [ -n "${WT_SYMLINK_PAIRS:-}" ]; then
		for rel in $WT_SYMLINK_PAIRS; do
			printf '%s\tmain/%s\n' "$rel" "$rel"
		done
	fi
}

# Symlink node_modules (universal) plus the project-specific pairs from
# WT_SYMLINK_PAIRS (e.g. .cache, .env) from main, then re-link workspace
# packages. Run from inside the new worktree folder.
setup_worktree_symlinks() {
	echo "Making symlinks from the main worktree..."
	# Optionally run npm install or yarn instead of copying the node_modules from the main branch
	while IFS=$'\t' read -r rel main_rel; do
		[ -z "$rel" ] && continue
		ln -s "$WT_WORKTREE_REPO_LOCATION/$main_rel" "$rel"
	done < <(worktree_symlink_pairs)

	echo "Symlinks pointing to the main worktree folder"
	link_workspaces
}
