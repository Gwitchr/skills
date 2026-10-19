# Query options and hooks

The TanStack Query side of the data layer: the key hierarchy and options functions per domain, and the hook that consumes them. Read it when writing or reviewing queries, hooks, or cache policy. The typed fetchers and `API_ENDPOINTS` the examples call are defined in [entry-points.md](entry-points.md); what a mutation does to the cache beyond the default invalidation is the `smart-tanstack-query` skill's subject.

## Query options (`<queries>/*.ts`)

One file per domain with two kinds of export: `xKeys`, a frozen object that builds the cache-key hierarchy, and one standalone `*Options` function per query that returns `queryOptions(...)` or `infiniteQueryOptions(...)`. Call sites spread the result into `useQuery` and add per-call settings on top.

The key hierarchy:

```
articleKeys.all              → ["articles"]                      the broadest invalidation target
articleKeys.lists()          → ["articles", "list"]              every paginated list
articleKeys.list(params)     → ["articles", "list", params]      one paginated list
articleKeys.details()        → ["articles", "detail"]            every detail
articleKeys.detail(id)       → ["articles", "detail", id]        one item
articleKeys.searches()       → ["articles", "search"]            every search
articleKeys.search(params)   → ["articles", "search", params]    one search
```

Every key extends `articleKeys.all`, so one `invalidateQueries({ queryKey: articleKeys.all })` covers the domain. `as const` makes the keys readonly tuples, which TanStack uses to infer narrower types.

```typescript
// <queries>/article.ts
import { keepPreviousData, queryOptions, infiniteQueryOptions } from "@tanstack/react-query";
import { API_ENDPOINTS } from "constants/apiEndpoints";
import { type GetArticleResponse, type GetArticlesResponse } from "types/article";
import { type PaginatedOptionsParams } from "types/common";
import { getModelFetcher } from "utils/fetcher";

export interface SearchArticleQueryProps extends PaginatedOptionsParams {
  searchText: string;
  filterOptions?: { authorId?: string; tag?: string };
}

export const articleKeys = {
  all: ["articles"] as const,
  lists: () => [...articleKeys.all, "list"] as const,
  list: (params: PaginatedOptionsParams) => [...articleKeys.lists(), params] as const,
  details: () => [...articleKeys.all, "detail"] as const,
  detail: (articleId: string) => [...articleKeys.details(), articleId] as const,
  searches: () => [...articleKeys.all, "search"] as const,
  search: (params: SearchArticleQueryProps) => [...articleKeys.searches(), params] as const
} as const;

export function articleListOptions(params: PaginatedOptionsParams) {
  return queryOptions({
    queryKey: articleKeys.list(params),
    queryFn: ({ signal }) =>
      getModelFetcher<GetArticlesResponse>({ url: API_ENDPOINTS.ARTICLES(), errorString: "Articles", queryParams: params, signal }),
    placeholderData: keepPreviousData
  });
}

export function articleDetailOptions(articleId?: string | null) {
  return queryOptions({
    queryKey: articleKeys.detail(articleId ?? ""),
    queryFn: () =>
      getModelFetcher<GetArticleResponse>({ url: API_ENDPOINTS.ARTICLE.SINGLE({ articleId }), errorString: "Article" }),
    enabled: !!articleId
  });
}

export function articleSearchOptions(params: SearchArticleQueryProps) {
  return queryOptions({
    queryKey: articleKeys.search(params),
    queryFn: () =>
      getModelFetcher<GetArticlesResponse>({
        url: API_ENDPOINTS.ARTICLES(),
        errorString: "Articles search",
        queryParams: { search: params.searchText, ...params.filterOptions, page: params.page, take: params.take }
      }),
    placeholderData: keepPreviousData
  });
}

export function articleInfiniteSearchOptions(params: SearchArticleQueryProps) {
  const take = params.take ?? 10;
  return infiniteQueryOptions({
    queryKey: articleKeys.search(params),
    queryFn: ({ pageParam }) =>
      getModelFetcher<GetArticlesResponse>({
        url: API_ENDPOINTS.ARTICLES(),
        errorString: "Articles search",
        queryParams: { search: params.searchText, page: pageParam, take, ...params.filterOptions }
      }),
    initialPageParam: 0,
    getNextPageParam: (lastPage, _allPages, lastPageParam) => (lastPage.articles.length < take ? undefined : lastPageParam + 1),
    placeholderData: keepPreviousData
  });
}
```

At the call site, spread the options and add the per-consumer settings:

```typescript
const articleQuery = useQuery({
  ...articleDetailOptions(id),
  throwOnError: true,
  select: (response) => response.article
});
```

Cache policy (`staleTime`, `gcTime`, `retry`) has three homes, and the higher the better: `QueryClient` defaults for the whole app, the `*Options` function for a domain whose freshness differs (articles stable for five minutes, comments for ten seconds), and the call site only for a one-off need on one screen. Per-consumer settings (`select`, `throwOnError`, `enabled`, a `refetchOnWindowFocus` override) never go in the `*Options` function.

The same options functions serve the server: `await queryClient.prefetchQuery(articleDetailOptions(id))` or `ensureQueryData`, with no separate server variant. Under a `<Suspense>` boundary, feed them to `useSuspenseQuery` or `useSuspenseInfiniteQuery`; `data` is then non-nullable. A suspense query cannot be disabled, so for an optional ID render the consumer only once the ID exists instead of passing `enabled: false`.

### Rules

- Use `queryOptions()` and `infiniteQueryOptions()`; they type `data` at the call site and let `select` narrow it.
- One `xKeys` object plus standalone `*Options` functions per domain; never a method-bag object of queries.
- URLs come from `API_ENDPOINTS`; requests go through the typed fetchers.
- A query that depends on a possibly-null ID sets `enabled: !!id` and still passes a stable key (`id ?? ""`).
- Pass the whole params object into the key builder as the leaf; never spread it into the array.
- `keepPreviousData` on paginated and search queries, so a page change does not blank the list.

## Hooks (`<hooks>/useX.ts`)

One hook per domain, taking an options bag where every input is optional and returning a uniform shape:

```typescript
// <hooks>/useArticles.ts
import { type UseMutationOptions, useMutation, useQueryClient, useQuery } from "@tanstack/react-query";
import { API_ENDPOINTS } from "constants/apiEndpoints";
import { articleKeys, articleListOptions, articleSearchOptions } from "queries/article";
import { type PostArticleParamsSchemaType } from "schemas/article";
import { type PostArticleMutationResponse } from "types/article";
import { type PaginatedOptionsParams } from "types/common";
import { postModelFetcher } from "utils/fetcher";

interface UseArticlesProps {
  articlesSearchText?: string;
  articlesListOptions?: PaginatedOptionsParams;
  searchListOptions?: PaginatedOptionsParams;
  mutationOptions?: Pick<UseMutationOptions<PostArticleMutationResponse, Error, PostArticleParamsSchemaType>, "onSuccess" | "onError">;
}

export function useArticles({ articlesListOptions, searchListOptions, mutationOptions, articlesSearchText }: UseArticlesProps = {}) {
  const queryClient = useQueryClient();

  const createArticle = useMutation<PostArticleMutationResponse, Error, PostArticleParamsSchemaType>({
    mutationFn: (params) => postModelFetcher({ url: API_ENDPOINTS.ARTICLES(), errorString: "Articles", params }),
    async onSuccess(data, variables, context) {
      mutationOptions?.onSuccess?.(data, variables, context);
      await queryClient.invalidateQueries({ queryKey: articleKeys.all });
    },
    onError(error, variables, context) {
      mutationOptions?.onError?.(error, variables, context);
    }
  });

  const articlesQuery = useQuery({
    ...articleListOptions({ page: articlesListOptions?.page ?? 0, take: articlesListOptions?.take ?? 10 }),
    select: (response) => response.articles
  });

  const searchQuery = useQuery({
    ...articleSearchOptions({ searchText: articlesSearchText ?? "", page: searchListOptions?.page ?? 0, take: searchListOptions?.take ?? 10 }),
    enabled: !!articlesSearchText,
    select: (response) => response.articles
  });

  return {
    createArticle,
    articles: articlesQuery.data ?? [],
    articlesIsLoading: articlesQuery.isLoading,
    articlesIsError: articlesQuery.isError,
    foundArticles: searchQuery.data ?? [],
    foundArticlesIsLoading: searchQuery.isLoading,
    foundArticlesIsError: searchQuery.isError
  };
}
```

### Rules

- Spread the `*Options` result into `useQuery` and add `select`, `throwOnError`, or `enabled` on top; `select` projects the response so the hook returns final shapes (`articles` is the array, not the wrapper).
- Mutation callbacks accept `Pick<UseMutationOptions<Res, Error, Params>, "onSuccess" | "onError">`; add `onMutate` and `onSettled` only when a consumer needs them. Always call the parent's callback first.
- On mutation success, invalidate `xKeys.all` and await it. For anything narrower, cross-domain effects, or optimistic updates, follow the `smart-tanstack-query` skill.
- Return data with safe defaults (`?? []`, `?? null`), the loading and error flags, and the mutation objects so consumers can read `isPending` and call `.mutate(...)`.
- Never copy server state into Redux or Zustand; TanStack Query is the server cache.
