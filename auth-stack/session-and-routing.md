# Sessions and routing

The auth catch-all route, `getAuthSession` and `requireAuthenticatedUser`, the redirect sanitizer, the sign-in / sign-up POST shape, and the type-narrowing pattern for additional user fields.

## The catch-all route

Better Auth's HTTP API lives behind a single TanStack Start file route that forwards every method to `auth.handler(...)`:

```ts
// <routes>/api/auth/$.ts
import { createFileRoute } from "@tanstack/react-router";
import { auth } from "<server>/lib/auth";

async function handleAuthRequest(request: Request) {
  return auth.handler(request);
}

export const Route = createFileRoute("/api/auth/$")({
  server: {
    handlers: {
      GET:  async ({ request }) => handleAuthRequest(request),
      POST: async ({ request }) => handleAuthRequest(request)
    }
  }
});
```

### Why both GET and POST

Better Auth uses GET for verify-callbacks (the link in the magic-link email is a GET) and POST for everything else (sending the link, signing out, refreshing the session). Both must forward to `auth.handler` — omitting either breaks half the flow.

### Why the file is `$.ts`, not `$path.tsx`

The `$` filename is TanStack Start's convention for a true wildcard segment that matches anything after `/api/auth/`. It pairs with `basePath: "/api/auth"` in the auth config (see [auth-config.md](auth-config.md)) — the two are a contract.

### Other frameworks

Same shape, different signatures:

- **Next.js App Router** — `<app>/api/auth/[...all]/route.ts` exporting `GET` and `POST` named functions that each call `auth.handler(request)`.
- **Hono** — `app.all("/api/auth/*", (c) => auth.handler(c.req.raw))`.
- **Remix** — `loader` and `action` in `<routes>/api/auth/$.tsx`, both calling `auth.handler(request)`.

---

## Reading the session

### `getAuthSession` — the snapshot used by the UI

```ts
// <server>/lib/auth/session.ts
import { createServerFn } from "@tanstack/react-start";
import { getRequestHeaders } from "@tanstack/react-start/server";
import { auth } from "<server>/lib/auth";
import { isRole, type Role } from "<server>/lib/auth/role";

export const getAuthSession = createServerFn({ method: "GET" }).handler(async () => {
  let session: Awaited<ReturnType<typeof auth.api.getSession>> | null = null;

  try {
    session = await auth.api.getSession({ headers: getRequestHeaders() });
  } catch {
    return { isAuthenticated: false, user: null };
  }

  if (!session) return { isAuthenticated: false, user: null };

  return {
    isAuthenticated: true,
    user: {
      id:    session.user.id,
      email: session.user.email,
      name:  session.user.name,
      image: session.user.image ?? null,
      role:  isRole(session.user.role) ? session.user.role : "user",
      preferredLocale:
        typeof session.user.preferredLocale === "string"
          ? session.user.preferredLocale
          : null
    }
  };
});
```

Three patterns to copy:

1. **Try/catch around `auth.api.getSession`.** The function can throw if the cookie is malformed or expired — treat that as "not authenticated", not as a 500.
2. **Type-narrow every `additionalFields` value.** `session.user.role` is typed as `unknown`; the `isRole` predicate is the only safe way to read it. Never `as`-cast.
3. **Return a flat, narrow shape.** Pick the fields the UI needs; never spread the whole `session.user` — it includes fields you don't want on the wire.

### `requireAuthenticatedUser` — the gate for mutating server fns

```ts
// <server>/lib/auth/require.ts
import { auth } from "<server>/lib/auth";
import { prisma } from "<server>/lib/prisma";
import { getRequestHeaders } from "@tanstack/react-start/server";

interface AuthenticatedUser {
  id: string;
  role: string;
}

async function requireFromHeaders(headers: Headers): Promise<AuthenticatedUser> {
  const session = await auth.api.getSession({ headers });
  if (!session) throw new Error("Unauthorized.");

  const user = await prisma.user.findUnique({
    where:  { id: session.user.id },
    select: { id: true, role: true }
  });
  if (!user) throw new Error("Unauthorized.");

  return user;
}

export async function requireAuthenticatedUser() {
  return requireFromHeaders(getRequestHeaders());
}

export async function requireAuthenticatedRequestUser(request: Request) {
  return requireFromHeaders(request.headers);
}
```

The DB roundtrip is intentional — `session.user.role` is `unknown` at the boundary, and a fresh DB read confirms the user still exists and gets the canonical role.

### When to call which

| Function                          | Use in                                           | Throws on missing session?      |
| --------------------------------- | ------------------------------------------------ | ------------------------------- |
| `getAuthSession`                  | Loaders, route component data fetch              | No — returns `{ user: null }`   |
| `requireAuthenticatedUser`        | `createServerFn` handlers that mutate            | Yes — `Error("Unauthorized.")`  |
| `requireAuthenticatedRequestUser` | API-route handlers (where `request` is in scope) | Yes                             |

**Never** call `auth.api.getSession()` directly from a feature module. Always go through one of the three above — they're the single source of truth for "what is the session right now".

---

## Type-narrowing additional fields

Use a `const` object + literal-union type and a colocated predicate. Don't use TS `enum` (TS 5.5+ `--erasableSyntaxOnly` rejects them, and the const-object pattern is more portable).

```ts
// <server>/lib/auth/role.ts
export const ROLES = ["user", "admin", "owner"] as const;
export type Role = (typeof ROLES)[number];

export function isRole(value: unknown): value is Role {
  return typeof value === "string" && ROLES.includes(value as Role);
}
```

The predicate is colocated with the union so `includes` and the type both update in lockstep when a role is added.

### Hard rule

**Never** write `session.user.role as Role`. Better Auth's additional fields are typed as `unknown` for a reason — the adapter doesn't validate them at the boundary, and Better Auth's types may evolve. If you need a new narrowed read, **write the predicate**.

---

## The sign-in / sign-up flow

### Endpoint constant

Define the magic-link endpoint in your project's API-endpoints constants file (see the `zod-prisma-tanstack` skill's `API_ENDPOINTS` pattern):

```ts
AUTH_MAGIC_LINK: () => "/api/auth/sign-in/magic-link"
```

The magic-link plugin handles `POST /api/auth/sign-in/magic-link` (request the link) and `GET /api/auth/magic-link/verify?token=…` (callback target — Better Auth handles redirect to `callbackURL` automatically).

### Request shape

```ts
const callbackURL = sanitizePostAuthRedirectPath(redirect);

await fetch(API_ENDPOINTS.AUTH_MAGIC_LINK(), {
  method: "POST",
  headers: { "content-type": "application/json" },
  credentials: "include",
  body: JSON.stringify({ email: normalizedEmail, callbackURL })
});
```

Required pieces:

| Piece                      | Why                                                                                                                                  |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `credentials: "include"`   | Better Auth sets the session cookie on the verify-callback response — without this, the cookie never lands on the browser.          |
| Lowercased, trimmed `email` | The DB stores lowercase; mismatches trigger duplicate users.                                                                        |
| Sanitized `callbackURL`    | Open-redirect protection (see below).                                                                                                |
| Optional `name`            | Used by the sign-up page only — Better Auth picks it up on first verification because `name` is a built-in field on `User`.         |

### Email-exists branching

Sign-in checks whether the email belongs to an existing user before sending the magic link. Implement this as a small `createServerFn`:

```ts
export const checkUserEmailExists = createServerFn({ method: "POST" })
  .inputValidator((input: unknown) => {
    if (!isRecord(input) || typeof input.email !== "string") {
      throw new Error("Invalid email.");
    }
    return { email: input.email.trim().toLowerCase() };
  })
  .handler(async ({ data }) => {
    const user = await prisma.user.findUnique({
      where: { email: data.email },
      select: { id: true }
    });
    return { exists: Boolean(user) };
  });
```

In the sign-in form:

```ts
const result = await checkEmailMutation.mutateAsync({ email: normalizedEmail });

if (!result.exists) {
  await navigate({ to: "/auth/sign-up", search: { redirect, email: normalizedEmail } });
  return;
}
// …else proceed to send the magic link
```

If your project has invitations or other "introduced but not yet a User" states, extend the check to consider those too — the goal is "land the user on the right page (sign-in vs sign-up) without a confusing error."

---

## The redirect sanitizer

```ts
// <server>/lib/auth/redirect.ts
const DEFAULT_AUTH_REDIRECT_PATH = "/dashboard"; // pick your project's safe authenticated landing
const AUTH_ERROR_QUERY_KEYS = ["error", "error_description", "errorDescription"] as const;

export function sanitizePostAuthRedirectPath(path: string | undefined): string {
  if (typeof path !== "string") return DEFAULT_AUTH_REDIRECT_PATH;

  const normalizedPath = path.trim();
  if (!normalizedPath.startsWith("/")) return DEFAULT_AUTH_REDIRECT_PATH;
  if (normalizedPath.startsWith("//")) return DEFAULT_AUTH_REDIRECT_PATH; // protocol-relative

  const pathname = normalizedPath.split("#")[0].split("?")[0];

  if (
    pathname === "/auth/sign-in" ||
    pathname === "/auth/sign-up" ||
    pathname.startsWith("/api/auth")
  ) {
    return DEFAULT_AUTH_REDIRECT_PATH; // would self-loop
  }

  return stripAuthErrorSearchParams(normalizedPath);
}

function stripAuthErrorSearchParams(path: string): string {
  const [pathname, search] = path.split("?", 2);
  if (!search) return path;
  const params = new URLSearchParams(search);
  for (const key of AUTH_ERROR_QUERY_KEYS) params.delete(key);
  const remaining = params.toString();
  return remaining ? `${pathname}?${remaining}` : pathname;
}
```

Three classes of attack/footgun it blocks:

| Input                       | Without sanitizer            | With sanitizer            |
| --------------------------- | ---------------------------- | ------------------------- |
| `//evil.com/phish`          | Browser navigates off-origin | `DEFAULT_AUTH_REDIRECT_PATH` |
| `https://evil.com/phish`    | Same                         | `DEFAULT_AUTH_REDIRECT_PATH` |
| `/auth/sign-in`             | Infinite loop on success     | `DEFAULT_AUTH_REDIRECT_PATH` |
| `/api/auth/sign-out`        | Signs the user out post-auth | `DEFAULT_AUTH_REDIRECT_PATH` |
| `/dashboard?error=foo`      | Stale error banner           | `/dashboard`              |

### Hard rules

- **Always** call this on user-supplied `redirect` (URL search params, form fields). Never trust the raw value.
- **Never** broaden `DEFAULT_AUTH_REDIRECT_PATH` to anything that requires permissions to reach — it should be a safe authenticated landing that any signed-in user can hit.
- **Never** add new error keys to whatever URL strips them; add them to `AUTH_ERROR_QUERY_KEYS` instead.

---

## Server-fn template that requires auth

```ts
import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { prisma } from "<server>/lib/prisma";
import { requireAuthenticatedUser } from "<server>/lib/auth/require";

const inputSchema = z.object({
  value: z.string().trim().min(1, "Value is required.")
});

export const updateSomething = createServerFn({ method: "POST" })
  .validator(inputSchema.parse)
  .handler(async ({ data }) => {
    const user = await requireAuthenticatedUser();

    const result = await prisma.someModel.update({
      where:  { id: data.id, ownerId: user.id },
      data:   { value: data.value },
      select: { id: true } // narrow shape — never leak full rows
    });

    return { result };
  });
```

Three rules this template encodes:

1. **`validator(inputSchema.parse)` runs before the handler** — Zod throws a typed error with a user-facing message on bad input. (If you're on a project that hand-rolls validation with `isRecord` predicates, the contract is the same — just run validation before the handler.)
2. **Auth check is `requireAuthenticatedUser()`** — never duplicate `auth.api.getSession()`.
3. **Return narrow shapes** (`select: { … }`) — don't leak whole rows to the client.
