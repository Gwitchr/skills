# Image / asset storage — Reference

Detailed specs for the upload-flow patterns in [SKILL.md](SKILL.md). For the underlying S3 + CloudFront primitives (`uploadObjectToS3`, `getPublicAssetUrl`, `getS3Client` with IAM fallback, env schema, cache header), see [auth-stack/storage-s3.md](../auth-stack/storage-s3.md). This file does not duplicate them.

## File layout

A typical project organizes the upload pieces like this:

| Concern                          | Path                                                |
| -------------------------------- | --------------------------------------------------- |
| S3 client + upload + URL builder | `<server>/lib/storage/s3.ts`                        |
| Data-URL parser                  | `<server>/lib/storage/dataUrl.ts`                   |
| Filename / segment sanitizers    | `<server>/lib/storage/sanitize.ts`                  |
| Domain upload server fn          | `<server>/lib/<domain>/uploadAsset.ts`              |
| AI-generation route              | `<routes>/services/generate/<kind>.ts`              |
| AI-upload-to-S3 route            | `<routes>/services/storage/<kind>.ts`               |
| Asset content / metadata helpers | `<server>/lib/assets/content.ts`                    |
| Display component                | `<components>/atoms/AssetPreview.tsx`               |
| Upload tests                     | `<server>/lib/<domain>/uploadAsset.test.ts`         |

Filenames are suggestive. Match the conventions in your project's structure (see [components-hierarchy](../components-hierarchy/SKILL.md) and [zod-prisma-tanstack](../zod-prisma-tanstack/SKILL.md) for layering rules).

---

## Key schemas — concrete examples

### User-uploaded asset

```
assets/<ownerId>/<assetId>/<sanitized-filename>.<ext>
```

- `<ownerId>` and `<assetId>` are Mongo ObjectIds (24-char hex).
- `<sanitized-filename>` comes from `sanitizeFileName(data.fileName)` (lowercase, hyphenated, length-capped).
- `<ext>` is derived from the validated MIME, never from the original filename.

### AI-generated, batched

```
generated/<ownerId>/<batchStamp>/<sanitized-prompt>-<imageIndex>-<uuid>.<ext>
```

- `batchStamp = new Date().toISOString().replace(/[:.]/g, "-")` — sortable, filesystem-safe.
- `<sanitized-prompt>` comes from `sanitizePathSegment(prompt, "image")` (caps at 80 chars).
- `<imageIndex>` is the zero- or one-based position within the batch (be consistent across the codebase).
- `<uuid>` is `crypto.randomUUID()` — prevents collisions when a single prompt produces multiple images.

### Avatar (mutable — needs short cache header)

```
users/<userId>/avatar/<contentHash>.<ext>
```

A content-derived hash (e.g. first 16 chars of SHA-256 of the bytes) makes the URL stable for identical content but unique on change. Combined with the default `immutable` cache header, this is a content-addressed mutable surface.

---

## Sanitizers — copy-paste-ready

```ts
// <server>/lib/storage/sanitize.ts

// Full filename — strips existing extension; extension is re-derived from MIME.
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

// Single path segment (id, prompt slug, etc.) — no dots allowed.
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

**Test cases worth covering:**

- Empty input → `"file"` / `fallback`.
- All-symbol input (`"---"`, `"   "`, `"@#$"`) → fallback.
- Unicode (`"café résumé.pdf"`) → ASCII-folded slug (depends on your slugifier — these helpers use a hyphen-replace strategy, not transliteration; if you need transliteration, swap to a slugify lib).
- Path-traversal attempts (`"../../etc/passwd"`) → harmless slug.
- Length explosion (10 KB filename) → capped at the length limit.

---

## MIME → extension tables

```ts
// Document / asset uploads (bitmap-only by default — SVG is opt-in per the SVG-XSS rule in SKILL.md)
export const MIME_TO_EXTENSION = {
  "image/png":       "png",
  "image/jpeg":      "jpg",
  "image/webp":      "webp",
  "application/pdf": "pdf",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx"
  // "image/svg+xml": "svg",  // ← only after wiring a server-side SVG sanitizer (see SKILL.md)
} as const;

// Image-only uploads (bitmap-only by default)
export const ALLOWED_IMAGE_MIME_TYPES = [
  "image/png",
  "image/jpeg",
  "image/webp"
  // "image/svg+xml",  // ← only after wiring a server-side SVG sanitizer (see SKILL.md)
] as const;
```

Suggested per-route caps:

| Route                  | Max size | Max items per batch |
| ---------------------- | -------- | ------------------- |
| Document / asset       | 20 MB    | 1                   |
| Image upload           | 12 MB    | 1                   |
| AI batch upload        | 12 MB    | 200                 |
| Avatar                 | 2 MB     | 1                   |

The numbers are starting points — adjust to your bandwidth budget.

---

## Asset model — generic shape

```prisma
model Asset {
  id        String    @id @default(auto()) @map("_id") @db.ObjectId
  ownerId   String    @db.ObjectId             // who owns / uploaded
  source    String    @default("user_uploaded") // "user_uploaded" | "ai_generated" | "system_imported"
  fileUrl   String?                              // CloudFront URL — null until upload completes
  metadata  Json?                                // optional metadata blob (prompt, dimensions, etc.)
  createdAt DateTime  @default(now())
  updatedAt DateTime  @updatedAt

  @@index([ownerId])
  @@index([source])
}
```

**Per the auth-stack/prisma-mongo.md rules:** every relation field needs an explicit `@@index`. The two indexes above cover the two common query patterns (assets-by-owner, assets-by-source).

`fileUrl` is **`String?`** because it's `null` between row creation and S3 upload completion. A row with `fileUrl == null` is a valid recoverable state — the upload either failed or is still in flight.

If your domain needs richer linkage (assets attached to projects, posts, conversations, etc.), keep `Asset` lean and add a join model or a foreign key on the consuming entity:

```prisma
model Post {
  id              String  @id @default(auto()) @map("_id") @db.ObjectId
  // …
  coverAssetId    String? @db.ObjectId
  coverAsset      Asset?  @relation(fields: [coverAssetId], references: [id])

  @@index([coverAssetId])
}
```

Don't bake business taxonomy (project, phase, round, status) into `Asset` itself — keep it a generic upload primitive.

---

## Metadata JSON shapes

`Asset.metadata` is `Json?`. Keep the shapes documented in a TS union alongside the parser. Example:

```ts
// <server>/lib/assets/content.ts
export type AssetMetadata =
  | { type: "image";           width: number; height: number }
  | { type: "generated_image"; prompt: string; model: string; index: number }
  | { type: "document";        pageCount: number };

export function parseAssetMetadata(value: unknown): AssetMetadata | null {
  if (!isRecord(value) || typeof value.type !== "string") return null;
  // …discriminate on `value.type`, validate fields, return narrowed type or null
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
```

Or use Zod and pick whichever validation pattern matches the rest of your project (`zod-prisma-tanstack` skill discusses the trade-off).

**Rules of thumb:**

- Always return `null` from the parser instead of throwing — display components can fall back to a generic "unknown asset" view.
- Add new metadata variants as new union arms; don't loosen existing ones.
- Don't put binary data in `metadata`. Anything large enough to matter belongs in S3.

---

## Upload server fn — full template with auth gate

```ts
import { createServerFn } from "@tanstack/react-start";
import { z } from "zod";
import { prisma } from "<server>/lib/prisma";
import { uploadObjectToS3 } from "<server>/lib/storage/s3";
import { parseFileDataUrl } from "<server>/lib/storage/dataUrl";
import { sanitizeFileName } from "<server>/lib/storage/sanitize";
import { requireAuthenticatedUser } from "<server>/lib/auth/require";
import { isAdmin } from "<server>/lib/auth/role";

const ALLOWED_MIME = [
  "image/png",
  "image/jpeg",
  "image/webp",
  "application/pdf"
] as const;

const MIME_TO_EXT = {
  "image/png":  "png",
  "image/jpeg": "jpg",
  "image/webp": "webp",
  "application/pdf": "pdf"
} as const satisfies Record<(typeof ALLOWED_MIME)[number], string>;

const MAX_SIZE_BYTES = 20 * 1024 * 1024; // 20 MB

const inputSchema = z.object({
  parentId:    z.string().min(1),                          // entity this asset attaches to
  fileName:    z.string().trim().min(1),
  fileDataUrl: z.string().min(1)
});

const UPLOADABLE_PARENT_STATES = ["pending", "in_progress", "in_review"] as const;

export const uploadAsset = createServerFn({ method: "POST" })
  .validator(inputSchema.parse)
  .handler(async ({ data }) => {
    // 1. Auth + role gate
    const user = await requireAuthenticatedUser();
    if (!isAdmin(user.role)) throw new Error("Forbidden.");

    // 2. Validate target entity is in an uploadable state
    const parent = await prisma.parent.findUnique({
      where:  { id: data.parentId },
      select: { id: true, state: true, ownerId: true }
    });
    if (!parent) throw new Error("Parent not found.");
    if (!UPLOADABLE_PARENT_STATES.includes(parent.state as typeof UPLOADABLE_PARENT_STATES[number])) {
      throw new Error(`Parent is not in an uploadable state (currently: ${parent.state}).`);
    }

    // 3. Parse + 4. validate MIME + size
    const parsed = parseFileDataUrl(data.fileDataUrl);
    if (!ALLOWED_MIME.includes(parsed.mimeType as typeof ALLOWED_MIME[number])) {
      throw new Error(`Unsupported file type: ${parsed.mimeType}`);
    }
    if (parsed.data.byteLength > MAX_SIZE_BYTES) {
      throw new Error("File exceeds size limit.");
    }

    // 5. Sanitize
    const safeName = sanitizeFileName(data.fileName);
    const ext = MIME_TO_EXT[parsed.mimeType as keyof typeof MIME_TO_EXT];

    // 6. Create the row first
    const asset = await prisma.asset.create({
      data: {
        ownerId: parent.ownerId,
        source:  "admin_uploaded"
      },
      select: { id: true }
    });

    // 7. Construct the key
    const key = ["assets", parent.id, asset.id, `${safeName}.${ext}`].join("/");

    // 8. Upload
    const { url } = await uploadObjectToS3({
      key,
      body:        parsed.data,
      contentType: parsed.mimeType
    });

    // 9. Persist the URL
    await prisma.asset.update({
      where:  { id: asset.id },
      data:   { fileUrl: url },
      select: { id: true }
    });

    return { asset: { id: asset.id, fileUrl: url } };
  });
```

The `parent` model and its `state` enum are illustrative — substitute your domain's parent entity.

---

## AI image flow — concrete shape

Three endpoints, three responsibilities:

### 1. Generate (server-side, expensive, cached)

```
POST /services/generate/<kind>

Request:  { prompt: string, model?: string, count?: number, ...params }
Response: { items: Array<{ prompt, index, imageDataUrl }> }
```

- Calls the image model via your AI SDK of choice.
- Caches responses in Redis (or your project's cache layer) with a short TTL (~5 min) keyed by `sha256(prompt + model + params)`.
- Rate-limited per IP (e.g. 20/min). Generation is the expensive operation.
- Returns base64 data URLs; the client decides which to keep.

### 2. Upload (server-side, cheap, no cache)

```
POST /services/storage/<kind>

Request:  { ownerId: string, items: Array<{ prompt, index, imageDataUrl }> }
Response: { uploads: Array<{ key, url, prompt, index }> }
```

- Runs the canonical upload flow per item: parse → validate MIME + size → sanitize → key → upload.
- No DB writes here — this route is just the storage layer.
- Higher rate limit than generation (storage is cheap).

### 3. Persist (server fn, attaches to a domain entity)

```
createAssetsFromUploads({ parentId, uploads })

Behavior: creates Asset rows with `source: "ai_generated"`, `fileUrl`, and
          `metadata: { type: "generated_image", prompt, index }`.
          May advance the parent entity's state (e.g. "generating" → "in_review").
```

This is where AI-generated assets become first-class rows that the rest of the app can query.

**Why three steps:**

- Generation can fan out (`count: 4`) but only some outputs get kept. Don't write discarded ones to S3.
- Generation cache (prompt-keyed) is independent of storage key (owner + asset id). Mixing them locks the cache.
- Rate limits differ by an order of magnitude.
- Each step has a clean failure boundary: a generation failure doesn't leave an S3 orphan; a storage failure doesn't leave an unsynced DB state.

---

## Display

```tsx
// <components>/atoms/AssetPreview.tsx
import { parseAssetMetadata } from "<server>/lib/assets/content";

export function AssetPreview({ fileUrl, metadata, alt }: Props) {
  if (fileUrl) return <img src={fileUrl} alt={alt} />;

  const parsed = parseAssetMetadata(metadata);
  if (parsed) return <MetadataPreview parsed={parsed} />;

  return <EmptyState />;
}
```

The CloudFront URL goes straight into `src`. **No proxy, no signed query string.** If your project uses `next/image` or another optimized image component, route the CloudFront URL through it for responsive sizes — but the persisted URL is still the CloudFront one.

For SVGs specifically: rendering via `<img src>` is the safe path. The browser sandboxes any inline `<script>` in the SVG. Never use `dangerouslySetInnerHTML` for user-uploaded SVGs.

---

## Test-mocking pattern

For an upload server fn, mock at four boundaries:

```ts
// <server>/lib/<domain>/uploadAsset.test.ts
vi.mock("<server>/lib/auth/require", () => ({
  requireAuthenticatedUser: vi.fn(async () => ({ id: "user_1", role: "admin" }))
}));

vi.mock("<server>/lib/storage/s3", () => ({
  uploadObjectToS3: vi.fn(async ({ key }) => ({
    key,
    url: `https://cdn.example.test/${key}`
  }))
}));

vi.mock("<server>/lib/prisma", () => ({
  prisma: {
    parent: { findUnique: vi.fn() },
    asset:  { create: vi.fn(), update: vi.fn() }
  }
}));
```

Coverage groups every upload server fn should have:

1. **Authorization.** Unauthenticated → throws. Wrong role → throws.
2. **Parent state validation.** Parent not found, parent in non-uploadable state.
3. **MIME validation.** Unsupported MIME → throws with the MIME in the message.
4. **Size validation.** Just over the cap → throws.
5. **Data-URL parsing.** Malformed data URL → throws.
6. **Key construction.** Sanitized filename, ID segments, extension from MIME.
7. **CloudFront URL persistence.** `fileUrl` written to the row equals the upload result `url`.
8. **Returned payload shape.** Matches the route contract.

Assert the **exact key string** passed to `uploadObjectToS3` — that's the contract that ties this layer to consumers (key prefixes are referenced for IAM bucket policies, lifecycle rules, etc.).

---

## What's intentionally absent

The S3 + CloudFront stack in this project family **deliberately does not provide**:

- **Presigned URLs** (PUT or GET). Everything is server-proxied.
- **CloudFront signed URLs / signed cookies.** All assets are public via CloudFront.
- **Cache invalidation** (`CreateInvalidation` API). Keys are content-addressed; new content = new key.
- **Image processing.** No resizing, thumbnailing, format conversion, EXIF stripping. `<img>` and CSS `object-fit` cover most needs; deliberate processing belongs in a separate worker, not the upload path.
- **A `deleteObject` helper.** The default cache is `immutable` for a year — deletes don't free CloudFront cache slots immediately, and the design assumes assets are not deleted in the normal flow. If you need deletion (compliance, GDPR), add a deliberate flow with cache-eviction and key-rotation handling — not a one-liner.
- **Direct-to-S3 uploads from the browser.** Same reason as no presigned URLs — every upload runs through your auth + validation + sanitization layer.

If a task seems to need one of these, **raise it before adding** — the absence is a deliberate design choice, not an oversight.
