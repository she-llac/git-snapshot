# git-snapshot

Zero-side-effect working tree snapshots for Git.

```sh
git snapshot                # save everything, index and worktree untouched
git snapshot list           # see what you've got
git snapshot show           # what's in the latest snapshot vs HEAD
git snapshot restore 0      # bring it all back
```

Creates a real commit from your full working tree (tracked, untracked, staged,
unstaged) without touching the index or working tree. Snapshots are stored in
the reflog and expire naturally with `git gc`.

## Usage

### Take a snapshot

```sh
git snapshot                        # default message: "snapshot"
git snapshot -m "before refactor"   # custom message
git snapshot -i                     # include ignored files
```

### List snapshots

```sh
git snapshot list
```

```
2dde69e snapshots@{0} before refactor  2026-02-20 11:15:34 +0100
53cb51e snapshots@{1} snapshot  2026-02-20 11:10:02 +0100
```

### Show what's in a snapshot

```sh
git snapshot show             # stat summary, latest snapshot vs HEAD
git snapshot show 2           # stat summary, snapshots@{2} vs HEAD
git snapshot show 0 -p        # full patch
git snapshot show 0 -- path   # limit to specific paths
```

### List files in a snapshot

```sh
git snapshot files      # latest
git snapshot files 3    # snapshots@{3}
```

### View a file from a snapshot

Snapshots are regular commits, so standard Git syntax works:

```sh
git show refs/snapshots@{0}:path/to/file
```

### Restore from a snapshot

```sh
git snapshot restore 0                    # restore everything
git snapshot restore 2 path/to/file.txt   # restore specific files
```

> **Note:** A full restore (`restore N` with no paths) replaces the worktree
> with the snapshot's tree exactly. Tracked files that don't exist in the
> snapshot will be removed from the worktree (untracked files are left alone).
> Your committed history is never affected.

### Drop a snapshot

```sh
git snapshot drop 3     # remove snapshots@{3}
```

### Use snapshot SHAs with any Git command

`git snapshot` prints the commit SHA. It's a real commit, so you can use it anywhere:

```sh
sha=$(git snapshot)
git diff $sha HEAD
git log -1 $sha
git cherry-pick $sha
git show $sha:some/file.txt
```

## Install

```sh
# symlink (updates when you git pull)
ln -s "$(pwd)/git-snapshot" /usr/local/bin/

# or copy
cp git-snapshot /usr/local/bin/
```

Git automatically picks up executables named `git-*` on your PATH as
subcommands.

## How it works

1. Copies the index to a temp file (real index is never touched)
2. Runs `git add -A` against the temp index to capture untracked files
3. `git write-tree` to create a tree object from the temp index
4. `git commit-tree` to wrap it in a commit (with HEAD as parent)
5. `git update-ref` to store the SHA in `refs/snapshots` with a reflog entry
6. Temp index is deleted; working tree and real index are unchanged

## Notes

- Snapshots respect `.gitignore` by default; pass `-i` to include ignored files
- Snapshots expire with `git gc` according to your reflog expiry settings
  (default: 90 days for unreachable entries)
- Only works inside a Git repository with at least one commit
- Snapshots are stored in `refs/snapshots`, which is shared across linked
  worktrees. Use the snapshot message or `git snapshot list` to identify
  which worktree a snapshot came from

## Testing

66 tests (201 assertions) covering snapshots, restore, edge cases, and error handling:

```sh
bash test.sh
```

## See also

- [temptree](https://github.com/she-llac/temptree) - disposable Git
  worktrees for AI agents and throwaway experiments

## License

MIT
