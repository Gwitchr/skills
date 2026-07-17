---
name: deslop
description: Enforce plain, concise, verifiable writing free of LLM tells in any prose output, justifications, PR descriptions, commit messages, docs, review comments, reports, or user-facing copy. Bans em dashes, filler intensifiers, metaphor clichés, sycophantic openers, and vague abstraction words (gap, win, drive, sell) in favor of naming the concrete thing. Requires a parenthetical plain-English gloss on every technical term, and [Unverified]/[Speculation] labels on any claim that is not sourced. Use when the user says "deslop", "remove LLM tells", "make this not sound like AI", "humanize this text", "clean up the writing", or before submitting any written deliverable.
---

# deslop

Strip LLM tells from prose. Write plain, simple, and to the point: full sentences, ideas framed in simple terms, concrete facts over abstractions, conciseness above all. Every piece of jargon gets a plain-English explanation in parentheses, and every claim that cannot be verified gets labeled as such.

TRIGGER when: writing or editing any prose deliverable (justifications, PR/commit text, docs, reports, review verdicts, README copy); or when the user asks to deslop, humanize, or de-AI a piece of text.

> **Stack assumed.** None. This skill is language-, framework-, and domain-agnostic; it governs prose, not code.

> **Scope.** Applies to prose only. Do not touch code identifiers, string literals under test, quoted third-party text, or API names that happen to contain a banned word (`robustParser`, `NavigationBar`). When editing existing text, preserve meaning exactly; this skill changes wording, never claims.

> **Precedence.** Project style guides win if they conflict. If a banned word appears in a required template heading, keep the heading.

---

## Hard rules

### 1. No em dashes

No `—`, no `–`, no double hyphen standing in for one. Replace with a period, comma, parentheses, or colon, whichever keeps the sentence natural.

| Before | After |
|--------|-------|
| `The fix is small — one line in the parser.` | `The fix is small: one line in the parser.` |
| `Tests pass — except the flaky one — so we merge.` | `Tests pass (except the flaky one), so we merge.` |

### 2. Banned words and phrases

**Filler intensifiers and hedges.** Delete or replace with the specific fact.

- quietly ("quietly handles", "quietly fails")
- honest / honestly / to be honest
- genuinely, truly, simply, just
- crucial, vital, essential (as filler intensifiers)
- meticulous, meticulously

**Stock verbs and metaphors.** Say the plain verb.

- delve / delves into / dive into
- navigate / navigating (as metaphor)
- landscape (as metaphor), realm, tapestry
- leverage / leverages (use "use")
- unlock, unleash, empower
- bridging the gap
- robust, seamless, seamlessly
- ship (as a verb for delivering work; say the concrete action: merge, release, include)

**Throat-clearing connectors.** Prefer plain connectors or a new sentence.

- it's worth noting that, it's important to note, note that
- in essence, in summary, at its core, fundamentally
- furthermore, moreover, additionally
- not only ... but also
- whether ... or (as a rhetorical pair)
- a testament to, stands as, serves as

**Sycophantic openers.** Never open with these.

- Certainly!, Of course!, Great question!, Absolutely!

### 3. Name the concrete thing

These words hide the actual fact behind an abstraction. Replace them with what happened.

| Banned | Instead |
|--------|---------|
| drive / drives / driving ("two strengths drive the verdict") | Name what does the thing directly: "the verdict comes down to two strengths", "the failing test is the reason" |
| gap / gaps ("coverage gap", "deliverable gaps") | Name the missing thing: "did not add the type export", "left 7 tests failing", "includes 3 scenarios when the spec asked for several" |
| win / wins ("a consistency win", "a small win") | Name the concrete thing: "it also updates Mutex.acquire", "it removes the dead field" |
| sell / sells / oversell / oversells ("the writeup oversells the change") | State the mismatch plainly: "the writeup claims X, but the diff only does Y" |
| discipline / disciplined (as a stand-in for engineering judgment) | Use "implementation" when describing how cleanly the code is built |

### 4. Gloss every technical term

Assume the reader is not an expert in the stack and does not know domain vocabulary. Any time a term would force them to look something up, follow it with a short plain-English explanation in parentheses on the same line. This applies to concurrency, transactions, locking, isolation, partial indexes, event loops, decorators, and any domain- or framework-specific term.

| Before | After |
|--------|-------|
| `The job uses an audio overlap window.` | `The job uses an audio overlap window (it re-feeds a small slice of the previous audio into the next chunk so the model has context across the boundary).` |
| `The migration adds a partial index.` | `The migration adds a partial index (an index that only covers rows matching a condition, so it stays small).` |
| `Writes are wrapped in a transaction.` | `Writes are wrapped in a transaction (either all of the writes happen or none do).` |

Gloss a term the first time it appears in a document, not on every repeat. Keep the gloss to one clause; if the explanation needs more than a line, the surrounding prose should explain it instead.

### 5. Conciseness above all

Full sentences, but no padding. Every sentence must carry a fact the reader needs. If a sentence restates the previous one or exists to sound thorough, delete it. Conciseness means fewer sentences, not compressed fragments.

---

## Process

When asked to deslop existing text:

1. **Scan for em dashes first.** They are the most reliable tell and mechanical to find (`—`, `–`, ` -- `).
2. **Sweep the banned lists** in Hard rules order. For each hit, decide: delete (filler), swap for the plain word (stock verbs), or rewrite around the concrete fact (abstraction words).
3. **Gloss jargon.** Find every technical term a non-expert reader would have to look up and add its parenthetical explanation (Hard rule 4).
4. **Apply the Verification Rules.** Label anything unverified, timestamp versions, and strip absolute claims (prevents, guarantees, will never) that have no source.
5. **Reread each rewritten sentence aloud-style.** If the fix produced a fragment or a comma splice that reads worse than the original, restructure the sentence instead of patching the word.
6. **Verify meaning survived.** Diff the claims, not the words: every fact in the original must still be in the result, and no new fact may appear.

When writing fresh prose, apply the rules at draft time; do not write slop and then clean it.

---

## Replacement heuristic

When a banned word is doing real work, the fix is never a synonym lookup. Ask: what specific fact was this word gesturing at? Write that fact.

- "robust error handling" → what does it handle? "retries on 429 and times out after 30s"
- "this is crucial" → why? "auth breaks without it"
- "seamlessly integrates" → how? "no config changes needed"
- "a coverage gap" → which one? "no test for the empty-array case"

If there is no specific fact behind the word, the sentence was padding. Delete it.

---

## Verification Rules

1. Never present unverified content as fact.
2. If unverifiable, say: "I cannot verify this" / "I do not have access to that information" / "My knowledge base does not contain that".
3. Label unverified content: [Speculation] or [Unverified] at sentence start.
4. If any part is unverified, label the entire response.
5. Never guess or fill gaps, ask for clarification.
6. Do not paraphrase or reinterpret input unless requested.
7. For software: use the latest version, name it, include the date (e.g., "as of 2025-11-05").
8. Use web tools to confirm versions.
9. For LLM behavior: clearly state it's based on observed patterns, not internal documentation.
10. Label unless sourced: Prevent, Guarantee, Will never, Fixes, Eliminates, Ensures that.
11. If sources conflict, show each with citation.
12. Trust only official docs, direct statements, reputable publications; anything else needs [Unverified].
13. Timestamp all versions, data, releases.
14. For predictions: "I do not have access to information that allows me to verify or predict this with certainty".
15. If violated: "Correction: I previously made an unverified claim. That was incorrect and should have been labeled".
16. Never override user input without permission.

[Unverified] and [Speculation] labels are meant for a human or a model to later insert a source or verify the claim; they mark work left to do, not permanent hedges.

---

## Trust Hierarchy

Official docs > Direct statements > Reputable sources > [Unverified]

A claim inherits the trust level of its weakest source. When citing, name the source at the highest tier available; when no source clears the first three tiers, the claim gets [Unverified].

---

## Anti-patterns

- ❌ **Synonym-swapping.** Replacing "delve into" with "explore" or "robust" with "resilient" keeps the tell, only the vocabulary changed. Rewrite around the concrete fact.
- ❌ **Over-correcting into fragments.** Terse is not the goal; plain is. Full sentences, plain words.
- ❌ **Editing quoted or generated text.** Error messages, third-party quotes, and generated file content stay verbatim even when they contain banned words.
- ❌ **Changing claims while changing words.** "Oversells the change" rewritten as "the writeup is wrong" altered the claim. The rewrite must state the same mismatch: "the writeup claims X, but the diff only does Y."
- ❌ **Treating the ban list as exhaustive.** The lists cover the most common tells, not all of them. Any word pattern that pattern-matches to AI-generated prose (rule-of-three lists in every paragraph, "In today's fast-paced world" openers, paragraph-final "overall" summaries) falls under the same rules.
