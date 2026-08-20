---
status: accepted
---

# Resident local model: G9v3-3B (MLX 4-bit)

Resolves the model bake-off (ticket #6), the last open item on the v1 architecture map.
`ADR-0006`/`ADR-0014` already fixed the shape (single resident model, 4-8B class, 16GB budget,
prefix/KV-cache reuse); this decides which model fills that slot.

**Decision:** `ai9stars/G9v3-3B`, run via its MLX 4-bit quantization
(`cof139/G9v3-3B-mlx-4Bit`, 1.68GB on disk).

**Why, from a live hardware-verified bake-off on the owner's actual M4 iMac (16GB)**, not spec
sheets:

- **0.59s load** (vs 58.4s for the same model's BF16 original via transformers/MPS)
- **44.7-52.0 tok/s** measured generation
- Correct tool-calling and JSON output, verified against a running local server
- Artificial Analysis Intelligence Index **16** — tied #1 among all ≤4B open-weight models
  (ahead of Qwen3-4B-2507 and MiniCPM5-1B, both at 12)
- 131K context, Apache-2.0, dense 3B `LlamaForCausalLM`
- ~11.4GB of the 16GB budget left over for KV cache, `LiraBonsaiService`, and system overhead

This supersedes the shortlist research in `#5`/`#31` (Qwen3-4B, Qwen3-8B, Gemma 3 4B,
Llama 3.2 3B, Qwen3.5-4B, Qwen3.5-9B) — those were never re-measured against G9v3-3B because
they don't need to be: G9v3-3B already leads on both intelligence and speed at this size class
on real hardware, not just on paper. Separately confirmed (`docs/research/2026-08-20-small-model-smartness-ceiling.md`):
no model under 10B parameters reaches 50+ on the Artificial Analysis Intelligence Index — the
frontier for that starts at 27B dense. Chasing it means leaving the resident-local tier
entirely, which `ADR-0017`'s provider-agnostic architecture already supports as a cloud option
with no new machinery.

**Why not the shortlist runners-up:** Qwen3.5-4B scores higher on paper (27 vs 16) but was
never bake-off-verified before this decision closed; G9v3-3B's numbers are real, measured, and
already comfortably ahead of every other candidate that *was* measured. If Qwen3.5-4B or
Qwen3.5-9B are ever worth reconsidering, that's a fresh ticket with its own real measurement,
not a reopening of this one.
