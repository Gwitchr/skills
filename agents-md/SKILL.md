---
name: agents-md
description: Scaffold an `AGENTS.md` entry-point file at the root of a repo following the conventions in this skills repo (documentation map, agent rules, runtime baseline, layout, API surface, data models, commands, coding rules, safety buckets, quality gates, and risk areas). Use when the user says "write AGENTS.md", "create AGENTS.md", "scaffold agents instructions", "add an agents file", "bootstrap AI-agent docs", or when working in a new repo that lacks one.
---

# AGENTS.md scaffolder

`AGENTS.md` lives at the repo root and is the entry point an AI agent reads before doing anything in the repo. It is not a README: it is terse and opinionated, and it points at deeper docs. Keep it under ~300 lines.

> **Stack assumed.** This skill is framework-agnostic and works for any React + TypeScript codebase, but most of the canonical sections (atomic hierarchy, `classNames()`, server functions, Prisma + Mongo) assume the conventions in the rest of this skills repo (`components-hierarchy`, `zod-prisma-tanstack`, `auth-stack`). Drop or adapt sections when the host project's stack differs.

> **Notation.** `<Project>`, `docs/`, `prisma/`, `src/`, `<server>`, `<components>` are placeholders. Resolve to the host project's actual root and paths. Helper names (`classNames()`, `requireAuthenticatedUser`, etc.) are convention examples; rename them to match the host project's style, and include them in the generated `AGENTS.md` only if those helpers exist in the host project.

> **Precedence.** Project rules (existing `CLAUDE.md` / contributing guide / lint config / `tsconfig`) win over this skill. If `AGENTS.md` already exists, read it first and merge; do not overwrite blindly.

---

## When to invoke

- New repo with no `AGENTS.md`.
- Existing `AGENTS.md` that is missing sections from the canonical structure.
- User asks to "regenerate" or "align" their agents file.

If `AGENTS.md` already exists, prefer `Edit` over `Write` unless rewriting from scratch.

---

## Process

1. **Inventory the repo.** Before writing anything:
   - `package.json` (or `pyproject.toml`, `Cargo.toml`, etc.) → stack, scripts, package manager.
   - `prisma/schema.prisma` / Drizzle config / migration dirs → data layer.
   - `src/routes/`, `app/`, `pages/` → routing model + API surface.
   - `src/components/` subdirs → atomic hierarchy presence (atoms / molecules / organisms).
   - `.cursorrules`, `CLAUDE.md`, existing `docs/` → carry forward house rules.
   - `.env.example` → env shape (**never** read `.env` / `.env.*`, they're live secrets).
   - `tsconfig.json` → path aliases (`@/*`, `~/*`, `#/*`, etc.).
   - Hosting/CI: `vercel.json`, `netlify.toml`, `fly.toml`, `railway.json`, `nixpacks.toml`, `.github/workflows/`.

2. **Verify, do not guess.** Every entry in Runtime Baseline / Commands / Layout must be grep-confirmed in the repo. If a section does not apply (no AI provider, no Stripe, no Redis), drop it; do not invent rows.

3. **Write `AGENTS.md` at the repo root** using the canonical structure below.

4. **Update read order** in the Documentation Map to reflect what actually exists under `docs/`. Do not list `docs/` files that aren't there.

---

## Canonical structure (in order)

Use exactly these top-level H2 headings, in this order. Omit a section only if it does not apply to the repo; never reorder.

1. **Title + one-line pitch.** `# <Project>`, then one or two sentences on what it is and who it is for.
   - Optional: a "Two audiences: **X** and **Y**" line if there are distinct user classes.
2. **Documentation Map.** A table of `Domain | File | What it covers`, followed by a `> Read order:` blockquote.
3. **Agent Rules.** Two H3s:
   - `### Communication`: concision, no guessing, the `[Unverified]` / `[Speculation]` / `[Probability: x%]` labels, and "trust official docs first".
   - `### Plan Mode`: short ordered bullets, ending every plan with `Ask: ...` or `Ask: none`.
4. **Runtime Baseline.** A table of `Layer | Stack`, one row per concern (Framework, UI, Language, Database, Auth, State, AI, Payments, Storage, Email, Cache, Hosting, Testing, Package manager, Observability). Drop rows that don't apply.
5. **Domain abstraction** *(optional, project-specific)*. Include it only when the project has a non-obvious core abstraction worth one screen of explanation (a workflow state machine, a content model with inheritance, an order/booking lifecycle). Otherwise omit it.
6. **Project Layout.** A fenced tree of `src/` (plus `prisma/`, `docs/`, etc. when relevant), with one-line `#` comments on non-obvious files. Do not dump every file; show the spine.
7. **API Surface.** A list of standalone API routes (auth catch-all, webhooks, polling), then a sentence on the dominant pattern (server functions, server actions, REST handlers). Name the most important server-function entry points.
8. **Key Data Models.** Point at the schema file, then give a one-line categorized list (e.g. `**Identity:** User, Account, Session`). Do not duplicate the schema.
9. **Commands.** A fenced bash block of every script in `package.json`, each with a 2-6-word comment. If a common command is missing (e.g. no `typecheck` script), call it out.
10. **Coding Rules.** Two paragraphs led by **Do:** and **Don't:**. Carry forward the conventions from the rest of this skills repo (path aliases, `classNames()` 3-class threshold, atomic hierarchy, type-guard predicates instead of `as`, type guards that check concrete properties rather than generic is-object predicates (`isRecord`, `isObject`), no `&&` in JSX, no `eslint-disable-next-line`, no comments inferable from code, no TS `enum` in app code, `const` object + literal-union types instead). Then a `### Documentation Hierarchy` subsection: explain code at the highest level that fits, `docs/` first, then module or file-level JSDoc, then function JSDoc, with inline comments the last resort for local surprises (a workaround with a reason, a deliberate deviation, an ordering constraint). Never restate what the code says; move an inline *why* comment up to the function or `docs/` when it fits there. Add project-specific subsections (AI, Sentry, i18n, payments) only for non-obvious patterns.
11. **Safety.** Three H3 buckets:
    - `### Allowed without prompt`: local read/search, single-file lint/format, targeted tests, `prisma generate`, git commit with hooks.
    - `### Ask first`: install/remove deps, delete files, full builds, `prisma db push` / `migrate` against non-local DBs, external service ops, force-push.
    - `### Never`: `git push` without explicit request; destructive git (`reset --hard`, `clean -fd`, `branch -D`, force-push to `main`); list files outside project; read `.env` / `.env.*` except `.env.example`; bypass hooks (`--no-verify`) or signing without explicit ask; hand-edit generated files.
12. **Quality Gates.** A one-line pipeline (`lint → typecheck → test → build`) and the PR title regex `^(feat|fix|refactor|docs|test|chore)(\(|:).*`
13. **Risk Areas (Plan First).** A comma-separated list of subsystems that demand a plan before edits (auth/session flows, payment/webhook handlers, schema changes, state machines, role/permission checks, env-variable usage, generated-file boundaries).

---

## Style rules

- **Tables over prose.** Use a table wherever a comparison is possible.
- **No marketing tone.** This file is for agents, not users.
- **No hypotheticals.** Don't document features that "might" exist.
- **Carry forward, don't copy.** When scaffolding from one repo to another, adapt every claim to the actual stack; different stacks have different rules (Mongo's `relationMode = "prisma"` does not apply to Postgres; TanStack Start server functions do not exist in Next.js).
- **Name generated files.** Always list them under Coding Rules / Safety / Risk Areas (e.g. `routeTree.gen.ts`, `src/generated/prisma/**`, lockfiles).
- **Emojis minimal.** Title may include a single decorative emoji; body should avoid them. AGENTS.md is read by tools more often than humans.
- **Cap at ~300 lines.** If a section needs more, push detail into `docs/<DOMAIN>.md` and link it from the Documentation Map.

---

## Cross-skill alignment

When the host project also uses other skills in this repo, the generated `AGENTS.md` should align, not duplicate, their rules:

| Generated `AGENTS.md` says | Detail lives in |
|----------------------------|-----------------|
| "Atomic hierarchy, `classNames()` 3-class threshold, no TS `enum`, React 19 ref-as-prop, no manual memoization under the React Compiler" | `components-hierarchy` |
| "Data flows Component → Hook → Query Options → Fetcher → Route → Server Action → Prisma. Standalone `*Options` functions + `xKeys` hierarchy. Zod-validated input on every server entry point." | `zod-prisma-tanstack` |
| "Better Auth + `requireAuthenticatedUser` for mutating server fns; magic-link tokens hashed at rest; IAM-fallback contract for AWS clients." | `auth-stack` |
| "Mongo `relationMode = 'prisma'`, every FK gets explicit `@@index`, `@db.ObjectId` decorator everywhere." | `auth-stack/prisma-mongo.md` |
| "Server-proxied uploads only, content-addressed keys, create-row-first ordering." | `image-storage` |
| "Tiptap v3 + markdown for long-form content; seed-as-source-of-truth for i18n." | `content-authoring` / `content-stack` |
| "Eight flat top-level domain docs in `docs/`, `DESIGN.md` follows the google-labs-code/design.md spec." | `docs-vault` |

If the host project does not use one of these skills, drop the relevant rule from `AGENTS.md`; don't paste it speculatively.

---

## Reference template

A fillable skeleton is at [`template/AGENTS.template.md`](template/AGENTS.template.md) in this skill. Copy it, strike sections that don't apply, and fill the rest from your repo inventory.

---

## Anti-patterns

- ❌ **Writing a tutorial.** The file should not explain how TanStack Router or Prisma works; it should say "TanStack Start (file routes)" and move on. Agents have docs; this file is the project-specific overlay.
- ❌ **Pasting `CLAUDE.md` content verbatim.** `CLAUDE.md` is for Claude Code's harness (auto-loaded on session start); `AGENTS.md` is the project-level entry point any agent can read. Cross-reference, don't duplicate.
- ❌ **Listing every file.** Show the spine of `src/` only. If a reader needs the full tree, they can `ls`.
- ❌ **Inventing safety rules.** The "Never" list is the one that prevents damage: keep it tight and accurate, and never soften it.
- ❌ **Copying recommendations that conflict with the host project's other tooling.** If the project uses Bun, don't write `pnpm`. If it uses Drizzle, don't say "Prisma client singleton."
- ❌ **Frontmatter on `AGENTS.md`.** The generated file is read by agents and humans alike; frontmatter only confuses GitHub's renderer. (This skill's own SKILL.md needs frontmatter; the produced `AGENTS.md` does not.)
