## Worktrees

Use your normal flow to start a worktree (`git worktree add`, or this project's own setup script). Run `./inventory-worktrees.sh` to see the state of every worktree: one table, its branch, age, dirty state, whether its work has landed, and why it exists.

Read that inventory, then add `--remove` only after you approve removing what it marks "would remove". Never remove a worktree or its branch by hand: no direct `git worktree remove` or `git branch -d`. Always go through `./inventory-worktrees.sh --remove`.
