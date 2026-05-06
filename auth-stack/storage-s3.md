# Storage (AWS S3 + CloudFront)

The S3 client setup, the upload primitive, the CloudFront URL builder, and key conventions.

## Overview

```
upload caller (avatar setter, content image, export, …)
    │
    ├── PutObjectCommand → S3 bucket (private)
    └── getPublicAssetUrl(key) → CloudFront URL  ← what the UI uses
```

The bucket itself is **private**. Public reads happen through CloudFront, which fronts the bucket via an OAC (Origin Access Control). **Never** expose `s3://` URIs or pre-signed S3 URLs to clients — clients always see CloudFront URLs from `getPublicAssetUrl`.

---

## The S3 client

```ts
// <server>/lib/storage/s3.ts
import { PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { serverEnv } from "<server>/lib/env.server";

function getS3Client() {
  const { AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY } = serverEnv;
  return new S3Client({
    region: serverEnv.AWS_REGION,
    credentials:
      AWS_ACCESS_KEY_ID && AWS_SECRET_ACCESS_KEY
        ? { accessKeyId: AWS_ACCESS_KEY_ID, secretAccessKey: AWS_SECRET_ACCESS_KEY }
        : undefined // → default credential chain (IAM role)
  });
}
```

The credential pattern is identical to `getSesClient()` (see [email-ses.md](email-ses.md)) and is the canonical IAM-fallback shape. When you add a new AWS SDK client (e.g. `@aws-sdk/client-cloudfront` for invalidations), copy this exact shape — see SKILL.md §"Core principles" rule 2.

---

## The upload primitive

```ts
const DEFAULT_CACHE_CONTROL = "public, max-age=31536000, immutable";

export async function uploadObjectToS3(input: {
  key: string;
  body: Uint8Array;
  contentType: string;
  cacheControl?: string;
}) {
  const bucketName = serverEnv.AWS_BUCKET_NAME;
  const client = getS3Client();

  await client.send(new PutObjectCommand({
    Bucket:       bucketName,
    Key:          input.key,
    Body:         input.body,
    ContentType:  input.contentType,
    CacheControl: input.cacheControl ?? DEFAULT_CACHE_CONTROL
  }));

  return {
    key: input.key,
    url: getPublicAssetUrl(input.key)
  };
}
```

### Why the default cache header is `immutable`

`public, max-age=31536000, immutable` (1 year, never revalidate) is only safe **because keys change when content changes**. The contract: if you upload new content under the same key, browsers and CloudFront edge caches will serve stale content for up to a year. So:

- ✅ Use a content-derived hash, parent-entity ID + artifact ID, or fresh ULID in the key.
- ❌ Never overwrite a key in place. Generate a new one.

If you genuinely need mutable content under a stable key (e.g. user avatar at `users/<id>/avatar.png` where the URL is referenced from many places), pass an explicit `cacheControl` like `"public, max-age=300"` and budget for the staleness — or generate a new key on every upload and persist the latest URL on the user row.

### Why `Body` is `Uint8Array`

The S3 SDK accepts `string | Uint8Array | Buffer | Readable`. `Uint8Array` is the lowest-common-denominator that works in both Node and edge runtimes without a coercion step, and `Buffer` already extends it. Use it as the canonical input type for the function signature, even when the caller is in Node.

---

## The CloudFront URL builder

```ts
export function getPublicAssetUrl(key: string): string {
  const encodedKey = encodeKeyForUrl(key);
  const cloudFrontBaseUrl = normalizeCloudFrontBaseUrl(serverEnv.AWS_CLOUDFRONT_URL);
  return `${cloudFrontBaseUrl}/${encodedKey}`;
}

function encodeKeyForUrl(key: string): string {
  return key.split("/").map(encodeURIComponent).join("/");
}

function normalizeCloudFrontBaseUrl(value: string): string {
  const trimmed = value.trim().replace(/^\/+/, "");
  const withProtocol = /^https?:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;
  return withProtocol.replace(/\/+$/g, "");
}
```

### Why per-segment encoding

`encodeURIComponent` on the whole key would escape the `/` separators and break the path. Splitting on `/`, encoding each segment, and rejoining preserves the path structure while still escaping spaces, parens, and unicode in filenames. The CloudFront origin maps the URL path to the S3 key 1:1 — get this wrong and you'll see 403s with no useful error.

### Why `normalizeCloudFrontBaseUrl` exists

`AWS_CLOUDFRONT_URL` is operator-supplied; it might come in as `d1234.cloudfront.net`, `https://d1234.cloudfront.net`, `https://d1234.cloudfront.net/`, or `//d1234.cloudfront.net`. The normalizer makes all of these produce the same final URL. **Don't replicate this logic at call sites** — always go through `getPublicAssetUrl`.

---

## Key conventions

Use `/`-segmented, human-readable keys with three rules:

```
<topNamespace>/<entityId>/<artifactKind>/<artifactId>.<ext>

users/<userId>/avatar/<hash>.png
articles/<articleId>/cover/<imageId>.jpg
exports/<exportId>.zip
system/static/<filename>
```

1. **Start with a top-level namespace** (`users/`, `articles/`, `system/`, etc.). Prevents key collisions between domains and makes IAM bucket policies easier to write per-prefix.
2. **Use IDs, not slugs.** Slugs change; ObjectIds / ULIDs don't. A renamed entity shouldn't move its assets — and asset-URL changes invalidate caches everywhere they're embedded.
3. **End with an extension.** CloudFront and browser tooling use it for content-type sniffing fallback. Don't rely on `Content-Type` alone.

---

## Hard rules

- **Never** instantiate `new S3Client(...)` outside `getS3Client()`. Duplicate clients bypass the IAM-fallback contract.
- **Never** expose raw `s3://` URIs or pre-signed S3 URLs to clients — the bucket is private. Always go through `getPublicAssetUrl`.
- **Never** overwrite a key under the default `immutable` cache header. Generate a new key for new content.
- **Never** hardcode the CloudFront URL in feature code. Read `serverEnv.AWS_CLOUDFRONT_URL` (via `getPublicAssetUrl`).
- **Never** skip `encodeKeyForUrl` — naive `encodeURIComponent(wholeKey)` will escape `/` and produce a broken URL.
- **Never** read or write to a bucket other than `serverEnv.AWS_BUCKET_NAME` from this codebase. If multi-bucket support is genuinely needed, add a new env var and a new uploader function — don't parameterize this one.
