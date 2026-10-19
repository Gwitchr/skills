# Server entry points and REST transport

The boundary between client and server: the API route or server function that authenticates, validates, delegates, and responds, plus the two REST-only pieces that reach it from the client, the typed fetchers and the `API_ENDPOINTS` constants. Read it when adding an endpoint or a server function, or wiring a project's transport. The server actions the entry points delegate to are in [server-actions.md](server-actions.md).

## Server entry points (API routes and server functions)

The entry point is the boundary between client and server. Whatever the framework, it does four things in order: authenticate when the route is private (read the session, else respond 401), validate the input with Zod, delegate to a server action in `<server>/actions/*`, and return a consistent shape (`{ articles, totalArticles }` for lists, `{ article }` for a single item).

### Flavor A, Next.js App Router (`<app>/api/**/route.ts`)

```typescript
import { NextRequest, NextResponse } from "next/server";
import { PostArticleParamsSchema } from "schemas/article";
import { findManyArticles, createArticle } from "<server>/actions/article";
import { auth } from "<server>/auth";

export async function POST(req: NextRequest) {
  const session = await auth();
  if (!session) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const { article } = PostArticleParamsSchema.parse(await req.json());
  const newArticle = await createArticle(article, session.userId);
  return NextResponse.json({ article: newArticle });
}

export async function GET(req: NextRequest) {
  const url = new URL(req.url);
  const page = Number(url.searchParams.get("page") ?? 0);
  const take = Number(url.searchParams.get("take") ?? 10);
  const articles = await findManyArticles({ searchQuery: {}, page, take });
  return NextResponse.json({ articles, totalArticles: articles.length });
}
```

### Flavor B, TanStack Start API route

`createAPIFileRoute("/api/articles")({ GET, POST })` from `@tanstack/react-start/api` takes the same two handler bodies as flavor A, with `json(...)` from `@tanstack/react-start` in place of `NextResponse.json` and `getSession(request)` for the auth check. Use it when the project needs a public REST surface for third-party or mobile clients.

### Flavor C, TanStack Start server function (`createServerFn`)

The RPC path replaces the fetcher and the route with a typed function; the query's `queryFn` calls it directly and TanStack Start handles the transport. Prefer it for new TanStack Start projects unless a public REST surface is required.

```typescript
// <server>/functions/article.ts
import { createServerFn } from "@tanstack/react-start";
import { PostArticleParamsSchema } from "schemas/article";
import { findManyArticles, createArticle } from "<server>/actions/article";
import { authMiddleware } from "<server>/auth";
import { z } from "zod";

export const fetchArticlesFn = createServerFn({ method: "GET" })
  .validator(z.object({ page: z.number().default(0), take: z.number().default(10) }).parse)
  .handler(async ({ data }) => {
    const articles = await findManyArticles({ searchQuery: {}, ...data });
    return { articles, totalArticles: articles.length };
  });

export const createArticleFn = createServerFn({ method: "POST" })
  .middleware([authMiddleware])
  .validator(PostArticleParamsSchema.parse)
  .handler(async ({ data, context }) => {
    const newArticle = await createArticle(data.article, context.session.userId);
    return { article: newArticle };
  });
```

```typescript
// <queries>/article.ts, TanStack Start variant
export function articleListOptions(params: PaginatedOptionsParams) {
  return queryOptions({
    queryKey: articleKeys.list(params),
    queryFn: () => fetchArticlesFn({ data: params }),
    placeholderData: keepPreviousData
  });
}
```

### Flavor D, Next.js Pages Router (`<pages>/api/*.ts`)

Pages Router is in maintenance mode; use this flavor only in a project that has not migrated. Route each method through the project's typed handler or method dispatcher (a `next-connect`-style router) rather than branching on `req.method` by hand, mark private methods there, and keep the same body: parse with Zod, call the server action, respond with the standard shape.

### Rules

- Validate every input with Zod: `.parse(...)` in a route handler, `.validator(schema.parse)` on a server function.
- When a hand-written check is unavoidable (raw driver results, `Json` columns), test concrete properties with `"x" in value` plus `typeof` per field, at least two when the shape has two or more. A generic is-object predicate (`isRecord`, `isObject`) proves nothing about the shape and is banned.
- Check the session at the top of the handler, in the dispatcher gate, or in server-function middleware.
- Call server actions only; no Prisma in a route file or a server function body.
- Return the consistent shapes above.

## Fetchers (`<utils>/fetcher.ts`), REST flow only

Skip this section when the project uses TanStack Start server functions only; the typed RPC call replaces it. For the REST flow, three typed fetchers wrap one `fetchWrapper` that throws on a non-2xx status and parses JSON. That wrapper is the single place for status handling, auth headers, and error normalization.

| Fetcher | Method | Params |
|---------|--------|--------|
| `getModelFetcher<Res>` | GET | `url`, `errorString`, `queryParams?`, `signal?` |
| `postModelFetcher<Res, Params>` | POST | `url`, `errorString`, `params` |
| `putModelFetcher<Res, Params>` | PUT | `url`, `errorString`, `params` |

### Rules

- Never call raw `fetch()` in a component or hook.
- `getModelFetcher` serializes `queryParams` to `URLSearchParams`, arrays included.
- `errorString` prefixes thrown messages (`"Articles: 500 Internal Server Error"`); pass the resource name. TanStack Query catches the throw and exposes it as `isError` and `error`.
- Pass the `signal` TanStack hands to `queryFn` through to `fetch`, so an unmount or key change aborts the request.

## API endpoints (`<constants>/apiEndpoints.ts`), REST flow only

One nested `API_ENDPOINTS` object with a function per endpoint, and no URL string anywhere else:

```typescript
export const API_ENDPOINTS = {
  ARTICLES: () => "/api/articles",
  ARTICLE: {
    SINGLE: ({ articleId }: { articleId?: string | null }) => `/api/articles/${articleId}`
  },
  AUTHOR: {
    SINGLE: ({ authorId }: { authorId?: string | null }) => `/api/authors/${authorId}`,
    ARTICLES: ({ authorId }: { authorId?: string | null }) => `/api/authors/${authorId}/articles`
  }
} as const;
```

Collection endpoints are functions (`ARTICLES()`) so a parameter can be added later without changing call sites. Single-resource endpoints accept a nullable id to match `enabled: !!id` in the query; a null id produces `/api/articles/null`, which never fetches because the query is disabled. Guard the template when that string bothers you.
