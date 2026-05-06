# Workflows

Five recipes that cover almost every change to this stack. Pick the one that matches your task and follow the steps in order — none of them have hidden dependencies you can skip.

> **Package manager / TS runner.** Examples use `prisma db push` and `prisma generate` directly; substitute the project's wrappers (`pnpm db:push`, `npm run db:push`, `bun run db:push`, etc.). The seed script runs with any TS executor — `tsx`, `bun run`, `ts-node` all work. Examples below use `tsx` as the default.

---

## Adding a string to an existing page

The most common change. The string must end up in **the seed file** to survive the next reset; the admin UI alone is not enough.

1. Open `prisma/seed-translations.ts` and locate the page object whose `slug` matches the route you're editing (e.g. `slug: "landing"`).
2. Add a new entry inside that page's `strings` array:

   ```ts
   {
     fallback: "Get started in 5 minutes",
     role: "action",        // pick the closest of the 11 StringRole values
     section: "hero",       // your name for the visual region; consistent within the page
     en: "Get started in 5 minutes",
     es: "Empieza en 5 minutos"        // optional — omit or null if not yet translated
   }
   ```

   The composite key `(slug, fallback, role, section)` must be unique within the page. If you want two buttons with the same base-language text, distinguish them by `section` or `role` — never by appending markers to `fallback`.

3. Re-seed:

   ```bash
   npx tsx prisma/seed-translations.ts
   ```

   This **wipes** all `ContentString` and `ContentPage` rows and re-creates from the file. Any unsaved admin-UI edits are lost — see "Coordinating with admin edits" below.

4. Use the string in JSX:

   ```tsx
   const t = useTranslation("landing");
   <button>{t({ text: "Get started in 5 minutes", role: "action", section: "hero" })}</button>
   ```

5. Verify both locales render. Switch via `<LocaleSelect />` or by dispatching `setLocale` in dev tools.

### When the string already exists

If you're editing existing copy, change `fallback` **and** the JSX call site in lockstep. The lookup matches on `fallback` exactly — leaving the old key in JSX leaves the user with the old translations and no way to recover them short of editing the row in the DB.

---

## Adding a new content page

A "page" is a logical bucket for strings, not necessarily a 1:1 mapping to a route. A `"global"` page holds strings used across multiple routes (nav labels, error messages, etc.).

1. In `prisma/seed-translations.ts`, add a new page object to the `pages` array:

   ```ts
   {
     slug: "pricing",
     label: "Pricing Page",
     strings: [
       { fallback: "Plans", role: "headline", section: "header", en: "Plans", es: "Planes" }
       // ...
     ]
   }
   ```

2. Re-seed: `npx tsx prisma/seed-translations.ts`.
3. In the route component, call `useTranslation("pricing")`.
4. The new page appears automatically in the admin selector — no UI change needed.

---

## Editing strings via the admin UI

The admin route is gated to admin role and lives at a path your project chooses (e.g. `/admin/translations`). It calls `listContentPages` for the dropdown and `upsertContentString` per save.

1. Navigate to the admin translations route.
2. Pick a page from the dropdown.
3. Click Edit on a row, change the locale columns, save.
4. The mutation invalidates `adminQueries.contentPages().queryKey` only — the **public** `i18nQueries.pageStrings(...)` cache remains warm. Refresh the public page (or the whole app) to see the change.

### Coordinating with admin edits

The seed wipes everything. Two safe patterns:

- **Use admin edits as a draft.** When the wording is final, copy the values back into `seed-translations.ts` and commit. Re-seeding then preserves them.
- **Use admin edits for hot fixes only.** Same pattern, but reduce the window between edit and seed-update so a stray seed run doesn't wipe a live correction.

There's no migration path. The DB is the cache; the seed is the source of truth.

---

## Adding a new `StringRole`

Three coordinated edits, **must stay in sync** — adding to only one place is the most common bug in this stack.

1. **Prisma enum** (`prisma/schema.prisma`):

   ```prisma
   enum StringRole {
     // ...existing
     caption     // new
   }
   ```

2. **TS union** (`<server>/lib/i18n/types.ts`):

   ```ts
   export type StringRole = /* ...existing */ | "caption";
   ```

3. **Admin validator array** (`<server>/lib/admin/upsertContentString.ts`):

   ```ts
   const VALID_STRING_ROLES = [
     // ...existing
     "caption"
   ] as const;
   ```

Then:

```bash
prisma db push       # push the enum addition to MongoDB
prisma generate      # regenerate Prisma client
```

Restart the dev server. The new role is now usable in the seed file and the admin UI.

> **Why three places?** Prisma's generated `StringRole` is a TS type only (no runtime value), so you can't `Object.values(StringRole)` to derive a runtime list. The TS union is needed for client code (`types.ts` is bundled to the browser; the Prisma client isn't). The runtime array is needed for Zod validation in `upsertContentString`. There's no clean way to deduplicate — accept the triple-sync cost and add a comment in each location pointing at the others.

---

## Adding a new language

The whole system is built single-locale-first with multi-locale extension points. Adding a new locale (e.g. French `fr`) is **four coordinated edits** plus a Prisma push and a re-seed.

The seams:

### 1. Prisma `Languages` type (`prisma/schema.prisma`)

```prisma
type Languages {
  en   String
  es   String?
  fr   String?    // new — optional so existing rows stay valid
}
```

Mongo embedded types tolerate missing optional fields, so existing rows don't need a backfill — they'll have `fr: null` implicitly.

### 2. `SUPPORTED_LOCALES` and `ResolvedString` (`<server>/lib/i18n/types.ts`)

```ts
export const SUPPORTED_LOCALES = ["en", "es", "fr"] as const;

export interface ResolvedString {
  fallback: string;
  role: StringRole;
  section: string;
  en: string;
  es: string | null;
  fr: string | null;   // new
}
```

### 3. The resolver (`<client>/hooks/useTranslation.ts`)

```ts
if (locale === "en") return match.en;
if (locale === "fr") return match.fr ?? match.en;   // new
return match.es ?? match.en;
```

### 4. `LocaleSelect` labels (`<client>/components/atoms/LocaleSelect.tsx`)

```ts
const LABELS_SHORT: Record<SupportedLocale, string> = {
  en: "EN",
  es: "ES",
  fr: "FR"   // new
};
const LABELS_LONG: Record<SupportedLocale, string> = {
  en: "English",
  es: "Español",
  fr: "Français"   // new
};
```

### Server fns to update

`getPageStrings` (`<server>/lib/i18n/getPageStrings.ts`) flattens the `Languages` type — add the new locale:

```ts
return page.strings.map((s) => ({
  fallback: s.fallback,
  role: s.role,
  section: s.section,
  en: s.text.en,
  es: s.text.es ?? null,
  fr: s.text.fr ?? null      // new
}));
```

`listContentPages` (`<server>/lib/admin/listContentPages.ts`) does the same shape — mirror it.

`upsertContentString` (`<server>/lib/admin/upsertContentString.ts`) accepts and writes the new field. Update both the Zod schema and the `text` write:

```ts
const inputSchema = z.object({
  // ...existing
  fr: z.string().nullable()   // new
});

// in handler:
const text = { en: data.en, es: data.es, fr: data.fr };
```

And `adminMutations.upsertContentString` in `<server>/lib/queries/adminMutations.ts` needs the new field on its input type.

### Admin UI

The admin route (`<routes>/admin/translations.tsx` or wherever your project routes it) shows one column per locale. Add a column and an edit-form field for the new locale. Keep the row layout consistent.

### Seed file

Add `fr?: string` to the `Str` type in the seed file and start filling translations:

```ts
type Str = {
  fallback: string;
  role: StringRole;
  section: string;
  en: string;
  es?: string;
  fr?: string;   // new
};
```

The seed handler that writes rows already handles missing optionals — strings without `fr` just store `null` and fall back to `en` at render time.

### Push and verify

```bash
prisma db push                            # apply Languages type change
prisma generate                           # regenerate Prisma client
npx tsx prisma/seed-translations.ts       # re-seed with new optional field
```

Verify:

- `LocaleSelect` shows the new locale option.
- Switching to the new locale renders translated strings where present, base language where not.
- An untranslated string falls back cleanly (no `null` rendered, no error).

### Single-locale forks

If a fork wants only the base language, it can ignore `LocaleSelect` and the `setLocale` plumbing — `DEFAULT_LOCALE` is set at the slice and resolution always returns `match.<base>` for the base locale. To re-enable multi-locale later, mount `<LocaleSelect />` and follow the steps above.

---

## Re-seeding safely

The seed script is **destructive**. Before running:

- [ ] Confirm no admin-UI edits are pending (or you have copied them back into the seed file).
- [ ] Confirm you're not pointing at a shared dev database others rely on (check `DATABASE_URL`).
- [ ] Confirm your seed file passes TS: `tsc --noEmit prisma/seed-translations.ts` (the TS runner won't tell you about subtle type issues — it transpiles and runs without strict typechecking).

Then:

```bash
npx tsx prisma/seed-translations.ts
```

The script should log `Cleared N pages and M strings` first, then `Seeded N pages and M strings`. If counts look wrong, your `pages` array is wrong — the seed file is the only input.

### A minimal seed-script skeleton

If your project doesn't have one yet:

```ts
// prisma/seed-translations.ts
import { PrismaClient } from "@prisma/client";
import type { StringRole } from "../<server>/lib/i18n/types";

const prisma = new PrismaClient();

type Str = {
  fallback: string;
  role: StringRole;
  section: string;
  en: string;
  es?: string;
};

type Page = { slug: string; label: string; strings: Str[] };

const pages: Page[] = [
  // ...your pages
];

async function main() {
  const cleared = await Promise.all([
    prisma.contentString.deleteMany({}),
    prisma.contentPage.deleteMany({})
  ]);
  console.log(`Cleared ${cleared[1].count} pages and ${cleared[0].count} strings`);

  let pageCount = 0;
  let stringCount = 0;
  for (const page of pages) {
    const created = await prisma.contentPage.create({
      data: {
        slug: page.slug,
        label: page.label,
        strings: {
          create: page.strings.map((s) => ({
            fallback: s.fallback,
            role: s.role,
            section: s.section,
            text: { en: s.en, es: s.es ?? null }
          }))
        }
      },
      include: { strings: true }
    });
    pageCount++;
    stringCount += created.strings.length;
  }
  console.log(`Seeded ${pageCount} pages and ${stringCount} strings`);
}

main()
  .catch((error) => {
    console.error(error);
    process.exit(1);
  })
  .finally(() => prisma.$disconnect());
```

When adding a new locale, extend the `Str` type and the `text:` literal in the `create` call to include the new field — see "Adding a new language" above.
