# Research: vector-index options alongside FTS5

**Ticket:** #13 (child of map issue #4)
**Status:** research complete
**Date:** 2026-08-18

## Question

Lira's canonical memory storage is already decided to be SQLite + FTS5 (ADR-0006, inherited), with a vector index called out as "an optional later addition, not a default." This research asks:

1. Should v1 add a vector index alongside FTS5?
2. If so, which embedding model/approach fits a local-first, 16 GB-constrained macOS app?
3. What is the case for staying FTS5-only for v1?

## TL;DR recommendation

**Stay FTS5-only for v1.** FTS5 plus metadata filtering satisfies the dominant v1 retrieval need (exact/prefix/boolean keyword recall over command runs, emails, notes, messages — with date/project/type filters) at zero added memory, zero model download, zero latency, fully offline, and it is already the decided mechanism (ADR-0006). Semantic search is a quality-of-life enhancement, not a v1 blocker, and can be layered in cleanly later behind a small seam.

**If and when a vector index is added,** the lowest-risk combo is:

- **Store:** `sqlite-vec` — a pure-C, in-process SQLite extension that adds a `vec0` virtual table and KNN queries, so the vector index lives inside the existing GRDB/SQLite store with no external vector DB and negligible RAM.
- **Embedder:** Apple **`NLEmbedding`** (NaturalLanguage framework, `sentenceEmbedding(for:)`, on-device, built into macOS 10.15+) as the zero-download default — no model shipped, no marginal RAM.
- **Upgrade path (only if retrieval quality demands it):** **`nomic-embed-text-v1.5`** (0.1 B params, Apache-2.0, matryoshka-truncatable to 512/256/128 dims, ~0.14 GB int8) run through MLX/Core ML — small enough to coexist with a resident generative model on 16 GB, but it is real additional footprint and needs the machine-specific bake-off ADR-0006 already defers for the local model pick.

---

## 1. Background and constraints

- **Canonical store is fixed.** ADR-0006 inherits "SQLite + FTS5 as canonical memory storage (not a heavy external vector service); a vector index is an optional later addition, not a default." The SQLite stack is accessed via GRDB (Swift).
- **Local-first.** No cloud embeddings. Everything must run on the owner's machine, offline.
- **16 GB machine, already budgeted tight.** ADR-0006 mandates a single resource governor that reserves measured memory/compute envelopes and pauses/evicts background work under pressure, prioritizing foreground. It also fixes a **zero-or-one resident custom local generative model, one decode lane**. So any *additional* resident model (an embedder) competes for the same 16 GB envelope the generative model already claims.
- **Native Swift/macOS.** Any approach must integrate with a Swift/SwiftUI app and the existing GRDB database.

These constraints sharply limit the viable options: no external vector service, no large separate vector DB, and any new model must be tiny and preferably lazy/resident-optional.

## 2. What FTS5 already gives you

FTS5 is a mature full-text engine (shipped in SQLite since 3.9.0, 2015) supporting:

- Exact-term, **phrase**, **prefix** (`thr*`), **NEAR**, and **boolean** (AND/OR/NOT) queries.
- Case-insensitive matching, diacritic removal, stemming via the `porter` tokenizer.
- A **trigram tokenizer** for general substring matching (`LIKE`/`GLOB` optimization).
- Relevance ranking via the built-in `bm25()` auxiliary function (`ORDER BY rank`).
- **External-content tables**, so the index can live in the same DB without duplicating content, and `rebuild` to rebuild from the canonical table.

*Source: SQLite FTS5 documentation* (https://www.sqlite.org/fts5.html).

For personal-agent memory — recalling "the email where I mentioned X", "that run that touched Y", "notes about Z project" — these capabilities, combined with ordinary SQL predicates on metadata columns (date, project, kind, run-id), cover the overwhelming majority of v1 recall cases **deterministically** (no embedding, no model, no chunking, no tuning).

## 3. The case for staying FTS5-only in v1

1. **It is the decided mechanism.** ADR-0006 explicitly records the vector index as "an optional later addition, not a default." Reversing that should require a demonstrated need, not a hypothetical.
2. **No extra memory pressure.** FTS5 runs in-process in SQLite with no resident model. On a 16 GB machine where a generative model already owns a large reserved envelope (and the resource governor evicts under pressure), every resident megabyte of an embedder is a real cost — including the risk of background eviction churn.
3. **No model/quality risk.** Adding vectors forces hard choices that are exactly the kind of thing ADR-0006 defers "to the relevant milestone, not on paper now": which embedder, which quantization, which matryoshka dimension, chunking policy, reindexing on schema change, and a bake-off on this specific machine. Each of these is an eval/quality task with real failure modes.
4. **Latency and determinism.** FTS5 queries are instant and reproducible. Embedding pipelines add per-query embedding latency (especially if the model is loaded on demand), reindex cost on writes, and nondeterminism across model revisions.
5. **v1 scale doesn't need it.** Personal memory at v1 scale (tens of thousands of records) is well within FTS5's comfortable range, and keyword recall is a good fit for the structured, entity-heavy text Lira stores (paths, command names, file names, product/brand tokens). Semantic retrieval shines on long, messy prose — less Lira's v1 corpus.
6. **Backward compatibility of the decision.** FTS5-only does not foreclose vectors. The append-only event ledger and GRDB schema are the canonical source of truth; a vector index is a derived structure that can be backfilled/rebuilt later (exactly like an FTS5 external-content index can `rebuild`). Nothing about FTS5-only commits Lira to a dead end.

## 4. If we add vectors — which store

**`sqlite-vec`** is the natural companion:

- A **pure-C, no-dependency SQLite extension** that "runs anywhere SQLite runs (Linux/macOS/Windows, in the browser with WASM)". A Mozilla Builders project (MIT/Apache-2.0).
- Adds a `vec0` virtual table storing float/int8/binary vectors with metadata columns and **KNN `MATCH` queries ordered by distance**.
- Because it lives *inside* SQLite, it fits the existing GRDB connection (custom SQLite extensions/functions are loadable on the same connection) — no external vector database, no new process, no network, negligible RAM footprint.

*Source: `sqlite-vec` README* (https://github.com/asg017/sqlite-vec).

Caveat: `sqlite-vec` is pre-v1 ("expect breaking changes"), so it is an acceptable v1 *later* choice but a reason to keep it out of the critical canonical-write path until it stabilizes — another argument for deferring.

## 5. If we add vectors — which embedder

Two realistic candidates fit a native, local-first, 16 GB macOS app:

### Option A — Apple `NLEmbedding` (zero-footprint default)

- Part of the **NaturalLanguage** framework, available macOS 10.15+. Provides built-in on-device **word** and **sentence** embeddings and nearest-neighbor/distance APIs.
- **No model to ship, download, or budget** — Apple hosts it in the OS. Marginal RAM is a few MB, not hundreds. Fully offline. Native Swift.
- Retrieval: embed the query with `sentenceEmbedding(for:)` (512-dim) and compare against stored vectors (which we compute once at write time) — semantics similar to classic SBERT-style lookup, and the vectors can live in a `sqlite-vec` table.
- **Trade-off:** it is Apple's fixed, general-purpose model. Sentence-embedding *quality* is below modern open embedders (no matryoshka control, English-centric, not tuned for retrieval/instruction prefixes). Good enough for fuzzy "related to" recall, not a retrieval-grade RAG embedder.

*Source: Apple `NLEmbedding` documentation* (https://developer.apple.com/documentation/naturallanguage/nlembedding).

### Option B — `nomic-embed-text-v1.5` (higher quality, still tiny)

- **0.1 B params, Apache-2.0**, long context (8192 tokens), ~0.55 GB in F32, ~0.14 GB in int8 quantization — small enough to be resident alongside a generative model or loaded lazily.
- **Matryoshka Representation Learning** lets you truncate the 768-dim vector down to 512/256/128/64 with negligible degradation (MTEB 62.28 → 61.96 @512 → 61.04 @256 → 59.34 @128), which is how you trade quality for RAM/query speed on a constrained machine.
- Retrieval-grade (task-instruction prefixes `search_document:` / `search_query:`), a strong choice for hybrid FTS5+vector RAG later.

*Sources: `nomic-embed-text-v1.5` model card* (https://huggingface.co/nomic-ai/nomic-embed-text-v1.5); *Matryoshka Representation Learning* (https://arxiv.org/abs/2205.13147).

The engineering cost is real: it must be bundled/quantized and run through MLX (mlx-swift) or converted to Core ML, which is precisely the "bake-off on this specific 16 GB machine" class of work ADR-0006 defers.

### Hybrid search (the future pattern)

The modern retrieval pattern is **hybrid**: run FTS5 (keyword) and vector KNN (semantic) in parallel and fuse rankings (e.g., reciprocal-rank fusion / RRF). This is the reason FTS5-only is *not* a dead end — FTS5 becomes one leg of a later hybrid. Nothing in v1's schema prevents adding the vector leg.

## 6. Bottom line for v1

- **Ship FTS5-only.** It meets the decided architecture, fits the 16 GB budget, needs no model, and covers the dominant recall cases deterministically.
- **Design the seam now.** Because the canonical source is the append-only event ledger + GRDB, a later vector index is a backfillable derived index. Keep the memory-search path behind one abstraction so `NLEmbedding` (Option A) or `nomic-embed-text-v1.5` (Option B) can slot in without touching the write path.
- **Defer the embedder decision** to the milestone where semantic search is actually exercised (consistent with ADR-0006's deferral of the local model pick). When that milestone arrives, validate Option A first (free, zero footprint); move to Option B (quantized/truncated) only if retrieval quality proves inadequate, and record the machine-specific bake-off result in an ADR.
