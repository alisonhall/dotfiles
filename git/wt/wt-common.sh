#!/usr/bin/env bash
# wt-common.sh — shared helpers for the wt-*.sh scripts.
# Sourced (not executed) by wt.sh (when run, not when sourced), wt-add.sh, wt-cd.sh, wt-clean.sh,
# wt-link.sh, wt-ls.sh and wt-rm.sh.
#
# These helpers read globals set by the calling script before they are invoked:
#   WT_WORKTREE_REPO_LOCATION, MAIN_WT, CURRENT_REMOTE_NAME, REMOTE_BRANCH_NAME,
#   LOCAL_BRANCH_NAME

# Failures (see "Exit codes" in wt help): every message goes to stderr, and the last line before
# a non-zero exit is one sentence saying what went wrong and what to do - a tool that runs wt
# shows that line (or the first fatal:/error: line) as the reason. 1 is refused or failed, 2 is
# usage or not configured, and wt add's 3 and 4 are a branch or PR that isn't there and a remote
# or gh that can't be asked.

# wt_not_configured <command>: Stop because wt can't tell which repo to work on (exit 2).
wt_not_configured() {
	echo "error: $1: WT_WORKTREE_REPO_LOCATION is not set, and this isn't a folder of wt's layout. Run it in the repo's main folder (or a branch's folder beside it), or export WT_WORKTREE_REPO_LOCATION as the folder that holds main." >&2
	exit 2
}

# resolve_dev_branch: Sets CURRENT_DEV_BRANCH, the branch new branches start from (and wt rm and
# wt clean never delete), from the first of: CURRENT_DEV_BRANCH itself, the clone's git config
# wt.devBranch, the remote's default branch as the clone knows it (refs/remotes/<remote>/HEAD, set
# by git clone or git remote set-head <remote> --auto), and main. Needs MAIN_WT; never fetches.
resolve_dev_branch() {
	local remote="${CURRENT_REMOTE_NAME:-origin}" ref
	[ -n "${CURRENT_DEV_BRANCH:-}" ] && return 0
	# (|| true: wt-clean.sh runs with set -e, and these fail when there's nothing to find)
	CURRENT_DEV_BRANCH="$(git -C "$MAIN_WT" config --get wt.devBranch 2>/dev/null)" || true
	[ -n "$CURRENT_DEV_BRANCH" ] && return 0
	ref="$(git -C "$MAIN_WT" symbolic-ref --quiet --short "refs/remotes/$remote/HEAD" 2>/dev/null)" || true
	CURRENT_DEV_BRANCH="${ref#"$remote"/}"
	[ -n "$CURRENT_DEV_BRANCH" ] || CURRENT_DEV_BRANCH=main
}

# Per-repo settings, as "<variable>:<git config key>:<single|multi>". They're read from the clone's
# git config (main/.git/config, or .bare/config - shared by every worktree, never committed), where
# wt setup writes them, so plain wt works in any repo with no per-repo command. A multi key has an
# entry per value (git config --add), joined with spaces as the scripts expect.
WT_SETTINGS="WT_REPO_SLUG:repoSlug:single CURRENT_DEV_BRANCH:devBranch:single CURRENT_REMOTE_NAME:remote:single
WT_PROTECTED_BRANCHES:protectedBranch:multi WT_SAFE_ARTIFACTS:safeArtifact:multi WT_SYMLINK_PAIRS:symlinkPair:multi"

# forget_settings: Unsets every setting, for when the environment's values are another repo's
forget_settings() {
	local entry
	for entry in $WT_SETTINGS; do
		unset "${entry%%:*}"
	done
}

# load_git_config <main folder> <own>: Exports each setting the clone's git config has. With <own>
# 1, the environment's values are this repo's own (its command passed them, with its location),
# so one set there wins; with 0, they may be another repo's, so git config wins. Records where each
# value came from in from_<variable> (env, git config), for wt config.
load_git_config() {
	local entry var key kind value
	for entry in $WT_SETTINGS; do
		IFS=: read -r var key kind <<< "$entry"
		[ -n "${!var:-}" ] && printf -v "from_$var" '%s' env
		if [ "$kind" = multi ]; then
			value="$(git -C "$1" config --get-all "wt.$key" 2>/dev/null | tr '\n' ' ')"
			value="${value% }"
		else
			value="$(git -C "$1" config --get "wt.$key" 2>/dev/null)"
		fi
		[ -n "$value" ] || continue
		[ "$2" = 1 ] && [ -n "${!var:-}" ] && continue
		export "$var=$value"
		printf -v "from_$var" '%s' "git config wt.$key"
	done
}

# pull_ref_number <branch>: If <branch> follows a pull request's head, refs/pull/<n>/head (as
# wt add --pr and gh pr checkout set up a fork's PR), prints <n> and succeeds. Such a branch isn't
# on the remote under its own name, so it's fetched, compared and looked up by its PR instead.
pull_ref_number() {
	local merge number
	merge="$(git -C "$MAIN_WT" config "branch.$1.merge" 2>/dev/null)" || return 1
	case "$merge" in refs/pull/*/head) ;; *) return 1 ;; esac
	number="${merge#refs/pull/}"
	number="${number%/head}"
	case "$number" in '' | *[!0-9]*) return 1 ;; esac
	printf '%s' "$number"
}

# common_dir <folder>: The folder's repo's git folder (shared by all its worktrees), as a full path
# (git gives it relative to the folder, unless absolute - C:/... from Windows' git too)
common_dir() {
	local dir
	dir="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || return 1
	case "$dir" in /* | [A-Za-z]:*) printf '%s' "$dir" ;; *) printf '%s/%s' "$1" "$dir" ;; esac
}

# same_repo <folder> <folder>: Whether both are worktrees of the same repo
same_repo() {
	local a b
	a="$(common_dir "$1")" && b="$(common_dir "$2")" && [ "$a" -ef "$b" ]
}

# is_folder_arg <arg>: Whether a command's argument is a folder rather than a branch: written as a
# path - ., .., ./x, ../x, a full path, or one with a drive letter - none of which can be a branch
# name. A plain name is always a branch, even with a folder of that name where it's run (wt rm docs
# in a branch folder with a docs folder means the docs branch, not that folder).
is_folder_arg() {
	case "$1" in . | .. | /* | ./* | ../* | [A-Za-z]:*) return 0 ;; esac
	return 1
}

# tell_folder <folder>: For the wt function, which moves your terminal into the folder once the
# script finishes, and can't always work it out itself (with --pr, only the script knows the
# branch). Only when it asks, with WT_CD_FILE.
tell_folder() {
	[ -n "${WT_CD_FILE:-}" ] || return 0
	printf '%s\n' "$1" > "$WT_CD_FILE"
}

# run_porcelain <script> <args...>: For wt add/cd --porcelain: runs the script again with the args
# (not --porcelain), all its output on stderr, and prints only the folder it used (as tell_folder
# says) on stdout - one line, its full path - then exits with its exit code. (The second run keeps
# anything it starts, like git's background maintenance after a fetch, from holding stdout open:
# a tool reads it until every program holding it has closed it.)
run_porcelain() {
	local script="$1" file code=0 folder
	shift
	file="$(mktemp "${TMPDIR:-/tmp}/wt-porcelain.XXXXXX")" || exit 1
	trap 'rm -f "$file"' EXIT
	trap 'exit 130' INT
	WT_CD_FILE="$file" bash "$script" "$@" >&2 || code=$?
	folder="$(cat "$file" 2>/dev/null)"
	[ "$code" -eq 0 ] || exit "$code"
	if [ -z "$folder" ]; then
		echo "error: $(basename "$script" .sh): it finished but didn't say which folder it used." >&2
		exit 1
	fi
	# (The wt function asks for it too, though with --porcelain it doesn't move the terminal)
	[ -n "${WT_CD_FILE:-}" ] && printf '%s\n' "$folder" > "$WT_CD_FILE"
	printf '%s\n' "$folder"
	exit 0
}

# Echo the number of a merged PR whose head was $REMOTE_BRANCH_NAME, or nothing
# (when gh is unavailable or no such PR matches). GitHub keeps every PR's head
# at refs/pull/<n>/head even after the branch is deleted, so the number alone is
# enough to recover the change set.
#
# gh needs to know the repo: from WT_REPO_SLUG if it's set, and otherwise from the clone it's run
# in. So it runs in the main worktree, since wt-add.sh works from the collection folder, which
# isn't a clone (and gh fails there, which this would otherwise hide as "no merged PR").
#
# The exact match is checked here rather than in --jq, which has no way to pass the branch name
# in as data: written into the filter, a name with " or \ in it would break it.
find_merged_pr() {
	command -v gh >/dev/null 2>&1 || return 0
	(
		cd "$MAIN_WT" 2>/dev/null || exit 0
		if [ -n "${WT_REPO_SLUG:-}" ]; then set -- --repo "$WT_REPO_SLUG"; else set --; fi
		gh pr list "$@" --state merged --head "$REMOTE_BRANCH_NAME" \
			--json number,headRefName \
			--jq '.[] | "\(.number)\t\(.headRefName)"' 2>/dev/null |
			while IFS=$'\t' read -r number head; do
				# (A branch name can't hold a tab or a newline, so each line splits cleanly)
				if [ "$head" = "$REMOTE_BRANCH_NAME" ]; then
					echo "$number"
					break
				fi
			done
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

# other_branch_in <folder> <branch>: If the worktree folder holds a branch other than <branch>,
# prints it and succeeds. Different branches can share a folder name, since / becomes _
# (feature/x and feature_x are both feature_x/). A detached folder, like one recovered from a
# merged PR, doesn't count.
other_branch_in() {
	local held
	held="$(git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null)" || return 1
	[ "$held" != "$2" ] || return 1
	printf '%s' "$held"
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
		# The paths reach cmd in a variable that's expanded with !...! only after cmd has read the
		# line, so it doesn't act on characters like & ^ % ; in them (a branch folder can have those).
		# Git Bash would escape quotes written in the command itself, which cmd doesn't understand,
		# so they're in the variable too. (No Windows path can contain a ".) MSYS2_ARG_CONV_EXCL
		# stops Git Bash converting /J and the others to paths.
		WT_MKLINK_ARGS="\"$(cygpath -w "$link")\" \"$(cygpath -w "$target")\"" \
			MSYS2_ARG_CONV_EXCL='*' cmd /d /v:on /c 'mklink /J !WT_MKLINK_ARGS!' >/dev/null
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
# It doesn't search inside a real node_modules folder (one installed in this folder, rather
# than a link to main's): that's slow on Windows, and the links npm makes in one point within
# this folder, so following them only reaches files that are being deleted anyway. The links wt
# makes (node_modules and WT_SYMLINK_PAIRS) are deleted by name, wherever they are.
#
# Links the repo itself tracks are deleted too: whether git follows them depends on the system
# (on Windows with Developer Mode, they're real symlinks). If the folder then isn't deleted after
# all, restore_tracked_links puts them back.
remove_links() {
	local link rel main_rel
	while IFS=$'\t' read -r rel main_rel; do
		[ -n "$rel" ] && [ -L "$1/$rel" ] && rm -f "$1/$rel"
	done < <(worktree_symlink_pairs)
	while IFS= read -r link; do
		rm -f "$link"
	done < <(find "$1" \( -name .git -o \( -name node_modules ! -type l \) \) -prune -o -type l -print 2>/dev/null)
}

# restore_tracked_links <folder>: Put back the tracked files remove_links deleted, for a folder
# that wasn't deleted after all. (Only deleted files are restored, never changed ones.)
restore_tracked_links() {
	local path
	while IFS= read -r -d '' path; do
		git -C "$1" checkout -- "$path" 2>/dev/null
	done < <(git -C "$1" ls-files --deleted -z 2>/dev/null)
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
			echo "wt: warning: link-workspaces.mjs failed; @scope/* imports may resolve to main." >&2
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
# local/shell_local.sh); each points at main/<rel>. This keeps the script
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
		make_link "$WT_WORKTREE_REPO_LOCATION/$main_rel" "$rel" || echo "  $rel: couldn't link it to $main_rel" >&2
	done < <(worktree_symlink_pairs)

	echo "Symlinks pointing to the main worktree folder"
	link_workspaces
}
