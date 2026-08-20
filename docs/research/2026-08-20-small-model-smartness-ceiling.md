# Can a <10B open-weight model hit a 50+ Artificial Analysis Intelligence Index? (2026-08-20)

Research snapshot: 2026-08-20, via Artificial Analysis and primary model pages.

**Question:** the owner asked whether a small (<10B parameter) open-weight model can reach 50+
on the Artificial Analysis Intelligence Index — the "smartness" bar that would make a
resident-local model genuinely capable, not just fast.

## What plain terms mean here

"Artificial Analysis Intelligence Index" (AA score) is one third-party lab's composite
benchmark (reasoning, knowledge, math, coding) that most model comparisons cite as a rough
smartness ranking. Higher is better; frontier cloud models score in the 60s-70s.

## Findings, with sources

| Model | Params | AA Intelligence Index | Source |
|---|---|---|---|
| Qwen3.8 27B (reasoning) | 27B dense | **52** — #1/135 in its class | [artificialanalysis.ai/models/qwen3-8-27b](https://artificialanalysis.ai/models/qwen3-8-27b) |
| Qwen3.5 9B (reasoning) | 9B dense | **32** — highest of any <10B model found | [artificialanalysis.ai/articles/qwen3-5-small-models](https://artificialanalysis.ai/articles/qwen3-5-small-models) |
| Qwen3.5 4B (reasoning) | 4B dense | **27** (20 on the model's own page, 27 per the family article — both AA-sourced, discrepancy is likely index-version drift) | [artificialanalysis.ai/models/qwen3-5-4b](https://artificialanalysis.ai/models/qwen3-5-4b) |
| Qwen3.5 2B (reasoning) | 2B dense | 16 | same article |
| Qwen3.5 0.8B (reasoning) | 0.8B dense | 9 | same article |
| Qwen3 4B 2507 (prior gen) | 4B dense | 18 | same article |
| Falcon-H1R-7B | 7B | 16 | same article |
| NVIDIA Nemotron Nano 9B V2 (reasoning) | 9B | 15 | same article |
| Qwen3.5 397B A17B (reasoning, for scale contrast) | 397B MoE, 17B active | 34 | [artificialanalysis.ai/models/comparisons/qwen3-5-397b-a17b-vs-lfm2-1-2b](https://artificialanalysis.ai/models/comparisons/qwen3-5-397b-a17b-vs-lfm2-1-2b) |
| Liquid LFM2 1.2B / LFM2.5-1.2B | 1.2B | 1-2 | same comparison pages — no AA score found for a larger LFM2 7B/8.3B-MoE variant |

**Bonsai (PrismML) and Nanbeige** were confirmed as real model families earlier this session
(direct search, not yet re-verified via a dedicated subagent run after the provider outage), but
no Artificial Analysis Intelligence Index score was found for either during this pass — that
remains an open gap, not a negative result.

**`ai9stars/G9v3-3B`** — found and live hardware-tested by a separate research thread
(`thr_ze29rdwdu3`) after this doc was first written; recovered from its log since it deleted its
own output files at end of session. AA Intelligence Index **16** — tied #1 among ≤4B open-weight
models (with Qwen3-4B-2507, also 12-16 depending on index snapshot; MiniCPM5-1B scores 12).
Dense 3B `LlamaForCausalLM`, 131K context, Apache-2.0, tool-calling tag. Live-tested on this
machine via its MLX 4-bit quant (`cof139/G9v3-3B-mlx-4Bit`, 1.68GB): **0.59s load** (vs 58s for
the BF16 original), **44.7-52.0 tok/s** measured generation, correct tool-call and JSON output.
This is a real candidate for the bake-off shortlist below Qwen3.5-4B/9B in AA score alone, but
notably smaller and faster — see ticket #6 for the full intelligence-per-GB comparison.

## Answer

**No.** As of August 2026, nothing under 10B parameters clears 50 on the AA Intelligence Index.
The best <10B open-weight model found is **Qwen3.5 9B at 32** — well ahead of the rest of its
size class, but roughly 20 points short of the 50+ bar. The only model in this research pass
that clears 50 is **Qwen3.8 27B at 52** — nearly 3x the parameter count Lira's local budget
targets.

## Why this doesn't change Lira's architecture

Qwen3.8 27B's own quantization ladder (researched separately —
[`2026-08-20-qwen-unsloth-8gb-mac.md`](2026-08-20-qwen-unsloth-8gb-mac.md), content recovered
from `thr_ze29rdwdu3`'s log since the file didn't land on disk from that thread's environment)
needs 16-19GB just for weights at a quality-preserving 4-bit quant; the only quant that fits a
16GB Mac comfortably is the 1-bit (6.19GB, ~77% top-1 retained) — a real accuracy cost, and
Unsloth's own guidance says 16GB should "skip" this model.

Running it as a **second, dispatched-worker model alongside the resident 4-8B foreground
model** — the option `thr_ze29rdwdu3` proposed — was checked against `ADR-0014`'s
**zero-or-one-resident-model rule** and does not hold up as written: a worker load while the
foreground model is still resident is two model weight sets in memory at once on a 16GB
machine, which is exactly the case that rule exists to prevent. Making it work would require
unloading the foreground model first, waiting for the worker to run, then reloading foreground
— real latency and state-management complexity for a 1-bit model that's already quality-degraded
relative to the resident 4-8B Q4 candidates already on the bake-off shortlist. That's the
overengineering trade `AGENTS.md`'s working agreement calls out explicitly.

**Decision: no ADR change.** The 4-8B Q4 resident-model target from `ADR-0006`/`ADR-0014` stands.
Chasing a 50+ score means leaving the local/resident tier entirely and using a cloud provider —
which `ADR-0017`'s provider-agnostic architecture already supports today, with zero new
machinery: the owner can pick Qwen3.8 27B (or any other 50+ cloud model) as primary or dispatch
specific hard sub-tasks to it, while Lira's identity, memory, and personality stay exactly the
same either way.
