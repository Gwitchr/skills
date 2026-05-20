# Editor Setup (Tiptap)

Detailed guidance for the editor in [SKILL.md](SKILL.md). The path is **Tiptap v3 + markdown**. Examples are framework-agnostic, swap project-specific helpers (storage SDK, server entry points) for whatever the host project uses. Schema-side guidance (MongoDB) lives in `SKILL.md`.

## Why ProseMirror (Tiptap) over hand-rolled `contenteditable`

Browser `contenteditable` will appear to work for a day, then break on:

- **IME composition** (Japanese, Chinese, Korean), selections collapse mid-character.
- **Paste from Word / Google Docs / Notion**, random spans, inline styles, `<b>` vs `<strong>`, smart-quote drift.
- **Undo/redo**, the native browser stack diverges from your model the instant you mutate the DOM.
- **Mobile**, Safari caret jumps, Android Gboard suggestions, Firefox `<br>` quirks.
- **Lists, blockquotes, nested formatting**, every browser disagrees.
- **Accessibility**, screen-reader announcements, focus management, `aria-*` lifecycle.

ProseMirror solves all of this with a controlled document model + transactions. Tiptap is the React-friendly wrapper.

---

## Tiptap v3 minimal setup

Install:

```bash
pnpm add @tiptap/react @tiptap/starter-kit @tiptap/extension-placeholder \
  @tiptap/extension-link @tiptap/extension-image @tiptap/extension-bubble-menu \
  tiptap-markdown
```

Component skeleton (illustrative, adapt to project conventions / the components-hierarchy skill):

```tsx
import { useEditor, EditorContent, BubbleMenu } from "@tiptap/react";
import StarterKit from "@tiptap/starter-kit";
import Placeholder from "@tiptap/extension-placeholder";
import Link from "@tiptap/extension-link";
import Image from "@tiptap/extension-image";
import { Markdown } from "tiptap-markdown";

interface ArticleEditorProps {
  initialMarkdown: string;
  onChange: (markdown: string) => void;
}

export function ArticleEditor({ initialMarkdown, onChange }: ArticleEditorProps) {
  const editor = useEditor({
    extensions: [
      StarterKit,
      Placeholder.configure({ placeholder: "Write your story…" }),
      Link.configure({
        openOnClick: false,
        autolink: true,
        HTMLAttributes: { rel: "noopener noreferrer", target: "_blank" }
      }),
      Image,
      Markdown.configure({ html: false, linkify: true, breaks: false })
    ],
    content: initialMarkdown,
    onUpdate: ({ editor }) => onChange(editor.storage.markdown.getMarkdown())
  });

  return (
    <>
      {editor && (
        <BubbleMenu editor={editor}>
          {/* bold / italic / link / H2 / H3 buttons */}
        </BubbleMenu>
      )}
      <EditorContent editor={editor} />
    </>
  );
}
```

**Round-trip rule:** read with `editor.storage.markdown.getMarkdown()`, write by passing markdown to `content`. Don't mix HTML and markdown loads in the same flow.

---

## Medium-like UX checklist

- **Bubble menu** on selection (`@tiptap/extension-bubble-menu`), bold, italic, link, H2, H3.
- **Slash menu** on `/` at line start, paragraph, headings, list, quote, image, divider. Use `@tiptap/suggestion` or copy Novel's implementation.
- **Floating "+" button** in the gutter for inserting blocks at empty lines.
- **Smart paste**, the markdown extension already linkifies and unwraps pasted prose; verify by pasting from Google Docs and Notion.
- **Image upload**, intercept paste/drop, upload via your storage layer, insert returned URL as markdown `![alt](url)`. Show inline progress placeholder. (See "Image upload flow" below.)
- **Autosave**, debounce ~1s, call a `saveDraft` server endpoint, show a subtle "Saved · just now" status. Never modals.
- **Typography**, Tailwind `@tailwindcss/typography` `prose` class on the editor surface; tune to match the published render so WYSIWYG actually means it.
- **Keyboard shortcuts**, StarterKit covers the basics. Add `Cmd+K` for link, `Cmd+Shift+K` to remove link.
- **Word count / read time**, show in the chrome, computed off the markdown string.
- **Accessibility**, set `aria-label` on the editor surface; ensure the bubble menu is keyboard-reachable; test with VoiceOver / NVDA.

---

## Markdown vs Tiptap-JSON storage trade-off

| Concern | Markdown | Tiptap JSON |
|---|---|---|
| Source of truth | ✅ Diffable, AI-friendly, portable | ❌ Schema versioning hurts |
| Custom blocks (callouts, embeds) | ❌ Awkward, needs MDX or directives | ✅ Natural, extension nodes |
| Pre-render to static HTML | ✅ Easy with `remark` / `rehype` | ⚠️ Possible but heavier, editor-specific |
| Migrate to another editor later | ✅ Trivial | ❌ Painful, schema lock-in |
| Diff-friendly version history | ✅ Plain text diffs work | ❌ JSON diffs are noisy |
| Real-time collaboration | ⚠️ Possible but coarse | ✅ First-class Y.js integration |

**Default to markdown.** Move to JSON only when custom block schemas dominate the content (e.g. a structured product page or Notion-style doc tool). When mixed, keep markdown canonical and store the JSON cache in `bodyJson`.

---

## MDX storage (technical / docs content)

When content needs live React components inline (interactive examples, custom callouts, demos), use MDX. Storage shape is identical to markdown, `body: String`, but the render pipeline differs:

- Server / build-time compile via `next-mdx-remote`, `@mdx-js/mdx`, `mdx-bundler`, or your framework's MDX loader.
- Pass a fixed component allowlist to the MDX renderer; **never** let authored MDX import arbitrary modules.
- For untrusted authors (e.g. user-generated content), MDX is a security risk, stick to markdown.

---

## Sanitization

Server-side render pipeline:

```
markdown
  → remark-parse
  → remark-gfm           (tables, strikethrough, task lists)
  → remark-rehype
  → rehype-sanitize      (default schema is a safe baseline)
  → rehype-stringify
```

`rehype-sanitize` with the default schema is XSS-safe out of the box. **Loosen only for explicit allowed tags** (e.g. `<iframe>` for known providers like YouTube/Vimeo, with `src` allowlists).

Specific risks to watch:

- **Protocol smuggling**: `javascript:`, `data:`, `vbscript:` URLs in `<a href>` and `<img src>`. Default schema blocks these, don't override without thinking.
- **Event-handler attributes**: `onClick`, `onError`, etc. Default schema strips them.
- **`rel="noopener noreferrer"`** on every external `<a target="_blank">`, set this in the link extension config and re-assert at render time.
- **Stored HTML**: if you ever store HTML as the source of truth (avoid), sanitize on **write** AND on **render**. Never trust the database.

---

## Image upload flow

1. Editor intercepts paste/drop event.
2. Insert a placeholder node with a temp id and a loading state.
3. Request a signed upload URL from the server (`POST /api/uploads/presign` or equivalent).
4. Upload directly to blob storage (S3 / R2 / GCS / Vercel Blob / Supabase Storage / etc.).
5. Replace the placeholder node's `src` with the final public URL.
6. On error, replace the placeholder with an error node and let the user retry.

**Strip EXIF and re-encode** on the worker side if the upload comes from an untrusted user, not the editor's job. EXIF can leak GPS/camera-serial data.

---

## Real-time collaboration (optional)

Tiptap integrates with **Y.js** (CRDT for conflict-free collab editing) via `@tiptap/extension-collaboration` and `@tiptap/extension-collaboration-cursor`. Pair with **Hocuspocus**, Tiptap's official Y.js server, for the transport. Self-hosted, batteries-included, runs on Node.

Persistence pattern: keep markdown / Tiptap JSON as the canonical store; treat the Y.js doc as ephemeral session state that flushes back to the canonical store on idle / disconnect.

---

## AI-assisted authoring (optional)

Tiptap exposes a command / transaction API that you wire to an LLM:

- **Inline completion** ("ghost text" suggestions on Tab), call your LLM provider on debounced typing, render the suggestion as a placeholder decoration via a custom Tiptap extension, accept on Tab.
- **Selection rewrite** ("improve writing", "translate", "shorten"), bind to bubble-menu actions; replace the selection with the LLM response via `editor.chain().insertContentAt(range, ...).run()`.
- **Slash commands** (`/summarize`, `/continue`), register as suggestion items in `@tiptap/suggestion`; call the LLM, insert returned content.

Keep the LLM call on the **server** (don't ship API keys); use streaming responses + `useTransition` to keep the editor responsive. Cite the response in the document if your editorial policy requires it (a footnote node, a metadata field, etc.).

---

## Localization in the editor

- One editor instance per locale row. Don't try to multiplex locales in one document.
- The editor never knows about translation, it reads/writes a single markdown / JSON string. Locale routing is the surrounding form's responsibility.
- For side-by-side translation UX, render two editor instances in a two-column layout; persist independently.
- For machine-translation-assisted workflows, fetch the translated draft into a fresh editor instance, don't try to "patch" an existing document with translation in place.
