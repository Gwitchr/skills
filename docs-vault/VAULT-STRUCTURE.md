# Vault structure reference

Per-file scaffolds for every artifact [SKILL.md](SKILL.md) produces. These are copy-paste targets, not normative content. Each scaffold encodes the progressive-disclosure layers defined in SKILL.md: every file summarizes its own layer and links one level deeper. Outline the vault (SKILL.md step 2) before instantiating any scaffold.

---

## Vault config (`docs/.obsidian/`)

### `app.json`

```json
{
  "useMarkdownLinks": false,
  "newLinkFormat": "shortest",
  "alwaysUpdateLinks": true,
  "showInlineTitle": true,
  "showFrontmatter": false,
  "promptDelete": true,
  "attachmentFolderPath": "_attachments"
}
```

### `core-plugins.json`

```json
{
  "file-explorer": true,
  "global-search": true,
  "switcher": true,
  "graph": true,
  "backlink": true,
  "canvas": true,
  "outgoing-link": true,
  "tag-pane": true,
  "properties": true,
  "page-preview": true,
  "templates": false,
  "note-composer": true,
  "command-palette": true,
  "editor-status": true,
  "bookmarks": true,
  "outline": true,
  "word-count": true,
  "file-recovery": true
}
```

### `community-plugins.json`

```json
[]
```

### `appearance.json`

```json
{
  "baseFontSize": 16,
  "showViewHeader": true
}
```

### `graph.json`

`graph.json` colors graph nodes by tag. Adjust hex/`rgb` values to taste; the structure is what matters.

```json
{
  "collapse-filter": false,
  "search": "",
  "showTags": true,
  "showAttachments": false,
  "hideUnresolved": false,
  "showOrphans": true,
  "collapse-color-groups": false,
  "colorGroups": [
    { "query": "tag:#architecture", "color": { "a": 1, "rgb": 14773924 } },
    { "query": "tag:#convention",   "color": { "a": 1, "rgb":  5431518 } },
    { "query": "tag:#workflow",     "color": { "a": 1, "rgb":  3636920 } },
    { "query": "tag:#quality",      "color": { "a": 1, "rgb": 14701138 } },
    { "query": "tag:#adr",          "color": { "a": 1, "rgb": 11823538 } },
    { "query": "tag:#upgrade",      "color": { "a": 1, "rgb": 13312586 } },
    { "query": "tag:#moc",          "color": { "a": 1, "rgb": 16777215 } }
  ],
  "collapse-display": false,
  "showArrow": true,
  "textFadeMultiplier": 0,
  "nodeSizeMultiplier": 1.2,
  "lineSizeMultiplier": 1,
  "collapse-forces": false,
  "centerStrength": 0.5,
  "repelStrength": 12,
  "linkStrength": 1,
  "linkDistance": 250,
  "scale": 1,
  "close": false
}
```

### `bookmarks.json`

Pin Home + 3-4 most-touched entry points.

```json
{
  "items": [
    { "type": "file", "path": "Home.md",                 "title": "Home" },
    { "type": "file", "path": "PRODUCT.md",              "title": "PRODUCT" },
    { "type": "file", "path": "ARCHITECTURE.md",         "title": "ARCHITECTURE" },
    { "type": "file", "path": "DESIGN.md",               "title": "DESIGN" },
    { "type": "file", "path": "upgrades/immediate.md",   "title": "Immediate Upgrades" }
  ]
}
```

---

## `docs/Home.md` (Obsidian map of content, MOC)

```markdown
---
aliases: [Vault Home, Index]
tags: [moc]
---

# Home

The single hub of <project>'s docs vault. Open `docs/` as the vault root; `.obsidian/` lives here.

On GitHub this folder renders [README](README.md), a pointer back here. The repo-root entry chain is [`CLAUDE.md`](../CLAUDE.md) → [`AGENTS.md`](../AGENTS.md) → this file.

## MOC (start here)

### Top-level (flat domain docs)

**Read order:** [[PRODUCT]] → [[RUNTIME]] → [[ARCHITECTURE]] → [[DATA]] → [[AUTH]] → [[ENGINEERING]] → [[TESTING]] → [[DESIGN]]

| File | What it covers |
|------|----------------|
| [[PRODUCT]] | What <project> is, audiences, surfaces, glossary |
| [[RUNTIME]] | Stack, services, env, setup, commands |
| [[ARCHITECTURE]] | Code layout, data flow, state boundary |
| [[DATA]] | DB + validation + cache layer |
| [[AUTH]] | Auth, sessions, role gates |
| [[ENGINEERING]] | Lint, format, language config, hooks, PR flow |
| [[TESTING]] | Test runner, strategy, coverage |
| [[DESIGN]] | Color, type, spacing, components, brand |

### Architecture
- [[overview]] · [[data-layer]] · [[components]] · [[state-*]] · [[auth-session]] · ...

### Conventions
- [[language-style]] · [[styling-system]] · [[naming]] · ...

### Workflows
- [[new-domain]] · [[new-component]] · [[diagnose-bug]] · ...

### Quality
- [[performance]] · [[accessibility]] · [[security]] · [[reliability]] · [[operability]]
- [[design-polish]] · [[audit-checklist]]

### Decisions
- [[Decisions Index]]

### Upgrades
- [[immediate]] · [[backlog]]

## Skills

Skill inventory lives in [`skills-lock.json`](../skills-lock.json) at repo root. Domain docs name the skill they distill inline; open `.agents/skills/<name>/SKILL.md` directly when working in that area.

## Tags set graph color groups

`#architecture` · `#convention` · `#workflow` · `#quality` · `#adr` · `#upgrade` · `#moc`
```

---

## `docs/README.md` (GitHub pointer)

GitHub renders this file in folder view; Obsidian readers never need it. Keep it a pointer, not a second index. It repeats the read order only because GitHub does not render wikilinks.

```markdown
---
tags: [moc]
---

# <project> docs vault

This folder is an Obsidian vault; open `docs/` as the vault root. Start at [Home.md](Home.md), on GitHub too.

Read order: PRODUCT → RUNTIME → ARCHITECTURE → DATA → AUTH → ENGINEERING → TESTING → DESIGN. Read only as deep as your question requires.

\`\`\`
docs/
├── .obsidian/        Obsidian config (graph colors, plugins, bookmarks)
├── Home.md           the vault's single hub, start here
├── README.md         this file, a pointer to Home
│
├── PRODUCT.md        ┐
├── RUNTIME.md        │
├── ARCHITECTURE.md   │  Flat top-level domain summaries
├── DATA.md           │  (each links into the deeper folder docs below)
├── AUTH.md           │
├── ENGINEERING.md    │
├── TESTING.md        │
├── DESIGN.md         ┘
│
├── architecture/     how parts fit (deeper specs)
├── conventions/      rules per layer
├── workflows/        step recipes
├── quality/          perf, accessibility, reliability, security, design polish
├── decisions/        architecture decision records (lazy)
└── upgrades/         what the repo lacks vs skill defaults
\`\`\`
```

---

## Top-level domain doc template

Every top-level (PRODUCT/RUNTIME/ARCHITECTURE/DATA/AUTH/ENGINEERING/TESTING) follows this shape:

```markdown
---
aliases: [<DisplayName>, <ALL_CAPS>]
tags: [moc, <domain-tag>]
---

# <Title>

<One-paragraph summary of what this domain covers in this project.>

---

## <Section 1>
<concrete content>

## <Section 2>
<concrete content>

## ...

---

## See also

- ↑ <up-links to other top-level docs that overlap, if any>
- <wikilinks to deeper folder docs>
- <peer top-level wikilinks>
- ↩ [[Home]]
```

`DESIGN.md` is the exception; see [DESIGN-MD-TEMPLATE.md](DESIGN-MD-TEMPLATE.md).

---

## Folder doc template (architecture / conventions / workflows / quality)

```markdown
---
aliases: [<DisplayName>]
tags: [<folder-tag>]
---

# <Title>

<concrete content>

---

## See also

- ↑ [[<TOP-LEVEL>]] · [[<OPTIONAL_SECOND_TOP>]]
- <peer wikilinks within the same folder>
- ↩ <[[overview]] for architecture/, [[Home]] otherwise>
```

The `↑` line is non-negotiable; it makes the graph bidirectional. See SKILL.md §6.

---

## ADR template (`docs/decisions/<NNNN>-<short-title>.md`)

ADRs (architecture decision records) are lazy: write one only when the decision is hard to reverse, surprising, and the result of a real trade-off.

```markdown
---
aliases: [<NNNN> <short title>]
tags: [adr]
---

# <NNNN>: <short imperative title>

## Status
proposed | accepted | superseded by <NNNN>

## Context
What's the situation? What forces are at play?

## Decision
The choice we're making and why.

## Consequences
What gets easier, what gets harder, what we now have to maintain.

## See also

- ↑ [[Decisions Index]] · [[ENGINEERING]] · [[ARCHITECTURE]]
```

---

## Repo-root entry files

### `CLAUDE.md`

Three lines, one job: send the reader to layer 2. Project-specific rules live in `AGENTS.md`, not here.

```markdown
# CLAUDE.md

Read [AGENTS.md](AGENTS.md) first; it is the entry point for agents working in this repo.
The docs vault starts at [docs/Home.md](docs/Home.md); read only as deep as the task needs.
Don't read `.env` / `.env.local` (live secrets); read `.env.example` instead.
```

### `AGENTS.md`

Mirror your project's specifics. The shape:

```markdown
# AGENTS.md

The entry point for any AI agent (Claude, Cursor, Aider, Copilot, ...) working in this repo.

## Read this first (top-level domain docs)

Read order: PRODUCT → RUNTIME → ARCHITECTURE → DATA → AUTH → ENGINEERING → TESTING → DESIGN.

| Domain | File | What it covers |
|--------|------|----------------|
| ... | ... | ... |

## Open as Obsidian vault

`docs/` is a real Obsidian vault. From the Obsidian app, choose **Open folder as vault** and pick `docs/`.

## Stack at a glance

<one-paragraph summary>

## The non-negotiables

- <repo-specific hard rules>

## Where things live

\`\`\`
src/
├── ...
\`\`\`

## Skills

Inventory: [`skills-lock.json`](skills-lock.json) at repo root. Sources installed under `.agents/skills/<name>/SKILL.md`.

The vault does **not** maintain a separate skills index; domain docs name the skill they distill inline. Open the relevant `.agents/skills/<name>/SKILL.md` directly when working in that area.

## Local commands

\`\`\`bash
<commands>
\`\`\`

## Vault entry

Start at [docs/Home.md](docs/Home.md), the vault's single hub, and read only as deep as the task needs.
```

---

## Up-link mapping (which folder doc → which top-level)

Use this when wiring `↑ See also` lines:

| Folder doc | Up-links |
|------------|---------|
| `architecture/overview` | `[[ARCHITECTURE]]` |
| `architecture/data-*` | `[[DATA]]` · `[[ARCHITECTURE]]` |
| `architecture/auth-*` | `[[AUTH]]` · `[[ARCHITECTURE]]` |
| `architecture/components` | `[[ARCHITECTURE]]` · `[[DESIGN]]` |
| `architecture/state-*` | `[[ARCHITECTURE]]` |
| `architecture/i18n-*` | `[[DATA]]` · `[[ARCHITECTURE]]` |
| `architecture/infrastructure` | `[[RUNTIME]]` · `[[ARCHITECTURE]]` |
| `conventions/language-style` | `[[ENGINEERING]]` · `[[ARCHITECTURE]]` |
| `conventions/styling-system` | `[[DESIGN]]` |
| `conventions/naming` · `variants` | `[[DESIGN]]` · `[[ENGINEERING]]` |
| `conventions/api-resources` · `background-jobs` · `fetchers` · `query-*` · `schemas-*` · `hooks-*` | `[[DATA]]` |
| `conventions/forms` | `[[DATA]]` · `[[DESIGN]]` |
| `conventions/icons` | `[[DESIGN]]` |
| `conventions/images` | `[[DESIGN]]` · `[[RUNTIME]]` (image host allowlist) |
| `conventions/tests` | `[[TESTING]]` · `[[ENGINEERING]]` |
| `conventions/git-and-pr` | `[[ENGINEERING]]` |
| `workflows/new-domain` | `[[DATA]]` · `[[ENGINEERING]]` |
| `workflows/new-component` | `[[DESIGN]]` · `[[ARCHITECTURE]]` · `[[ENGINEERING]]` |
| `workflows/new-surface` | `[[ARCHITECTURE]]` · `[[ENGINEERING]]` |
| `workflows/diagnose-*` · `tdd` | `[[TESTING]]` · `[[ENGINEERING]]` |
| `workflows/triage-*` · `write-prd` · `grill` | `[[PRODUCT]]` · `[[ENGINEERING]]` |
| `workflows/write-skill` · `ultrareview` | `[[ENGINEERING]]` |
| `quality/performance-budget` | `[[RUNTIME]]` · `[[DESIGN]]` |
| `quality/performance` | `[[RUNTIME]]` · `[[ENGINEERING]]` |
| `quality/accessibility` | `[[DESIGN]]` · `[[ENGINEERING]]` |
| `quality/discoverability` | `[[PRODUCT]]` · `[[RUNTIME]]` |
| `quality/security` | `[[RUNTIME]]` · `[[AUTH]]` · `[[ENGINEERING]]` |
| `quality/audit-checklist` | `[[ENGINEERING]]` · `[[RUNTIME]]` |
| `quality/design-polish` | `[[DESIGN]]` |
| `decisions/<*>` | `[[Decisions Index]]` · `[[ENGINEERING]]` · `[[ARCHITECTURE]]` |
| `upgrades/immediate` · `backlog` | Multi (the doc names the relevant tiers) |
