# skills

A set of opinionated, publication-grade Claude Code skills for building React + TypeScript web apps. Each skill is a self-contained set of `*.md` files that an AI agent (Claude Code, Cursor, Aider, etc.) can read to understand a convention, apply it, and resist drift over time.

The skills below are **interlocking but independent**, pick the ones that match the project's stack and ignore the rest. Where one skill depends on another, the dependency is named explicitly in its frontmatter and Stack-assumed callout.

| Skill | What it covers |
|---|---|
| [`components-hierarchy`](components-hierarchy/SKILL.md) | React/TS/Tailwind UI conventions, atomic hierarchy, `classNames` utility, variant/size dictionaries, polymorphic `as` prop, composition slots, icon usage, React 19 patterns, Tailwind v3/v4 styling. Framework-agnostic (Vite SPA, Next.js, Remix, TanStack Start). |
| [`zod-prisma-tanstack`](zod-prisma-tanstack/SKILL.md) | Full-stack data layer, Prisma server actions, Zod schemas, TanStack Query v5 options-functions + cache-key hierarchy, typed fetchers, REST API routes (Next.js App/Pages Router, TanStack Start API routes) and RPC server functions (TanStack Start `createServerFn`). |
| [`auth-stack`](auth-stack/SKILL.md) | Better Auth + Prisma + MongoDB + AWS SES + S3/CloudFront. Magic-link auth with hashed tokens at rest, session/role narrowing, redirect sanitization, IAM-fallback contract for AWS clients, transactional vs marketing email split. |
| [`content-stack`](content-stack/SKILL.md) | Database-backed i18n on Prisma + MongoDB. `ContentPage`/`ContentString` schema, `useTranslation(pageSlug)` hook with fallback resolution, store-driven active locale, seed-as-source-of-truth + gated admin patch UI. Depends on `auth-stack`. |
| [`content-authoring`](content-authoring/SKILL.md) | Tiptap v3 + markdown content authoring on Prisma + MongoDB. Markdown vs editor-JSON vs MDX storage trade-offs, locale strategy, sanitization, image upload, AI-assisted authoring, real-time collab via Y.js + Hocuspocus. |
| [`image-storage`](image-storage/SKILL.md) | File-upload patterns on top of S3 + CloudFront, server-proxied data-URL uploads, MIME and size validation, filename sanitization, create-row-first ordering, AI-generated image flow. Builds on `auth-stack/storage-s3.md`. |
| [`docs-vault`](docs-vault/SKILL.md) | Build a `docs/` Obsidian vault that doubles as a GitHub-readable index. Eight flat top-level domain docs (PRODUCT / RUNTIME / ARCHITECTURE / DATA / AUTH / ENGINEERING / TESTING / DESIGN), bidirectional wikilinks, graph color groups, and a spec-compliant DESIGN.md derived from `tailwind.config.{ts,js}` or the v4 `@theme` block. |

## Conventions every skill shares

- **Mongo-first.** Where a database is needed, examples assume Prisma + MongoDB (`relationMode = "prisma"`). The data-layer rules (ObjectId decorators, explicit FK indexes) are stated once in `auth-stack/prisma-mongo.md` and referenced from the rest.
- **React 19 + TanStack Query v5.** The component skill assumes the React Compiler may or may not be enabled and gates its memoization guidance accordingly. The data skill uses `queryOptions()` + standalone options functions, not method-bag query factories.
- **Zod v4** is the default for runtime validation. Zod v3 guidance is mentioned where APIs diverge; otherwise it's treated as legacy.
- **TS `enum` is avoided** in app-authored code (Prisma-generated enums in `schema.prisma` are fine). The standard replacement is `const` object + literal-union type.
- **Standard callouts** at the top of every SKILL.md: **Stack assumed** (what the skill expects), **Notation** (how to read placeholder paths), **Precedence** (project rules win when they conflict).
- **No project leaks.** Identifiers, brand names, real domains, personal style policies, and internal helper names with no rename disclaimer are out. Every example uses neutral entities (`Article`, `Asset`, `Newsletter`, `Widget`, `User`) and `<placeholder>` paths.

## Using a skill

The skills are designed to be installed under `.agents/skills/<name>/` in a host project (Claude Code's skill discovery mechanism) and referenced from an `AGENTS.md` or `CLAUDE.md` entry point. They also work as plain reference documentation, clone this repo, read the relevant SKILL.md, apply.

When working in a project that uses one of these skills, an AI agent should:

1. Read the skill's `SKILL.md` (the entry point) first.
2. Read the topic files listed in the SKILL.md's reference table **only when** the task touches that topic.
3. Treat the host project's `CLAUDE.md` / `AGENTS.md` / ESLint / `tsconfig` as authoritative when they conflict with the skill.

## License

MIT, see [LICENSE](LICENSE).
