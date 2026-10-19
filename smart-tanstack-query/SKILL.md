---
name: smart-tanstack-query
description: Cache correctness for TanStack Query v5. Which queries a mutation must invalidate (the domain root by default, a narrower key only with a reason), what refetches on visible versus hidden screens, when to await a refetch, optimistic updates with cancel and rollback, infinite-query updates, cross-domain and server-driven changes, the MutationCache plus meta.invalidates pattern that automates the mapping, and a review checklist. Use whenever a list does not update after a save, a detail page shows old data, a mutation needs onSuccess or onSettled wiring, someone writes setQueryData or invalidateQueries, a review touches query keys or mutations, or staleTime is being raised, even when nobody says "cache".
---

# smart-tanstack-query

This skill covers what happens to the TanStack Query cache after data changes: which queries a mutation marks stale, what refetches and when, how to patch the cache by hand without lying to the user, and how to keep the mutation-to-query mapping from drifting as an app grows. It is for anyone writing or reviewing mutations, query keys, or cache policy in a TanStack Query v5 app.

TRIGGER when: a list or count does not update after a create, update, or delete; a detail screen shows old data; a mutation needs `onSuccess`, `onSettled`, or `onMutate` wiring; code calls `setQueryData`, `invalidateQueries`, or `refetchQueries`; a review touches query keys or mutations; or someone raises `staleTime` and old data starts showing.

> **Stack assumed.** TanStack Query v5 (`@tanstack/react-query`); the cache rules come from `@tanstack/query-core`, so they hold for the Vue, Solid, and Svelte adapters as well. Query keys built from a per-domain root the way the `zod-prisma-tanstack` skill lays out (`postKeys.all`, `postKeys.list(params)`, `postKeys.detail(id)`). Behavior below is as documented for v5 as of 2026-10-19.

> **Notation.** `postKeys` stands for any domain's key factory. `<hooks>/` and `<queries>/` are placeholder paths; resolve them to the project's layout.

> **Precedence.** Project conventions in `AGENTS.md` or `CLAUDE.md` win. The `zod-prisma-tanstack` skill owns file layout, key factories, and options functions; this skill owns what a write does to the cache.

## How the cache behaves

Every rule below rests on these facts, so read them once.

- **Keys match by prefix.** `invalidateQueries({ queryKey: ["posts"] })` matches `["posts"]`, `["posts", "list", { page: 1 }]`, and `["posts", "detail", id]`. A longer key matches less. `exact: true` matches one key only, and `predicate` runs your own test per cached query.
- **Invalidation marks matches stale and refetches the visible ones.** Stale means the cached value is still shown but eligible for refetch, and the mark overrides any `staleTime`. With the default `refetchType: "active"`, a query with a mounted observer (a hook on a rendered component reading it) refetches at once; a query nobody is rendering stays stale and refetches on its next mount. `refetchType: "all"` refetches hidden ones too, `"inactive"` only those, `"none"` marks and stops.
- **`invalidateQueries` returns a promise** that settles when the refetches it started finish.
- **`staleTime` defaults to 0.** Remount and window focus refetch everything, which hides a missing invalidation until someone raises `staleTime` for performance. Then the old data shows.
- **Mutation callbacks run in order** `onMutate`, then `onSuccess` or `onError`, then `onSettled`. A promise returned from any of them is awaited before the next one runs, and the mutation stays `isPending` until the chain finishes.
- **Two sets of callbacks exist.** The ones on `useMutation` fire for every call. The ones passed to `mutate(vars, { onSuccess })` fire after those, only for the last call when calls overlap, and only while the component is still mounted.
- **An infinite query refetches its pages one after another, from the first.** `maxPages` caps how many pages it stores and therefore refetches. A manual update must keep `pages` and `pageParams` the same length.
- **Nothing links a mutation to the queries it changes.** The library gives the mechanism; the mapping is yours. The only built-in hook for automating it is the global `MutationCache` callbacks together with a mutation's `meta`.

## Rules

### Invalidate from the hook, never from the call site

Put cache work in the `onSuccess` or `onSettled` of `useMutation`. The callbacks passed to `mutate()` are for one component's side effects (close a dialog, navigate) because they do not fire once that component unmounts, and an unmounted form is the common case after a save.

```typescript
// <hooks>/usePosts.ts
const updatePost = useMutation({
  mutationFn: (params: UpdatePostParams) => putModelFetcher({ url: API_ENDPOINTS.POST.SINGLE(params), params }),
  onSuccess: () => queryClient.invalidateQueries({ queryKey: postKeys.all })
});
```

### Invalidate the domain root by default

A post update must mark every query that shows a post stale: the detail, every list, every search, counts, and feeds. `postKeys.all` covers all of them in one call, and because only mounted queries refetch, the cost is one request per visible query, not one per cached key.

Narrow the key only with a reason you can state: a visible list on the same screen is expensive and the server response already carries the updated entity, so you write that entity with `setQueryData` and invalidate `postKeys.lists()`. Never invalidate only the detail key.

### Return the invalidation promise

Return (or `await`) the promise from `invalidateQueries` so `isPending` holds until the refetch lands. A form that re-enables before the list shows the new row looks broken. When the mutation must not wait, for example before a navigation, call `invalidateQueries` without returning it and leave a comment saying the refetch is intentionally detached.

### Declare cross-domain effects next to the mutation

Deleting a post changes the author's post count, a dashboard feed, and tag counts. List every affected root in the mutation; run them with `Promise.all`:

```typescript
onSuccess: () =>
  Promise.all([
    queryClient.invalidateQueries({ queryKey: postKeys.all }),
    queryClient.invalidateQueries({ queryKey: authorKeys.detail(authorId) }),
    queryClient.invalidateQueries({ queryKey: feedKeys.all })
  ])
```

When a new domain starts reading posts, add it here. When these lists grow past a handful of mutations, switch to the automated mapping below so a forgotten entry invalidates everything rather than nothing.

### Optimistic updates follow one sequence

An optimistic update (showing the result before the server confirms it) through the cache has five steps, in this order:

```typescript
useMutation({
  mutationFn: updatePost,
  async onMutate(next) {
    await queryClient.cancelQueries({ queryKey: postKeys.detail(next.id) }); // 1. stop in-flight refetches
    const previous = queryClient.getQueryData(postKeys.detail(next.id));    // 2. snapshot
    queryClient.setQueryData(postKeys.detail(next.id), next);               // 3. write the optimistic value
    return { previous };                                                     // 4. hand the snapshot on
  },
  onError(_error, next, context) {
    queryClient.setQueryData(postKeys.detail(next.id), context?.previous);  // 5a. roll back
  },
  onSettled: (_data, _error, next) =>
    queryClient.invalidateQueries({ queryKey: postKeys.all })               // 5b. server truth wins
});
```

Skipping step 1 lets a refetch that was already in flight overwrite the optimistic value. Write the shape the `queryFn` returns, not the shape a `select` produced at a call site. When only one component shows the pending item, prefer the UI path instead: render from `mutation.variables` while `isPending`, or read pending mutations elsewhere with `useMutationState` filtered by `mutationKey`. It needs no rollback code.

### Patch the cache only when you know the full shape

`setQueryData` replaces the cached value for one key; `setQueriesData` does it for every existing key matching a prefix and creates nothing. Both take an updater that must return a new object (never mutate the old one) and that aborts the write when it returns `undefined`. Use keys from `queryOptions()` so the value type is inferred. After any manual write, still invalidate, so the server's version replaces yours.

For an infinite query, prefer invalidation over patching. If you patch, return `{ pages, pageParams }` with both arrays changed together, and set `maxPages` on queries that grow without bound.

### Changes that happen outside a mutation still need an invalidation

A websocket or server-sent event, a cron on the server, another browser tab, or a Next.js server action followed by `revalidatePath` changes data without passing through `useMutation`. Call `invalidateQueries` on the matching root from the event handler. `router.refresh()` in Next.js re-renders server components and leaves the query cache untouched. Where no event exists, `refetchInterval` on the options function is the honest fallback.

### Raise staleTime on purpose

Set `staleTime` domain-wide in the options function or app-wide in `QueryClient` defaults, as the `zod-prisma-tanstack` skill lays out, and only after checking every mutation that touches that domain invalidates it. Data that never changes during a session gets `staleTime: "static"`, and a blanket invalidation can skip it with a `predicate`. `gcTime` is unrelated to freshness; it only decides when an unused entry leaves memory.

## Automating the mapping

Once mutations outnumber what a reviewer can hold in their head, move the mapping into the `QueryClient` and tag each mutation with the roots it touches. A mutation without tags invalidates everything, which is the safe failure.

```typescript
// <queries>/client.ts
import { MutationCache, QueryClient, matchQuery, type QueryKey } from "@tanstack/react-query";

declare module "@tanstack/react-query" {
  interface Register {
    mutationMeta: { invalidates?: QueryKey[] };
  }
}

export const queryClient = new QueryClient({
  mutationCache: new MutationCache({
    onSuccess: (_data, _variables, _context, mutation) => {
      const tags = mutation.meta?.invalidates;
      queryClient.invalidateQueries({
        predicate: (query) => !tags || tags.some((queryKey) => matchQuery({ queryKey }, query))
      });
    }
  })
});
```

```typescript
// <hooks>/usePosts.ts
const deletePost = useMutation({
  mutationFn: deletePostFn,
  meta: { invalidates: [postKeys.all, authorKeys.all, feedKeys.all] }
});
```

The global callback runs before the mutation's own `onSuccess`, so a hook that must wait for one specific refetch returns it locally with `cancelRefetch: false`, which joins the request the global callback already started instead of firing a second one:

```typescript
onSuccess: () => queryClient.invalidateQueries({ queryKey: postKeys.lists() }, { cancelRefetch: false })
```

## Review checklist

Run these questions over every mutation in a change:

- Which cached queries show the entity this mutation changes, including counts, feeds, and other domains? Does the invalidation cover all of them?
- Is the invalidation on `useMutation`, not inside `mutate(vars, { onSuccess })`?
- Is the promise returned or awaited, and if not, is the detachment commented?
- Is every key passed to `invalidateQueries` or `setQueryData` built from the domain's key factory?
- Does each `setQueryData` write the `queryFn` shape, and is an invalidation scheduled after it?
- Does each `onMutate` start with `cancelQueries` and return a snapshot that `onError` restores?
- Is any `staleTime` above 0 backed by mutations that invalidate that domain?
- Do realtime or server-triggered changes reach `invalidateQueries`?

## Anti-patterns

- ❌ Invalidating only the detail key after an update; lists, searches, and counts keep the old row.
- ❌ Cache writes inside `mutate(vars, { onSuccess })`; they never run once the form unmounts.
- ❌ Fire-and-forget `invalidateQueries` in `onSuccess` without a comment; the form re-enables before the list updates.
- ❌ `setQueryData` without `cancelQueries` first in an optimistic update; an in-flight refetch overwrites it.
- ❌ `setQueryData` with the shape a `select` produced; the next render reads the wrong fields.
- ❌ Manual cache writes with no invalidation afterwards; the cache drifts from the server.
- ❌ Hand-written keys in `invalidateQueries` that do not share the factory's prefix; nothing matches and nothing refetches.
- ❌ Raising `staleTime` to fix performance before auditing invalidations; it exposes every missing one.
- ❌ Patching an infinite query's `pages` without `pageParams`; the next page fetch uses the wrong cursor.
- ❌ Expecting `router.refresh()` or `revalidatePath` to update TanStack Query data; they do not touch the cache.
- ❌ Mirroring server state into Redux or Zustand and invalidating only one of the two copies.
