---
name: worktrees
description: Install a self-contained worktree workflow into a bare git clone (a git clone with no working tree of its own), so the repo needs no separate command-line tool, config file, or registry. Setup is a short deterministic sequence the agent runs directly: install two scripts into the repo root, seed a copy manifest, and extend the ignore file, cloning first for a brand-new project. The installed inventory-worktrees.sh script's first job is oversight, not cleanup: one table listing every worktree, its branch, age, state, whether its work has landed, and why it exists, dry run by default; removing the done ones is the second, opt-in action, taken only after the user passes --remove. Pull request lookups through gh (the GitHub command-line tool) are the default, and --no-gh turns them off. Use for "worktree status", "worktree inventory", "which worktrees can I delete", "set up worktrees for this repo", "clean up merged worktrees", and "onboard this repo to the worktree setup".
---

# worktrees

This skill installs two bash scripts, a copy manifest, and a managed ignore block into a bare clone that holds linked worktrees. After setup the repo runs its own inventory and cleanup with no help from this skill; creating a worktree still means a plain `git worktree add`, and this skill never changes that.

TRIGGER when: the user asks about the state of their worktrees, wants an inventory of what each one is for, which ones are safe to delete, how to set up or onboard a repo onto this workflow, or wants to clean up merged worktrees without deleting anything by hand.

> **Stack assumed.** Git 2.30 or newer, bash 3.2 or newer (macOS ships 3.2 by default, Linux usually ships bash 5, and both scripts run the same on either), and `gh` (the GitHub command-line tool) as an optional dependency for pull request lookups. Without `gh`, or with `--no-gh`, `inventory-worktrees.sh` only checks whether a branch merged into the default branch; the squash-merge check below is skipped.

> **Notation.** `<root>` is the bare clone root: the top-level directory of a bare git clone, where linked worktrees live as sibling directories once setup finishes.

> **Precedence.** Project conventions in `AGENTS.md` or `CLAUDE.md` win. If a project already documents its own worktree workflow, follow that instead of the defaults below.

## Setting up a repo

No installer script exists. The agent performs these steps directly, each one idempotent, so running them again on an already-set-up repo changes nothing:

1. Verify the target: run `git worktree list` in `<root>` and confirm it shows the bare record plus at least one linked worktree.
2. Copy this skill's `assets/warm-worktrees.sh` and `assets/inventory-worktrees.sh` into `<root>` and set both to `chmod 755`. When a file of that name already exists there and differs from the copy this skill ships, show the user a diff summary and ask before replacing it. Never overwrite silently.
3. Seed `<root>/.worktree-copy` from `assets/worktree-copy.template` when `<root>` has no such file yet. Never edit an existing `.worktree-copy` without asking first: treat it as append-only, and never rewrite a line the user wrote by hand.
4. Append the block below to `<root>/info/exclude` (a git-ignore file that lives inside the repo's internals and is shared by every worktree, so it is never committed) when its markers are not already present. Never duplicate the block; if the markers are already there, leave the file alone.

```
# >>> wt managed (worktrees skill) >>>
.env
.local
# <<< wt managed <<<
```

5. For a brand-new project, start here instead of step 1: run `git clone --bare <url> <dir>`, set `remote.origin.fetch` to `+refs/heads/*:refs/remotes/origin/*`, run `git fetch`, then `git remote set-head origin --auto`. Resolve the default branch from the now-set `refs/remotes/origin/HEAD` and add its worktree (`git worktree add <default> <default>`, run from `<dir>`). Continue into steps 2 through 4 against the new root.

## Day-to-day: inventory first, removal second

Change into the repo root and run the installed scripts; neither takes a flag for where the repo lives, because each runs from inside it.

| User asks | Run |
|---|---|
| What's the state of my worktrees? / what is each one for? / which ones can I delete? | `./inventory-worktrees.sh` |
| Clean up merged worktrees | `./inventory-worktrees.sh --remove` (after reading the inventory) |

```sh
cd <root>
./inventory-worktrees.sh          # inventory: a table, one row per worktree, nothing removed
./inventory-worktrees.sh --remove # removes the worktrees the table marked "would remove"
./inventory-worktrees.sh --no-gh  # skips the pull request lookup
```

`inventory-worktrees.sh`'s first job is oversight, not cleanup: it always prints the full table first, and only acts on it when told to. The table has seven columns: `NAME` (the default-branch worktree marked with a leading `*`), `BRANCH` (or `(detached)`), `AGE` as a relative time, `STATE` (`clean`, `dirty`, `warm` when the only changes are files the copy manifest re-creates, `locked`, or a comma-joined combination), `DONE` (`merged into origin/<default>`, `pr #N merged`, `open pr #N`, or `-`), `VERDICT` (`would remove`, or `kept: <reason>` naming what is blocking it), and `REASON`: why the worktree exists, derived fresh on every run and never stored, taken from the title of its pull request when it has one (even when the branch landed through a plain merge rather than that pull request), or otherwise the subject of its last commit, cut to 40 characters with a trailing `...` when longer. A summary line follows: `would remove: 2  kept: 3`, then, only when a worktree qualifies, `re-run with --remove to remove 2 worktrees.`

A worktree counts as done, and gets a `would remove` verdict, when its branch is merged into the default branch, or when a merged pull request's head commit (its branch's last commit) equals the worktree's current commit. The second check catches a squash merge (GitHub combining every commit on a branch into one new commit on the default branch), where the worktree's own commit never becomes an ancestor of the default branch even though the change shipped. Removal is always blocked, regardless of the done check, when the worktree is the one checked out to the default branch, when it holds real uncommitted work (not only files the copy manifest re-creates), or when it is not yet done by either check above, which covers a branch nothing has pushed or merged.

With `--remove`, each removal deletes the worktree, then tries to delete its branch with `git branch -d`. When git refuses because the branch's history is not fully merged (the case a squash merge leaves behind), the script prints the exact `git branch -D <branch>` command instead of forcing the deletion itself, so removing an unusual branch stays a decision the user makes by hand.

## Discernment: the agent proposes, the script decides

The agent's job is to run the inventory, present it to the user verbatim, and run `--remove` only after the user approves removing what it lists. The script's job is everything mechanical: classifying worktrees, checking pull requests, and removing the approved ones. Never run `git worktree remove` or `git branch -d` by hand instead of `inventory-worktrees.sh --remove`; doing so skips the same checks the inventory already showed. The one exception is a `git branch -D` command the script itself prints when it declines to force a branch deletion; that command is the script asking the user to make the call, so run it only after the user says to.

## Working across more than one project

Each script lives inside the repo it was installed into, not in a central place, so no registry exists to consult. Change into each repo's root in turn and run its own copy:

```sh
cd ~/dev/app.git
./inventory-worktrees.sh

cd ~/dev/api.git
./inventory-worktrees.sh
```
