# Resident-model candidates for Lira

Wayfinder research ticket #5 (child of map issue #4). Surveys candidate open-weight models that could plausibly run as Lira's **zero-or-one resident custom local generative model** (ADR-0006, unchanged), on the owner's Apple **M4 iMac, 16GB RAM, macOS 26**, with **MLX Swift** as the inference runtime.

**Scope note:** this is a *shortlist*, not a final pick. ADR-0006 defers "exact local model pick and quantization" to a bake-off on this specific machine. This doc bounds the candidate space and budgets headroom so that bake-off starts from a small, realistic set.

## Hard constraint: this is the owner's daily-use Mac

The ticket is explicit that real headroom matters, not just raw capacity. Lira is a durable, always-available agent (SQLite core, event ledger, Playwright/CDP browser, Activepieces connectors, voice STT) running on the *same* machine the owner works on all day. So the resident model must:

- Fit comfortably in the **unified 16GB** pool *alongside* the rest of macOS + the owner's apps + Lira's own subsystems (the resource governor in ADR-0006 reserves envelopes and evicts background work under pressure — the resident model is the single biggest, most permanent reservation).
- Leave enough free memory for the user's foreground apps to stay responsive (foreground always wins).

A pragmatic budget: reserve **2–6GB** for the resident model (weights + KV cache + runtime), keeping **10GB+** of headroom for everything else. That rules out anything that needs ~8GB+ at its plausible quant, and pushes toward **3B–8B-class** models quantized to 4-bit.

> Memory figures below are the official **MLX 4-bit checkpoint sizes** published on Hugging Face (`mlx-community/...`), which are the actual on-disk/in-RAM weight sizes for MLX. True peak RSS is somewhat higher (KV cache + activations), so each candidate's working headroom is budgeted with margin.

## Shortlist

All four candidates are open-weight, have first-class, actively-maintained MLX ports, and support the MLX Swift stack (`mlx-swift-lm`, `MLXLLM`/`MLXVLM`) referenced in the mlx-swift-examples repo. License notes included because they matter for distribution/updates (ADR-0002 public repo).

| Model (MLX 4-bit repo) | Weights @4-bit | Working budget (with margin) | Quality tier | Latency feel | License |
|---|---|---|---|---|---|
| **Qwen3-4B** | 2.26 GB | ~3 GB | High for size | Very fast, near-instant | Apache-2.0 |
| **Qwen3-8B** | 4.61 GB | ~6 GB | Top of this class | Fast, responsive | Apache-2.0 |
| **Gemma 3 4B (IT)** | 3.4 GB | ~4.5 GB | High for size, **multimodal** | Fast, responsive | Gemma Terms of Use |
| **Llama 3.2 3B (Instruct)** | 1.81 GB | ~2.5 GB | Good (lightweight) | Fastest, minimal | Llama 3.2 license |

### 1. Qwen3-4B — the balanced default candidate

- **Memory:** 2.26 GB @4-bit MLX; comfortably ~3GB working budget.
- **Quality:** Qwen3 generation is the strongest small-model family in the current open-weight landscape for its size — strong instruction-following, reasoning, and multilingual support. Notably better conversational quality than older 7B/8B models.
- **Latency:** at ~4B params on an M4 this is effectively interactive — sub-100ms per-token decode at 4-bit, giving a genuinely conversational, "responding as you think" feel rather than stalling.
- **Why for Lira:** best quality-per-gigabyte; leaves the most headroom of the quality candidates; Qwen3 explicitly markets agentic/tool-calling capability, which is directly relevant to Lira's tool-adapter / MCP surface. Apache-2.0 is the cleanest license for a public repo and for bundling with the app.
- **Notes:** supports a thinking/non-thinking toggle within one model (relevant to the "foreground always wins" decode-lane constraint — run simple turns in non-thinking mode, spend tokens on reasoning only when needed). Sources: [Qwen3-8B model card](https://huggingface.co/Qwen/Qwen3-8B) (family/features), [Qwen3-4B MLX 4-bit](https://huggingface.co/mlx-community/Qwen3-4B-4bit).

### 2. Qwen3-8B — the quality-maximum candidate

- **Memory:** 4.61 GB @4-bit MLX; ~6GB working budget. Still fits within a 16GB machine with a realistic 10GB+ headroom envelope for the rest of the system, but it is the largest model this doc considers comfortable for a daily-use 16GB machine.
- **Quality:** the top of this size class — noticeably stronger reasoning and writing than 4B, best-in-class agentic/tool-calling among open small models.
- **Latency:** fast and responsive on M4 at 4-bit, though decode-per-token is slightly slower than 4B; still comfortably interactive.
- **Why for Lira / vs 4B:** pick 8B if quality turns out to dominate and the bake-off shows the ~6GB reservation is tolerable day-to-day. Pick 4B if you want maximum headroom for the owner's other apps. Both are in the same family, so switching is a config change, not a rewrite.
- **Sources:** [Qwen3-8B model card](https://huggingface.co/Qwen/Qwen3-8B), [Qwen3-8B MLX 4-bit](https://huggingface.co/mlx-community/Qwen3-8B-4bit).

### 3. Gemma 3 4B (IT) — the multimodal candidate

- **Memory:** 3.4 GB @4-bit MLX; ~4.5GB working budget (slightly higher than Qwen3-4B because it carries vision weights).
- **Quality:** strong conversational model from Google's Gemma 3 family (built on Gemini 2.0 research).
- **Latency:** fast/responsive on M4 at 4-bit.
- **Why for Lira:** the differentiator is that Gemma 3 4B is **multimodal (image + text)**. Lira's computer-control surface (per-app screen capture shown via a preview, ADR-0006) could benefit from a model that can actually *see* a captured screen and reason about it, in one resident model — no separate vision component. If that capability is worth the extra ~1.5GB vs Qwen3-4B, it's a strong candidate.
- **Notes:** license is Google's Gemma Terms of Use (more restrictive than Apache-2.0 — worth checking against the public-repo/distribution story). Source: [Gemma 3 4B MLX 4-bit](https://huggingface.co/mlx-community/gemma-3-4b-it-4bit) (mlx-vlm; note this is a VLM port).

### 4. Llama 3.2 3B (Instruct) — the minimal-footprint candidate

- **Memory:** 1.81 GB @4-bit MLX; ~2.5GB working budget — the smallest here. This is mlx-lm's own default example model.
- **Quality:** good but noticeably lighter than Qwen3/Gemma 3 at similar sizes; best for lightweight, always-on assistant chat, not heavy reasoning or tool orchestration.
- **Latency:** fastest of the set; smallest memory reservation leaves maximum room for the owner's apps and the rest of Lira's subsystems.
- **Why for Lira:** the "safest" choice for headroom on a heavily-used 16GB Mac, and the natural fallback if the bake-off shows quality is acceptable and footprint is the binding constraint. Source: [Llama 3.2 3B Instruct MLX 4-bit](https://huggingface.co/mlx-community/Llama-3.2-3B-Instruct-4bit), [mlx-lm README](https://github.com/ml-explore/mlx-lm).

## Explicitly not shortlisted

- **Qwen3-14B** (8.31 GB @4-bit MLX): weights alone consume half the machine. Even before KV cache and the rest of Lira + macOS + the owner's apps, this leaves far too little headroom on a 16GB daily-use Mac. Listed only as the ceiling to say *this is where "too big for this machine's headroom budget" starts*. Source: [Qwen3-14B MLX 4-bit](https://huggingface.co/mlx-community/Qwen3-14B-4bit).
- Larger Llama 3.1/3.3 8B and Mistral/ Ministral 8B: redundant with Qwen3-8B (same size class, generally weaker small-model quality/agentic support) — listed for completeness but not competitive for Lira's needs. Mistral 7B has an MLX port but Qwen3-4B/8B beat it on quality-per-byte and licensing.

## Recommendation for the bake-off (not a final pick)

Run a same-machine bake-off (per ADR-0006) on **Qwen3-4B vs Qwen3-8B vs Gemma 3 4B**, all at 4-bit, measuring: real peak memory (RSS) *while the owner's normal workload is running*, per-token latency, and quality on a small set of Lira-relevant tasks (conversation, tool-call formatting, and — if Gemma is in the mix — screen-capture description). Use the results to pick the resident model; the runner-up in the same family remains a config swap.

Deciding factors to weigh: **Qwen3-4B** if headroom is the priority (default), **Qwen3-8B** if quality wins and ~6GB is tolerable, **Gemma 3 4B** if native vision (screen understanding) is worth the footprint and the license is acceptable, **Llama 3.2 3B** only as the minimal-footprint fallback.

## Sources

- [MLX LM (ml-explore)](https://github.com/ml-explore/mlx-lm) — MLX inference engine, supported-model + streaming + quantization docs; confirms Qwen/Llama/Mistral/Gemma support and 4-bit MLX community checkpoints.
- [MLX Swift Examples](https://github.com/ml-explore/mlx-swift-examples) — the Swift inference stack (`mlx-swift-lm`, `MLXLLM`, `MLXVLM`) Lira would embed; confirms the runtime is viable in a native Swift app.
- [Qwen/Qwen3-8B](https://huggingface.co/Qwen/Qwen3-8B) — family, features (thinking toggle, agentic/tool use, Apache-2.0).
- [mlx-community/Qwen3-4B-4bit](https://huggingface.co/mlx-community/Qwen3-4B-4bit) — 2.26 GB @4-bit.
- [mlx-community/Qwen3-8B-4bit](https://huggingface.co/mlx-community/Qwen3-8B-4bit) — 4.61 GB @4-bit.
- [mlx-community/Qwen3-14B-4bit](https://huggingface.co/mlx-community/Qwen3-14B-4bit) — 8.31 GB @4-bit (excluded).
- [mlx-community/gemma-3-4b-it-4bit](https://huggingface.co/mlx-community/gemma-3-4b-it-4bit) — 3.4 GB @4-bit (VLM).
- [mlx-community/Llama-3.2-3B-Instruct-4bit](https://huggingface.co/mlx-community/Llama-3.2-3B-Instruct-4bit) — 1.81 GB @4-bit.

*All external facts (memory sizes, MLX availability, licensing, family/feature claims) were verified against the live sources above at the time of writing. Quality-tier and latency-feel ratings are informed estimates for an M4 16GB machine and must be confirmed by the same-machine bake-off; they are not benchmark measurements.*
