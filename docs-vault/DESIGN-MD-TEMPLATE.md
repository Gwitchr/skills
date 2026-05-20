# DESIGN.md template (Tailwind-focused)

Reference for [SKILL.md](SKILL.md) Step 6.

This file explains how to derive a spec-compliant `docs/DESIGN.md` from a Tailwind-using project. The DESIGN.md spec is [google-labs-code/design.md](https://github.com/google-labs-code/design.md), read its `docs/spec.md` for the normative format definition.

---

## Goal

Produce a `docs/DESIGN.md` that:

1. **Lints clean**, `npx @google/design.md lint docs/DESIGN.md` reports `0 errors, 0 warnings`.
2. **Round-trips to Tailwind**, `npx @google/design.md export --format tailwind docs/DESIGN.md` produces a JSON `theme.extend` object that could replace the project's existing Tailwind theme.
3. **Coexists with Obsidian**, frontmatter carries both spec keys and Obsidian metadata (`aliases`, `tags`).
4. **Documents intent, not just current code**, if the project's `Button.tsx` reaches for a raw Tailwind palette color (e.g. `violet-700`) but the brand tokens intend a custom one (e.g. `brand-primary`), tokens encode the *intended* state and prose calls out the drift.

## Step-by-step derivation

### Step 1, Read the project's Tailwind config

For Tailwind v3:

```bash
cat tailwind.config.ts   # or .js
```

Look for:
- `theme.extend.colors`, the brand palette.
- `theme.extend.fontFamily`, display + body fonts.
- `theme.extend.borderRadius`, custom radii (rare; usually defaults).
- `theme.extend.spacing`, custom spacing (rare).
- `theme.extend.keyframes` + `theme.extend.animation`, custom motion.
- `content`, paths Tailwind scans (tells you where the components live).
- `plugins`, `@tailwindcss/forms`, `@tailwindcss/typography`, etc.

For Tailwind v4 (CSS-first):

```bash
grep -r "@theme" src/ app/ styles/
```

The `@theme { --color-*: ...; --font-*: ...; }` block is the source.

### Step 2, Read the dominant atoms to find actual usage

Even with brand tokens in the config, atoms often reach for raw Tailwind palette colors. Read:

```bash
src/components/atoms/Button.{tsx,ui.tsx}
src/components/atoms/Input.{tsx,ui.tsx}
src/components/atoms/Card.{tsx,ui.tsx}
src/components/atoms/Text.{tsx,ui.tsx}
```

For each variant, capture:
- Background fill (e.g., `bg-violet-700`)
- Text color (e.g., `text-white`)
- Hover state (e.g., `hover:bg-violet-900`)
- Padding (e.g., `px-5 py-2.5`)
- Radius (e.g., `rounded-lg`)
- Font size (e.g., `text-sm`)

This tells you what the design system *currently produces* vs what the brand tokens *intend*.

### Step 3, Read the global stylesheet

```bash
cat src/styles/globals.css   # or app/globals.css
cat src/pages/_document.tsx  # body className tells you the app shell bg
```

Find:
- Font-loading method (Typekit `<link>`, `next/font`, `@import`, self-hosted).
- Body bg / text defaults.
- Any CSS custom properties (`--surface`, `--main`, etc.) used by atoms.

### Step 4, Decide the semantic palette

Map raw values to semantic token names. The DESIGN.md spec recommends:

| Spec name | Common role |
|-----------|-------------|
| `primary` | Action color, buttons, active states |
| `on-primary` | Text/icon on primary fill |
| `primary-container` | Soft brand surface, chips, badges, hover |
| `on-primary-container` | Text on soft surface |
| `secondary` | Accent, links, highlights |
| `tertiary` | Marketing surface |
| `surface` | App body bg |
| `surface-container-low/medium/high` | Elevation ladder for cards/modals |
| `on-surface` | Primary text on surface |
| `on-surface-variant` | Secondary text |
| `on-surface-muted` | Placeholders, metadata |
| `outline` | Borders, dividers |
| `error` / `success` / `warning` / `info` | Semantic |

**WCAG check before committing:** any `primary` paired with white text must hit ≥ 4.5:1 contrast. If the brand color is too light (e.g. a pastel), introduce a Material-style split:
- `primary` = derived darker shade (carries `on-primary: #FFFFFF`)
- `primary-container` = the soft brand color (carries dark `on-primary-container`)

This is the most common adjustment when coming from a "soft brand palette" project.

### Step 5, Define the typography scale

Most projects haven't codified one, they reach for `text-xs` / `text-sm` / `text-base` / `text-lg` / `text-xl` ad hoc. The skill's job is to **codify the scale this file commits to**, even if it didn't exist before.

Recommended levels (matches the spec's non-normative naming):

```yaml
typography:
  display-lg:   { fontFamily: <display>, fontSize: 48px, fontWeight: 700, lineHeight: 1.1, letterSpacing: -0.02em }
  display-md:   { fontFamily: <display>, fontSize: 36px, fontWeight: 700, lineHeight: 1.15 }
  headline-lg:  { fontFamily: <display>, fontSize: 28px, fontWeight: 600, lineHeight: 1.2 }
  headline-md:  { fontFamily: <display>, fontSize: 22px, fontWeight: 600, lineHeight: 1.3 }
  title-lg:     { fontFamily: <display>, fontSize: 18px, fontWeight: 600, lineHeight: 1.4 }
  title-md:     { fontFamily: <display>, fontSize: 16px, fontWeight: 600, lineHeight: 1.4 }
  body-lg:      { fontFamily: <body>,    fontSize: 16px, fontWeight: 400, lineHeight: 1.5 }
  body-md:      { fontFamily: <body>,    fontSize: 14px, fontWeight: 400, lineHeight: 1.5 }
  body-sm:      { fontFamily: <body>,    fontSize: 13px, fontWeight: 400, lineHeight: 1.5 }
  label-lg:     { fontFamily: <body>,    fontSize: 14px, fontWeight: 500, lineHeight: 1 }
  label-md:     { fontFamily: <body>,    fontSize: 13px, fontWeight: 500, lineHeight: 1 }
  label-sm:     { fontFamily: <body>,    fontSize: 12px, fontWeight: 500, lineHeight: 1 }
  caption:      { fontFamily: <body>,    fontSize: 11px, fontWeight: 400, lineHeight: 1.4, letterSpacing: 0.02em }
  numeric-tabular: { fontFamily: <body>, fontSize: 14px, fontWeight: 500, lineHeight: 1, fontFeature: '"tnum" 1' }
```

If the project ships dynamic numbers (counters, prices, timers), always include `numeric-tabular` with `fontFeature: '"tnum" 1'`.

### Step 6, Spacing & radius

Tailwind's defaults are fine; document the named anchors the project actually uses:

```yaml
rounded:
  none: 0px
  sm: 4px      # tag, badge
  md: 6px      # input
  lg: 8px      # button, card, dialog
  xl: 12px     # large card
  full: 9999px # pill, avatar

spacing:
  xs: 4px
  sm: 8px
  md: 16px
  lg: 24px
  xl: 32px
  xxl: 48px
  # Atom anchors (observed in code), name them so future changes have a referent
  input-padding: 10px         # Tailwind p-2.5
  button-medium-x: 20px       # px-5
  button-medium-y: 10px       # py-2.5
  modal-padding: 16px         # p-4
  modal-padding-md: 24px      # md:p-6
  card-gap: 16px              # gap-4
```

### Step 7, Components

Define every visual atom that varies by tokens. **Reference tokens, never inline hex.** Use `{colors.primary}`, `{rounded.lg}`, etc.

Minimum component coverage (the linter flags orphan colors not referenced anywhere):

- `button-primary` + `-hover` + `-disabled`
- `button-secondary`
- `button-outlined`
- `button-plain` (text-only)
- `button-danger`
- `button-tiny` (small variant for toolbars)
- `input-text`
- `card`
- `badge`
- `toast`
- `app-shell` (body)
- `divider`
- `alert-success` / `alert-warning` / `alert-info` / `alert-error` (when those colors exist)

Every defined color token must be referenced by at least one component, otherwise the linter warns "orphaned-tokens".

### Step 8, Sections in canonical order

```
1. Overview                          (also: "Brand & Style")
2. Colors
3. Typography
4. Layout                            (also: "Layout & Spacing")
5. Elevation & Depth                 (also: "Elevation")
6. Shapes
7. Components                        (sub-sections OK: Iconography, Animations, etc.)
8. Do's and Don'ts
```

Sections can be omitted, but those present must appear in this order. Don't reorder; the linter checks.

### Step 9, The Tailwind bridge

Add a final section bridging tokens → Tailwind utility classes. This is what makes the file Tailwind-focused (the spec is framework-agnostic; the bridge is project-specific):

```markdown
## Tailwind mapping

How tokens flow into the actual Tailwind config:

| Token group | Tailwind path | Class prefix |
|-------------|---------------|--------------|
| `colors.*` | `theme.extend.colors` | `bg-`, `text-`, `border-`, `ring-` |
| `typography.<name>.fontSize` | `theme.extend.fontSize` | `text-<name>` |
| `typography.<name>.fontFamily` | `theme.extend.fontFamily` | `font-<family>` |
| `rounded.<size>` | `theme.extend.borderRadius` | `rounded-<size>` |
| `spacing.<name>` | `theme.extend.spacing` | `p-<name>`, `m-<name>`, `gap-<name>` |

Convergence loop: when this file changes, regenerate `tailwind.config.ts`'s `theme.extend`:

\`\`\`bash
npx @google/design.md export --format tailwind docs/DESIGN.md > tmp/tailwind.theme.json
# diff against current theme.extend in tailwind.config.ts and apply
\`\`\`
```

### Step 10, Lint

```bash
npx @google/design.md lint docs/DESIGN.md
```

Fix every error and every warning except `info`-level. Common fixes:

| Finding | Fix |
|---------|-----|
| `contrast-ratio` warning | Split the brand color into `primary` + `primary-container` (Material pattern). Re-test. |
| `orphaned-tokens` warning | Add a component that references the token, OR delete the token if it's truly unused. |
| `missing-primary` warning | Define `colors.primary`. |
| `missing-typography` warning | Define at least one `typography.*` entry. |
| `broken-ref` error | A `{path.to.token}` reference doesn't resolve. Check the path. |
| `section-order` warning | Reorder sections to match the canonical order. |

Re-lint until clean.

## Frontmatter template

```yaml
---
# DESIGN.md spec (google-labs-code/design.md, version: alpha)
# Tokens are normative. Prose explains how to apply them.

# Obsidian metadata (preserved alongside the spec; ignored by the linter)
aliases: [Design, Design System, DESIGN]
tags: [moc, quality]

version: alpha
name: <Project Brand Name>
description: >
  One-paragraph summary of the brand personality, color emphasis, type pairing,
  and theme decision (light / dark / both).

colors:
  primary: "#XXXXXX"            # action color, must pass WCAG AA against on-primary
  on-primary: "#FFFFFF"
  primary-hover: "#XXXXXX"
  primary-container: "#XXXXXX"  # soft brand surface
  on-primary-container: "#XXXXXX"
  # ... + secondary, tertiary, surface ladder, on-surface family,
  # outline, error/success/warning/info

typography:
  display-lg: { ... }
  # ... 9-14 levels total

rounded:
  none: 0px
  sm: 4px
  md: 6px
  lg: 8px
  xl: 12px
  full: 9999px

spacing:
  xs: 4px
  sm: 8px
  md: 16px
  lg: 24px
  xl: 32px
  xxl: 48px
  # + atom anchors

components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.on-primary}"
    typography: "{typography.label-lg}"
    rounded: "{rounded.lg}"
    padding: 10px 20px
  # + every other atom variant
---
```

## Body section template

Each section is short prose followed by token-derivation notes where useful. Don't restate the token values, they're already in the YAML; instead explain *why* and *when* to use them.

For an exemplar that lints clean, see the spec's reference samples at [google-labs-code/design.md](https://github.com/google-labs-code/design.md).
