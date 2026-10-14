#!/usr/bin/env bats
# Tests for the wt commands (git/wt/), against a local "GitHub" repo and a fake gh.

setup() {
	WT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/wt"
	export HOME="$BATS_TEST_TMPDIR/home"
	export GIT_CONFIG_NOSYSTEM=1
	unset GIT_CONFIG_GLOBAL
	mkdir -p "$HOME"
	git config --global user.name Test
	git config --global user.email test@example.com
	git config --global init.defaultBranch main

	# The "GitHub" repo, and the folder wt manages, with its clone in main/
	git init -q --bare "$BATS_TEST_TMPDIR/origin.git"
	export WT_WORKTREE_REPO_LOCATION="$BATS_TEST_TMPDIR/repo"
	export WT_REPO_SLUG=acme/shop
	MAIN="$WT_WORKTREE_REPO_LOCATION/main"
	git clone -q "$BATS_TEST_TMPDIR/origin.git" "$MAIN" 2>/dev/null
	printf 'node_modules\n.env\n' > "$MAIN/.gitignore"
	git -C "$MAIN" add .gitignore
	git -C "$MAIN" commit -q -m init
	git -C "$MAIN" push -q origin main

	# main's dependencies, which branch folders share
	mkdir -p "$MAIN/node_modules/pkg"
	echo 'module.exports = 42' > "$MAIN/node_modules/pkg/index.js"

	# A gh that's logged in, and says every branch's pull request was merged at its current commit
	mkdir -p "$BATS_TEST_TMPDIR/bin"
	cat > "$BATS_TEST_TMPDIR/bin/gh" <<-'EOF'
		#!/usr/bin/env bash
		case "$1 $2" in
			"auth status") exit 0 ;;
			"pr list")
				while [ $# -gt 0 ]; do [ "$1" = --head ] && head="$2"; shift; done
				printf '1\tMERGED\t%s\n' "$(git -C "$WT_WORKTREE_REPO_LOCATION/main" rev-parse "refs/heads/$head")"
				;;
			*) exit 1 ;;
		esac
	EOF
	chmod +x "$BATS_TEST_TMPDIR/bin/gh"
	export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

is_windows() {
	case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) return 0 ;; esac
	return 1
}

# link_dir <target> <link>: Link to a folder the way Windows users get by default: a junction there,
# a symlink elsewhere
link_dir() {
	if is_windows; then
		cmd //c "mklink /J $(cygpath -w "$2") $(cygpath -w "$1")" >/dev/null
	else
		ln -s "$1" "$2"
	fi
}

# merged_branch <branch>: A branch folder for <branch>, pushed, with a node_modules link to main's
merged_branch() {
	local folder="$WT_WORKTREE_REPO_LOCATION/${1//\//_}"
	git -C "$MAIN" worktree add -q -b "$1" "$folder"
	git -C "$folder" commit -q --allow-empty -m "work on $1"
	git -C "$folder" push -q -u origin "$1" 2>/dev/null
	link_dir "$MAIN/node_modules" "$folder/node_modules"
	[ -f "$folder/node_modules/pkg/index.js" ]
}

#   -------------------------------
#   REMOVING BRANCH FOLDERS
#   -------------------------------

@test "wt clean deletes a merged branch's folder, but not the main/node_modules its link points to" {
	merged_branch feature/done
	run bash "$WT/wt.sh" clean --apply
	[ "$status" -eq 0 ]
	[[ "$output" == *"GONE"*"feature_done"* ]] || false
	[ ! -e "$WT_WORKTREE_REPO_LOCATION/feature_done" ]
	[ -f "$MAIN/node_modules/pkg/index.js" ]
}

@test "wt rm deletes a branch's folder, but not the main/node_modules its link points to" {
	merged_branch feature/done
	run bash "$WT/wt.sh" rm feature/done
	[ "$status" -eq 0 ]
	[ ! -e "$WT_WORKTREE_REPO_LOCATION/feature_done" ]
	[ -f "$MAIN/node_modules/pkg/index.js" ]
}
