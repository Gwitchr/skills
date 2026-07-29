# worktrees

This skill installs a self-contained worktree (a linked working directory that shares one repository's history) inventory and cleanup workflow into a bare git clone (a git clone with no working tree of its own). Once installed, the repo needs nothing else from this skill: two scripts sit in its root and run from there, with no config file, no registry, and no command-line tool to keep on your `PATH` (the list of directories your shell searches for commands).

## What gets installed

Setup puts four things at the bare clone root, `<root>`:

- `warm-worktrees.sh`, copied in from this skill's `assets/`, `chmod 755`.
- `inventory-worktrees.sh`, copied in the same way.
- `.worktree-copy`, seeded from `assets/worktree-copy.template` if `<root>` has none yet.
- A managed block appended to `<root>/info/exclude` (git's own shared ignore file for every worktree in the clone), if its markers are not already there.

Setup never overwrites a script that already exists and differs without asking first, and never edits an existing `.worktree-copy` without asking. For a brand-new project, cloning comes first: `git clone --bare <url> <dir>`, set `remote.origin.fetch` to `+refs/heads/*:refs/remotes/origin/*`, `git fetch`, `git remote set-head origin --auto`, then add the default-branch worktree before installing the rest.

## Requirements

- Git 2.30 or newer.
- Bash 3.2 or newer. macOS ships 3.2 by default and Linux usually ships bash 5; both scripts run the same on either.
- `gh` (the GitHub command-line tool), optional. Without it, or with `--no-gh`, `inventory-worktrees.sh` only checks whether a branch merged into the default branch; it skips the squash-merge check described below.

## warm-worktrees.sh

Copies the paths listed in `.worktree-copy` into every linked worktree, or into specific ones named on the command line:

```
Usage: warm-worktrees.sh [--skip WORKTREE]... [--rebase] [WORKTREE...]
```

- With no arguments, it warms every linked worktree.
- Name one or more worktrees (by directory name or absolute path) to warm only those.
- `--skip WORKTREE` excludes a worktree; repeat it for more than one.
- `--rebase` rebases each selected worktree's branch onto the detected default branch after copying, skipping a worktree already on that branch or in detached HEAD (no branch checked out). A conflict aborts that worktree's rebase; the script moves to the next one and exits non-zero if any rebase failed.

## inventory-worktrees.sh

Run it from `<root>`; it takes no flag for where the repo lives. Its first job is oversight: it always prints the full inventory before it removes anything, and only removes worktrees when told to.

```sh
cd <root>
./inventory-worktrees.sh          # inventory: a table, one row per worktree, nothing removed
./inventory-worktrees.sh --remove # removes the worktrees the table marked "would remove"
./inventory-worktrees.sh --no-gh  # skips the pull request lookup
```

The table carries seven columns: `NAME`, `BRANCH`, `AGE`, `STATE` (dirty state), `DONE` (how the work landed, if it did), `VERDICT` (`would remove`, or `kept: <reason>` naming what is blocking it), and `REASON`. `REASON` says why the worktree exists: the title of its pull request when it has one, even when the branch actually landed through a plain merge rather than that pull request, or otherwise the subject of its last commit, cut to 40 characters with a trailing `...` when longer. Nothing here is stored; every column is computed fresh on each run.

A worktree counts as done when its branch is merged into the default branch, or when a merged pull request's head commit (its branch's last commit) equals the worktree's current commit. The second check catches a squash merge (GitHub combining every commit on a branch into one new commit on the default branch), where the worktree's own commit never becomes an ancestor of the default branch even though the change shipped. Removal is always blocked for the worktree checked out to the default branch, for one with real uncommitted work (not only files `.worktree-copy` re-creates), and for one that is not yet done by either check, which covers a branch nothing has pushed or merged.

With `--remove`, each removal also tries to delete the worktree's branch with `git branch -d`. When git refuses because the branch's history is not fully merged (what a squash merge leaves behind), the script prints the exact `git branch -D <branch>` command instead of forcing the deletion itself, so removing an unusual branch stays your call.

## Copy manifest

`.worktree-copy` lives at `<root>`: one path per line, relative to that root. A `#` starts a comment; blank lines are skipped. An optional second field sets the copy mode:

- `copy` (the default when the field is absent): always overwrite the destination.
- `copy-if-missing`: copy only if the destination does not already exist, so a worktree's local edits survive future warms.
- `link`: symlink the destination to the source instead of copying, so every worktree shares one file.

`assets/worktree-copy.template` lists the paths setup commonly offers (`.env.local`, `.envrc`, `.npmrc`, `.tool-versions`, `.mcp.json`, `.claude`, `.agents`, `.cursor`, `.kiro`, `AGENTS.local.md`) as commented examples, with `.env` and `.local` enabled by default since those are the two files most projects need copied into every worktree.

## AGENTS.md snippet

Paste `assets/AGENTS-snippet.md` into a project's `AGENTS.md` so an agent working there knows to run `./inventory-worktrees.sh` instead of removing a worktree by hand.

## Safety rules

Every destructive action is dry run by default: `inventory-worktrees.sh` prints its inventory and removes nothing until you pass `--remove`. Read the inventory before approving it. Plain `git worktree remove` still works, since git has no notion of this skill, but running it by hand skips the same checks `inventory-worktrees.sh` runs before removing anything, so it is never the right way to clean up a finished worktree.
