# Qwen3.8 27B on 8-16GB Macs via Unsloth quants (2026-08-20)

Research snapshot: 2026-08-20. Content recovered from bb thread `thr_ze29rdwdu3`'s log — the
thread reported writing this file but its environment never persisted it to this repo, so this
is a reconstruction from its cited primary sources and reasoning, not a copy of a lost file.

## What Qwen3.8 27B is

Released August 13-14 2026: [Qwen/Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B) /
[QwenLM/Qwen3.8](https://github.com/QwenLM/Qwen3.8). 27B dense, native vision+video input, 262K
context (extendable to 1M via YaRN), hybrid Gated DeltaNet attention (only 16 of 64 layers do
full attention — cheaper KV cache than a plain 27B transformer), Apache 2.0. Distinct from the
much older Qwen3-32B (April 2025).

## Unsloth's quantization ladder

[unsloth/Qwen3.8-27B-GGUF](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF): 21 quantization
levels from 6.19GB (`UD-IQ1_S`, 1-bit) to 54.7GB (BF16), using Unsloth's "Dynamic V3.0" method
(post-training quantization with improved per-layer importance sampling — [docs](https://unsloth.ai/docs/basics/dynamic-3.0-ggufs)).

Official Unsloth hardware table ([docs](https://unsloth.ai/docs/models/qwen3.8)):

| Quant | Size | Total memory needed |
|---|---|---|
| 1-bit (`UD-IQ1_S`) | 6.19GB | 7-8GB |
| 2-bit (`UD-IQ2_XXS`) | 7.27GB | 9-11GB |
| 3-bit (`UD-Q3_K_XL`) | 13.1GB | 12-14GB |
| 4-bit (`UD-Q4_K_XL`) | 17.6GB | 16-19GB |
| 6-bit | — | 23-26GB |
| 8-bit | — | 31GB |
| BF16 | 54.7GB | 56GB |

Unsloth's own text: *"4-bit works on 16-19GB VRAM like RTX 4090 or Mac with 24GB RAM."* The
"runs on 8GB" claim refers specifically to the 1-bit quant, which Unsloth states retains ~77%
of full-model accuracy ([discussion 74](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/discussions/74)).

## What this means on a 16GB Mac specifically

After ~3GB for macOS itself, a 16GB Mac has ~13GB of real headroom.

- **1-bit (6.19GB) and 2-bit (7.27GB) fit comfortably** — real headroom left for KV cache
  (conversation memory) and system overhead, no swapping, even at large context.
- **4-bit (17.6GB, the quality-preserving tier) does not fit** — this is why community guides
  (e.g. [fxai.ai](https://fxai.ai/notes/run-qwen38-mac-unsloth/)) say 16GB = "skip" this model
  at usable quality, 24GB is the real floor for 4-bit, 32GB is comfortable.
- Historical precedent for what happens when a model doesn't fit and swaps to SSD instead:
  [llama.cpp discussion #833](https://github.com/ggml-org/llama.cpp/discussions/833) — a 30B
  model on an 8GB Mac dropped to roughly 1 token/minute.

## Bottom line for Lira

This validates `ADR-0006`/`ADR-0014`'s existing 4-8B-class resident-model target for a 16GB
floor machine — it was already the right call, not something this research overturns. Qwen3.8
27B only becomes usable at meaningful quality on 24GB+ Macs, or as a **cloud** option via
`ADR-0017`'s provider-agnostic architecture (Qwen Cloud API or similar), not as a 16GB-floor
resident model. See
[`2026-08-20-small-model-smartness-ceiling.md`](2026-08-20-small-model-smartness-ceiling.md)
for why running it as a dispatched local worker alongside the resident model was considered and
rejected (conflicts with the zero-or-one-resident-model rule).
