#!/usr/bin/env bats
# Behavioral tests for the more complex aliases in git/gitconfig: bclean, m, co-wip/coa-wip and
# merge-no-commit. tools/__test__/check-aliases.bats covers static/structural checks (syntax,
# portability); these actually run the aliases against a real repo.

setup() {
	GITCONFIG="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/gitconfig"
	export HOME="$BATS_TEST_TMPDIR/home"
	export GIT_CONFIG_NOSYSTEM=1
	unset GIT_CONFIG_GLOBAL
	mkdir -p "$HOME"
	git config --global user.name Test
	git config --global user.email test@example.com

	PROJECT="$BATS_TEST_TMPDIR/project"
	git init -q "$PROJECT"
	git -C "$PROJECT" config include.path "$GITCONFIG"
	git -C "$PROJECT" commit -q --allow-empty -m base
	git -C "$PROJECT" branch -M main
	cd "$PROJECT"
}

#   -------------------------------
#   bclean
#   -------------------------------

@test "bclean deletes a branch merged into main" {
	git checkout -qb feature
	git commit -q --allow-empty -m "feature commit"
	git checkout -q main
	git merge -q feature
	git bclean
	run git branch --format='%(refname:short)'
	[[ "$output" != *feature* ]] || false
}

@test "bclean defaults to main and leaves main itself alone" {
	git bclean
	run git branch --format='%(refname:short)'
	[ "$output" = "main" ]
}

@test "bclean leaves an unmerged branch alone" {
	git checkout -qb unmerged
	git commit -q --allow-empty -m "not merged"
	git checkout -q main
	git bclean
	run git branch --format='%(refname:short)'
	[[ "$output" == *unmerged* ]] || false
}

@test "bclean doesn't delete a branch checked out in another worktree" {
	git checkout -qb feature
	git commit -q --allow-empty -m "feature commit"
	git checkout -q main
	git merge -q feature
	git worktree add -q "$BATS_TEST_TMPDIR/other-worktree" feature
	git bclean
	run git branch --format='%(refname:short)'
	[[ "$output" == *feature* ]] || false
}

#   -------------------------------
#   co-wip / coa-wip
#   -------------------------------

@test "co-wip commits only what's already staged" {
	echo content > staged.txt
	echo content > unstaged.txt
	git add staged.txt
	run git co-wip
	run git log -1 --format=%s
	[[ "$output" == "WIP main "* ]] || false
	run git show --pretty="" --name-only HEAD
	[ "$output" = "staged.txt" ]
}

@test "co-wip does nothing when nothing is staged" {
	before="$(git rev-parse HEAD)"
	echo content > untracked.txt
	run git co-wip
	[ "$(git rev-parse HEAD)" = "$before" ]
}

@test "coa-wip stages and commits everything" {
	echo content > a.txt
	echo content > b.txt
	run git coa-wip
	run git log -1 --format=%s
	[[ "$output" == "WIP main "* ]] || false
	run git status --porcelain
	[ -z "$output" ]
}

@test "co-wip is prevented when the last commit is already WIP" {
	echo content > a.txt
	git coa-wip
	before="$(git rev-parse HEAD)"
	echo more > b.txt
	git add b.txt
	run git co-wip
	[[ "$output" == *"Preventing commit"* ]] || false
	[ "$(git rev-parse HEAD)" = "$before" ]
}

#   -------------------------------
#   m
#   -------------------------------

@test "m merges cleanly when the tree is clean" {
	git checkout -qb feature
	echo content > feature.txt
	git add feature.txt
	git commit -q -m "feature commit"
	git checkout -q main
	git m feature
	[ -f feature.txt ]
	run git log -1 --format=%s
	[ "$output" = "feature commit" ]
}

@test "m undoes a WIP commit, merges, then restores it on top" {
	git checkout -qb feature
	echo content > feature.txt
	git add feature.txt
	git commit -q -m "feature commit"
	git checkout -q main

	echo work > work.txt
	git coa-wip
	wip_message="$(git log -1 --format=%s)"

	git m feature

	[ -f feature.txt ]
	[ -f work.txt ]
	run git log --format=%s -3
	[[ "$output" == *"$wip_message"* ]] || false
}

@test "m stashes and restores unrelated working-tree changes" {
	git checkout -qb feature
	git commit -q --allow-empty -m "feature commit"
	git checkout -q main

	echo dirty > dirty.txt

	git m feature

	[ -f dirty.txt ]
	run git status --porcelain -- dirty.txt
	[[ "$output" == *dirty.txt* ]] || false
}

#   -------------------------------
#   merge-no-commit
#   -------------------------------

@test "merge-no-commit stages the merge but doesn't commit" {
	git checkout -qb feature
	echo content > feature.txt
	git add feature.txt
	git commit -q -m "feature commit"
	git checkout -q main

	git merge-no-commit feature

	run git diff --cached --name-only
	[ "$output" = "feature.txt" ]
	run git log -1 --format=%s
	[ "$output" = "base" ]
}

@test "merge-no-commit leaves no MERGE_HEAD behind" {
	git checkout -qb feature
	git commit -q --allow-empty -m "feature commit"
	git checkout -q main

	git merge-no-commit feature

	[ ! -f "$(git rev-parse --git-dir)/MERGE_HEAD" ]
}
