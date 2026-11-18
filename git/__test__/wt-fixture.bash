# Shared by the wt tests (wt*.bats, wt-tools.bats): each test gets a local "GitHub" repo, a clone of
# it in the folder layout wt manages (repo/main), and a fake gh.

wt_fixture_setup() {
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

	# (Printed beside a test that fails, so a wt add --pr test failing with exit 4 says why)
	command -v jq >/dev/null 2>&1 || echo "# jq isn't installed, and the tests' gh needs it for wt add --pr"

	# A gh that's logged in. Asked for every pull request of a branch (wt clean), it says each
	# existing branch's was merged at its current commit (a branch that doesn't exist yet has
	# none). Asked for merged ones only (wt add and wt cd), it lists those in FAKE_MERGED_PRS
	# ("<branch>=<number> ..."), as "<number><TAB><branch>" lines like find_merged_pr's --jq
	# makes. Like the real gh, it needs --repo outside a clone. Asked to view a pull request (wt add
	# --pr), it answers from FAKE_PRS ("<number>:<from a fork: true|false>:<base>:<head>[:<the
	# fork, owner/repo, when its author lets maintainers push>] ..."), put through wt-add's own
	# --jq, and fails for any other number. Asked for its state (wt clean), any PR whose head is on the
	# "GitHub" repo was merged at that commit, unless it's in FAKE_OPEN_PRS ("<number> ...").
	mkdir -p "$BATS_TEST_TMPDIR/bin"
	cat > "$BATS_TEST_TMPDIR/bin/gh" <<-'EOF'
		#!/usr/bin/env bash
		case "$1 $2" in
			"auth status") exit 0 ;;
			# The repo of the clone it's run in, like the real gh; outside a clone it can't tell
			"repo view")
				git rev-parse --git-dir >/dev/null 2>&1 || exit 1
				echo acme/shop
				;;
			"pr view")
				# FAKE_GH_OFFLINE: as when GitHub can't be reached
				[ -n "${FAKE_GH_OFFLINE:-}" ] && { echo "error connecting to api.github.com" >&2; exit 1; }
				[ "$4" = --repo ] && [ "$5" != acme/shop ] && { echo "no such pull request" >&2; exit 1; }
				if [[ " $* " == *" number,state,headRefOid "* ]]; then
					oid="$(git -C "$WT_WORKTREE_REPO_LOCATION/main" ls-remote origin "refs/pull/$3/head" | cut -f1)"
					[ -n "$oid" ] || { echo "GraphQL: Could not resolve to a PullRequest with the number of $3." >&2; exit 1; }
					state=MERGED
					[[ " ${FAKE_OPEN_PRS:-} " == *" $3 "* ]] && state=OPEN
					printf '%s\t%s\t%s\n' "$3" "$state" "$oid"
					exit 0
				fi
				for pr in ${FAKE_PRS:-}; do
					IFS=: read -r number fork base head pushable <<< "$pr"
					if [ "$number" = "$3" ]; then
						can_modify=false
						[ -n "$pushable" ] && can_modify=true
						pushable="${pushable:-forker/shop}"
						# The fork as GitHub gives it: null once it's deleted ("gone")
						owner="{\"login\":\"${pushable%%/*}\"}" name="{\"name\":\"${pushable#*/}\"}"
						[ "$pushable" = gone ] && owner=null name=null
						# Through wt-add's own --jq, as the real gh would: on Windows jq is a Windows
						# program too, so Git Bash changes the expression on its way, as it would for gh
						command -v jq >/dev/null 2>&1 || { echo "wt tests: the tests' gh needs jq, to run wt-add's --jq as gh would" >&2; exit 1; }
						expression=""
						while [ $# -gt 0 ]; do [ "$1" = --jq ] && expression="$2"; shift; done
						printf '{"isCrossRepository":%s,"baseRefName":"%s","maintainerCanModify":%s,"headRepositoryOwner":%s,"headRepository":%s,"headRefName":"%s"}' \
							"$fork" "$base" "$can_modify" "$owner" "$name" "$head" | jq -r "$expression"
						exit
					fi
				done
				echo "GraphQL: Could not resolve to a PullRequest with the number of $3." >&2
				exit 1
				;;
			"pr list")
				repo="" state="" head=""
				while [ $# -gt 0 ]; do
					case "$1" in
						--repo) repo="$2" ;;
						--state) state="$2" ;;
						--head) head="$2" ;;
					esac
					shift
				done
				if [ -z "$repo" ] && ! git rev-parse --git-dir >/dev/null 2>&1; then
					echo "failed to run git: fatal: not a git repository" >&2
					exit 1
				fi
				# Another repo has none of these pull requests
				[ -n "$repo" ] && [ "$repo" != acme/shop ] && exit 0
				# FAKE_GH_NEEDS_REPO: as for a clone with several remotes and no default set
				if [ -z "$repo" ] && [ -n "${FAKE_GH_NEEDS_REPO:-}" ]; then
					echo "multiple remotes detected; please run gh repo set-default" >&2
					exit 1
				fi
				if [ "$state" = merged ]; then
					for pr in ${FAKE_MERGED_PRS:-}; do
						[ "${pr%%=*}" = "$head" ] && printf '%s\t%s\n' "${pr#*=}" "$head"
					done
				else
					oid="$(git -C "$WT_WORKTREE_REPO_LOCATION/main" rev-parse --verify --quiet "refs/heads/$head")" &&
						printf '1\tMERGED\t%s\n' "$oid"
				fi
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
		# (The same way as make_link in wt-common.sh, so folder names with & and such work)
		WT_MKLINK_ARGS="\"$(cygpath -w "$2")\" \"$(cygpath -w "$1")\"" \
			MSYS2_ARG_CONV_EXCL="*" cmd /d /v:on /c 'mklink /J !WT_MKLINK_ARGS!' >/dev/null
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

# fork_pr <number>: A commit only at refs/pull/<number>/head on the "GitHub" repo, as a fork's
# pull request's head is (its branch is in the fork). Prints the commit.
fork_pr() {
	local sha
	git -C "$MAIN" switch -q -c "fork-work-$1"
	git -C "$MAIN" commit -q --allow-empty -m "a fork's work for #$1"
	sha="$(git -C "$MAIN" rev-parse HEAD)"
	git -C "$MAIN" push -q origin "HEAD:refs/pull/$1/head" 2>/dev/null
	git -C "$MAIN" switch -q main
	git -C "$MAIN" branch -q -D "fork-work-$1"
	echo "$sha"
}

# pr_commit <number>: A new commit on pull request <number>'s head, as its author pushing more.
# Prints the commit.
pr_commit() {
	local sha
	git -C "$MAIN" switch -q --detach "$(git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse "refs/pull/$1/head")" 2>/dev/null ||
		{ git -C "$MAIN" fetch -q origin "refs/pull/$1/head" && git -C "$MAIN" switch -q --detach FETCH_HEAD; }
	git -C "$MAIN" commit -q --allow-empty -m "more work on #$1"
	sha="$(git -C "$MAIN" rev-parse HEAD)"
	git -C "$MAIN" push -q origin "HEAD:refs/pull/$1/head" 2>/dev/null
	git -C "$MAIN" switch -q main
	echo "$sha"
}

# deleted_after_merge <branch> <number>: A branch that was pushed, merged as pull request
# <number>, and then deleted, from GitHub and from the clone. Prints its last commit.
deleted_after_merge() {
	local sha
	git -C "$MAIN" switch -q -c "$1"
	git -C "$MAIN" commit -q --allow-empty -m "work on $1"
	sha="$(git -C "$MAIN" rev-parse HEAD)"
	git -C "$MAIN" push -q origin "$1" 2>/dev/null
	# GitHub keeps every pull request's last commit at refs/pull/<number>/head
	git -C "$BATS_TEST_TMPDIR/origin.git" update-ref "refs/pull/$2/head" "$sha"
	git -C "$MAIN" push -q origin --delete "$1" 2>/dev/null
	git -C "$MAIN" switch -q main
	git -C "$MAIN" branch -q -D "$1"
	git -C "$MAIN" fetch -q --prune
	echo "$sha"
}
