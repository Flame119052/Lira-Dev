---
status: accepted
---

# Local inference optimization: prefix/KV-cache reuse, no PagedAttention, no two-model speculative decoding

The owner asked for heavy optimization of the resident local model given its small size (~4-8B class) and the potential for large conversation context. Research confirmed the prior implementation's cache-identity contract (`docs/MODEL_RUNTIME.md` §7-9 in the reference repo) was already sound — the gap was that it was never actually built, not that it was wrong.

**Decision:**

1. **Adopt prompt/KV-cache reuse** as the core v1 optimization, per the prior contract: cache identity keyed on model revision + runtime revision + tokenizer hash + quantization/config + chat-template hash + persona/constitution revision + tool-schema revision + exact append-only conversation-prefix hash. Invalidate the instant any component changes; never restore raw cache state under a different key. This is what avoids re-processing the entire growing conversation from scratch on every message — the single highest-leverage technique for this product's shape.
2. **Explicitly reject PagedAttention** (the vLLM memory-management technique) — no MLX equivalent exists, and it solves a many-concurrent-sequences problem Lira doesn't have (one user, one conversation, one decode lane).
3. **Explicitly reject two-model speculative decoding** (a draft model predicting tokens a larger model verifies) — would require a second resident model, breaking the already-decided zero-or-one-resident-model rule and the 16GB unified-memory budget; MLX also lacks stable support for it.
4. **Defer, don't decide now: draft-free self-speculative techniques** (prompt-lookup decoding, EAGLE-style heads — the same single model speeding itself up, no second model) — genuinely promising, but evaluated with real numbers during the model bake-off (ticket #6), not committed to abstractly here.
5. **Also adopted from the prior contract**: KV-cache compression starting at a conservative level (more aggressive only after quality testing), and chunked handling of long context rather than processing it all at once.

**Why:** focuses real engineering effort on what actually matters for a single-user local assistant, rather than building server-scale machinery (PagedAttention, multi-model speculative decoding) this product will never need — the same overengineering-avoidance principle already codified in `AGENTS.md`.
