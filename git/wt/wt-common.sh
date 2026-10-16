#!/usr/bin/env bash
# wt-common.sh — shared helpers for the wt-*.sh scripts.
# Sourced (not executed) by wt-add.sh, wt-cd.sh, wt-clean.sh, wt-link.sh and wt-rm.sh.
#
# These helpers read globals set by the calling script before they are invoked:
#   WT_WORKTREE_REPO_LOCATION, MAIN_WT, CURRENT_REMOTE_NAME, REMOTE_BRANCH_NAME,
#   LOCAL_BRANCH_NAME

# Echo the number of a merged PR whose head was $REMOTE_BRANCH_NAME, or nothing
# (when gh is unavailable or no such PR matches). GitHub keeps every PR's head
# at refs/pull/<n>/head even after the branch is deleted, so the number alone is
# enough to recover the change set.
#
# gh needs to know the repo: from WT_REPO_SLUG if it's set, and otherwise from the clone it's run
# in. So it runs in the main worktree, since wt-add.sh works from the collection folder, which
# isn't a clone (and gh fails there, which this would otherwise hide as "no merged PR").
find_merged_pr() {
	command -v gh >/dev/null 2>&1 || return 0
	(
		cd "$MAIN_WT" 2>/dev/null || exit 0
		if [ -n "${WT_REPO_SLUG:-}" ]; then set -- --repo "$WT_REPO_SLUG"; else set --; fi
		gh pr list "$@" --state merged --head "$REMOTE_BRANCH_NAME" \
			--json number,headRefName \
			--jq '.[] | select(.headRefName == "'"$REMOTE_BRANCH_NAME"'") | .number' 2>/dev/null | head -n 1
	)
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

# wt_is_windows: Whether this is Git Bash (or another Unix layer) on Windows. Tests set WT_OS to
# act as if on another system.
wt_is_windows() {
	case "${WT_OS:-$(uname -s)}" in MINGW* | MSYS* | CYGWIN*) return 0 ;; esac
	return 1
}

# make_link <target> <link>: Make <link> share <target>, which must exist. That's a symlink,
# except on Windows, where Git Bash's ln -s copies instead of linking (unless Developer Mode is
# on): there a folder gets a junction and a file a hard link, neither of which needs admin
# rights. A hard link shares the file's contents until an editor saves it by replacing the
# file; wt link --check reports that.
make_link() {
	local target="$1" link="$2"
	[ -e "$target" ] || return 1
	if ! wt_is_windows; then
		ln -s "$target" "$link"
		return
	fi
	# A real symlink, if Windows allows them (Developer Mode); this fails rather than copying
	MSYS=winsymlinks:nativestrict ln -s "$target" "$link" 2>/dev/null && return 0
	if [ -d "$target" ]; then
		# (Separate arguments, without Git Bash converting them, so paths with spaces work)
		MSYS2_ARG_CONV_EXCL='*' cmd /c mklink /J "$(cygpath -w "$link")" "$(cygpath -w "$target")" >/dev/null
	else
		ln "$target" "$link"
	fi
}

# folder_in_use <folder>: Whether Windows won't let the folder be deleted right now, because a
# program is using it (an editor, or a terminal that's in it). Deleting it would fail partway
# and leave it half deleted, so this checks by renaming it and back, which either works or
# fails as a whole. Never true on other systems, which allow deleting folders in use.
#
# Returns 0 if it's in use, 1 if it isn't, and 2 if it was renamed but couldn't be renamed
# back, even after retrying (antivirus or the search indexer can hold a folder for a moment).
# Then it says where the folder is, and how to put it back.
folder_in_use() {
	local probe="$1.wt-in-use-check-$$" tries=0
	wt_is_windows || return 1
	mv "$1" "$probe" 2>/dev/null || return 0
	until mv "$probe" "$1" 2>/dev/null; do
		tries=$((tries + 1))
		if [ "$tries" -ge 6 ]; then
			echo "wt: while checking whether $(basename "$1") was in use, it was renamed to" >&2
			echo "    $probe, and Windows won't let it be renamed back yet. Nothing in it was deleted." >&2
			echo "    Put it back with: mv \"$probe\" \"$1\"" >&2
			return 2
		fi
		sleep 0.5
	done
	return 1
}

# remove_links <folder>: Delete the links (symlinks, and junctions on Windows) inside a
# worktree folder, leaving what they point at alone. Run it before deleting the folder: on
# Windows, `git worktree remove` follows junctions and deletes everything inside the folders
# they point to, such as main/node_modules. (rm -r doesn't, but this protects either way.)
#
# It doesn't look inside a real node_modules folder (one installed in this folder, rather than
# a link to main's): that's slow on Windows, and the links in one point within this folder, so
# following them only reaches files that are being deleted anyway. It also leaves symlinks the
# repo itself tracks, which git removes as files, so the folder stays intact if git refuses.
remove_links() {
	local link
	while IFS= read -r link; do
		git -C "$1" ls-files --error-unmatch -- "${link#"$1"/}" >/dev/null 2>&1 && continue
		rm -f "$link"
	done < <(find "$1" \( -name .git -o \( -name node_modules ! -type l \) \) -prune -o -type l -print 2>/dev/null)
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
	local rel main_rel
	echo "Making symlinks from the main worktree..."
	# Optionally run npm install or yarn instead of copying the node_modules from the main branch
	while IFS=$'\t' read -r rel main_rel; do
		[ -z "$rel" ] && continue
		if [ ! -e "$WT_WORKTREE_REPO_LOCATION/$main_rel" ]; then
			echo "  $rel: skipped, because $main_rel doesn't exist"
			continue
		fi
		mkdir -p "$(dirname "$rel")"
		make_link "$WT_WORKTREE_REPO_LOCATION/$main_rel" "$rel" || echo "  $rel: couldn't link it to $main_rel"
	done < <(worktree_symlink_pairs)

	echo "Symlinks pointing to the main worktree folder"
	link_workspaces
}
