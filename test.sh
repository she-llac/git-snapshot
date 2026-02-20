#!/bin/bash

SNAPSHOT="${SNAPSHOT:-$(cd "$(dirname "$0")" && pwd)/git-snapshot}"

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
RESET='\033[0m'

pass=0
fail=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}✓${RESET} $label" >&2
        ((pass++))
    else
        echo -e "  ${RED}✗${RESET} $label" >&2
        echo "    expected: $(echo "$expected" | head -3)" >&2
        echo "    actual:   $(echo "$actual" | head -3)" >&2
        ((fail++))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        echo -e "  ${GREEN}✓${RESET} $label" >&2
        ((pass++))
    else
        echo -e "  ${RED}✗${RESET} $label" >&2
        echo "    expected to contain: $needle" >&2
        echo "    actual: $(echo "$haystack" | head -3)" >&2
        ((fail++))
    fi
}

# snapshot helper that also verifies index + worktree are unchanged
snapshot_and_verify() {
    local label="$1"
    shift
    local index_before index_after worktree_before worktree_after

    index_before=$(git diff --cached --name-status)
    worktree_before=$(git diff --name-status)
    untracked_before=$(git ls-files --others --exclude-standard | sort)

    sha=$("$SNAPSHOT" "$@")

    index_after=$(git diff --cached --name-status)
    worktree_after=$(git diff --name-status)
    untracked_after=$(git ls-files --others --exclude-standard | sort)

    assert_eq "$label: index unchanged" "$index_before" "$index_after"
    assert_eq "$label: worktree unchanged" "$worktree_before" "$worktree_after"
    assert_eq "$label: untracked unchanged" "$untracked_before" "$untracked_after"

    echo "$sha"
}

# --- setup ---
dir=$(mktemp -d)
cd "$dir" || exit
echo "test repo: $dir"
echo

git init -q
git commit --allow-empty -m "root" -q
# shellcheck disable=SC2164  # test repo in /tmp, cd failure is not recoverable anyway

# === Test 1: clean repo ===
echo -e "${BOLD}Test 1: clean repo${RESET}"
sha=$(snapshot_and_verify "clean")
snap_tree=$(git rev-parse "$sha^{tree}")
head_tree=$(git rev-parse "HEAD^{tree}")
assert_eq "snapshot tree matches HEAD" "$head_tree" "$snap_tree"
echo

# === Test 2: untracked file only ===
echo -e "${BOLD}Test 2: untracked file${RESET}"
echo "hello" > untracked.txt
sha=$(snapshot_and_verify "untracked")
assert_eq "snapshot has untracked.txt" "untracked.txt" "$(git ls-tree --name-only "$sha" -- untracked.txt)"
echo

# === Test 3: staged file only ===
echo -e "${BOLD}Test 3: staged file${RESET}"
echo "staged content" > staged.txt
git add staged.txt
sha=$(snapshot_and_verify "staged")
assert_eq "snapshot has staged.txt" "staged content" "$(git show "$sha:staged.txt")"
assert_eq "staged.txt still in index" "A	staged.txt" "$(git diff --cached --name-status -- staged.txt)"
echo

# === Test 4: tracked + modified (unstaged) ===
echo -e "${BOLD}Test 4: tracked modified unstaged${RESET}"
git commit -q -m "add staged" -- staged.txt
echo "modified content" > staged.txt
sha=$(snapshot_and_verify "modified unstaged")
assert_eq "snapshot has modified content" "modified content" "$(git show "$sha:staged.txt")"
echo

# === Test 5: mix of staged, unstaged, untracked ===
echo -e "${BOLD}Test 5: mixed state${RESET}"
echo "new staged" > new.txt
git add new.txt
echo "also unstaged change" >> staged.txt
echo "another untracked" > another.txt
sha=$(snapshot_and_verify "mixed")
assert_eq "snapshot has new.txt" "new staged" "$(git show "$sha:new.txt")"
assert_eq "snapshot has another.txt" "another untracked" "$(git show "$sha:another.txt")"
assert_eq "snapshot has untracked.txt" "hello" "$(git show "$sha:untracked.txt")"
staged_in_snap=$(git show "$sha:staged.txt")
assert_eq "snapshot has modified staged.txt" "modified content
also unstaged change" "$staged_in_snap"
assert_eq "new.txt still staged" "A	new.txt" "$(git diff --cached --name-status -- new.txt)"
assert_eq "staged.txt has unstaged changes" "M	staged.txt" "$(git diff --name-status -- staged.txt)"
echo

# === Test 6: ignored files excluded by default ===
echo -e "${BOLD}Test 6: ignored files excluded${RESET}"
echo "*.log" > .gitignore
echo "should be ignored" > debug.log
sha=$(snapshot_and_verify "ignored excluded")
log_in_snap=$(git ls-tree --name-only "$sha" -- debug.log 2>/dev/null || echo "")
assert_eq "ignored file not in snapshot" "" "$log_in_snap"
gitignore_in_snap=$(git ls-tree --name-only "$sha" -- .gitignore)
assert_eq ".gitignore is in snapshot" ".gitignore" "$gitignore_in_snap"
echo

# === Test 7: ignored files included with -i ===
echo -e "${BOLD}Test 7: ignored files included with -i${RESET}"
sha=$(snapshot_and_verify "ignored included" -i)
log_in_snap=$(git ls-tree --name-only "$sha" -- debug.log 2>/dev/null || echo "")
assert_eq "ignored file in snapshot with -i" "debug.log" "$log_in_snap"
echo

# === Test 8: deleted tracked file ===
echo -e "${BOLD}Test 8: deleted tracked file${RESET}"
git add -A && git commit -q -m "checkpoint"
rm staged.txt
sha=$(snapshot_and_verify "deleted")
staged_in_snap=$(git ls-tree --name-only "$sha" -- staged.txt 2>/dev/null || echo "")
assert_eq "deleted file absent from snapshot" "" "$staged_in_snap"
echo

# === Test 9: staged deletion ===
echo -e "${BOLD}Test 9: staged deletion${RESET}"
git rm -q new.txt
sha=$(snapshot_and_verify "staged deletion")
new_in_snap=$(git ls-tree --name-only "$sha" -- new.txt 2>/dev/null || echo "")
assert_eq "staged-deleted file absent from snapshot" "" "$new_in_snap"
assert_eq "new.txt still staged for deletion" "D	new.txt" "$(git diff --cached --name-status -- new.txt)"
echo

# === Test 10: custom message ===
echo -e "${BOLD}Test 10: custom message${RESET}"
sha=$("$SNAPSHOT" -m "before the chaos")
reflog_msg=$(git reflog show refs/snapshots -1 --format='%gs')
assert_eq "reflog has custom message" "before the chaos" "$reflog_msg"
commit_msg=$(git log -1 --format='%s' "$sha")
assert_eq "commit has custom message" "before the chaos" "$commit_msg"
echo

# === Test 11: reflog accumulates ===
echo -e "${BOLD}Test 11: reflog${RESET}"
count=$(git reflog show refs/snapshots --no-decorate 2>/dev/null | wc -l | tr -d ' ')
assert_eq "reflog has 10 entries" "10" "$count"
echo

# === Test 12: from subdirectory ===
echo -e "${BOLD}Test 12: from subdirectory${RESET}"
mkdir -p sub/deep
echo "deep file" > sub/deep/file.txt
cd sub/deep || exit
sha=$(snapshot_and_verify "subdir")
assert_eq "snapshot has deep file" "deep file" "$(git show "$sha:sub/deep/file.txt")"
cd "$dir" || exit
echo

# === Test 13: list subcommand ===
echo -e "${BOLD}Test 13: list${RESET}"
list_output=$("$SNAPSHOT" list 2>&1)
assert_contains "list shows entries" "before the chaos" "$list_output"
assert_contains "list shows ref syntax" "snapshots@{" "$list_output"
echo

# === Test 14: show subcommand (stat by default) ===
echo -e "${BOLD}Test 14: show${RESET}"
echo "show test" > showfile.txt
sha=$("$SNAPSHOT" -m "for show test")
show_output=$("$SNAPSHOT" show 0)
assert_contains "show has stat output" "showfile.txt" "$show_output"
# -p gives full diff
show_p_output=$("$SNAPSHOT" show 0 -p)
assert_contains "show -p has diff content" "+show test" "$show_p_output"
echo

# === Test 15: files subcommand ===
echo -e "${BOLD}Test 15: files${RESET}"
files_output=$("$SNAPSHOT" files 0)
assert_contains "files lists showfile.txt" "showfile.txt" "$files_output"
assert_contains "files lists .gitignore" ".gitignore" "$files_output"
echo

# === Test 16: restore subcommand (single file) ===
echo -e "${BOLD}Test 16: restore single file${RESET}"
git add -A && git commit -q -m "checkpoint 2"
echo "original" > restore-me.txt
git add restore-me.txt && git commit -q -m "add restore-me"
echo "changed" > restore-me.txt
sha=$("$SNAPSHOT" -m "before restore test")
echo "destroyed" > restore-me.txt
"$SNAPSHOT" restore 0 restore-me.txt
assert_eq "file restored" "changed" "$(cat restore-me.txt)"
echo

# === Test 17: restore subcommand (full) ===
echo -e "${BOLD}Test 17: restore full${RESET}"
echo "aaa" > a.txt
echo "bbb" > b.txt
git add -A && git commit -q -m "add a and b"
echo "aaa modified" > a.txt
echo "bbb modified" > b.txt
sha=$("$SNAPSHOT" -m "before full restore")
echo "aaa destroyed" > a.txt
echo "bbb destroyed" > b.txt
"$SNAPSHOT" restore 0
assert_eq "a.txt restored" "aaa modified" "$(cat a.txt)"
assert_eq "b.txt restored" "bbb modified" "$(cat b.txt)"
echo

# === Test 18: show defaults to latest snapshot ===
echo -e "${BOLD}Test 18: show default snapshot${RESET}"
echo "default show" > default-show.txt
sha=$("$SNAPSHOT" -m "default show snapshot")
show_default_output=$("$SNAPSHOT" show)
assert_contains "show defaults to latest snapshot" "default-show.txt" "$show_default_output"
echo

# === Test 19: files defaults to latest snapshot ===
echo -e "${BOLD}Test 19: files default snapshot${RESET}"
files_default_output=$("$SNAPSHOT" files)
assert_contains "files defaults to latest snapshot" "default-show.txt" "$files_default_output"
echo

# === Test 20: invalid snapshot reference handling ===
echo -e "${BOLD}Test 20: invalid snapshot reference${RESET}"
show_missing_output=$("$SNAPSHOT" show 9999 2>&1)
show_missing_status=$?
assert_eq "show missing snapshot exits non-zero" "1" "$show_missing_status"
assert_contains "show missing snapshot prints error" "snapshot @{9999} not found" "$show_missing_output"

files_missing_output=$("$SNAPSHOT" files 9999 2>&1)
files_missing_status=$?
assert_eq "files missing snapshot exits non-zero" "1" "$files_missing_status"
assert_contains "files missing snapshot prints error" "snapshot @{9999} not found" "$files_missing_output"

restore_missing_output=$("$SNAPSHOT" restore 9999 2>&1)
restore_missing_status=$?
assert_eq "restore missing snapshot exits non-zero" "1" "$restore_missing_status"
assert_contains "restore missing snapshot prints error" "snapshot @{9999} not found" "$restore_missing_output"
echo

# === Test 21: restore usage validation ===
echo -e "${BOLD}Test 21: restore usage validation${RESET}"
restore_usage_output=$("$SNAPSHOT" restore 2>&1)
restore_usage_status=$?
assert_eq "restore without args exits non-zero" "1" "$restore_usage_status"
assert_contains "restore without args prints usage" "usage: git snapshot restore N [path...]" "$restore_usage_output"
echo

# === Test 22: snapshot option validation ===
echo -e "${BOLD}Test 22: snapshot option validation${RESET}"
message_missing_output=$("$SNAPSHOT" -m 2>&1)
message_missing_status=$?
assert_eq "missing message value exits non-zero" "1" "$message_missing_status"
assert_contains "missing message value prints error" "--message requires a value" "$message_missing_output"

unknown_option_output=$("$SNAPSHOT" -i --definitely-unknown 2>&1)
unknown_option_status=$?
assert_eq "unknown option exits non-zero" "1" "$unknown_option_status"
assert_contains "unknown option prints error" "unknown option: --definitely-unknown" "$unknown_option_output"
echo

# === Test 23: command parsing and help ===
echo -e "${BOLD}Test 23: command parsing and help${RESET}"
unknown_cmd_output=$("$SNAPSHOT" no-such-command 2>&1)
unknown_cmd_status=$?
assert_eq "unknown command exits non-zero" "1" "$unknown_cmd_status"
assert_contains "unknown command prints error" "unknown command: no-such-command" "$unknown_cmd_output"

help_output=$("$SNAPSHOT" --help)
help_status=$?
assert_eq "help exits zero" "0" "$help_status"
assert_contains "help contains usage" "Usage: git snapshot" "$help_output"
echo

# === Test 24: list in repo with no snapshots ===
echo -e "${BOLD}Test 24: list with no snapshots${RESET}"
empty_repo=$(mktemp -d)
git -C "$empty_repo" init -q
git -C "$empty_repo" commit --allow-empty -m "root" -q
empty_list_output=$(cd "$empty_repo" && "$SNAPSHOT" list)
assert_eq "list reports no snapshots when ref is absent" "no snapshots" "$empty_list_output"
rm -rf "$empty_repo"
echo

# === Test 25: drop ===
echo -e "${BOLD}Test 25: drop${RESET}"
count_before=$(git reflog show refs/snapshots --no-decorate 2>/dev/null | wc -l | tr -d ' ')
"$SNAPSHOT" -m "to be dropped" >/dev/null
count_after=$(git reflog show refs/snapshots --no-decorate 2>/dev/null | wc -l | tr -d ' ')
assert_eq "snapshot added" "$((count_before + 1))" "$count_after"
"$SNAPSHOT" drop 0
count_dropped=$(git reflog show refs/snapshots --no-decorate 2>/dev/null | wc -l | tr -d ' ')
assert_eq "snapshot dropped" "$count_before" "$count_dropped"

drop_usage_output=$("$SNAPSHOT" drop 2>&1)
drop_usage_status=$?
assert_eq "drop without args exits non-zero" "1" "$drop_usage_status"
assert_contains "drop without args prints usage" "usage: git snapshot drop N" "$drop_usage_output"

drop_missing_output=$("$SNAPSHOT" drop 9999 2>&1)
drop_missing_status=$?
assert_eq "drop missing snapshot exits non-zero" "1" "$drop_missing_status"
assert_contains "drop missing snapshot prints error" "snapshot @{9999} not found" "$drop_missing_output"
echo

# === Test 26: restore single file does not stage ===
echo -e "${BOLD}Test 26: restore single file does not stage${RESET}"
git add -A && git commit -q -m "checkpoint 3"
echo "original" > nostage.txt
git add nostage.txt && git commit -q -m "add nostage"
echo "modified" > nostage.txt
"$SNAPSHOT" -m "before nostage test" >/dev/null
echo "destroyed" > nostage.txt
"$SNAPSHOT" restore 0 nostage.txt
assert_eq "file content restored" "modified" "$(cat nostage.txt)"
index_status=$(git diff --cached --name-status -- nostage.txt)
assert_eq "restored file not staged" "" "$index_status"
worktree_status=$(git diff --name-status -- nostage.txt)
assert_eq "restored file shows as worktree modification" "M	nostage.txt" "$worktree_status"
echo

# === Test 27: restore full does not stage ===
echo -e "${BOLD}Test 27: restore full does not stage${RESET}"
git add -A && git commit -q -m "checkpoint 4"
echo "aa" > rs1.txt
echo "bb" > rs2.txt
git add rs1.txt rs2.txt && git commit -q -m "add rs1 rs2"
echo "aa modified" > rs1.txt
echo "bb modified" > rs2.txt
"$SNAPSHOT" -m "before full nostage" >/dev/null
echo "aa destroyed" > rs1.txt
echo "bb destroyed" > rs2.txt
"$SNAPSHOT" restore 0
assert_eq "rs1 content restored" "aa modified" "$(cat rs1.txt)"
assert_eq "rs2 content restored" "bb modified" "$(cat rs2.txt)"
staged_after=$(git diff --cached --name-status)
assert_eq "nothing staged after full restore" "" "$staged_after"
echo

# === Test 28: no commits (empty repo) ===
echo -e "${BOLD}Test 28: no commits (empty repo)${RESET}"
empty_nocommit=$(mktemp -d)
git -C "$empty_nocommit" init -q
echo "test" > "$empty_nocommit/file.txt"
snap_nocommit_output=$(cd "$empty_nocommit" && "$SNAPSHOT" 2>&1)
snap_nocommit_status=$?
assert_eq "snapshot on empty repo exits non-zero" "1" "$snap_nocommit_status"
assert_contains "snapshot on empty repo prints error" "error" "$snap_nocommit_output"
rm -rf "$empty_nocommit"
echo

# === Test 29: temp file cleaned up on failure ===
echo -e "${BOLD}Test 29: temp file cleanup${RESET}"
# Use a private TMPDIR so other processes don't interfere
leak_tmpdir=$(mktemp -d)
cleanup_repo=$(mktemp -d)
git -C "$cleanup_repo" init -q
(cd "$cleanup_repo" && TMPDIR="$leak_tmpdir" "$SNAPSHOT" 2>&1) || true
leaked=$(find "$leak_tmpdir" -maxdepth 1 -type f | wc -l | tr -d ' ')
assert_eq "no temp files leaked" "0" "$leaked"
rm -rf "$cleanup_repo" "$leak_tmpdir"
echo

# === Test 30: filenames with spaces and special chars ===
echo -e "${BOLD}Test 30: special filenames${RESET}"
echo "content spaces" > "file with spaces.txt"
echo "content quote" > "file'quote.txt"
sha=$(snapshot_and_verify "special filenames")
assert_eq "snapshot has file with spaces" "content spaces" "$(git show "$sha:file with spaces.txt")"
assert_eq "snapshot has file with quote" "content quote" "$(git show "$sha:file'quote.txt")"
echo

# === Test 31: symlink handling ===
echo -e "${BOLD}Test 31: symlinks${RESET}"
git add -A && git commit -q -m "checkpoint 5"
echo "symlink target" > real.txt
ln -s real.txt link.txt
sha=$(snapshot_and_verify "symlinks")
link_mode=$(git ls-tree "$sha" -- link.txt | awk '{print $1}')
assert_eq "symlink stored as symlink" "120000" "$link_mode"
link_content=$(git show "$sha:link.txt")
assert_eq "symlink target preserved" "real.txt" "$link_content"
echo

# === Test 32: binary file ===
echo -e "${BOLD}Test 32: binary file${RESET}"
git add -A && git commit -q -m "checkpoint 6"
dd if=/dev/urandom of=binary.bin bs=1024 count=64 2>/dev/null
expected_md5=$(md5 -q binary.bin)
sha=$(snapshot_and_verify "binary")
actual_md5=$(git show "$sha:binary.bin" | md5 -q)
assert_eq "binary file roundtrips correctly" "$expected_md5" "$actual_md5"
echo

# === Test 33: help text default message accuracy ===
echo -e "${BOLD}Test 33: help text accuracy${RESET}"
help_output=$("$SNAPSHOT" --help)
sha=$("$SNAPSHOT")
commit_msg=$(git log -1 --format='%s' "$sha")
if echo "$help_output" | grep -q "default: timestamp"; then
    # help says "default: timestamp", so the actual default should not be the literal "snapshot"
    is_literal_snapshot=$(echo "$commit_msg" | grep -c '^snapshot$')
    assert_eq "default message is a timestamp, not literal 'snapshot'" "0" "$is_literal_snapshot"
else
    assert_eq "default message matches help" "snapshot" "$commit_msg"
fi
echo

# === Test 34: drop shifts numbering ===
echo -e "${BOLD}Test 34: drop shifts numbering${RESET}"
"$SNAPSHOT" -m "drop-first" >/dev/null
"$SNAPSHOT" -m "drop-second" >/dev/null
"$SNAPSHOT" -m "drop-third" >/dev/null
# git reflog show lists newest first; sed -n Np picks the Nth line (1-indexed)
msg_before_0=$(git reflog show refs/snapshots --format='%gs' | sed -n '1p')
msg_before_1=$(git reflog show refs/snapshots --format='%gs' | sed -n '2p')
msg_before_2=$(git reflog show refs/snapshots --format='%gs' | sed -n '3p')
assert_eq "before drop: @{0} is third" "drop-third" "$msg_before_0"
assert_eq "before drop: @{1} is second" "drop-second" "$msg_before_1"
assert_eq "before drop: @{2} is first" "drop-first" "$msg_before_2"
"$SNAPSHOT" drop 1
msg_after_0=$(git reflog show refs/snapshots --format='%gs' | sed -n '1p')
msg_after_1=$(git reflog show refs/snapshots --format='%gs' | sed -n '2p')
assert_eq "after drop @{1}: @{0} still third" "drop-third" "$msg_after_0"
assert_eq "after drop @{1}: @{1} is now first" "drop-first" "$msg_after_1"
echo

# === Test 35: show with extra diff flags ===
echo -e "${BOLD}Test 35: show passes extra args to git diff${RESET}"
git add -A && git commit -q -m "checkpoint 7"
echo "diffme" > difftest.txt
"$SNAPSHOT" -m "for diff flags" >/dev/null
# --name-only should produce just filenames, not stat
show_nameonly=$("$SNAPSHOT" show 0 --name-only)
assert_contains "show --name-only includes file" "difftest.txt" "$show_nameonly"
# should NOT contain the stat format (e.g. " | ")
if echo "$show_nameonly" | grep -q ' | '; then
    echo -e "  ${RED}✗${RESET} show --name-only suppresses stat" >&2
    ((fail++))
else
    echo -e "  ${GREEN}✓${RESET} show --name-only suppresses stat" >&2
    ((pass++))
fi
echo

# --- results ---
echo -e "${BOLD}Results: ${GREEN}$pass passed${RESET}, ${RED}$fail failed${RESET}"
rm -rf "$dir"
exit $fail
