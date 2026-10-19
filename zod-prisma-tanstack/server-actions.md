# Server actions and Prisma types

The Prisma side of the data layer: one actions file per domain that wraps the client, and the types derived from the same include objects. Read it when adding a domain, a query that the typed API cannot express, or a response type. The entry points that call these functions are in [entry-points.md](entry-points.md).

## Server actions (`<server>/actions/*.ts`)

"Server actions" here are plain async functions that wrap Prisma. They are not Next.js `"use server"` actions, and the directive never goes in these files.

One file per domain:

```typescript
// <server>/actions/article.ts
import { type Prisma } from "@prisma/client";
import { prisma } from "server/db";
import { type FindManyProps, type SearchManyProps } from "types/common";
import { type ArticleFull } from "types/article";

type FindManyArticlesProps = FindManyProps<Prisma.ArticleWhereInput>;
```

| Export | Purpose |
|--------|---------|
| `IncludeXRelations` | `Prisma.XInclude` object naming the related data to load |
| `findOneX` | `findFirst` with the include |
| `findManyX` | `findMany` with `take` and `skip` pagination |
| `searchManyX` | raw query for full-text, geo, or anything the typed API cannot express |
| `countX` | `.count()` wrapper |

The include object is exported so the type in the next section can mirror it; nested relations take their own `orderBy` and `include`:

```typescript
export const IncludeArticleRelations: Prisma.ArticleInclude = {
  author: true,
  tags: true,
  comments: { orderBy: { createdAt: "asc" }, include: { user: true } },
  category: { include: { parent: true } }
};

export async function findOneArticle({ searchQuery }: Pick<FindManyArticlesProps, "searchQuery">) {
  return prisma.article.findFirst({
    ...(searchQuery && { where: searchQuery }),
    include: IncludeArticleRelations
  });
}

export async function findManyArticles({ searchQuery, take = 10, page = 0 }: FindManyArticlesProps) {
  return prisma.article.findMany({
    where: searchQuery,
    take,
    skip: take * page,
    include: IncludeArticleRelations
  });
}

export async function countArticles({ searchQuery }: Pick<FindManyArticlesProps, "searchQuery">) {
  return prisma.article.count({ ...(searchQuery && { where: searchQuery }) });
}
```

### Raw search (MongoDB)

Use a raw aggregation when the typed API cannot express the query: full-text search, `$geoNear` (placed before `$facet`), or multi-stage pipelines. Paginate with `$facet: { data, total }`, convert Mongo `_id` to the `id` string Prisma's types expect, and treat the result as untyped until you have checked it:

```typescript
export async function searchManyArticles({ searchText, take = 10, page = 0, language }: SearchManyProps) {
  const rawData = await prisma.article.aggregateRaw({
    pipeline: [
      { $match: { $text: { $search: `"${searchText}"`, $language: language } } },
      {
        $facet: {
          data: [
            { $skip: take * page },
            { $limit: take },
            { $lookup: { from: "Tag", localField: "tagIDs", foreignField: "_id", as: "tags" } },
            { $sort: { updatedAt: -1 } },
            { $addFields: { id: { $toString: "$_id" }, updatedAt: { $toString: "$updatedAt" } } },
            { $project: { _id: 0 } }
          ],
          total: [{ $count: "totalItems" }]
        }
      }
    ]
  });

  const first = Array.isArray(rawData)
    ? (rawData as unknown as { data: ArticleFull[]; total: { totalItems: number }[] }[]).at(0)
    : undefined;
  const articles = Array.isArray(first?.data) ? first.data : [];
  const totalItems = first?.total.at(0)?.totalItems;
  return { articles, totalArticles: typeof totalItems === "number" ? totalItems : 0 };
}
```

On PostGIS, MySQL spatial, or SQLite R*Tree, write the equivalent SQL through `$queryRaw` rather than forcing a pipeline shape onto SQL.

### Rules

- Import `prisma` from the singleton, never `new PrismaClient()` in a domain file.
- Import Prisma types as `import { type Prisma } from "@prisma/client"`.
- For `orderBy`, `"asc"` literals and `Prisma.SortOrder.asc` type the same; pick one form per file. `Prisma.SortOrder` is a generated TS `enum`, and consuming a generated enum is fine even though app code avoids authoring them.
- Cast raw results as `unknown as T[]` and check the shape before using it.
- On MongoDB, add `id: { $toString: "$_id" }` and project `_id` away so the shape matches Prisma's types.

## Prisma type reuse (`<types>/*.ts`)

`Prisma.XGetPayload` infers the return type from the include shape, so keep it in step with `IncludeXRelations`:

```typescript
import { type Prisma } from "@prisma/client";

export type ArticleFull = Prisma.ArticleGetPayload<{
  include: { author: true; tags: true; comments: true };
}>;
```

Shared types live in `<types>/common.ts`. Drop `language` and `SimplifyTextProp` in a single-language project, and `GeoProps` when there are no geo features:

```typescript
export type DBCommonData = "id" | "createdAt" | "updatedAt";

// Flattens a localized-text field to a plain string for update flows.
// Substitute the project's own localized-text type for LocalizedText.
export type SimplifyTextProp<T> = {
  [K in keyof T]: T[K] extends LocalizedText | null ? string : T[K];
};

export interface PaginatedOptionsParams {
  page?: number;
  take?: number;
  allEntries?: boolean;
  private?: boolean;
  inactive?: boolean;
}

export interface FindManyProps<T = Record<string, string | boolean | null | number | object>>
  extends PaginatedOptionsParams {
  searchQuery: T;
}

export interface SearchManyProps extends PaginatedOptionsParams {
  searchText: string;
  language?: string;
  userId?: string;
}

export interface GeoProps {
  coordinates: [number, number] | null;
  distance: number;
}
```
