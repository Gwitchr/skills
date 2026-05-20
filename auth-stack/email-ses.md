# Email (AWS SES)

Transactional and marketing email pipelines, the SES client with IAM fallback, and how to compose new senders.

## Overview

```
sender function (sendMagicLinkEmail, sendInviteEmail, …)
    │
    ├── compose: EmailBlock[] (heading / paragraph / cta / meta / divider)
    ├── render:  renderEmailLayout({ locale, preheader, blocks })
    │              → { html, text }
    └── send:    SendEmailCommand via getSesClient()
```

Three layers, each with a single source: a blocks module (block types and constructors), a layout module (the renderer), a senders module (one exported function per template + the `sendOne` primitive). Don't introduce a fourth layer.

---

## The SES client

```ts
// <server>/lib/email/ses.ts
import { SESClient, SendEmailCommand } from "@aws-sdk/client-ses";
import { serverEnv } from "<server>/lib/env.server";

function getSesClient() {
  const { AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY } = serverEnv;
  return new SESClient({
    region: serverEnv.AWS_REGION,
    credentials:
      AWS_ACCESS_KEY_ID && AWS_SECRET_ACCESS_KEY
        ? { accessKeyId: AWS_ACCESS_KEY_ID, secretAccessKey: AWS_SECRET_ACCESS_KEY }
        : undefined // → default credential chain (IAM role)
  });
}
```

The credential pattern is identical to `getS3Client()` (see [storage-s3.md](storage-s3.md)) and is the canonical IAM-fallback shape, see SKILL.md §"Core principles" rule 2 for the rationale.

### Why a factory, not a singleton

The SES SDK client is cheap to construct, holds no per-call state, and the factory keeps the credential-chain decision visible at every call site. **Don't cache it as a module-level constant**, that hides which credentials any given call ends up using.

---

## The `sendOne` primitive

```ts
async function sendOne(input: {
  source: string;
  to: string;
  subject: string;
  html: string;
  text: string;
}): Promise<void> {
  const ses = getSesClient();

  const command = new SendEmailCommand({
    Source:      input.source,
    Destination: { ToAddresses: [input.to] },
    Message: {
      Subject: { Data: input.subject, Charset: "UTF-8" },
      Body: {
        Text: { Data: input.text, Charset: "UTF-8" },
        Html: { Data: input.html, Charset: "UTF-8" }
      }
    }
  });

  await ses.send(command);
}
```

Always send **both** HTML and text. The text body is what shows up in inbox-preview tooling, and SES uses it as fallback for plain-text-only clients. Don't ship HTML-only emails.

`sendOne` is **internal**, exported senders are the public API. Callers outside the email module should never construct a `SendEmailCommand` directly.

---

## The block primitives

```ts
// <server>/lib/email/blocks.ts
export type EmailBlock =
  | { type: "paragraph"; text: string }
  | { type: "heading";   text: string }
  | { type: "cta";       label: string; href: string }
  | { type: "divider" }
  | { type: "meta";      text: string }
  | { type: "rawHtml";   html: string; text: string };

// Constructors
export const heading   = (text: string): EmailBlock => ({ type: "heading", text });
export const paragraph = (text: string): EmailBlock => ({ type: "paragraph", text });
export const cta       = (input: { label: string; href: string }): EmailBlock => ({ type: "cta", ...input });
export const divider   = (): EmailBlock => ({ type: "divider" });
export const meta      = (text: string): EmailBlock => ({ type: "meta", text });
```

The `rawHtml` block exists for one-off marketing campaigns that need bespoke layout. **Don't reach for it in transactional senders**, stick to `heading + paragraph + cta + meta`.

### Why blocks, not template strings

The email layout has to render brand chrome, locale-aware greeting, and footer consistently. A template-string approach drifts within weeks; the block list keeps every email visually consistent and locale-correct. If you're tempted to "just inline the HTML this once," you're starting the drift.

---

## The layout renderer

```ts
// <server>/lib/email/layout.ts
export function renderEmailLayout(input: {
  locale: SupportedLocale;
  preheader: string;
  greetingName?: string;
  blocks: EmailBlock[];
  unsubscribeUrl?: string;
}): { html: string; text: string };
```

The renderer applies:

- Brand chrome (logo, color tokens, font stack, defined as `TOKENS` constants in the layout module).
- A locale-aware greeting (`Hi`, `Hola`, `Olá`, etc.).
- The block list, rendered to both HTML and plain text.
- The footer (tagline + unsubscribe + address).

The `preheader` is the **inbox preview text**, the first ~100 chars users see in their list view. Always write a meaningful one (not a duplicate of the subject), it's free copy that decides whether the email gets opened.

---

## Example sender, magic link

```ts
import { heading, paragraph, cta, meta, type EmailBlock } from "<server>/lib/email/blocks";
import { renderEmailLayout } from "<server>/lib/email/layout";
import { serverEnv } from "<server>/lib/env.server";

export async function sendMagicLinkEmail(input: { email: string; url: string }): Promise<void> {
  const subject = "Your sign-in link";
  const blocks: EmailBlock[] = [
    heading("Sign in"),
    paragraph("Use the button below to securely sign in. The link is single-use and expires in 15 minutes."),
    cta({ label: "Sign in", href: input.url }),
    paragraph(input.url), // Plain-URL block, for clients that strip CTAs
    meta("If you did not request this email, you can ignore it.")
  ];

  const rendered = renderEmailLayout({
    locale: "en",
    preheader: "Your secure sign-in link",
    blocks
  });

  await sendOne({
    source:  serverEnv.SES_FROM_EMAIL,
    to:      input.email,
    subject,
    html:    rendered.html,
    text:    rendered.text
  });
}
```

Two patterns to copy:

1. **The `cta` block is followed by a plain-URL `paragraph`.** Some email clients strip styled buttons; the URL gives users a manual fallback. Don't omit it.
2. **`meta` is reserved for "ignore this if you didn't request it" footers.** It renders smaller and dimmer than `paragraph`, so reserve it for that semantic.

---

## Adding a new transactional sender

1. **Pick the FROM**: `serverEnv.SES_FROM_EMAIL` (transactional) or `SES_MARKETING_FROM_EMAIL` (newsletter only). See "Transactional vs marketing" below.
2. **Compose `EmailBlock[]`**, keep it to 3-5 blocks. Long emails get marked as spam.
3. **Write a meaningful `preheader`**, not a duplicate of the subject.
4. **Add locale variants if recipients might be non-English.** Use a `Record<SupportedLocale, …>` table for copy:

   ```ts
   const COPY: Record<SupportedLocale, { subject: string; preheader: string; heading: string; body: string; cta: string }> = {
     en: { subject: "…", preheader: "…", heading: "…", body: "…", cta: "…" },
     es: { subject: "…", preheader: "…", heading: "…", body: "…", cta: "…" }
   };

   const copy = COPY[locale];
   const blocks: EmailBlock[] = [heading(copy.heading), paragraph(copy.body), cta({ label: copy.cta, href: url })];
   ```

5. **Call `renderEmailLayout` and `sendOne`.**

---

## Transactional vs marketing, the FROM split

| Concern              | Transactional                                       | Marketing                                       |
| -------------------- | --------------------------------------------------- | ----------------------------------------------- |
| Env var              | `SES_FROM_EMAIL` (required)                         | `SES_MARKETING_FROM_EMAIL` (optional)           |
| Subdomain pattern    | `notify.<your-host>` (transactional reputation)     | `news.<your-host>` (reputation-isolated)        |
| Volume               | Per-user actions (1 per sign-in / invite / confirm) | Bulk (newsletter sends)                         |
| Spam-complaint risk  | Low                                                 | High (unsubscribe-driven complaints)            |

**Why the split matters:** spam complaints from the marketing list damage the **sender domain's reputation** with major mailbox providers. If marketing and transactional share that reputation, a bad campaign tanks deliverability of magic-link emails, users stop getting sign-in links. Reputation isolation via separate subdomains keeps the two failure modes independent.

`sendMarketingEmail` should **fall back to `SES_FROM_EMAIL`** if `SES_MARKETING_FROM_EMAIL` is unset (common in dev). In production the marketing var **must** be set; verify before any newsletter campaign.

---

## Known limitation, `List-Unsubscribe` header

The SES v1 `SendEmailCommand` doesn't accept custom MIME headers via the `Message` field. If you need a proper `List-Unsubscribe` header (e.g. for Gmail's bulk-sender enforcement on marketing volume), switch the marketing path to `SendRawEmailCommand` and build the MIME tree manually. Embedding the unsubscribe link in the rendered HTML/text footer is acceptable for low-volume sends and required for transactional emails (which don't need the header).

---

## Hard rules

- **Never** instantiate `new SESClient(...)` outside `getSesClient()`. Duplicate clients bypass the IAM-fallback contract.
- **Never** send HTML-only, always include `text`. Use `renderEmailLayout` so both come from one source.
- **Never** hand-craft HTML strings for transactional emails. Compose `EmailBlock[]` and let the renderer apply the brand chrome.
- **Never** send marketing email from `SES_FROM_EMAIL`, reputation isolation is the whole point of the split.
- **Never** put PII into the `subject` line. It's logged by relays and visible in inbox-preview cards before unlock.
- **Never** call `sendOne` from outside the email module, exported senders are the public API.
