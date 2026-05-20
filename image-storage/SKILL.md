---
name: image-storage
description: File-upload patterns layered on top of an S3 + CloudFront storage primitive, server-proxied uploads from data URLs, MIME and size validation, filename sanitization, content-addressed key construction, the create-row-first ordering, and AI-generated image flows. Use when adding a file or image upload route, integrating AI-generated images into permanent storage, building an admin-content upload flow, or designing key conventions for user-supplied or generated assets.
---

# Image / asset storage patterns

Patterns for safely accepting file uploads in a server-proxied flow with a private S3 bucket fronted by CloudFront. The conventions here are deliberately narrow:

- **Server-proxied uploads only.** Clients send base64 data URLs to your server; your server validates, sanitizes, and writes to S3. **No presigned PUT/GET URLs, no signed CloudFront cookies, no client-direct uploads.**
- **Content-addressed, immutable keys.** New content gets a new key. **No overwriting, no cache invalidation.**
- **No image processing.** No resizing, thumbnailing, format conversion, EXIF stripping. (Add deliberately, with the user's sign-off, the absence is a design choice.)

> **Stack assumed.** Prisma + MongoDB (`relationMode = "prisma"`), AWS SDK v3 (`@aws-sdk/client-s3`), TanStack Start server functions (or any framework that supports server-side handlers), Zod v4 for input validation. **Builds on the [auth-stack skill](../auth-stack/SKILL.md)**, `getS3Client()`, `uploadObjectToS3()`, `getPublicAssetUrl()`, `requireAuthenticatedUser()`, the IAM-fallback contract, and the env schema all come from there. This skill adds the **upload-flow patterns** that sit above those primitives.

> **Notation.** `<server>/lib/storage/`, `<server>/lib/<domain>/`, `<routes>/services/`, `<components>/...` are placeholders. Resolve to the project's actual paths and aliases. Helper names (`uploadObjectToS3`, `getPublicAssetUrl`, `requireAuthenticatedUser`, `parseFileDataUrl`, `sanitizeFileName`, `sanitizePathSegment`) are suggested conventions, rename to match your project's style.

> **Precedence.** Project rules (ESLint / Biome / `tsconfig` / `CLAUDE.md` / `AGENTS.md` / contributing guides) win over this skill.

---

## Quick start

```ts
import { uploadObjectToS3 } from "<server>/lib/storage/s3";

const { key, url } = await uploadObjectToS3({
  key:         `assets/${ownerId}/${assetId}/${safeName}.${ext}`,
  body:        bytes,                 // Uint8Array
  contentType: "image/png"            // from validated MIME whitelist
});
// `url` → CloudFront URL. Persist to your row's `fileUrl` field.
```

For the `uploadObjectToS3` / `getPublicAssetUrl` primitives and the IAM-fallback contract, see [auth-stack/storage-s3.md](../auth-stack/storage-s3.md). This skill assumes both are wired up.

---

## The canonical upload flow (server-only)

A new upload moves through these steps, in this exact order:

1. **Auth + permission gate.** Most upload endpoints are gated to authenticated users (and often a specific role). Use `requireAuthenticatedUser()` from the auth-stack skill, then add a role check if needed.
2. **Validate the target entity** (e.g. "is this asset still in a state that accepts uploads?"). Reject early.
3. **Parse the input data URL** → `{ mimeType, data: Uint8Array }`. Reject any MIME not on the per-route whitelist.
4. **Enforce size limits** against `data.byteLength`. Reject before the network round-trip to S3.
5. **Sanitize user-controlled segments** of the eventual key (filename, prompt slug, etc.).
6. **Create the DB row first** to get a stable ID. The ID becomes part of the S3 key.
7. **Construct the key** using sanitized inputs and the row's ID.
8. **`uploadObjectToS3({ key, body, contentType })`**, single writer, IAM fallback, immutable cache header.
9. **Update the row with the CloudFront URL** (`fileUrl`). Now consumers can render it.

Steps 6 → 9 are the **create-row-first** pattern and are non-negotiable when keys embed the row's ID:

- ✅ Row exists with `fileUrl: null`, then key contains the row's `id`, then S3 has the bytes, then `fileUrl` is set.
- ❌ Don't generate a UUID up front and use it as both the row's `id` and the key segment, that fights Mongo's `ObjectId` default and creates a parallel ID space.
- ❌ Don't upload first and create the row from the result, if the row creation fails, you have an orphan in S3 you can't easily clean up (since this skill doesn't provide a `deleteObject` helper).

A dangling row with `fileUrl: null` is the recoverable state, the row can be deleted or retried.

---

## Data-URL parsing

Clients send `data:<mime>;base64,<base64>` strings. Parse them on the server:

```ts
// <server>/lib/storage/dataUrl.ts
const DATA_URL_PATTERN = /^data:([^;,]+);base64,([A-Za-z0-9+/=]+)$/;

export function parseFileDataUrl(input: string): { mimeType: string; data: Uint8Array } {
  if (typeof input !== "string") throw new Error("Invalid data URL.");
  const match = DATA_URL_PATTERN.exec(input);
  if (!match) throw new Error("Invalid data URL.");

  const mimeType = match[1].trim().toLowerCase();
  const base64 = match[2];

  // Use atob in environments that support it; Buffer.from in Node.
  const binary = typeof atob === "function" ? atob(base64) : Buffer.from(base64, "base64").toString("binary");
  const data = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) data[i] = binary.charCodeAt(i);

  return { mimeType, data };
}
```

Two rules:

- **Reject anything not on the route's MIME whitelist** *before* allocating the byte array on a real upload, for very large bodies, reject by inspecting the data-URL prefix first and only decode after the MIME passes.
- **Derive the file extension from the validated MIME**, never from the original filename. A user could upload `payload.exe` renamed to `image.png`; trusting the filename means trusting the user.

---

## Sanitizers

Two helpers with different rules, full filenames allow `.`, single path segments don't.

```ts
// <server>/lib/storage/sanitize.ts

// Full filename, strips existing extension; extension is re-derived from MIME.
export function sanitizeFileName(raw: string): string {
  const trimmed = raw.trim();
  if (!trimmed) return "file";
  const withoutExtension = trimmed.replace(/\.[^.]+$/, "");
  const sanitized =
    withoutExtension
      .toLowerCase()
      .replace(/[^a-z0-9._-]+/g, "-")
      .replace(/-+/g, "-")
      .replace(/^-+|-+$/g, "") || "file";
  return sanitized.slice(0, 120);
}

// Single path segment (id, prompt slug, etc.), no dots allowed.
export function sanitizePathSegment(value: string, fallback: string): string {
  const sanitized = value
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9-]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-+|-+$/g, "");
  return (sanitized || fallback).slice(0, 80);
}
```

Why two:

- **Filenames** can contain `.` (e.g. `report.v2.draft`). The function strips only the trailing extension; the rest is allowed.
- **Path segments** are consumed by the URL builder, which uses `/` as the separator. A `.` in a path segment is fine for S3 but can confuse path-based parsing downstream, keep them out.

Both functions: lowercase, hyphenate non-alphanumerics, collapse repeats, trim leading/trailing hyphens, length-cap. The fallback (`"file"` / caller-supplied) prevents empty segments after sanitization (a user supplying `"---"` as a filename would otherwise produce `""`).

---

## Key conventions

Hierarchical, ID-based, lowercase, hyphenated. Three rules:

1. **Top-level namespace.** `assets/`, `users/`, `system/`, etc. Prevents key collisions between domains and lets you scope IAM bucket policies per prefix.
2. **Use IDs, not slugs.** Slugs change; ObjectIds don't. A renamed entity shouldn't move its assets, and a moved asset URL invalidates everywhere it's embedded.
3. **End with the validated extension** (from MIME). Tooling sniffs by extension when `Content-Type` is missing or wrong.

Add a `crypto.randomUUID()` segment when **name collisions are possible within a single batch**, for example, AI-generated images where multiple outputs from one prompt would otherwise share a key.

```
assets/<ownerId>/<assetId>/<sanitized-name>.<ext>
users/<userId>/avatar/<hash>.<ext>
generated/<ownerId>/<batchStamp>/<sanitized-prompt>-<index>-<uuid>.<ext>

# batchStamp is `new Date().toISOString().replace(/[:.]/g, "-")`, sortable, filesystem-safe.
```

---

## MIME and size limits

Per-route whitelists. Keep them tight; widen deliberately. **Bitmap formats only by default**, SVG is opt-in (see SVG note below).

| Flow              | Suggested cap | Suggested MIME whitelist                                |
| ----------------- | ------------- | ------------------------------------------------------- |
| Document / asset  | 20 MB         | `image/png`, `image/jpeg`, `application/pdf`, Office docs as needed |
| Image-only upload | 12 MB         | `image/png`, `image/jpeg`, `image/webp`                 |
| Avatar            | 2 MB          | `image/png`, `image/jpeg`, `image/webp`                 |

Exact numbers depend on your bandwidth budget and storage policy, the point is that **every upload route has a documented cap and whitelist**, not that 20 MB is the right number.

**SVG is opt-in, not default.** SVGs can carry inline JavaScript, foreign-object HTML, and external resource loads, they're an XSS vector when accepted from untrusted users. Allow `image/svg+xml` only when (a) the upload source is trusted (admin tooling, internal vector assets), or (b) you run uploaded SVGs through a sanitizer like [DOMPurify](https://github.com/cure53/DOMPurify) (server-side: `isomorphic-dompurify`) with `{ USE_PROFILES: { svg: true, svgFilters: true } }` before write. If you do accept SVG, render via `<img src>` (which sandboxes the script context), never via `dangerouslySetInnerHTML` or inline `<svg>` insertion.

---

## Server-fn template (Zod-validated, auth-gated)

```ts
import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { prisma } from "<server>/lib/prisma";
import { uploadObjectToS3 } from "<server>/lib/storage/s3";
import { parseFileDataUrl } from "<server>/lib/storage/dataUrl";
import { sanitizeFileName } from "<server>/lib/storage/sanitize";
import { requireAuthenticatedUser } from "<server>/lib/auth/require";

const ALLOWED_MIME = ["image/png", "image/jpeg", "image/webp"] as const;
type AllowedMime = (typeof ALLOWED_MIME)[number];

const MIME_TO_EXT: Record<AllowedMime, string> = {
  "image/png": "png",
  "image/jpeg": "jpg",
  "image/webp": "webp"
};

const MAX_SIZE_BYTES = 12 * 1024 * 1024; // 12 MB

const inputSchema = z.object({
  fileName:    z.string().trim().min(1),
  fileDataUrl: z.string().min(1)
});

export const uploadAsset = createServerFn({ method: "POST" })
  .validator(inputSchema.parse)
  .handler(async ({ data }) => {
    const user = await requireAuthenticatedUser();

    const parsed = parseFileDataUrl(data.fileDataUrl);
    if (!ALLOWED_MIME.includes(parsed.mimeType as AllowedMime)) {
      throw new Error(`Unsupported file type: ${parsed.mimeType}`);
    }
    if (parsed.data.byteLength > MAX_SIZE_BYTES) {
      throw new Error("File exceeds size limit.");
    }

    const ext = MIME_TO_EXT[parsed.mimeType as AllowedMime];
    const safeName = sanitizeFileName(data.fileName);

    // Step 1: create the row to claim an ID.
    const asset = await prisma.asset.create({
      data:   { ownerId: user.id, source: "user_uploaded" },
      select: { id: true }
    });

    // Step 2: build the key and upload.
    const key = ["assets", user.id, asset.id, `${safeName}.${ext}`].join("/");
    const { url } = await uploadObjectToS3({
      key,
      body:        parsed.data,
      contentType: parsed.mimeType
    });

    // Step 3: persist the CloudFront URL.
    await prisma.asset.update({
      where:  { id: asset.id },
      data:   { fileUrl: url },
      select: { id: true }
    });

    return { asset: { id: asset.id, fileUrl: url } };
  });
```

This template encodes every rule in this skill: Zod validation, auth gate, parse + MIME + size check, sanitization, create-row-first, key construction, single upload writer, persist URL. **Use it as a starting point**; the per-route knobs are the MIME whitelist, the size cap, the role check, and the key prefix.

---

## Retrieval

Persist the CloudFront URL directly on the row (`fileUrl: String?`) and render it as `<img src={fileUrl}>`. **Do not** generate URLs per-request, they're pure functions of the key, and the key never changes after upload.

If you ever need to re-derive the S3 key from a CloudFront URL (rare, since the immutable-key design avoids deletes and signing), parse the URL and strip the CloudFront base. **Don't store the key separately**, `fileUrl` is the canonical persisted form.

---

## AI-generated images, the same flow, applied

A common applied pattern: client requests AI generation, gets back base64 images, then uploads the chosen ones to S3 via a separate route. Three steps:

1. **Generate.** A `POST /services/generate/<kind>` endpoint calls your image model (OpenAI, Replicate, your own) and returns base64 data URLs. Cache responses in Redis (or your project's cache) keyed by `sha256(inputs)` with a short TTL, image generation is expensive and prompts often repeat. Rate-limit by IP.
2. **Upload.** The client picks one or more outputs and POSTs them to a storage route (e.g. `POST /services/storage/<kind>`) with `{ ownerId, items: [{ prompt, index, dataUrl }, ...] }`. The route runs the canonical upload flow per item: parse → validate → sanitize → key → upload. Returns `{ uploads: [{ key, url, ... }] }`.
3. **Persist.** A separate server fn (or the upload route itself) creates `Asset` rows with `source: "ai_generated"`, `fileUrl`, and a `metadata` blob like `{ prompt, index }`. The metadata lets you regenerate or attribute the asset later.

Why split generation and upload into two routes:

- **The generation step doesn't always end in an upload.** Users see N options, pick M ≤ N. You shouldn't write the discarded ones to S3.
- **The cache key for generation** (prompt + model + parameters) is independent from the storage key (owner + asset id + name). Mixing them locks the cache.
- **Rate limits and quotas differ.** Generation is expensive per call; storage is cheap. Different SLOs, different limiters.

Add a `generated/<ownerId>/<batchStamp>/<sanitized-prompt>-<index>-<uuid>.<ext>` key for the upload step, the UUID prevents collisions when a single batch contains multiple images per prompt.

---

## Don't

- ❌ Generate presigned PUT or GET URLs. Out of pattern; everything is server-proxied + public CloudFront.
- ❌ Add CloudFront cache invalidation. Keys are content-addressed; new content = new key. If you genuinely need a `CreateInvalidation` flow, that's a different design, consult before adding.
- ❌ Trust client-provided MIME or filename without re-validating + sanitizing. Both can be lies.
- ❌ Store the S3 key separately from `fileUrl`. Only `fileUrl` is persisted; the key is derivable but rarely needed.
- ❌ Upload before creating the DB row. The row's ID is part of the key; an orphaned object in S3 is harder to clean up than an orphaned row with `fileUrl: null`.
- ❌ Overwrite an existing key. Default cache header is `immutable`, overwrites serve stale content for up to a year.
- ❌ Add image resizing, thumbnailing, format conversion, or EXIF stripping silently. Each is a deliberate design choice; raise it before adding.
- ❌ Render SVGs via `dangerouslySetInnerHTML`. Use `<img src>` so the browser sandboxes the SVG's script context.

---

## Reference

See [REFERENCE.md](REFERENCE.md) for: the asset/artifact Prisma model, content-metadata JSON shapes, the test-mocking pattern for upload server fns, and the explicit list of features this skill intentionally omits.
