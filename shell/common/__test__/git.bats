#!/usr/bin/env bats
# Tests for shell/common/git.sh: git_dev_branch, which picks the branch that dev, sprint,
# gpull-dev, gmerge-dev and friends use.

setup() {
	GIT_SH="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/git.sh"
	export HOME="$BATS_TEST_TMPDIR/home"
	export GIT_CONFIG_NOSYSTEM=1
	unset GIT_CONFIG_GLOBAL CURRENT_DEV_BRANCH
	export CURRENT_REMOTE_NAME=origin
	mkdir -p "$HOME"
	git config --global user.name Test
	git config --global user.email test@example.com

	PROJECT="$BATS_TEST_TMPDIR/project"
	git init -q "$PROJECT"
	git -C "$PROJECT" commit -q --allow-empty -m first
}

# set_remote_default <remote> <branch>: Make <remote>/HEAD point at <branch>, as `git clone` does
set_remote_default() {
	git -C "$PROJECT" update-ref "refs/remotes/$1/$2" HEAD
	git -C "$PROJECT" symbolic-ref "refs/remotes/$1/HEAD" "refs/remotes/$1/$2"
}

# dev_branch [dir]: Run git_dev_branch in the project (or another folder)
dev_branch() {
	run bash -c 'source "$1" && cd "$2" && git_dev_branch' _ "$GIT_SH" "${1:-$PROJECT}"
}

@test "uses CURRENT_DEV_BRANCH when it's set" {
	set_remote_default origin develop
	CURRENT_DEV_BRANCH=release dev_branch
	[ "$output" = "release" ]
}

@test "otherwise uses the remote's default branch" {
	set_remote_default origin develop
	dev_branch
	[ "$output" = "develop" ]
}

@test "follows CURRENT_REMOTE_NAME" {
	set_remote_default origin develop
	set_remote_default upstream trunk
	CURRENT_REMOTE_NAME=upstream dev_branch
	[ "$output" = "trunk" ]
}

@test "keeps slashes in the default branch's name" {
	set_remote_default origin release/2026
	dev_branch
	[ "$output" = "release/2026" ]
}

@test "falls back to main when the remote has no default branch" {
	dev_branch
	[ "$output" = "main" ]
}

@test "falls back to main outside a git repo" {
	mkdir -p "$BATS_TEST_TMPDIR/not-a-repo"
	dev_branch "$BATS_TEST_TMPDIR/not-a-repo"
	[ "$output" = "main" ]
}

@test "loads in zsh without zsh's completion system (e.g. no oh-my-zsh), with no errors" {
	command -v zsh >/dev/null 2>&1 || skip "zsh isn't installed"
	run zsh -f -c 'source "$1" && echo loaded' _ "$GIT_SH"
	[ "$status" -eq 0 ]
	[ "$output" = loaded ]
}
