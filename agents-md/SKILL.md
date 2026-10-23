---
name: agents-md
description: Write, prune, or audit a repo's AGENTS.md so every line is something a coding agent would get wrong without it, such as the commands to run and where, scope and verification rules, boundaries (allowed, ask first, never), testing and git conventions, and the subsystems that need a plan first. Leaves out stack tables, directory trees, and anything the code or README already shows, wires CLAUDE.md through an @AGENTS.md import, and moves package-only rules into nested AGENTS.md files. Use when the user says "write AGENTS.md", "create, update, or clean up AGENTS.md", "add an agents file", "set up CLAUDE.md", or "rules for the agent", when a repo has no AGENTS.md, or when agents keep repeating the same mistake in a repo.
---

# agents-md

This skill writes or prunes the `AGENTS.md` at a repo's root, and any nested ones, so that every line is something a coding agent would get wrong without it. It also wires `CLAUDE.md` and other tool-specific files to the same source. It is for anyone setting up or cleaning up agent instructions in a repo.

TRIGGER when: a repo has no `AGENTS.md`; the user asks to write, update, align, or shorten one; the user asks to set up `CLAUDE.md`, `GEMINI.md`, or Copilot instructions; or agents keep making the same mistake in a repo and the fix is a standing rule.

> **Stack assumed.** Any repository, and any agent that reads `AGENTS.md`: Codex, Copilot, and Cursor natively, Gemini CLI with one setting, Claude Code through an import. The template's code rules use the React + TypeScript conventions of this repo's sibling skills; drop them when the host stack differs. Tool behavior below is as documented on 2026-10-22.

> **Notation.** `<Project>`, `<pm>`, `<check>`, `<generate>`, and the other angle-bracket names in the template are placeholders. Resolve each one from the host repo, and delete the line when the repo has no such thing; never invent a value.

> **Precedence.** An existing `AGENTS.md`, `CLAUDE.md`, or contributing guide wins. Read it first, merge into it, and never overwrite it wholesale. A user's instruction in chat overrides the file.

## What earns a line

Keep a line only if an agent that has read the code, the manifests, CI, and the README would get something wrong without it. Apply this test to every line, including lines the user already has.

Earns a line:

- The commands, with their flags and the directory they run from, and the one command that counts as "checks pass" (usually what CI runs).
- Commands that look right but are wrong here: bare `tsc` instead of the repo's typecheck script, a full production build, tests run from the wrong directory, tests that read a stale build.
- Scope, verification, and reporting rules for the agent.
- Conventions that differ from what an agent writes by default, and bans on what it reaches for (type assertions, lint-disable comments).
- Generated files and the command that regenerates each one.
- Dependency direction between packages or layers, when breaking it compiles but is wrong.
- Boundaries: what the agent may do without asking, what needs approval, and what it must never do.
- Subsystems that need a plan before any edit.

Does not earn a line:

- Stack tables, directory trees, API lists, and data-model lists. The agent reads `package.json`, the tree, and the schema itself, and copies go stale.
- A repository overview longer than one sentence.
- Rules a linter or formatter already enforces. Name the command instead.
- Language conventions any agent already follows, and framework tutorials.
- Anything the README already says.
- An instruction to read every doc before each task. Each session pays for it.

## Why this shape

- **Generated files cost more than they help.** An ETH Zurich study (Gloaguen et al., arXiv 2602.11988, v3 of 2026-09-29) ran four agent and model pairs on SWE-bench Lite and on 138 tasks from 12 repos that ship developer-written files. LLM-generated context files lowered resolution rates by 0.5 and 2 percent and raised cost by 20 and 23 percent. Developer-written files raised success by 2.4 percent on average, a result the authors report as not significant (p = 21 percent), and beat generated ones by 7 percent. Repository overviews did not help. The authors recommend files that hold only "specific additional instructions beyond what is already available in the codebase". This skill therefore drafts, cuts, and asks the owner to confirm every rule it inferred, instead of publishing what it generates.
- **Length.** Claude Code's memory docs target under 200 lines per file and ask, for each line, "Would removing this cause Claude to make mistakes?". Codex stops loading instruction files once their combined size reaches 32 KiB (`project_doc_max_bytes`).
- **Discovery.** Claude Code (v2.1.277 and later) reads `AGENTS.md` on its own only when no `CLAUDE.md` exists in the working directory or above it. Claude Code, Codex, and Gemini CLI all concatenate the files from the root down to the working directory and read the closest one last; the agents.md site describes the closest file as winning. Either way, a nested file should add to the root file, not contradict it.
- **Rules.** The template's working rules come from the root files of 28 open-source repos read on 2026-10-22, among them opencode, uv, ruff, biome, zed, deno, airflow, langchain, openai-agents-python, next.js, tldraw, astro, cloudflare workers-sdk, TanStack Router, bun, and prisma. Most rules appear in several of them. The rule on speculative edge cases is opencode's, word for word.

## Process

1. **Read what exists.** Root and nested `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.cursorrules`, `.cursor/rules/`, `.github/copilot-instructions.md`, `CONTRIBUTING.md`, the README, and the PR template. Never read `.env` or `.env.*`; use `.env.example`.
2. **Find the commands.** Read the package manager's scripts, `Makefile` or `justfile`, and the CI workflows; the command CI runs is the canonical check. Run the check and one targeted test when that is cheap, to confirm they work and from which directory. Label any command you could not run `[Unverified]` in your report to the owner, not in the file.
3. **Find the traps.** Lint and formatter configs (whatever they enforce stays out of the file), generated files (`*.gen.*`, `generated/`, codegen scripts, lockfiles), workspace packages (each package with its own rules gets a nested file), the default branch and commit style from `git log`, and the release-note mechanism (changesets, newsfragments).
4. **Ask the owner** for what the code cannot show: mistakes agents keep making here, subsystems that need a plan first, the commit and push policy, and the AI-attribution policy.
5. **Draft from the template**, then cut every line that fails the test above. Check the size with `wc -l AGENTS.md` (under 200) and `wc -c` across all `AGENTS.md` files (under 32 KiB).
6. **Confirm inferred rules.** List for the owner each rule you inferred rather than verified or were told, and keep only the ones they confirm.
7. **Wire the other tools** (next section).

## Canonical structure

Use these H2 headings in this order. Delete a section that has nothing in it; do not reorder.

1. `# <Project>` and one sentence on what the repo is.
2. `## Commands`: the fenced command block, then the commands not to run and what to run instead, then the cleanup rule.
3. `## Working rules`: scope, verification, reporting, and plans.
4. `## Boundaries`: three H3s, `Allowed without asking`, `Ask first`, and `Never`.
5. `## Code`: a **Do:** line and a **Don't:** line, a pointer to the skill per file type, and `### Comments and docs`.
6. `## Testing`.
7. `## Git`: default branch, branch names, commit and PR title format, attribution, release notes.
8. `## Plan first`: the subsystems that need an approved plan.
9. `## Architecture`, optional: dependency direction, and the core domain abstraction only when it is non-obvious (a lifecycle, a state machine, an inheritance rule).
10. `## Docs`, optional: one line per file in `docs/`, read when a task touches that domain.
11. `## This file`: the size cap and how rules get added.

A fillable skeleton is at [`template/AGENTS.template.md`](template/AGENTS.template.md).

## Monorepos and nested files

Keep repo-wide rules in the root file. Put rules that apply to one package in that package's own `AGENTS.md`, and never repeat a root rule there. Agents load every file from the root down to where they work, so the combined size counts against Codex's 32 KiB cap.

## Wiring other tools

- **Claude Code.** Create `CLAUDE.md` with `@AGENTS.md` as its only line (tldraw, n8n, supabase, mastra, and ruff do exactly this), and put any Claude-only instructions below the import. A symlink `CLAUDE.md -> AGENTS.md` also works (prisma, airflow). Never maintain two copies; they drift.
- **Gemini CLI.** Add `"AGENTS.md"` to `context.fileName` in `.gemini/settings.json`, or symlink `GEMINI.md -> AGENTS.md`.
- **Codex, Copilot, Cursor** read `AGENTS.md` without setup. Codex also honors an `AGENTS.override.md` next to it; do not create one unless asked.
- **Skills.** Keep one skills directory (`.agents/skills/`, where this repo's skills install) and point each tool at it with a symlink, instead of copying skills per tool.

## Aligning with sibling skills

When the host project uses another skill from this repo, `AGENTS.md` names the skill instead of restating its rules:

- `components-hierarchy` and `pedantic-react` for `*.tsx` files.
- `zod-prisma-tanstack` for the data layer, and `smart-tanstack-query` for mutations and cache updates.
- `auth-stack`, `image-storage`, `content-stack`, and `content-authoring` for their subsystems.
- `deslop` for maintainer-facing prose.
- `worktrees`: paste its `assets/AGENTS-snippet.md` as a section.

Drop a pointer when the project does not use that skill.

## Anti-patterns

- ❌ Publishing a generated file without the owner confirming the rules you inferred.
- ❌ Maps instead of traps: stack tables, directory trees, API and model lists, a paragraph-long overview.
- ❌ Restating lint or formatter rules instead of naming the command.
- ❌ A `CLAUDE.md` that duplicates `AGENTS.md` instead of importing it.
- ❌ Package-only rules in the root file, or root rules repeated in a nested file.
- ❌ `IMPORTANT` or `MUST` on many lines. Claude Code's docs advise emphasis on the one line agents keep skipping, since emphasis on every line makes none stand out.
- ❌ A "read these docs first" list that every session pays for.
- ❌ Commands copied from another repo (`pnpm` in a Bun repo, a `prisma` script in a Drizzle repo).
- ❌ Softening the **Never** list, or inventing entries for it.
- ❌ Frontmatter on the generated `AGENTS.md`. This skill's own `SKILL.md` needs frontmatter; the file it produces does not.
