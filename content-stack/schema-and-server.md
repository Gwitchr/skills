# Schema and server functions

Everything that exits MongoDB lives in `prisma/schema.prisma`; everything that crosses the wire goes through one of four `createServerFn` calls in `<server>/lib/i18n/` and `<server>/lib/admin/`. This file documents both layers and the contracts between them.

## Prisma models

Defined in `prisma/schema.prisma`. The example uses `en` as the mandatory base language; any single language can play that role.

```prisma
// ─── i18n primitives ───

type Languages {
  en   String       // base language — mandatory
  es   String?      // additional languages — optional, fall back to `en` at render time
  // Add more locale fields here. Every additional locale is `String?`.
}

enum StringRole {
  headline
  subheading
  title
  body
  label
  placeholder
  navigation
  action
  tooltip
  error
  empty_state
}

// ─── i18n: Content Pages ───

model ContentPage {
  id        String          @id @default(auto()) @map("_id") @db.ObjectId
  slug      String          @unique
  label     String
  strings   ContentString[]
  createdAt DateTime        @default(now())
  updatedAt DateTime        @updatedAt
}

model ContentString {
  id        String     @id @default(auto()) @map("_id") @db.ObjectId
  pageId    String     @db.ObjectId
  fallback  String
  role      StringRole
  section   String
  text      Languages
  createdAt DateTime   @default(now())
  updatedAt DateTime   @updatedAt

  page ContentPage @relation(fields: [pageId], references: [id], onDelete: Cascade)

  @@unique([pageId, fallback, role, section])
  @@index([pageId])
}
```

(`@db.ObjectId` decorators and `@@index([pageId])` are mandatory under `relationMode = "prisma"` — see the auth-stack skill's `prisma-mongo.md` for the canonical Mongo schema rules.)

### Why these shapes

- **`Languages` is a Mongo embedded type, not a separate collection.** Reads are a single document fetch — no `$lookup`, no second round-trip. The trade-off is that adding a new locale requires a Prisma type change (see [workflows.md](workflows.md)).
- **`fallback` is the lookup key, not a separate `key` column.** Keeps the seed file self-documenting (you read the base copy directly), at the cost of forcing a re-seed when copy is reworded. The trade is worth it for a small content surface; on a multi-thousand-string surface you'd want a separate `key`.
- **The composite unique `(pageId, fallback, role, section)`** is what makes the same base-language copy reusable across regions. Each row is "this exact base text, in this typographic role, in this section of this page."
- **`onDelete: Cascade`** on `ContentString.page` means deleting a `ContentPage` wipes its strings. The seed relies on this — it `deleteMany({})` on strings first, then on pages, but cascade would handle it either way.

### Related fields elsewhere

- `User.preferredLocale: String?` — defaults to the base language; persisted by `updateUserLocale` server fn. Declared on the `User` model in the auth-stack schema.
- Any "global default locale" read from a config table is fine but **not necessary** — `DEFAULT_LOCALE` in the type module (below) is the live default and is the simpler source of truth. Don't introduce a config-table read for a value that ships with the build.

---

## Type module

`<server>/lib/i18n/types.ts` is the single source of truth for client-visible types and the locale list.

```ts
export type StringRole =
  | "headline" | "subheading" | "title" | "body" | "label"
  | "placeholder" | "navigation" | "action" | "tooltip"
  | "error" | "empty_state";

export const SUPPORTED_LOCALES = ["en", "es"] as const;
export type SupportedLocale = (typeof SUPPORTED_LOCALES)[number];

export const DEFAULT_LOCALE: SupportedLocale = "en";

export function isSupportedLocale(value: unknown): value is SupportedLocale {
  return typeof value === "string" && SUPPORTED_LOCALES.includes(value as SupportedLocale);
}

export interface TranslateArgs {
  text: string;
  role: StringRole;
  section: string;
}

export interface ResolvedString {
  fallback: string;
  role: StringRole;
  section: string;
  // One field per supported locale — keep in sync with SUPPORTED_LOCALES and Prisma `Languages`.
  en: string;          // base language — always non-null
  es: string | null;   // additional languages — null if not yet translated
}
```

`StringRole` is duplicated here as a TS string union (independent of the Prisma generated enum) to avoid coupling client code to Prisma's runtime. **If you add a role, update both** — the Prisma enum AND this union, plus `VALID_STRING_ROLES` in `upsertContentString.ts`. Adding to only one place is the most common bug in this stack.

The `const`-object + literal-union pattern is the canonical replacement for TS `enum` — `enum` is rejected by TS 5.5+ `--erasableSyntaxOnly` and is unnecessary here since `StringRole` is just a list of strings.

---

## Server functions

All four are `createServerFn` from `@tanstack/react-start`. Validate input with Zod (preferred) or a hand-rolled `isRecord` predicate; pick one and stay consistent within the project.

### `getPageStrings` — public read

`<server>/lib/i18n/getPageStrings.ts`

```ts
import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { prisma } from "<server>/lib/prisma";
import type { ResolvedString } from "./types";

const inputSchema = z.object({
  pageSlug: z.string().trim().min(1)
});

export const getPageStrings = createServerFn({ method: "POST" })
  .validator(inputSchema.parse)
  .handler(async ({ data }): Promise<ResolvedString[]> => {
    const page = await prisma.contentPage.findUnique({
      where: { slug: data.pageSlug },
      include: { strings: true }
    });
    if (!page) return [];

    return page.strings.map((s) => ({
      fallback: s.fallback,
      role: s.role,
      section: s.section,
      en: s.text.en,
      es: s.text.es ?? null
    }));
  });
```

- **Method:** `POST` (TanStack Start's default for fns that take input — not idempotent in the HTTP sense, but the read is read-only).
- **Auth:** None. Anonymous users hit this on the landing page.
- **Returns:** `Array<ResolvedString>` — empty array if page not found (no throw).
- **Behavior:** Fetches `ContentPage` by slug with all `strings` relation, flattens `text: { en, es, … }` to top-level `{ en, es, … }`.

The flatten step is **load-bearing** — clients shouldn't see the nested `text` shape, and TanStack Query serialises the response across the network boundary. If you add a locale, mirror the new field both in the `ResolvedString` interface and in this `.map(...)` call.

### `updateUserLocale` — authenticated write

`<server>/lib/i18n/updateUserLocale.ts`

```ts
import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { prisma } from "<server>/lib/prisma";
import { requireAuthenticatedUser } from "<server>/lib/auth/require";
import { SUPPORTED_LOCALES } from "./types";

const inputSchema = z.object({
  locale: z.enum(SUPPORTED_LOCALES) // Zod 4 — accepts readonly tuples directly
});

export const updateUserLocale = createServerFn({ method: "POST" })
  .validator(inputSchema.parse)
  .handler(async ({ data }) => {
    const user = await requireAuthenticatedUser();
    await prisma.user.update({
      where: { id: user.id },
      data:  { preferredLocale: data.locale },
      select: { id: true }
    });
    return { locale: data.locale };
  });
```

- **Auth:** `requireAuthenticatedUser()` from the auth-stack skill.
- **Side effect:** writes `User.preferredLocale`.
- **Returns:** `{ locale }`.

This is the only path that persists locale to the DB. The `LocaleSelect` component does **not** call it — features that want the choice to outlive a refresh must wire it explicitly via `i18nMutations.updateUserLocale` (see [client-and-locale.md](client-and-locale.md)).

### `listContentPages` — admin read

`<server>/lib/admin/listContentPages.ts`

```ts
import { createServerFn } from "@tanstack/react-start";
import { prisma } from "<server>/lib/prisma";
import { requireAuthenticatedUser } from "<server>/lib/auth/require";
import { isAdmin } from "<server>/lib/auth/role";

export const listContentPages = createServerFn({ method: "GET" }).handler(async () => {
  const user = await requireAuthenticatedUser();
  if (!isAdmin(user.role)) throw new Error("Forbidden.");

  const pages = await prisma.contentPage.findMany({
    orderBy: { slug: "asc" },
    include: {
      strings: { orderBy: [{ section: "asc" }, { role: "asc" }] }
    }
  });

  return pages.map((page) => ({
    id: page.id,
    slug: page.slug,
    label: page.label,
    strings: page.strings.map((s) => ({
      id: s.id,
      fallback: s.fallback,
      role: s.role,
      section: s.section,
      en: s.text.en,
      es: s.text.es ?? null
    }))
  }));
});
```

- **Auth:** `requireAuthenticatedUser()` + admin role check; throws `Forbidden` otherwise.
- **Returns:** Pages ordered by `slug`, strings ordered by `(section, role)`, each string flattened.
- **Used by:** the admin route via `adminQueries.contentPages()`.

### `upsertContentString` — admin write

`<server>/lib/admin/upsertContentString.ts`

```ts
import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { prisma } from "<server>/lib/prisma";
import { requireAuthenticatedUser } from "<server>/lib/auth/require";
import { isAdmin } from "<server>/lib/auth/role";

// MUST mirror the Prisma `StringRole` enum exactly — see "Adding a new StringRole" in workflows.md.
const VALID_STRING_ROLES = [
  "headline", "subheading", "title", "body", "label",
  "placeholder", "navigation", "action", "tooltip", "error", "empty_state"
] as const;

const inputSchema = z.object({
  id:       z.string().optional(),
  pageId:   z.string(),
  fallback: z.string().trim().min(1),
  role:     z.enum(VALID_STRING_ROLES),
  section:  z.string().trim().min(1),
  en:       z.string(),
  es:       z.string().nullable()
});

export const upsertContentString = createServerFn({ method: "POST" })
  .validator(inputSchema.parse)
  .handler(async ({ data }) => {
    const user = await requireAuthenticatedUser();
    if (!isAdmin(user.role)) throw new Error("Forbidden.");

    const text = { en: data.en, es: data.es };

    if (data.id) {
      const result = await prisma.contentString.update({
        where:  { id: data.id },
        data:   { fallback: data.fallback, role: data.role, section: data.section, text },
        select: { id: true }
      });
      return { id: result.id };
    }

    const result = await prisma.contentString.create({
      data: { pageId: data.pageId, fallback: data.fallback, role: data.role, section: data.section, text },
      select: { id: true }
    });
    return { id: result.id };
  });
```

- **Auth:** `requireAuthenticatedUser()` + admin role check.
- **Behavior:** If `id` present → `update`; otherwise → `create`. Returns only `{ id }`.

`VALID_STRING_ROLES` is duplicated from the Prisma enum because Prisma's generated `StringRole` is a TS type, not a runtime value. Keep this array in sync with the enum and with the `StringRole` union in `types.ts` — three-place sync, flagged as the most common drift point in this stack.

> **A note on validation.** This skill leans on Zod for input validation. If your project hand-rolls validation with predicates (`isRecord`, custom `parseInput` helpers), the contract is the same — validate input before the handler runs and throw a typed error on bad input. Zod is the preferred default; hand-rolled validation is acceptable for projects that already use it consistently.

---

## Auth + permission helpers referenced

These come from the [auth-stack skill](../auth-stack/SKILL.md):

- `requireAuthenticatedUser()` — throws if no session; returns a `{ id, role }` user.
- `isAdmin(role)` — typically `role === "admin" || role === "owner"`. Define once in your role module; reuse here.

Don't redefine them locally.

---

## Adding a new server function (rare)

If you need a new content read path (e.g. "get strings for two pages at once"):

1. Place it in `<server>/lib/i18n/` (public) or `<server>/lib/admin/` (gated).
2. Validate input with Zod (or your project's validation pattern).
3. Flatten `Languages` to top-level fields before returning. Never leak the nested shape.
4. Add a `queryOptions` entry to `<server>/lib/queries/i18nQueries.ts` (or `adminQueries.ts`).
5. If reads should be cached forever, set `staleTime: Infinity`.
6. Do **not** call `prisma.contentString` / `prisma.contentPage` from any other module — those two are the only authorized access points.
