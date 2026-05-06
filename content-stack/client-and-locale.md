# Client translation and locale management

The client side is two pieces glued together: a TanStack Query cache that holds all locales' values for one page slug, and a client-store slice (Redux / Zustand / Context — Redux in the examples) that holds the active locale. `useTranslation(pageSlug)` reads both and resolves on the fly — synchronous, no network on locale switch.

## TanStack Query layer

`<server>/lib/queries/i18nQueries.ts`:

```ts
import { queryOptions } from "@tanstack/react-query";
import { getPageStrings } from "<server>/lib/i18n/getPageStrings";

export const i18nQueries = {
  all: () => ["i18n"] as const,
  pageStrings: ({ pageSlug }: { pageSlug: string }) =>
    queryOptions({
      queryKey: [...i18nQueries.all(), "pageStrings", pageSlug] as const,
      queryFn: () => getPageStrings({ data: { pageSlug } }),
      staleTime: Infinity
    })
};
```

`<server>/lib/queries/i18nMutations.ts`:

```ts
import { mutationOptions } from "@tanstack/react-query";
import { updateUserLocale } from "<server>/lib/i18n/updateUserLocale";

export const i18nMutations = {
  updateUserLocale: () =>
    mutationOptions({
      mutationFn: (data: { locale: string }) => updateUserLocale({ data })
    })
};
```

Key choices:

- **`staleTime: Infinity`** — content is treated as immutable for the session. Don't lower it; lower stale times defeat the cache and re-fetch on every locale switch (which is supposed to be a pure store dispatch).
- **One cache entry per `pageSlug`.** If a route uses two pages of strings (e.g. `"global"` plus `"landing"`), call `useTranslation` twice — one hook per slug.
- **Domain-wide cache policy lives here.** Per-call concerns (`select`, `throwOnError`) belong at the `useQuery` call site. See the `zod-prisma-tanstack` skill for the layering rule.
- **No mutation for content writes** in `i18nMutations`. Admin writes go through `adminMutations.upsertContentString` (different module, admin-gated — see [schema-and-server.md](schema-and-server.md)).

---

## The translate hook

`<client>/hooks/useTranslation.ts`:

```ts
import { useQuery } from "@tanstack/react-query";
import { i18nQueries } from "<server>/lib/queries/i18nQueries";
import { useAppSelector } from "<client>/store";
import { selectLocale } from "<client>/store/slices/languageSlice";
import type { ResolvedString, SupportedLocale, TranslateArgs } from "<server>/lib/i18n/types";

const EMPTY_STRINGS: Array<ResolvedString> = [];

function resolve(strings: ResolvedString[], locale: SupportedLocale, args: TranslateArgs): string {
  const match = strings.find(
    (s) => s.fallback === args.text && s.role === args.role && s.section === args.section
  );
  if (!match) return args.text;

  // Pick the value for the active locale; fall back to the base language if null.
  // Add cases for additional locales here, mirroring SUPPORTED_LOCALES.
  if (locale === "en") return match.en;
  return match.es ?? match.en; // es (or any other additional locale) → fall back to en
}

type TranslateFn = {
  (args: TranslateArgs): string;
  (role: TranslateArgs["role"], section: string, text: string): string;
};

export function useTranslation(pageSlug: string): TranslateFn {
  const locale = useAppSelector(selectLocale);
  const { data: strings } = useQuery(i18nQueries.pageStrings({ pageSlug }));
  const resolved = strings ?? EMPTY_STRINGS;

  // Single discriminating function — string first arg = positional, object first arg = named.
  const t: TranslateFn = ((
    argOrRole: TranslateArgs | TranslateArgs["role"],
    section?: string,
    text?: string
  ) => {
    if (typeof argOrRole === "string") {
      return resolve(resolved, locale, { role: argOrRole, section: section!, text: text! });
    }
    return resolve(resolved, locale, argOrRole);
  }) as TranslateFn;

  return t;
}
```

### Resolution algorithm

1. Find a row where **all three** of `fallback === args.text`, `role === args.role`, `section === args.section` match.
2. If no row matches, return `args.text` unchanged. **No console warning, no error** — silent fallback by design (the JSX-as-base-copy pattern means an unseeded string still renders correctly in the base language).
3. If a row matches, pick the value for the current locale.
4. If that value is `null` (not seeded yet), fall back to `match.<base-language>`.

### Calling the hook

Two equivalent shapes — pick whichever reads cleaner at the call site:

```tsx
const t = useTranslation("landing");

// Object form (recommended for readability)
<h1>{t({ text: "Brief → brand → website", role: "headline", section: "hero" })}</h1>

// Positional form (recommended when wrapping in JSX with many calls)
<button>{t("action", "hero", "Start your project")}</button>
```

The first argument's type discriminates: a string starts the positional form; an object starts the named form.

### Why `EMPTY_STRINGS` is module-scoped

If `resolved` were `strings ?? []` inline, every render would create a new array literal. Most consumers don't memoize on `resolved`, but if anyone ever does (a child hook that depends on it), the inline literal would bust the memo. The shared constant keeps it stable while the query is loading.

> **React 19 / React Compiler note:** the `useMemo`s you might be tempted to add around `resolve` calls are unnecessary if the React Compiler is enabled in your project. Trust the compiler; profile before adding manual memoization. See the `components-hierarchy` skill's "Compiler-first mindset" section.

---

## Locale store slice (Redux example)

`<client>/store/slices/languageSlice.ts`:

```ts
import { createSlice, type PayloadAction } from "@reduxjs/toolkit";
import { DEFAULT_LOCALE, type SupportedLocale } from "<server>/lib/i18n/types";

interface LanguageState {
  locale: SupportedLocale;
}

const initialState: LanguageState = {
  locale: DEFAULT_LOCALE
};

const languageSlice = createSlice({
  name: "language",
  initialState,
  reducers: {
    setLocale: (state, action: PayloadAction<SupportedLocale>) => {
      state.locale = action.payload;
    }
  }
});

export const { setLocale } = languageSlice.actions;
export const selectLocale = (state: { language: LanguageState }) => state.language.locale;
export default languageSlice.reducer;
```

The slice is intentionally minimal — one field, one reducer, one selector. If your project uses Zustand or React Context instead of Redux, the shape is the same: one piece of state, one setter.

If your framework recreates the store per request (TanStack Start SSR, Next.js with a per-request store), the only way to change locale during the request is via the dispatch — see "Locale initialization" below.

---

## Locale initialization

`<client>/components/providers/AppProviders.tsx`:

```tsx
import { useEffect } from "react";
import { setLocale } from "<client>/store/slices/languageSlice";
import { isSupportedLocale } from "<server>/lib/i18n/types";
import type { AuthSession } from "<server>/lib/auth/session";

export function AppProviders({ children, authSession, store }: Props) {
  useEffect(() => {
    const userLocale = authSession.user?.preferredLocale;
    if (userLocale && isSupportedLocale(userLocale)) {
      store.dispatch(setLocale(userLocale));
    }
  }, [authSession, store]);

  return <>{children}</>;
}
```

Order:

1. Store initialised with `DEFAULT_LOCALE`.
2. Auth session hydrated from the server.
3. If the user has a valid `preferredLocale`, dispatch `setLocale`.
4. If the value is missing or not in `SUPPORTED_LOCALES`, stay on the default.

There is **no** `Accept-Language` detection, **no** cookie sniffing, **no** localStorage. The system is opinionated: default base-language, opt-in via the picker, persistence via the user record.

If you need `Accept-Language` detection, the right place to add it is the same `useEffect` — read the header during SSR, fall back to it when there's no `preferredLocale`, but never override an explicit choice.

---

## Locale switcher

`<client>/components/atoms/LocaleSelect.tsx`:

```tsx
import { useAppDispatch, useAppSelector } from "<client>/store";
import { selectLocale, setLocale } from "<client>/store/slices/languageSlice";
import { SUPPORTED_LOCALES, type SupportedLocale } from "<server>/lib/i18n/types";

interface LocaleSelectProps {
  variant?: "short" | "long";
  onLocaleChange?: (locale: SupportedLocale) => void;
}

const LABELS_SHORT: Record<SupportedLocale, string> = {
  en: "EN",
  es: "ES"
};
const LABELS_LONG: Record<SupportedLocale, string> = {
  en: "English",
  es: "Español"
};

export function LocaleSelect({ variant = "short", onLocaleChange }: LocaleSelectProps) {
  const dispatch = useAppDispatch();
  const current = useAppSelector(selectLocale);
  const labels = variant === "short" ? LABELS_SHORT : LABELS_LONG;

  return (
    <select
      value={current}
      onChange={(event) => {
        const next = event.target.value as SupportedLocale;
        dispatch(setLocale(next));
        onLocaleChange?.(next);
      }}
    >
      {SUPPORTED_LOCALES.map((locale) => (
        <option key={locale} value={locale}>
          {labels[locale]}
        </option>
      ))}
    </select>
  );
}
```

Important:

- **Does NOT call `updateUserLocale`.** Switching locale is a UI-only change; it survives page navigations within the SPA but **not** a refresh for an authenticated user (the auth session would re-seed from `User.preferredLocale`).
- **Variants:** `"short"` for compact navs, `"long"` for settings panels. Add a third variant if the UI needs it.
- **Callback is fire-and-forget.** A consumer that wants persistence calls `i18nMutations.updateUserLocale` from `onLocaleChange`.
- **Labels are pure strings** — no flag emojis, no country names. Flags imply nation-equals-language (German for Germany? Austrian Germans? Swiss?), which is wrong; labels in the language itself are the safer convention. Add flags only if your project explicitly opts into the country-flag aesthetic.

### Persistence pattern

If a feature needs the locale to outlive a refresh:

```tsx
import { useMutation } from "@tanstack/react-query";
import { i18nMutations } from "<server>/lib/queries/i18nMutations";

const persistLocale = useMutation(i18nMutations.updateUserLocale());

<LocaleSelect
  variant="long"
  onLocaleChange={(locale) => persistLocale.mutate({ locale })}
/>
```

Don't put this inside `LocaleSelect` itself — anonymous users on the landing page can't call the mutation (it requires auth), so the component stays auth-agnostic.

---

## Concrete consumer example

A typical route component:

```tsx
import { useTranslation } from "<client>/hooks/useTranslation";

export function LandingPage() {
  const t = useTranslation("landing");

  return (
    <section>
      <h1>{t({ text: "Welcome", role: "headline", section: "hero" })}</h1>
      <p>{t({ text: "Build something great", role: "body", section: "hero" })}</p>
      <button>{t("action", "hero", "Start your project")}</button>
    </section>
  );
}
```

For most components, prefer `useTranslation` over hand-rolling `resolve` calls — the hook gives you the standard `(text, role, section)` lookup with the right fallback semantics built in. Reserve hand-rolled resolution for routes that pick a specific known set of strings (e.g. a legal page that reads `terms-title` directly).
