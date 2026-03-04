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

    _sv_sha=$sha
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
snapshot_and_verify "clean"
sha=$_sv_sha
snap_tree=$(git rev-parse "$sha^{tree}")
head_tree=$(git rev-parse "HEAD^{tree}")
assert_eq "snapshot tree matches HEAD" "$head_tree" "$snap_tree"
echo

# === Test 2: untracked file only ===
echo -e "${BOLD}Test 2: untracked file${RESET}"
echo "hello" > untracked.txt
snapshot_and_verify "untracked"
sha=$_sv_sha
assert_eq "snapshot has untracked.txt" "untracked.txt" "$(git ls-tree --name-only "$sha" -- untracked.txt)"
echo

# === Test 3: staged file only ===
echo -e "${BOLD}Test 3: staged file${RESET}"
echo "staged content" > staged.txt
git add staged.txt
snapshot_and_verify "staged"
sha=$_sv_sha
assert_eq "snapshot has staged.txt" "staged content" "$(git show "$sha:staged.txt")"
assert_eq "staged.txt still in index" "A	staged.txt" "$(git diff --cached --name-status -- staged.txt)"
echo

# === Test 4: tracked + modified (unstaged) ===
echo -e "${BOLD}Test 4: tracked modified unstaged${RESET}"
git commit -q -m "add staged" -- staged.txt
echo "modified content" > staged.txt
snapshot_and_verify "modified unstaged"
sha=$_sv_sha
assert_eq "snapshot has modified content" "modified content" "$(git show "$sha:staged.txt")"
echo

# === Test 5: mix of staged, unstaged, untracked ===
echo -e "${BOLD}Test 5: mixed state${RESET}"
echo "new staged" > new.txt
git add new.txt
echo "also unstaged change" >> staged.txt
echo "another untracked" > another.txt
snapshot_and_verify "mixed"
sha=$_sv_sha
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
snapshot_and_verify "ignored excluded"
sha=$_sv_sha
log_in_snap=$(git ls-tree --name-only "$sha" -- debug.log 2>/dev/null || echo "")
assert_eq "ignored file not in snapshot" "" "$log_in_snap"
gitignore_in_snap=$(git ls-tree --name-only "$sha" -- .gitignore)
assert_eq ".gitignore is in snapshot" ".gitignore" "$gitignore_in_snap"
echo

# === Test 7: ignored files included with -i ===
echo -e "${BOLD}Test 7: ignored files included with -i${RESET}"
snapshot_and_verify "ignored included" -i
sha=$_sv_sha
log_in_snap=$(git ls-tree --name-only "$sha" -- debug.log 2>/dev/null || echo "")
assert_eq "ignored file in snapshot with -i" "debug.log" "$log_in_snap"
echo

# === Test 8: deleted tracked file ===
echo -e "${BOLD}Test 8: deleted tracked file${RESET}"
git add -A && git commit -q -m "checkpoint"
rm staged.txt
snapshot_and_verify "deleted"
sha=$_sv_sha
staged_in_snap=$(git ls-tree --name-only "$sha" -- staged.txt 2>/dev/null || echo "")
assert_eq "deleted file absent from snapshot" "" "$staged_in_snap"
echo

# === Test 9: staged deletion ===
echo -e "${BOLD}Test 9: staged deletion${RESET}"
git rm -q new.txt
snapshot_and_verify "staged deletion"
sha=$_sv_sha
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
snapshot_and_verify "subdir"
sha=$_sv_sha
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
echo "modified nostagefile" > nostage.txt
"$SNAPSHOT" -m "before nostage test" >/dev/null
echo "destroyed" > nostage.txt
"$SNAPSHOT" restore 0 nostage.txt
assert_eq "file content restored" "modified nostagefile" "$(cat nostage.txt)"
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
(cd "$cleanup_repo" && TMPDIR="$leak_tmpdir" "$SNAPSHOT" >/dev/null 2>&1) || true
leaked=$(find "$leak_tmpdir" -maxdepth 1 -type f | wc -l | tr -d ' ')
assert_eq "no temp files leaked" "0" "$leaked"
rm -rf "$cleanup_repo" "$leak_tmpdir"
echo

# === Test 30: filenames with spaces and special chars ===
echo -e "${BOLD}Test 30: special filenames${RESET}"
echo "content spaces" > "file with spaces.txt"
echo "content quote" > "file'quote.txt"
snapshot_and_verify "special filenames"
sha=$_sv_sha
assert_eq "snapshot has file with spaces" "content spaces" "$(git show "$sha:file with spaces.txt")"
assert_eq "snapshot has file with quote" "content quote" "$(git show "$sha:file'quote.txt")"
echo

# === Test 31: symlink handling ===
echo -e "${BOLD}Test 31: symlinks${RESET}"
git add -A && git commit -q -m "checkpoint 5"
echo "symlink target" > real.txt
ln -s real.txt link.txt
snapshot_and_verify "symlinks"
sha=$_sv_sha
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
snapshot_and_verify "binary"
sha=$_sv_sha
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

# === Test 36: show with flags but no index ===
echo -e "${BOLD}Test 36: show with flags but no index${RESET}"
git add -A && git commit -q -m "checkpoint 8"
echo "flag-test" > flagtest.txt
"$SNAPSHOT" -m "for flag test" >/dev/null
# "show -p" should treat -p as a diff flag, not a snapshot index
show_flag_output=$("$SNAPSHOT" show -p 2>&1)
show_flag_status=$?
assert_eq "show -p exits zero" "0" "$show_flag_status"
assert_contains "show -p includes file" "flagtest.txt" "$show_flag_output"
assert_contains "show -p includes diff content" "+flag-test" "$show_flag_output"
# show --name-only (no index)
show_nameonly2=$("$SNAPSHOT" show --name-only)
assert_contains "show --name-only (no index) includes file" "flagtest.txt" "$show_nameonly2"
echo

# === Test 37: show with N > 0 ===
echo -e "${BOLD}Test 37: show with N > 0${RESET}"
git add -A && git commit -q -m "checkpoint 9"
echo "older" > older.txt
"$SNAPSHOT" -m "older snap" >/dev/null
echo "newer" > newer.txt
"$SNAPSHOT" -m "newer snap" >/dev/null
show_0=$("$SNAPSHOT" show 0 --name-only)
show_1=$("$SNAPSHOT" show 1 --name-only)
assert_contains "show 0 has newer.txt" "newer.txt" "$show_0"
assert_contains "show 1 has older.txt" "older.txt" "$show_1"
echo

# === Test 38: files with N > 0 ===
echo -e "${BOLD}Test 38: files with N > 0${RESET}"
files_0=$("$SNAPSHOT" files 0)
files_1=$("$SNAPSHOT" files 1)
assert_contains "files 0 has newer.txt" "newer.txt" "$files_0"
assert_contains "files 1 has older.txt" "older.txt" "$files_1"
echo

# === Test 39: restore from subdirectory restores full tree ===
echo -e "${BOLD}Test 39: restore from subdirectory${RESET}"
git add -A && git commit -q -m "checkpoint 10"
mkdir -p rsub
echo "root content" > root-rsub.txt
echo "sub content" > rsub/sub-rsub.txt
git add -A && git commit -q -m "add rsub files"
echo "root modified" > root-rsub.txt
echo "sub modified" > rsub/sub-rsub.txt
"$SNAPSHOT" -m "before subdir restore" >/dev/null
echo "root destroyed" > root-rsub.txt
echo "sub destroyed" > rsub/sub-rsub.txt
cd rsub
"$SNAPSHOT" restore 0
cd "$dir"
assert_eq "root file restored from subdir" "root modified" "$(cat root-rsub.txt)"
assert_eq "sub file restored from subdir" "sub modified" "$(cat rsub/sub-rsub.txt)"
echo

# === Test 40: restore deleted tracked file ===
echo -e "${BOLD}Test 40: restore deleted tracked file${RESET}"
git add -A && git commit -q -m "checkpoint 11"
echo "will delete" > deleteme.txt
git add deleteme.txt && git commit -q -m "add deleteme"
"$SNAPSHOT" -m "has deleteme" >/dev/null
rm deleteme.txt
"$SNAPSHOT" restore 0 deleteme.txt
assert_eq "deleted file restored" "will delete" "$(cat deleteme.txt)"
echo

# === Test 41: restore untracked file from snapshot ===
echo -e "${BOLD}Test 41: restore untracked file from snapshot${RESET}"
{ git add -A && git commit -q -m "checkpoint 12"; } >/dev/null 2>&1 || true
echo "untracked snap" > untracked-restore.txt
"$SNAPSHOT" -m "has untracked" >/dev/null
rm untracked-restore.txt
"$SNAPSHOT" restore 0 untracked-restore.txt
assert_eq "untracked file restored from snapshot" "untracked snap" "$(cat untracked-restore.txt)"
echo

# === Test 42: restore nonexistent path errors cleanly ===
echo -e "${BOLD}Test 42: restore nonexistent path${RESET}"
restore_bad_output=$("$SNAPSHOT" restore 0 no-such-file.txt 2>&1)
restore_bad_status=$?
assert_eq "restore nonexistent path exits non-zero" "1" "$restore_bad_status"
assert_contains "restore nonexistent path mentions pathspec" "pathspec" "$restore_bad_output"
echo

# === Test 43: list after dropping all snapshots ===
echo -e "${BOLD}Test 43: list after dropping all snapshots${RESET}"
drop_repo=$(mktemp -d)
git -C "$drop_repo" init -q
git -C "$drop_repo" commit --allow-empty -m "root" -q
(cd "$drop_repo" && "$SNAPSHOT" -m "only" >/dev/null)
(cd "$drop_repo" && "$SNAPSHOT" drop 0)
drop_list_output=$(cd "$drop_repo" && "$SNAPSHOT" list)
assert_eq "list shows 'no snapshots' after dropping all" "no snapshots" "$drop_list_output"
drop_ref_exists=$(git -C "$drop_repo" rev-parse --verify refs/snapshots 2>/dev/null && echo YES || echo NO)
assert_eq "ref removed after dropping last snapshot" "NO" "$drop_ref_exists"
rm -rf "$drop_repo"
echo

# === Test 44: snapshot after dropping all snapshots ===
echo -e "${BOLD}Test 44: snapshot after dropping all snapshots${RESET}"
fresh_repo=$(mktemp -d)
git -C "$fresh_repo" init -q
git -C "$fresh_repo" commit --allow-empty -m "root" -q
(cd "$fresh_repo" && "$SNAPSHOT" -m "first" >/dev/null)
(cd "$fresh_repo" && "$SNAPSHOT" drop 0)
fresh_sha=$(cd "$fresh_repo" && "$SNAPSHOT" -m "after drop")
fresh_status=$?
assert_eq "snapshot after drop exits zero" "0" "$fresh_status"
fresh_list=$(cd "$fresh_repo" && "$SNAPSHOT" list)
assert_contains "new snapshot appears in list after drop" "after drop" "$fresh_list"
rm -rf "$fresh_repo"
echo

# === Test 45: detached HEAD ===
echo -e "${BOLD}Test 45: detached HEAD${RESET}"
detach_repo=$(mktemp -d)
git -C "$detach_repo" init -q
git -C "$detach_repo" commit --allow-empty -m "root" -q
git -C "$detach_repo" commit --allow-empty -m "second" -q
git -C "$detach_repo" checkout --detach HEAD -q
echo "detached content" > "$detach_repo/det.txt"
det_sha=$(cd "$detach_repo" && "$SNAPSHOT" -m "detached snap")
det_status=$?
assert_eq "snapshot on detached HEAD exits zero" "0" "$det_status"
det_content=$(git -C "$detach_repo" show "$det_sha:det.txt")
assert_eq "detached snapshot has file" "detached content" "$det_content"
rm -rf "$detach_repo"
echo

# === Test 46: outside git repo ===
echo -e "${BOLD}Test 46: outside git repo${RESET}"
nogit_dir=$(mktemp -d)
nogit_output=$(cd "$nogit_dir" && "$SNAPSHOT" 2>&1)
nogit_status=$?
assert_eq "outside git repo exits non-zero" "1" "$nogit_status"
assert_contains "outside git repo prints friendly error" "not a git repository" "$nogit_output"
rm -rf "$nogit_dir"
echo

# === Test 47: bare repository ===
echo -e "${BOLD}Test 47: bare repository${RESET}"
bare_dir=$(mktemp -d)/bare.git
git init --bare -q "$bare_dir"
bare_output=$(cd "$bare_dir" && "$SNAPSHOT" 2>&1)
bare_status=$?
assert_eq "bare repo exits non-zero" "1" "$bare_status"
assert_contains "bare repo prints friendly error" "not a git repository" "$bare_output"
rm -rf "$bare_dir"
echo

# === Test 48: combined -m and -i flags ===
echo -e "${BOLD}Test 48: combined -m and -i${RESET}"
git add -A && git commit -q -m "checkpoint 13"
echo "*.tmp" >> .gitignore
echo "combo ignored" > combo.tmp
echo "combo tracked" > combo.txt
sha=$("$SNAPSHOT" -m "combo test" -i)
combo_status=$?
assert_eq "combined flags exit zero" "0" "$combo_status"
combo_msg=$(git log -1 --format='%s' "$sha")
assert_eq "combined flags: message correct" "combo test" "$combo_msg"
combo_ignored=$(git ls-tree --name-only "$sha" -- combo.tmp)
assert_eq "combined flags: ignored file included" "combo.tmp" "$combo_ignored"
# Also test -i before -m
sha2=$("$SNAPSHOT" -i -m "combo reverse")
combo2_msg=$(git log -1 --format='%s' "$sha2")
assert_eq "reverse flag order: message correct" "combo reverse" "$combo2_msg"
combo2_ignored=$(git ls-tree --name-only "$sha2" -- combo.tmp)
assert_eq "reverse flag order: ignored file included" "combo.tmp" "$combo2_ignored"
echo

# === Test 49: temp file cleanup on mid-operation failure ===
echo -e "${BOLD}Test 49: temp file cleanup on failure${RESET}"
cleanup2_repo=$(mktemp -d)
git -C "$cleanup2_repo" init -q
git -C "$cleanup2_repo" commit --allow-empty -m "root" -q
echo "test" > "$cleanup2_repo/file.txt"
# Make the index unreadable to force cp failure after mktemp
chmod 000 "$cleanup2_repo/.git/index"
cleanup2_output=$(cd "$cleanup2_repo" && "$SNAPSHOT" 2>&1) || true
chmod 644 "$cleanup2_repo/.git/index"
assert_contains "failure error is clean" "error:" "$cleanup2_output"
assert_contains "failure error mentions copy" "failed to copy index" "$cleanup2_output"
# Should NOT mention "unbound variable"
if echo "$cleanup2_output" | grep -q "unbound variable"; then
    echo -e "  ${RED}✗${RESET} no unbound variable error" >&2
    ((fail++))
else
    echo -e "  ${GREEN}✓${RESET} no unbound variable error" >&2
    ((pass++))
fi
rm -rf "$cleanup2_repo"
echo

# === Test 50: show --stat is default, not forced with user flags ===
echo -e "${BOLD}Test 50: show stat vs user format flags${RESET}"
git add -A && git commit -q -m "checkpoint 14"
echo "stat-test" > stattest.txt
"$SNAPSHOT" -m "stat test" >/dev/null
# Default should include stat format
show_default=$("$SNAPSHOT" show)
assert_contains "show default has stat (|)" " | " "$show_default"
# With --name-only, should NOT have stat
show_no=$("$SNAPSHOT" show --name-only)
if echo "$show_no" | grep -q ' | '; then
    echo -e "  ${RED}✗${RESET} --name-only suppresses stat (no forced --stat)" >&2
    ((fail++))
else
    echo -e "  ${GREEN}✓${RESET} --name-only suppresses stat (no forced --stat)" >&2
    ((pass++))
fi
echo

# === Test 51: show with -- path limiting ===
echo -e "${BOLD}Test 51: show with -- path limiting${RESET}"
git add -A && git commit -q -m "checkpoint 15"
echo "pathA" > path-a.txt
echo "pathB" > path-b.txt
"$SNAPSHOT" -m "for path limiting" >/dev/null
show_path_output=$("$SNAPSHOT" show 0 -- path-a.txt)
assert_contains "show -- path has target file" "path-a.txt" "$show_path_output"
if echo "$show_path_output" | grep -q "path-b.txt"; then
    echo -e "  ${RED}✗${RESET} show -- path excludes other files" >&2
    ((fail++))
else
    echo -e "  ${GREEN}✓${RESET} show -- path excludes other files" >&2
    ((pass++))
fi
echo

# === Test 52: show with flags and -- path limiting ===
echo -e "${BOLD}Test 52: show with flags and -- path limiting${RESET}"
show_path_p=$("$SNAPSHOT" show 0 -p -- path-a.txt)
assert_contains "show -p -- path has diff content" "+pathA" "$show_path_p"
if echo "$show_path_p" | grep -q "+pathB"; then
    echo -e "  ${RED}✗${RESET} show -p -- path excludes other files" >&2
    ((fail++))
else
    echo -e "  ${GREEN}✓${RESET} show -p -- path excludes other files" >&2
    ((pass++))
fi
echo

# === Test 53: --message=value form ===
echo -e "${BOLD}Test 53: --message=value form${RESET}"
sha=$("$SNAPSHOT" --message="equals form")
msg53=$(git log -1 --format='%s' "$sha")
assert_eq "--message=value sets message" "equals form" "$msg53"
# --message= (empty) should fail
msg_empty_output=$("$SNAPSHOT" --message= 2>&1)
msg_empty_status=$?
assert_eq "--message= (empty) exits non-zero" "1" "$msg_empty_status"
assert_contains "--message= (empty) prints error" "--message requires a value" "$msg_empty_output"
# --message=value with -i
sha53b=$("$SNAPSHOT" --message="equals with ignored" -i)
msg53b=$(git log -1 --format='%s' "$sha53b")
assert_eq "--message=value with -i: message correct" "equals with ignored" "$msg53b"
echo

# === Test 54: restore full tree removes files not in snapshot ===
echo -e "${BOLD}Test 54: restore full tree removes post-snapshot files${RESET}"
restore_repo=$(mktemp -d)
git -C "$restore_repo" init -q
git -C "$restore_repo" commit --allow-empty -m "root" -q
echo "original" > "$restore_repo/original.txt"
(cd "$restore_repo" && git add -A && git commit -q -m "add original")
(cd "$restore_repo" && "$SNAPSHOT" -m "before new file" >/dev/null)
echo "new committed" > "$restore_repo/new-committed.txt"
(cd "$restore_repo" && git add -A && git commit -q -m "add new-committed")
(cd "$restore_repo" && "$SNAPSHOT" restore 0)
assert_eq "committed file not in snapshot is removed" "NO" "$(test -f "$restore_repo/new-committed.txt" && echo YES || echo NO)"
assert_eq "original file still present" "original" "$(cat "$restore_repo/original.txt")"
rm -rf "$restore_repo"
echo

# === Test 55: restore full tree preserves untracked files not in snapshot ===
echo -e "${BOLD}Test 55: restore full tree preserves untracked files${RESET}"
restore_repo2=$(mktemp -d)
git -C "$restore_repo2" init -q
git -C "$restore_repo2" commit --allow-empty -m "root" -q
echo "tracked" > "$restore_repo2/tracked.txt"
(cd "$restore_repo2" && git add -A && git commit -q -m "add tracked")
(cd "$restore_repo2" && "$SNAPSHOT" -m "before untracked" >/dev/null)
echo "new untracked" > "$restore_repo2/untracked-new.txt"
(cd "$restore_repo2" && "$SNAPSHOT" restore 0)
assert_eq "untracked file not in snapshot is preserved" "new untracked" "$(cat "$restore_repo2/untracked-new.txt")"
rm -rf "$restore_repo2"
echo

# === Test 56: drop with non-numeric argument ===
echo -e "${BOLD}Test 56: drop with non-numeric argument${RESET}"
drop_nonnumeric_output=$("$SNAPSHOT" drop abc 2>&1)
drop_nonnumeric_status=$?
assert_eq "drop abc exits non-zero" "1" "$drop_nonnumeric_status"
assert_contains "drop abc prints error" "snapshot @{abc} not found" "$drop_nonnumeric_output"
echo

# === Test 57: drop with reflog date string ===
echo -e "${BOLD}Test 57: drop with reflog date string${RESET}"
drop_date_repo=$(mktemp -d)
git -C "$drop_date_repo" init -q
git -C "$drop_date_repo" commit --allow-empty -m "root" -q
(cd "$drop_date_repo" && "$SNAPSHOT" -m "first" >/dev/null)
sleep 2
(cd "$drop_date_repo" && "$SNAPSHOT" -m "second" >/dev/null)
(cd "$drop_date_repo" && "$SNAPSHOT" drop "1.second.ago")
remaining_count=$(cd "$drop_date_repo" && git reflog show refs/snapshots --no-decorate 2>/dev/null | wc -l | tr -d ' ')
assert_eq "date-based drop: one entry removed" "1" "$remaining_count"
rm -rf "$drop_date_repo"
echo

# === Test 58: snapshot during merge conflict ===
echo -e "${BOLD}Test 58: snapshot during merge conflict${RESET}"
merge_repo=$(mktemp -d)
git -C "$merge_repo" init -q
echo "base" > "$merge_repo/conflict.txt"
(cd "$merge_repo" && git add -A && git commit -q -m "base")
(cd "$merge_repo" && git checkout -q -b branch1)
echo "branch1" > "$merge_repo/conflict.txt"
(cd "$merge_repo" && git commit -q -am "b1")
(cd "$merge_repo" && git checkout -q main)
echo "main change" > "$merge_repo/conflict.txt"
(cd "$merge_repo" && git commit -q -am "main change")
(cd "$merge_repo" && git merge branch1 >/dev/null 2>&1) || true
merge_sha=$(cd "$merge_repo" && "$SNAPSHOT" -m "during merge")
merge_status=$?
assert_eq "snapshot during merge exits zero" "0" "$merge_status"
merge_content=$(git -C "$merge_repo" show "$merge_sha:conflict.txt")
assert_contains "snapshot captures conflict markers" "<<<<<<<" "$merge_content"
rm -rf "$merge_repo"
echo

# === Test 59: git mv rename ===
echo -e "${BOLD}Test 59: git mv rename${RESET}"
git add -A && git commit -q -m "checkpoint 16"
echo "rename content" > before-rename.txt
git add before-rename.txt && git commit -q -m "add before-rename"
git mv before-rename.txt after-rename.txt
snapshot_and_verify "rename"
sha=$_sv_sha
rename_old=$(git ls-tree --name-only "$sha" -- before-rename.txt 2>/dev/null || echo "")
rename_new=$(git ls-tree --name-only "$sha" -- after-rename.txt)
assert_eq "old name absent from snapshot" "" "$rename_old"
assert_eq "new name present in snapshot" "after-rename.txt" "$rename_new"
assert_eq "snapshot has renamed content" "rename content" "$(git show "$sha:after-rename.txt")"
assert_eq "rename still staged" "R100	before-rename.txt	after-rename.txt" "$(git diff --cached --name-status -- before-rename.txt after-rename.txt)"
echo

# === Test 60: permission changes captured ===
echo -e "${BOLD}Test 60: permission changes captured${RESET}"
git add -A && git commit -q -m "checkpoint 17"
echo "mode test" > modefile.sh
git add modefile.sh && git commit -q -m "add modefile"
mode_before=$(git ls-tree HEAD -- modefile.sh | awk '{print $1}')
chmod +x modefile.sh
snapshot_and_verify "permissions"
sha=$_sv_sha
mode_snap=$(git ls-tree "$sha" -- modefile.sh | awk '{print $1}')
mode_head=$(git ls-tree HEAD -- modefile.sh | awk '{print $1}')
assert_eq "HEAD still has old mode" "$mode_before" "$mode_head"
assert_eq "snapshot has executable mode" "100755" "$mode_snap"
echo

# === Test 61: full restore recovers previously-untracked files ===
echo -e "${BOLD}Test 61: full restore recovers previously-untracked files${RESET}"
restore_untracked_repo=$(mktemp -d)
git -C "$restore_untracked_repo" init -q
git -C "$restore_untracked_repo" commit --allow-empty -m "root" -q
echo "tracked" > "$restore_untracked_repo/tracked.txt"
(cd "$restore_untracked_repo" && git add -A && git commit -q -m "add tracked")
echo "bonus1" > "$restore_untracked_repo/bonus1.txt"
echo "bonus2" > "$restore_untracked_repo/bonus2.txt"
(cd "$restore_untracked_repo" && "$SNAPSHOT" -m "has untracked" >/dev/null)
rm "$restore_untracked_repo/bonus1.txt" "$restore_untracked_repo/bonus2.txt"
(cd "$restore_untracked_repo" && "$SNAPSHOT" restore 0)
assert_eq "untracked bonus1 restored by full restore" "bonus1" "$(cat "$restore_untracked_repo/bonus1.txt")"
assert_eq "untracked bonus2 restored by full restore" "bonus2" "$(cat "$restore_untracked_repo/bonus2.txt")"
assert_eq "tracked file still present" "tracked" "$(cat "$restore_untracked_repo/tracked.txt")"
rm -rf "$restore_untracked_repo"
echo

# === Test 62: full restore with staged-but-uncommitted file ===
echo -e "${BOLD}Test 62: full restore with staged-but-uncommitted file${RESET}"
staged_restore_repo=$(mktemp -d)
git -C "$staged_restore_repo" init -q
git -C "$staged_restore_repo" commit --allow-empty -m "root" -q
echo "orig" > "$staged_restore_repo/orig.txt"
(cd "$staged_restore_repo" && git add orig.txt && git commit -q -m "add orig")
(cd "$staged_restore_repo" && "$SNAPSHOT" -m "before staging" >/dev/null)
echo "staged-new" > "$staged_restore_repo/staged-new.txt"
(cd "$staged_restore_repo" && git add staged-new.txt)
(cd "$staged_restore_repo" && "$SNAPSHOT" restore 0)
assert_eq "staged file removed from worktree" "NO" "$(test -f "$staged_restore_repo/staged-new.txt" && echo YES || echo NO)"
staged_status=$(cd "$staged_restore_repo" && git diff --cached --name-status -- staged-new.txt)
assert_eq "staged file remains in index" "A	staged-new.txt" "$staged_status"
echo

# === Test 63: file-to-directory type change ===
echo -e "${BOLD}Test 63: file-to-directory type change${RESET}"
git add -A && git commit -q -m "checkpoint 18"
echo "I am a file" > thing
git add thing && git commit -q -m "thing as file"
snapshot_and_verify "thing as file"
sha_file=$_sv_sha
assert_eq "snapshot has thing as file" "100644" "$(git ls-tree "$sha_file" -- thing | awk '{print $1}')"
rm thing
mkdir thing
echo "inside dir" > thing/inner.txt
snapshot_and_verify "thing as dir"
sha_dir=$_sv_sha
assert_eq "snapshot has thing as dir" "040000" "$(git ls-tree "$sha_dir" -- thing | awk '{print $1}')"
assert_eq "snapshot has inner file" "inside dir" "$(git show "$sha_dir:thing/inner.txt")"
echo

# === Test 64: restore single file from subdirectory with relative path ===
echo -e "${BOLD}Test 64: restore from subdirectory with relative path${RESET}"
git add -A && git commit -q -m "checkpoint 19"
mkdir -p relpath-sub
echo "root content" > relpath-root.txt
echo "sub content" > relpath-sub/child.txt
git add -A && git commit -q -m "add relpath files"
echo "root modified" > relpath-root.txt
echo "sub modified" > relpath-sub/child.txt
"$SNAPSHOT" -m "relpath snap" >/dev/null
echo "root destroyed" > relpath-root.txt
echo "sub destroyed" > relpath-sub/child.txt
cd relpath-sub
"$SNAPSHOT" restore 0 child.txt
assert_eq "child restored via relative path" "sub modified" "$(cat child.txt)"
"$SNAPSHOT" restore 0 ../relpath-root.txt
assert_eq "root restored via ../ path" "root modified" "$(cat ../relpath-root.txt)"
cd "$dir"
echo

# === Test 65: -- ends option parsing ===
echo -e "${BOLD}Test 65: -- ends option parsing${RESET}"
sha=$("$SNAPSHOT" -m "with separator" -i --)
sep_status=$?
assert_eq "-- exits zero" "0" "$sep_status"
sep_msg=$(git log -1 --format='%s' "$sha")
assert_eq "-- preserves message" "with separator" "$sep_msg"
sha2=$("$SNAPSHOT" --)
sep2_status=$?
assert_eq "bare -- exits zero" "0" "$sep2_status"
echo

# === Test 66: --help works outside a git repo ===
echo -e "${BOLD}Test 66: --help outside git repo${RESET}"
nogit_help_dir=$(mktemp -d)
nogit_help_output=$(cd "$nogit_help_dir" && "$SNAPSHOT" --help)
nogit_help_status=$?
assert_eq "--help outside repo exits zero" "0" "$nogit_help_status"
assert_contains "--help outside repo shows usage" "Usage: git snapshot" "$nogit_help_output"
nogit_h_output=$(cd "$nogit_help_dir" && "$SNAPSHOT" -h)
nogit_h_status=$?
assert_eq "-h outside repo exits zero" "0" "$nogit_h_status"
assert_contains "-h outside repo shows usage" "Usage: git snapshot" "$nogit_h_output"
rm -rf "$nogit_help_dir"
echo

# --- results ---
echo -e "${BOLD}Results: ${GREEN}$pass passed${RESET}, ${RED}$fail failed${RESET}"
rm -rf "$dir"
exit $fail
