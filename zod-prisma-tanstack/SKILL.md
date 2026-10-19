---
name: zod-prisma-tanstack
description: Full-stack data-layer conventions for projects that use Prisma + Zod + TanStack Query, server actions, schema validation, query factories, hooks, fetchers, API routes, and TanStack Start Server Functions. Framework-agnostic; works with Next.js (App or Pages Router), TanStack Start (REST or RPC), Remix, Hono, Express. Use when creating domain features, adding endpoints, modifying the Prisma schema, writing hooks/queries, or reviewing data-layer code, or when bootstrapping these conventions in a project that does not yet follow them.
---

# Prisma + Zod + TanStack Query stack

Use this skill when writing, reviewing, or changing the data layer of a TypeScript app built on Prisma, Zod, and TanStack Query: server-side data access, schema validation, query options, hooks, and the server entry points that join them.

TRIGGER when: creating a domain feature, adding an API endpoint or server function, writing hooks or queries, changing the Prisma schema, adding Zod validation, reviewing data-layer code, or the user asks to "set up the data layer" or "wire Prisma + Zod + React Query".

> **Stack assumed.** Prisma v5 or newer on any supported database; the raw-aggregation example in [server-actions.md](server-actions.md) is MongoDB-only, so substitute `$queryRaw` with a full-text index or PostGIS on SQL. Zod v4, with v3 named where the API differs; pin one version, mixing them is unsupported. TanStack Query v5, since the conventions rely on `queryOptions()`, `infiniteQueryOptions()`, `useSuspenseQuery`, and the v5 cache-key model. TypeScript with `strict` and `noUncheckedIndexedAccess`. A framework with a typed server entry point: [entry-points.md](entry-points.md) shows Next.js App Router, TanStack Start (API routes and server functions), and Next.js Pages Router, and the same shape fits Remix, Hono, and Express. A path alias (`tsconfig` `paths` plus the bundler equivalent) so imports are root-relative. Install a missing piece first, or skip the section that needs it.

> **Notation.** `<server>/actions/`, `<types>/`, `<schemas>/`, `<queries>/`, `<hooks>/`, `<utils>/`, and `<constants>/` are placeholders. Resolve them to the project's layout (`src/server`, `app/lib`, `~/server`, `@/lib`). The shape of each layer is the rule; the paths are not.

> **Precedence.** The project's own rules win: ESLint, Biome, or Prettier configs, `tsconfig`, `CLAUDE.md` or `AGENTS.md`, contributing guides, and framework conventions. Note a deviation in the PR description when it helps the reviewer.

> **Related skills.** `smart-tanstack-query` owns what a mutation does to the cache (which keys to invalidate, optimistic updates, cross-domain effects); this skill only states the one default. `components-hierarchy` owns the `<Suspense>` boundaries that `useSuspenseQuery` relies on.

## Layers at a glance

Read a topic file only when the task touches that layer; this file holds the flow, the setup, the checklist, and the review list.

| Layer | Holds | Topic |
|---|---|---|
| Server actions | `<server>/actions/*.ts`: include objects, `findOne`, `findMany`, `count`, raw search | [server-actions.md](server-actions.md) |
| Prisma types | `<types>/*.ts`: `Prisma.XGetPayload`, shared pagination and search types | [server-actions.md](server-actions.md) |
| Zod schemas | `<schemas>/*.ts`: base, post, and update schemas bound with `satisfies` | [schemas.md](schemas.md) |
| Query options | `<queries>/*.ts`: `xKeys` hierarchy, `*Options` functions, cache policy, suspense | [queries-and-hooks.md](queries-and-hooks.md) |
| Hooks | `<hooks>/useX.ts`: options bag, spread and `select`, mutations | [queries-and-hooks.md](queries-and-hooks.md) |
| Entry points | API routes and `createServerFn`: authenticate, validate, delegate, respond | [entry-points.md](entry-points.md) |
| REST transport | `<utils>/fetcher.ts` and `<constants>/apiEndpoints.ts` | [entry-points.md](entry-points.md) |

## Data flow

REST flow, any framework:

```
Component (UI)
  → Hook                       (<hooks>/useX.ts)
    → Query options + keys     (<queries>/x.ts, `xKeys` + standalone `*Options` functions)
      → Fetcher                (<utils>/fetcher.ts, typed wrappers over `fetch`)
        → API route            (Next.js App/Pages Router, TanStack Start `createAPIFileRoute`, Hono, ...)
          → Server action      (<server>/actions/x.ts, plain async Prisma wrappers)
            → Prisma → database
```

RPC flow, TanStack Start server functions or Next.js `"use server"` actions used as RPC:

```
Component (UI)
  → Hook                       (<hooks>/useX.ts)
    → Query options + keys     (<queries>/x.ts)
      → Server function        (`createServerFn` / `"use server"`, replaces fetcher + route)
        → Server action        (<server>/actions/x.ts)
          → Prisma → database
```

Every domain feature follows one of the two chains with no layer skipped: no Prisma call inside a route handler or server function, and no raw `fetch` inside a component.

## Bootstrap

Skip this section when the project already follows the layering. Otherwise:

1. Pick the locations and record them in `CLAUDE.md`, `AGENTS.md`, or the contributing guide: `<server>/actions/` (Prisma access, one file per domain), `<server>/db.ts` (the singleton client), `<server>/functions/` (TanStack Start RPC only), `<types>/`, `<schemas>/` (one file per domain plus `common.ts`), `<queries>/`, `<hooks>/`, and for the REST flow `<utils>/fetcher.ts` and `<constants>/apiEndpoints.ts`.
2. Add the singleton Prisma client in `<server>/db.ts` with the Prisma docs' pattern (cached on `globalThis` in development, fresh in production). Never construct `new PrismaClient()` elsewhere.
3. Add `<utils>/fetcher.ts` with the three typed fetchers from [entry-points.md](entry-points.md) (REST flow only).
4. Add `<constants>/apiEndpoints.ts` with one nested `API_ENDPOINTS` object from [entry-points.md](entry-points.md) (REST flow only).
5. Add `<types>/common.ts` with the shared pagination and search interfaces from [server-actions.md](server-actions.md).
6. Add `<schemas>/common.ts` with the shared Zod primitives the project needs, from [schemas.md](schemas.md).
7. Build the first domain end to end with the checklist below and treat it as the reference for the rest.

## New domain checklist

When adding a domain such as `Widget`:

1. Add the model to `prisma/schema.prisma` and run the project's migration or push command.
2. Add `<types>/widget.ts` with `Prisma.WidgetGetPayload<...>` and the response types.
3. Add `<server>/actions/widget.ts` with `IncludeWidgetRelations`, `findOneWidget`, `findManyWidgets`, `countWidgets`, and `searchManyWidgets` when full-text or geo search is needed.
4. Add `<schemas>/widget.ts` with `WidgetSchema`, `PostWidgetParamsSchema`, and `WidgetUpdateParamsSchema` (or `WidgetSchema.partial()`).
5. Add the endpoints to `<constants>/apiEndpoints.ts` (REST flow).
6. Add the entry point in the project's flavor: `<app>/api/widgets/route.ts`, `<routes>/api/widgets.ts`, `<server>/functions/widget.ts` (skip step 5), or `<pages>/api/widgets/index.ts`.
7. Add `<queries>/widget.ts` with `widgetKeys` and the `*Options` functions.
8. Add `<hooks>/useWidgets.ts` with the queries and mutations.
9. Export the hook from `<hooks>/index.ts` when the project uses barrels.

## Anti-patterns

- ❌ Raw `fetch()` in a component or hook; use the typed fetchers.
- ❌ A URL string outside `API_ENDPOINTS`.
- ❌ Server state copied into Redux or Zustand.
- ❌ A hand-written TS type that `z.infer<>` or `Prisma.GetPayload<>` already produces.
- ❌ Prisma called from a route file or a server-function handler; delegate to `<server>/actions/*`.
- ❌ `"use server"` on a data-layer function; those are plain async functions.
- ❌ A server function without `.validator(schema.parse)`, or a route that reads `req.body` without `.parse(...)`.
- ❌ A query key not built from the domain's `xKeys.all` prefix.
- ❌ Queries bundled into one `xQueries` object instead of `xKeys` plus standalone `*Options` functions.
- ❌ `select` or `throwOnError` inside an `*Options` function; those belong at the call site.
- ❌ A query on a possibly-null ID without `enabled`.
- ❌ A mutation that succeeds without invalidating.
- ❌ `new PrismaClient()` outside the singleton; it leaks connections under HMR and in tests.
- ❌ User input spread into `where` or `data` (`prisma.x.findMany({ where: req.query })`); parse and project explicitly.
