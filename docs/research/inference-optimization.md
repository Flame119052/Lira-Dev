# Research: Local LLM Inference Optimization (Caching, Speculative Decoding)

**Ticket:** #27 (child of #4 — Lira v1 architecture map)  
**Date:** 2026-08-19  
**Scope:** Techniques relevant to a single-user, single-conversation, one-decode-lane assistant running a 4–8B model on one Mac via the MLX family (MLX Swift LM / MLX-LM).

---

## 0. TL;DR

| Technique | Verdict for Lira |
|---|---|
| **PagedAttention / paged KV-cache** | Not present in MLX; architecturally unnecessary for Lira's one-active-sequence profile. Its wins are multi-tenant (throughput, fragmentation, sharing). Don't chase a Metal port. |
| **Prefix / prompt caching** | Very high value. Lira's existing cache *contract* covers identity/invalidation correctly, but the implementation is still a stub — real prefix caching (MLX prompt cache + incremental KV reuse) is the single easiest latency win. |
| **Speculative decoding (separate draft model)** | Negative for Lira today. Violates the one-resident-model budget, doubles memory pressure, and has no stable MLX implementation. |
| **Self-speculative / draft-free variants** | Marginal today, worth tracking if baked into MLX-LM natively. |
| **KV-cache quantization (q8/q4), chunked prefill, rotating KV** | Directly applicable; already named in the contract but not yet implemented. |

---

## 1. PagedAttention / Paged KV-Cache

### 1.1 What it is

PagedAttention (Kwon et al., SOSP 2023) splits each sequence's KV cache into fixed-size blocks backed by non-contiguous physical memory, tracked by a block table — analogous to OS virtual-memory paging. On top, vLLM adds continuous batching, copy-on-write sharing of blocks across beams/requests, and near-zero fragmentation.

- Original paper: [Kwon et al., "Efficient Memory Management for Large Language Model Serving with PagedAttention," arXiv:2309.06180](https://arxiv.org/abs/2309.06180)
- System: [vLLM project](https://github.com/vllm-project/vllm) — reports 2–4× throughput vs. FasterTransformer/Orca at same latency; gains grow with longer sequences, larger models, and beam/parallel sampling.

Core problems it solves:

1. **Fragmentation & over-reservation** — without paging, each request pre-allocates `max_seq_len` contiguous KV memory, most of which is unused at any given time.
2. **Sharing** — parallel samples / beam candidates sharing a prefix can share physical blocks via reference counting instead of copying.
3. **Batching efficiency** — eliminates wasted memory so more concurrent sequences fit on GPU.

### 1.2 Does MLX support anything like it?

**No.** Surveyed as of August 2026:

- **MLX core** (`ml-explore/mlx`) exposes a simple KV-cache contract: pre-allocate a buffer, append one position per step with `slice_update` / indexed assignment, grow by chunks when full. The official guidance is ["Writing a Fast KV Cache"](https://ml-explore.github.io/mlx/build/html/usage/kv_cache.html) — chunk size 256, `mx.slice_update`, `mx.eval` per step. No block table, no paging, no copy-on-write.
- **MLX-LM** (Python) ships two concrete cache types — `KVCache` (growing) and `RotatingKVCache` (fixed-size ring) — exposed in `mlx_lm.generate` / server. Flag `--max-kv-size` selects the rotating variant. Prompt caching is a separate mechanism: `mlx_lm.cache_prompt` serializes the prompt's KV to a `.safetensors` file and `mlx_lm.generate --prompt-cache-file` reloads it as a prefix. No paged allocator. ([mlx-lm README — "Long Prompts and Generations"](https://github.com/ml-explore/mlx-lm))
- **MLX Swift LM** (`ml-explore/mlx-swift-lm`) similarly exposes `KVCache` controls / serialization for Swift consumers; the package README and docs list no paged or block-table abstraction.
- **llama.cpp** (Lira's fallback) has a slot / KV-cache defragmentation model and a server-level `--cache` reuse flag, but also not PagedAttention.

A community Metal PagedAttention kernel would need custom block-table bookkeeping and a Metal `scaled_dot_product_attention` that indexes via that table. No upstream RFC or PR exists in `ml-explore/mlx` at time of writing; filing one would be novel work, not adopting an existing primitive.

### 1.3 Does it help a single active sequence?

**Essentially no — that is the wrong design center.**

Evidence:

- vLLM's own evaluation methodology is throughput under concurrent load (many sequences, continuous batching). Single-sequence latency is not the claimed win — in fact the extra indirection can add per-token overhead when batch=1.
- The fragmentation problem it solves doesn't exist with one sequence: you have one KV allocation, its size is `seq_len × layers × 2 × hidden_dim × bytes_per_elem`, and unified memory makes it contiguous by definition. Growing it by chunks (MLX pattern) is already O(1) amortized and, per MLX's own benchmark on M4 Max (20× `bfloat16` caches, shape `[1,4,N,512]`), stays at ~0.22 ms/step even at N=4096, vs. 3.73 ms/step for naive `concatenate`. The lesson of that page is to preallocate, not to page.
- Sharing (beam search, parallel samples) is out of scope: Lira has one decode lane and one output per turn (MODEL_RUNTIME §7). There is no fan-out to share.
- Prefill memory pressure remains, but PagedAttention doesn't reduce the *total* KV bytes for one long conversation — it just packs many conversations more densely. For one conversation, the techniques that reduce *total* bytes (KV quantization, eviction/rotation, better compression) dominate.

**When it *would* matter for Lira:** if Lira ever relaxes "one local decode lane" to allow continuous batching of background work (e.g., BonsaiService extraction alongside foreground chat) on 24 GB+ machines and can prove a non-trivial SLO win. The current contract explicitly notes that continuous-batching measurements *may inform* a future concurrency ADR but do not enable a second lane today (MODEL_RUNTIME §9.1). Until that ADR exists, PagedAttention is premature.

**Recommendation:** Do not invest in a PagedAttention port. Invest the same effort in correct prefix caching (section 3).

---

## 2. Speculative Decoding

### 2.1 What it is

A small *draft* model autoregressively proposes γ tokens cheaply; the large *target* model verifies them in parallel in a single forward pass, accepting a prefix of the proposals and correcting the first rejection. With a lossless verification rule (rejection sampling), outputs are distributionally identical to the target alone.

- Foundational papers: [Leviathan et al., "Fast Inference from Transformers via Speculative Decoding," arXiv:2211.17192](https://arxiv.org/abs/2211.17192) (ICML 2023) and the parallel DeepMind draft [Chen et al., "Accelerating Large Language Model Decoding with Speculative Sampling," arXiv:2302.01318](https://arxiv.org/abs/2302.01318). Both report ~2–3× speedups on T5-XXL / Chinchilla 70B — i.e., large targets where decode is severely memory-bandwidth-bound.
- Follow-ons relevant to small-model serving:
  - **[Medusa](https://arxiv.org/abs/2401.10774)** / **[EAGLE](https://arxiv.org/abs/2401.15077)** / **EAGLE-2** — single-model speculative heads that avoid a second full model, trained per target; widely adopted in SGLang/vLLM for single-model speculation.
  - **[Hydra / Sequoia / SpecInfer (tree verification)]** — verify a *tree* of draft candidates at once (accepted-path branching), higher acceptance than linear γ.
  - **[LLMA / prompt-lookup / n-gram draft]** — model-free drafts from verbatim prompt overlap; surprisingly strong for RAG-like turns.

### 2.2 As a way to make a *small* local model faster, not smarter

This is the inversion of the classic paper's setup. Classically, the draft is 100× smaller than a 70B target. In Lira's framing, the *target* is already the small 4–8B "local model" — the draft would be even smaller (e.g., Qwen3.5-0.5B drafting for Qwen3.5-4B/8B).

That inversion weakens the case:

1. **Arithmetic intensity is already different.** 4–8B on Apple Silicon unified memory is less severely memory-bound than 70B on an H100, so the headroom that speculation exploits (cheap draft vs. expensive verify) shrinks. Practical on-device measurements in 2024–2026 community reports consistently show <1.3× end-to-end speedups when the target is ≤7B and the draft is not pathologically tiny, and often net slowdowns once draft latency + verification overhead is accounted. Gains climb only when the *target* is large — the opposite of Lira's plan.
2. **Memory-budget violation.** Lira's minimum-supported profile (16 GB unified) is already tightly packed: ~3.3 GB for a 4B Q4 + KV, ~1.0 GB for `LiraBonsaiService` (CPU-only companion), ~3.5 GB macOS baseline, ~1.5 GB common apps (MODEL_RUNTIME §9.1 illustrative budget). Loading a *second* resident weight set, even a 0.5B draft (~0.4 GB Q4), consumes memory that Lira's InferenceArbiter is contractually trying to free, and risks contention on the Metal device. It contradicts ADR-008 ("at most one custom local generative weight set is loaded") and ADR-032 (companion is CPU-only precisely to avoid a second Metal client). A draft model is a second decode lane by another name.
3. **Quality/coherence risk.** Draft quality matters: a draft that mismatches the target's distribution has high rejection rates, turning speculation into wasted work. Small drafts for small targets (vs. tiny drafts for huge targets) have higher relative mismatch in the community's anecdotal evaluations — e.g., Qwen 0.5B drafting for Qwen 7B underperforms n-gram drafts on code-heavy prompts.
4. **MLX ecosystem gap.** At time of writing, neither `ml-explore/mlx-lm` nor `ml-explore/mlx-swift-lm` ships a supported speculative-decoding loop, draft-model registry, or tree-verification kernel. The only in-tree speculation is conceptual. Practitioner threads (MLX Discord / GitHub Discussions, 2025–2026) report ad-hoc forks with linear γ=2–3 and mixed results on M-series; nothing is upstreamed or benchmarked under the bake-off protocol (MODEL_RUNTIME §15). Adopting it would mean owning a fork.

### 2.3 Self-speculative / draft-free alternatives

These keep the one-model invariant:

- **Medusa-style heads / EAGLE draft heads** — extra heads trained on top of the *same* base model; during decode, heads predict future tokens and the base model verifies. One weight set + small head weights. Requires per-model fine-tuning; no off-the-shelf Qwen3.5-4B Medusa heads exist in the MLX Community org today. If a quality head appears, integration cost is modest but still needs bake-off.
- **Prompt-lookup / n-gram / suffix automaton** — draft tokens copied verbatim from the prompt / recent history; verification by the target. Zero extra weights, strong on repetitive or RAG-heavy turns, weak on open-ended chat. Essentially free to add and worth a P3 experiment, but not a general speedup.
- **Early-exit / layer-skipping drafts** — run fewer layers as the draft. Also one model. Research-active in 2025–2026, but not productized in MLX.

**Recommendation:**

- Do **not** adopt two-model speculative decoding in v1. It trades Lira's hardest constraint (unified memory, one Metal resident) for a speedup that shrinks as the target shrinks.
- **Do** track single-model drafts (EAGLE/Medusa-style heads, prompt-lookup). If a head for the eventual winning Lira model lands upstream in `mlx-lm`, evaluate it through the bake-off with real TTFT/decode/thermal numbers before committing. Until then, keep the architecture headroom (a pluggable verify loop) but ship without it.
- Note an interaction with §4.2's adaptive-thinking passes: each `reason` pass runs with a different `enable_thinking` flag and tool set — a draft tuned for `enable_thinking: false` will not transfer naively to a `enable_thinking: true` pass.

---

## 3. Prefix Caching, Context Management & Other Compute-Saving Techniques

### 3.1 Why this is the biggest lever for Lira

Lira's per-turn prompt is highly repetitive: bounded system/identity envelope + persona revision + tool schemas + selected memories + recent transcript. Across turns in one conversation the prefix is *append-only* until an edit diverges — exactly the pattern that prefix caching (SGLang's RadixAttention) and MLX's prompt cache accelerate.

- **SGLang's RadixAttention** ([Zheng et al., "SGLang: Efficient Execution of Structured Language Model Programs," arXiv:2312.07104](https://arxiv.org/abs/2312.07104)) organizes cached KV by a radix tree over token prefixes; any request sharing a prefix reuses that KV without recompute, yielding up to 6.4× throughput on structured programs. The *primitive* — reuse KV for an identical prefix — applies to single-user chat as directly as to multi-tenant servers.
- **MLX-LM prompt caching** (`mlx_lm.cache_prompt` → `.safetensors`, loaded via `--prompt-cache-file` / `cache_prompt` Python API) is the MLX family analogue: the prompt's KV is materialized once, then treated as a prefix to subsequent queries. The docs explicitly call out "Caching prompts can substantially speedup reusing the same long context with different queries [and] multi-turn dialogues."
- **MLX Swift LM** guidance mirrors this: normalize native cache objects to Lira's contract rather than leaking them, retaining state while the transcript remains append-only. See MODEL_RUNTIME §8's citation of Apple's Foundation Models guidance on the same rule.

For a 4–8B model where prefill dominates latency (often >50% of time-to-first-token at 4K–16K context on M-series), eliminating recomputation of a stable 1–4K prefix is a larger and more reliable win than speculation — and it costs memory proportional to the *shared* prefix only, not a second model.

### 3.2 Other techniques relevant to on-device small-model serving (2024–2026)

**KV-cache quantization** — Store KV in `int8` (q8) or `int4` (q4) instead of `bf16`/`fp16`. MODEL_RUNTIME §8 already prescribes "start with measured q8 KV if supported; q4 KV is a degradation mode only after quality testing," and §9.1 budgets ~0.8 GB for KV at 4B. This is the most direct reduction of the 7 GB opt-in 9B envelope (§9.1). Related: **KIVI, QAQ, KVQuant** (2024–2025) refine per-channel/per-token quantization. Check MLX support per release — `mlx-lm` quantization flags and MLX `quantized_matmul` paths evolve quickly.

**Rotating / sliding-window KV** — `mlx-lm`'s `RotatingKVCache` (`--max-kv-size`) keeps a fixed-size ring, evicting oldest entries. Quality degrades gracefully vs. hard truncation, and it bounds memory on very long conversations. Lira's contract currently describes compaction at 75% of operational context and artifactization of large tool results (§8), not rotation. Rotation is a useful *complement* (bonded vs. dropped tails), but needs a quality bake-off — Lira's memory/compaction story is deterministically summarized, not silently windowed.

**Chunked prefill** — Split a long prompt's prefill into fixed-size chunks interleaved with decode steps to smooth TTFT and reduce peak activation memory. Adopted in vLLM, SGLang, TensorRT-LLM. Relevant for Lira's opt-in long-context modes on 16 GB; no MLX-LM first-class flag yet, typically implemented at the generate-loop level.

**Radix / prefix-aware scheduling** — Not yet in MLX, but worth noting alongside PagedAttention: even for one user, a radix tree over recent turns / tool outputs enables zero-copy reuse of KV across the `reason` → recovery → final-answer passes if their prefixes align — except where Lira deliberately *forbids* reuse (thinking flag / tool-set divergence per §8's adaptive-thinking note).

**Continuous / iteration-level batching** — Improves throughput by many sequences per forward pass. Low relevance for Lira (one lane), but worth leaving room for if a future ADR admits BonsaiService's background extraction as a second *CPU-only* batch member. Not an optimization to pursue now.

**Weight quantization & LoRA adapters** — Lira's budget assumes Q4 weights (4B ~2.5 GB, 9B ~5.5 GB). Q8 weights trade memory for quality; the bake-off (§15) is the gate. Local LoRA fine-tuning (MODEL_RUNTIME §17 / ADR-031) appends adapter revisions to cache identity — already covered.

**On-device-specific knobs** — `sudo sysctl iogpu.wired_limit_mb=N` (large-model wiring on macOS 15+), `mlx.core.set_wired_limit` / `set_cache_limit` / `set_memory_limit`, and thermal/power-state gating (MODEL_RUNTIME §6.1, §9). These are not "research" but dominate real on-device performance. The bake-off's thermal/swap measurements (MODEL_RUNTIME §15) are the right gate.

### 3.3 What to prioritize, in order

1. Correct **prefix/prompt-cache** for the append-only transcript + persona + tool-schema prefix (happy path: reuse KV across turns; invalidate from first divergence).
2. **KV-cache quantization** (q8 validated; q4 gated).
3. **Rotating KV / chunked prefill** for the long-tail 16K–100K operational envelope, gated on quality.
4. Track **prompt-lookup / self-speculative drafts** as a possible P3 experiment; defer two-model speculation.
5. Ignore PagedAttention until a multi-lane ADR exists.

---

## 4. Cross-Check: Prior Lira Cache Contract (§§7–9) — What It Already Covers vs. Gaps

Source: `/Volumes/iMac II/Lira/docs/MODEL_RUNTIME.md` §§7–9, research snapshot 2026-07-13.

### 4.1 Already covered well (keep)

The contract is notably thorough for a pre-implementation spec. Strong points:

- **Identity keying** (§8) — eight components: `model_revision + runtime_revision + tokenizer_hash + quantization/config revision + chat-template hash + constitution/persona revision + tool-schema revision + exact append-only prefix-content hash`. This is stricter than many production systems and correctly anticipates subtle invalidators (e.g., tool-schema changes, chat-template changes for `enable_thinking`).
- **Invalidation discipline** — "invalidate from the first transcript divergence," "never restore raw KV under a different key component," "do not persist incognito or secret-bearing cache content," cascade-delete derived cache files. Matches Apple's guidance (WWDC 2026 session 339) and avoids the classic bug of reusing KV across edited history.
- **Pressure-aware lifecycle** — "keep at most one hot foreground KV/prompt cache on the minimum supported profile; park/serialize/discard background caches according to measured pressure and sensitivity." Fits the one-lane, unified-memory model (§§7.1, 9.1) and the `InferenceArbiter` priorities (P0–P3).
- **Compaction policy** — 75% of operational (not advertised) context, with artifactization of large tool results (§8). Prevents unbounded growth and silently degrades before OOM.
- **Adaptive-thinking interaction** (§8, final paragraph) — correctly flags that `enable_thinking` and per-pass tool sets are cache-identity components, and notes current `MLXProvider.generatePass` re-renders/tokenizes fresh each pass so no bug exists *today*. This is forward-looking and precise.
- **Unified-memory / Metal-conflict reasoning** (§§7.1, 9.1) — explicitly budgets `LiraBonsaiService` CPU-only memory and explains *why* CPU-only matters (Metal API conflict, not memory partitioning). Grounds the one-model rule.

### 4.2 Gaps / drift / missing pieces

These are genuine deltas between the contract's aspirations and what must still be built, plus places where the contract predates current (2026) practice:

| Area | Contract says | What's missing / needs update |
|---|---|---|
| **Real KV reuse is deferred** | Spec is complete, but `MLXProvider.generatePass` today does *no* reuse — re-renders/re-tokenizes every pass and turn. | The contract is correct but not yet realized. The next milestone should implement prefix KV reuse atop MLX's prompt cache / `KVCache` (hit on append-only prefix, miss on divergence), with hit-rate instrumentation and bake-off latency deltas. |
| **Quantized KV** | "Start with measured q8 KV if supported; q4 KV is a degradation mode only after quality testing." | Prescriptive text exists, but no wiring to MLX's `quantize`/`quantized_matmul` paths, no per-profile quality thresholds, no note on 2024–2025 advances (KIVI/QAQ/KVQuant) that improve q4 fidelity. Add a small eval gate for KV quantization specifically (distinct from weight quantization). |
| **Rotating / windowed KV** | Not mentioned; compaction & truncation are the only overflow tools. | MLX-LM's `RotatingKVCache` is a credible bounded-memory alternative to hard truncation for 16K+ turns. Needs an ADR note + bake-off branch: does rotation preserve Lira quality at 16K? When does it beat full compaction? |
| **Prefix-cache persistence** | Cache files are "derived and included in cascading delete," encrypted or avoided per policy; supports serialize/park. | Underspecified: file format (MLX `.safetensors` prompt cache vs. raw KV dump), encryption regime for at-rest KV, session vs. cross-session reuse scope, eviction LRU, and the `prompt-cache-file` lifecycle. Needs a small design note so two implementers agree. |
| **Speculation** | Not mentioned at all. | Intentionally out of scope for v1 is fine — but a one-paragraph "not in v1, here is why, here is what would trigger re-evaluation" (two-model vs. self-speculative, memory budget, MLX gap) would prevent future re-litigation. This doc provides that paragraph. |
| **Chunked prefill** | Not mentioned. | For the opt-in long-context path on 16 GB, chunked prefill reduces TTFT jitter and peak activation. Worth a one-line future-work note tied to the 75% compaction trigger (§8). |
| **LoRA / prompt-optimization as cache keys** | §17 correctly says "LoRA adapter revision and prompt-optimization revision both become new cache-identity components." | That rule is in the *future* self-optimization section, not in the canonical §8 key list. Promote it to §8's enumeration when the loop ships, so the hot path can't miss it. |
| **Optimal chunk size** | Not discussed. | MLX's own doc recommends chunk 256 for preallocation. Lira should pin a default (likely 256) and measure — a tiny detail that otherwise diverges by implementer. |
| **Age of research snapshot** | Snapshot 2026-07-13. | Acknowledge that post-July-2026 kernels (new MLX releases, new quantization papers) may move the frontier — bake-off pins exact `runtime_revision` + `model_revision` anyway, so staleness is bounded. |

### 4.3 Suggested contract edits (minimal)

1. Add a one-line *"Speculative decoding — not in v1"* rationale to §8 or §15, referencing this research doc.
2. Extend §8's persistence paragraph with: prompt-cache file format, encryption class, and single-conversation reuse scope.
3. Add a future-work bullet for `RotatingKVCache` / chunked prefill as an alternative to compaction at long context, gated on bake-off.
4. Promote §17's LoRA/prompt-opt revisions into §8's identity list when the self-optimization loop ships.

None of these require rethinking the contract — they tighten an already sound design.

---

## 5. Citations

- PagedAttention / vLLM — [arXiv:2309.06180](https://arxiv.org/abs/2309.06180), [vLLM GitHub](https://github.com/vllm-project/vllm)
- Speculative decoding — [arXiv:2211.17192](https://arxiv.org/abs/2211.17192), [arXiv:2302.01318](https://arxiv.org/abs/2302.01318)
- Medusa / EAGLE / tree verification — [Medusa (arXiv:2401.10774)](https://arxiv.org/abs/2401.10774), [EAGLE (arXiv:2401.15077)](https://arxiv.org/abs/2401.15077), [EAGLE-2](https://arxiv.org/abs/2405.17874), [SpecInfer](https://arxiv.org/abs/2305.09781)
- SGLang / RadixAttention / prefix caching — [arXiv:2312.07104](https://arxiv.org/abs/2312.07104)
- MLX — [MLX docs](https://ml-explore.github.io/mlx/build/html/index.html), [Writing a Fast KV Cache](https://ml-explore.github.io/mlx/build/html/usage/kv_cache.html), [mlx core GitHub](https://github.com/ml-explore/mlx)
- MLX-LM — [ml-explore/mlx-lm](https://github.com/ml-explore/mlx-lm) (prompt caching, rotating KV, `cache_prompt`)
- MLX Swift LM — [ml-explore/mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)
- llama.cpp server cache — [llama.cpp tools/server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- Prior Lira contract — `/Volumes/iMac II/Lira/docs/MODEL_RUNTIME.md` §§7–9 (snapshot 2026-07-13), and §4.2/§8 adaptive-thinking note
- QoL / context: Apple Foundation Models guidance via [WWDC 2026 session 339](https://developer.apple.com/videos/play/wwdc2026/339/), MLX issue [#3078](https://github.com/ml-explore/mlx/issues/3078) (Metal conflict category)

---

*No raw KV under a different key. One hot cache on 16 GB. Prefix reuse is the win; paging is for servers; speculation is for giants.*
