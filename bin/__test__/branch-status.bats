#!/usr/bin/env bats
# Tests for bin/branch-status.sh: a read-only report of local branch(es) vs a base branch.

setup() {
	SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/branch-status.sh"
	export HOME="$BATS_TEST_TMPDIR/home"
	export GIT_CONFIG_NOSYSTEM=1
	unset GIT_CONFIG_GLOBAL
	mkdir -p "$HOME"
	git config --global user.name Test
	git config --global user.email test@example.com

	PROJECT="$BATS_TEST_TMPDIR/project"
	git init -q "$PROJECT"
	git -C "$PROJECT" commit -q --allow-empty -m base
	git -C "$PROJECT" branch -M main
}

# branch_status [options]: Run branch-status.sh in $PROJECT against main, with no network fetch
branch_status() {
	run bash "$SCRIPT" --base main --no-fetch "$@"
}

@test "exists and is executable" {
	[ -f "$SCRIPT" ]
	[ -x "$SCRIPT" ]
}

@test "--help prints usage and exits 0" {
	run bash "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"branch-status.sh"* ]] || false
	[[ "$output" == *"--base"* ]] || false
	[[ "$output" == *"--no-fetch"* ]] || false
}

@test "reports each local branch vs a base" {
	cd "$PROJECT"
	git checkout -qb feature/x
	git commit -q --allow-empty -m f1
	git checkout -qb merged-in
	git commit -q --allow-empty -m mi
	git checkout -q main
	git merge -q --ff-only merged-in
	git checkout -q main

	branch_status
	[[ "$output" == *"Branch status vs main"* ]] || false
	[[ "$output" == *"feature/x"* ]] || false
	[[ "$output" == *"merged-in"* ]] || false
	[[ "$output" == *"Summary: 2 branch(es) vs main"* ]] || false
}

@test "is read-only: doesn't modify branches or HEAD" {
	cd "$PROJECT"
	git checkout -qb feature/x
	git commit -q --allow-empty -m f1
	git checkout -q main

	before_head="$(git rev-parse HEAD)"
	before_branches="$(git branch --format='%(refname:short)')"
	branch_status
	[ "$(git rev-parse HEAD)" = "$before_head" ]
	[ "$(git branch --format='%(refname:short)')" = "$before_branches" ]
}

@test "reports a branch merged into base as in base" {
	cd "$PROJECT"
	git checkout -qb feature/y
	git commit -q --allow-empty -m f1
	git checkout -q main
	git merge -q --ff-only feature/y

	branch_status
	[[ "$output" == *"in base:  YES (ancestor)"* ]] || false
}
