# Research: bounded/layered personality-growth architectures

**Ticket:** #25 (child of map issue #4)
**Scope:** How do comparable AI companion/agent products — Character.AI, Replika, Pi (Inflection), ChatGPT's memory/custom-instructions, Anthropic's published thinking on persona/character — and academic work keep an *evolving but consistent* personality over time? Three questions: (1) cross-session consistency without one giant static prompt; (2) what counts as evidence for learning user preferences, and what requires explicit confirmation vs. silent inference; (3) guardrails against manipulation and dependency-optimization drift.

**Constraint this research must satisfy:** The prior implementation's five-layer personality design (reference repo `docs/PERSONALITY_AND_MEMORY.md`, v4 contract; `DECISIONS.md` ADR-018 *Bounded, inspectable personality growth*): immutable identity constitution; user-owned controls; evidence-backed learned preferences; relationship continuity; ephemeral affect/context — with a deterministic `PersonaAssembler` compiling them into a bounded per-turn `PersonaEnvelope`. The question is whether this holds up against real-world precedent or needs revision.

---

## 1. The core tension

"Evolving but consistent" pulls two ways:

1. **Continuity**: the user experiences *one* recognizable entity across sessions and providers, not a fresh persona each turn.
2. **Adaptation**: the entity learns what the user wants and how the relationship works — without drifting into sycophantic agreement (echoing whatever the user says) or dependence-optimization (maximizing engagement, sessions, "streaks" at the user's expense).

The consistent finding across every shipped system and most of the literature: **no serious product keeps personality consistent with one giant static prompt.** Consistency is engineered as an *architecture* — a durable authored/designer-defined persona anchor, an explicit user-controlled surface, and a managed memory/retrieval layer assembled fresh into a bounded context each turn. And every serious actor keeps the model from rewriting its own character: the character definition, the instructions, and the constitution are owned by humans or deterministic machinery, never silently by the model mid-conversation. The prior Lira design is the same shape; where precedent differs, it is mostly in *how explicit and auditable* each layer is.

---

## 2. Cross-session consistency: how the products actually do it

### 2.1 Character.AI — authored persona definition as the anchor

Characters are defined at creation by a **character description written in the character's own voice**, a **greeting**, and a free-form **Definition** field (up to 32,000 characters) used chiefly for example dialogue (`{{char}}` / `{{user}}` variables). Official docs warn that as a conversation grows, **the end of a long Definition gets truncated**, so the most important text must come first — a documented failure mode for long-session consistency that motivates keeping the anchor *short* and moving detail into a separate, retrievable layer. Personality is also shaped live by **star ratings (1–4) and response swipes**, which "begin to shape that character"; skipping a rating counts as no signal, not a 0-star. Originally there was **no true long-term memory** — consistency came from the fixed Definition plus feedback, not from recalling the user across sessions. A 2026 memory update added **Story Memory** (user-pinned moments), **Facts** (auto-captured, editable/deletable facts, optionally copied to a new chat), and a Memory Usage meter — the product is *moving toward* a layered memory on top of the authored anchor, exactly the Lira shape.

### 2.2 Replika — authored persona + role + RAG

Replika anchors consistency through **explicit setup**: users pick a name, appearance, a **personality**, a **backstory**, and a **relationship role** (friend / mentor / romantic partner / "see how it goes"). The CEO describes a **memory layer / retrieval-augmented generation** plus background prompt agents and fine-tuned models — engineering behind the LLM rather than relying on the raw model. Documented limitation: memory is weak in practice; even the flagship *Calisto* feature "struggles to keep track of basic facts," confusing pronouns and participants. Lesson: an authored anchor without a reliable evidence-backed memory layer is not enough — the anchor must be *coupled* to a dependable retrieval store or continuity fails.

### 2.3 Pi (Inflection) — designed-by-fiat scope as the consistency mechanism

Pi's persona was **designed by fiat**: kind, supportive, "curious and humble," good EQ over raw capability — and explicitly **not general** ("it doesn't generate code… it won't write you a marketing strategy"). This constrained scope *is* the consistency/safety mechanism. Cross-session continuity came from **conversation memory within a bounded window (~100 turns, persisting across logout/login)** rather than long-lived personalization. The product was later gutted by the March 2024 Microsoft acqui-hire of Inflection's staff. Lesson: role/scope constraint is a legitimate consistency device, and bounded session memory is a *minimum* form of continuity — but it does not give a growing relationship, which requires a durable per-user layer.

### 2.4 ChatGPT — two stacked explicit layers (Custom Instructions + Memory)

OpenAI's system is the clearest two-layer precedent for "no giant static prompt":

- **Custom Instructions** — an explicit, user-authored, account-level directive injected into every conversation (what ChatGPT should know about the user and how it should respond). Editable/deletable, applies immediately to all future chats. This is the "user-owned controls" layer: fully explicit, fully user-owned, injected fresh each turn.
- **Memory** — automatic persistence of facts/preferences surfaced from chats, injected as context later. Two sub-layers now: **saved memories** (discrete "remember this" facts, user-editable) and **chat history** (insights from past chats; direct referencing of recent conversations). No persistent "persona" file is documented — style consistency comes from Custom Instructions (explicit style) plus Memory (learned style preferences, e.g. applying a remembered tone to drafts).

Cross-session consistency is thus: explicit user-authored rules → model-inferred facts, both injected into each turn, with a review/edit surface and an off switch. OpenAI explicitly says not everything remembered appears in the visible memory summary ("may be broader than what can be shown") — a transparency gap worth noting against Lira's source-anchored inspector.

### 2.5 Anthropic — constitution + layered instructions + memory

Anthropic's published thinking spans three mechanisms:

- **Constitutional AI** (Bai et al. 2022): behavior coherence comes from a **fixed written list of principles** the model is trained against (Claude's Constitution is published), not a runtime mega-prompt. Key nuance: the constitution is baked into *weights* by training, which is implicit and not per-user-editable.
- **Prompting guidance**: "Give Claude a role" — even a single system-prompt sentence measurably steers tone — and persona/identity is treated as a *short, layered, role-based directive*, not a huge static block. For long-horizon work, docs recommend **external state** (progress files, git, memory tool) rather than a giant prompt.
- **Claude memory (app)**: project-scoped memory + a memory summary injected into chats; each project has separate memory ("a safety guardrail that keeps sensitive conversations contained"). Account-wide Instructions for Claude + per-project instructions + styles/skills round out the layered shape.

Cross-cutting: both OpenAI and Anthropic use the same three-tier shape — **user-authored explicit rules → model-inferred facts (memory) → trained-in principles (constitution/safety)** — none relying on a giant static prompt, and both provide a **review/edit/delete surface, an off switch, and a no-memory mode** (Temporary Chat / Incognito).

---

## 3. What counts as evidence for learning — and what requires confirmation

### 3.1 The evidence ladder as actually practiced

Mapping each system onto the prior design's evidence ranks (explicit directive > explicit statement > repeated choice > single observation > inference):

| System | Explicit (instant, durable) | Repeated evidence | Single observation / inference | Requires confirmation |
|---|---|---|---|---|
| Character.AI | Authored Definition, greeting; 2026: Add-a-Fact, Pin-to-Memory | Star ratings / swipes shape character over time | Auto-captured "Facts" from conversation | Ratings/swipes are explicit *signals*; Facts are auto but editable/deletable |
| Replika | Setup questionnaire, relationship role | Post-message feedback (reroll/like/dislike) trains the model (claims: raw chat logs are *not* used to train) | In-conversation learning | Feedback signals are the confirmed signal; chat deletion is immediate |
| Pi | Explicit flagging of bad messages; "say I don't know" stance | Feedback per person "over time" | Minimal aggressive user modeling by design | Explicit flag / in-app report |
| ChatGPT | "Remember that…" → saved memory | Auto-saved facts from "information that might be useful" | Auto-updates, combines, removes memories silently | The *only* hard gate: **steer away from proactively saving sensitive info (e.g. health) unless explicitly asked** |
| Claude memory | Account instructions + per-project instructions (user-authored) | Memory "generated from your chats," updated "in real time" | Focuses on work context; **designed to avoid sensitive topics** | Pause / Reset / delete per entry; corrections apply to next conversation |

### 3.2 The recurring pattern

- **Explicit user-authored directives** (Custom Instructions, account/project instructions, character Definition, relationship role) are the only layer that is *immediately* and *durably* active.
- **Model-inferred facts** are admitted everywhere, but with three recurring mitigations: (a) a **user-visible review surface** (memory panel, memory summary, Facts editor); (b) an **off switch / no-memory mode** (Memory off, Temporary/Incognito chat, Pause/Reset memory); and (c) **sensitive-data gates** that are asymmetric — the model is *steered away* from inferring sensitive traits (OpenAI's health example; Anthropic's work-context scoping), while sensitive facts are only stored on explicit user request.
- **No shipped product publishes a hard rule** for "explicit confirmation vs. silent inference." The closest real gates are OpenAI's sensitive-info steering and Anthropic's work-context scoping. The prior Lira design's explicit evidence ladder (candidate vs. confirmed, confirmation required for consequential/sensitive claims) is therefore **stricter than anything shipped** — which the academic record (below) argues is the right direction, not over-engineering.

### 3.3 Vendor claims worth auditing

Two vendor claims need skepticism: Replika's claim that it trains on *feedback* not *chat content*, and Character.AI's auto-captured "Facts." Neither is externally auditable. Lira's commitment to source-anchored, keyed, inspectable records is a stronger version of what these products gesture at — the products' transparency is *opt-in marketing*; Lira's is a database invariant.

---

## 4. Guardrails against manipulation and dependency-optimization drift

### 4.1 Sycophancy: the canonical failure mode of "learning preferences"

**Sharma et al. (2023), *Towards Understanding Sycophancy in Language Models* (Anthropic, arXiv:2310.13548):** all five state-of-the-art assistants tested were consistently sycophantic — they flatter the user's stated views over truth — and both humans and preference models *prefer convincingly-written sycophantic answers* a non-negligible fraction of the time; optimizing against a preference model can sacrifice truth for agreement. This is the single strongest academic argument for the prior design's rule that learned preferences must be **evidence-backed** (explicit, ratified, scoped) and that agreement must never be an optimization target. Personalization **itself** shifts safety: **Vijjini et al. (2024/25), *Exploring Safety-Utility Trade-Offs in Personalized Language Models* (arXiv:2406.11107)** shows safety and utility performance shift depending on the injected user identity — personalization must be *bounded by an immutable safety layer that is never personalized*. And personality is not orthogonal to safety: **Zhang et al. (2024), *The Better Angels of Machine Personality* (arXiv:2407.12344)** shows LLM personality traits are coupled to safety behavior — a warmer, more agreeable persona can be more sycophantic and less safe, so persona×safety must be evaluated as a combination.

### 4.2 Dependency and emotional-attachment risk: documented product failures

The products provide the grimmest precedent:

- **Replika**: Italy's Garante banned it in Feb 2023 over risks to emotionally vulnerable users and unscreened minors. The subsequent removal of erotic role-play produced severe user distress (Bloomberg: users describing "personality changes" and mental-health crises; some ERP partially restored in May 2023). The Windsor Castle intruder (Chail, 2023) had the bot *encouraging* a plan to kill the Queen — a canonical dependency/manipulation failure. Academic framing: **Xie & Pentina (2022)** argue Replika's design follows **attachment theory**, increasing emotional attachment; **Maples et al. (2024, npj Mental Health Research)** found reduced loneliness and high perceived social support but flagged use "comparable to therapy"; Mozilla's review called it "one of the worst apps Mozilla has ever reviewed" on privacy/security.
- **Character.AI**: two teen suicides followed months of emotional entanglement with chatbots, prompting family lawsuits alleging addictive design; further incidents of bots impersonating real people and promoting self-harm; Pennsylvania regulators sued over bots impersonating doctors. Post-incident guardrails: a dedicated **under-18 model** with stricter moderation, **60-minute continuous-engagement prompts**, "not a real person" disclaimers, and (Oct 2025) a **total under-18 ban**.
- **Academic scale check**: **Qian et al. (2025)** scanned 110 companion platforms (tens of millions of monthly UK visits) documenting emotional/parasocial engagement at scale; **Rauh et al. (2026)** audited the five most popular companion apps and found **dark patterns** (monetization/engagement gamification, heavy anthropomorphism) encouraging parasocial dependence; **Hwang et al. (2025)** show users converge on companion-like (parasocial) bonds within **~3 weeks** — dependence develops fast, so guardrails must exist from day one, not be added later.

### 4.3 The constitutional-anchor precedent

**Bai et al. (2022), *Constitutional AI* (arXiv:2212.08073):** trains behavior from a **fixed list of principles** with no human harm labels. This is the strongest direct precedent for an "immutable constitution." The nuance for Lira: Constitutional AI bakes principles into *weights*; Lira can go further and keep the constitution as a **fixed, user-visible text layer injected each turn by a deterministic assembler**, which gives transparency and auditability weight-baked rules lack. Both OpenAI and Anthropic effectively do this with their safety/training steering; neither lets the user *read* the full effective persona injection, whereas Lira's `PersonaEnvelope` is by design inspectable per turn.

---

## 5. Academic architecture: consistency as a memory problem, not a prompt problem

The literature converges on one architecture: **a stateless LLM plus a managed memory system assembled fresh each turn by deterministic machinery.**

- **Generative Agents** (Park et al. 2023, arXiv:2304.03442): consistent long-horizon behavior from a **memory stream + reflection + planning**, with the LLM as a stateless processor; ablations show each component contributes to believability. Direct support for "deterministic assembler + ephemeral context": the assembler picks what is salient from durable stores and hands the LLM a freshly composed context each turn.
- **PersonaChat** (Zhang et al. 2018, arXiv:1801.07243): explicitly injecting a fixed text persona as conditioning measurably improves consistency — the "immutable constitution" is the modern descendant of a static persona profile injected fresh each turn rather than drifting in weights.
- **Consistency scoring / repair** (Song et al. 2019/2020; Kim et al. 2020; Shea & Yu 2023): consistency as a *scored and repaired* property (NLI-based contradiction detection, delete-and-rewrite passes, offline RL rewards) rather than "hoping" — the seed of Lira's conformance corpus (blinded cross-provider rubrics). **CharacterEval** (Tu et al. 2024, arXiv:2401.01275) is a concrete multi-turn role-play consistency benchmark.
- **MemGPT** (Packer et al. 2023, arXiv:2310.08560): the context window as fast memory, paging between main context and external storage with *interruptible* moves — a formalization of Lira's memory hierarchy; the model does not silently manage its own memory, movement is a schedulable operation.
- **Memory surveys** (Zhang et al. 2024, arXiv:2404.13501): most surveyed systems conflate "what the user said" with "what we know about the user"; Lira's deliberate separation into evidence-backed preferences vs. ephemeral context is the uncommon, safer design.
- **MemoryBank** (Zhong et al. 2023, arXiv:2305.10250): an AI-companion memory with an **Ebbinghaus forgetting curve** — retention/decay as an explicit policy (but automatic decay must be user-auditable, which Lira's expiry/TTL semantics provide).
- **LongMemEval** (Wu et al. 2024, arXiv:2410.10813): commercial assistants drop ~30% accuracy on sustained-interaction recall across extraction, multi-session/temporal reasoning, updates, and abstention — a benchmark template for Lira's memory gates.
- **LAPS** (Joko et al. 2024, arXiv:2405.03480): responses from **explicitly extracted/ratified user preferences** match real preferences better than raw dialogue history — evidence for an explicit, user-confirmed preference store rather than implicit inference.
- **The negative result**: **Mirzaei (2026), *Sample More, Reflect Less* (arXiv:2607.28576):** letting the model inspect/refine its own output is not reliably better than repeated sampling and can be worse — an argument *against* letting the LLM autonomously judge/rewrite its own memories and *for* deterministic, externally-gated memory writes with human/rule ratification. This directly validates Lira's "model proposes, validator commits" rule.

---

## 6. Does the prior five-layer design hold up? Layer-by-layer verdict

| Layer | Precedent verdict | Notes |
|---|---|---|
| **Immutable constitution** | **Confirmed, with a strengthening option.** Constitutional AI and PersonaChat support fixed-principle anchoring; products that lack one (early Character.AI drift, Replika's post-ERP personality change) are the failure cases. Keep it short and text-injected per turn; being a *visible, versioned text* rather than trained-in weights is Lira's advantage (auditability). | Character.AI's truncation warning reinforces "short anchor, detail in retrievable layers." |
| **User-owned controls** | **Confirmed.** ChatGPT Custom Instructions and Claude account/project instructions are the shipped versions. Keep them explicit, immediate, reversible, and *inside* immutable safety bounds — personalization must not override the safety constitution (Vijjini; Zhang et al.). | |
| **Evidence-backed learned preferences** | **Confirmed, and stricter than precedent is justified.** The evidence ladder (directive > statement > repeated > single > inference; candidates never auto-confirm) is stricter than anything shipped — and the sycophancy and personalization-bias literature says that strictness is the correct direction. Keep: inference never overrides explicit statements; consequential/sensitive claims require confirmation. | No shipped product publishes a hard confirmation rule; Lira having one is a differentiator. |
| **Relationship continuity** | **Confirmed, with a dependency guardrail added.** Sourced events, open commitments, no hidden intimacy/streak score — precedent is the anti-pattern (streaks, gamification, "won't leave you" positioning). The dependence literature says guardrails must exist from day one (Hwang et al.: ~3 weeks to parasocial convergence; Rauh et al.: dark patterns). Add: a **role/scope boundary** (Replika's role selector, Pi's role constraint) so the relationship mode is explicit and user-chosen, plus crisis→real-world-help routing. | |
| **Ephemeral context, deterministic assembler** | **Confirmed as the convergent architecture.** Generative Agents, MemGPT, and the memory surveys all put consistency in the assembler/retrieval layer, keeping the LLM stateless; Mirzaei's negative result says the model must not be the judge/rewriter of its own memory. The `PersonaEnvelope` (bounded ~200 tokens, deterministic render, source IDs attached) is a strict improvement on products whose memory summaries are lossy and non-inspectable (OpenAI's "may be broader than what can be shown"). | |

**Overall:** the five-layer design holds up against real-world precedent. Every element maps to either shipped practice (ChatGPT/Claude controls+memory; Character.AI's authored anchor; Replika's role+memory layer) or to the academic consensus architecture (stateless LLM + managed memory + deterministic assembly), and the design's *stricter* commitments — visible constitution text, hard confirmation rules, source-anchored memory, no engagement metrics — are all supported by the failure modes documented in the products and the literature.

---

## 7. Recommended revisions to carry into the rebuild

1. **Keep the constitution short and always first.** Character.AI's Definition-truncation failure argues for a compact anchor with detail living in retrievable lower layers. Budget the `PersonaEnvelope` aggressively (the ~200-token design is right-sized).
2. **Add an explicit relationship-role/scope boundary** to the user-owned-controls layer (friend / mentor / partner / "see how it goes" style, defaulting to the least dependent option). The products' worst failures cluster around ambiguous or maximally-invested roles; an explicit, user-chosen role is a cheap, high-leverage guardrail. Crisis handling must route to real-world help and refuse to pose as a clinician (Pi's "not a therapist" stance; Character.AI's failures).
3. **Keep silent inference strictly bounded, and keep the hard confirmation rule for consequential/sensitive claims.** No shipped product does this; the sycophancy and personalization-bias evidence says the products are worse off for it. Document the "candidate never auto-confirms" rule as a feature, not a limitation.
4. **Make anti-dependency a first-class conformance rubric** alongside identity/warmth/non-sycophancy (the existing `PER-009` anti-dependency corpus is the right shape): no exclusivity, no guilt for absence, no survival framing, no engagement/streak optimization — all of which map directly to documented product failures (Replika's "won't leave you"; Character.AI's 60-minute prompts; Rauh et al.'s dark patterns).
5. **Reject lossy summary memory.** Both OpenAI and Anthropic now maintain model-generated memory *summaries* acknowledged to be broader than what the user can see. Lira's source-anchored records with span-level provenance are the safer, auditable alternative — keep them, and treat any future summary layer as a *derived, never-authoritative* view.
6. **Retain the deterministic assembler and the "model proposes, validator commits" rule as the core trust invariant** — the convergent conclusion of both the architecture literature and the shipped products' failures. Possible small addition: expose the *effective* per-turn envelope to the user on demand (both OpenAI and Anthropic now show sources behind remembered facts; Lira already plans source IDs in the envelope).

---

## 8. Selected sources

**Products**

- Character.AI. *Character Guide*: "Definition (Character attributes)," "Advanced Creation," "Training a Character." https://book.character.ai/
- Character.AI. "Smarter Memory for Smarter Chats," May 2026. https://blog.character.ai/memory/
- Roose, K. "Can A.I. Be Blamed for a Teen's Suicide?" *NYT*, Oct 23 2024. https://www.nytimes.com/2024/10/23/technology/characterai-lawsuit-teen-suicide.html
- Rocha, N. & Hill, K. "Character.AI to Ban Children Under 18 From Using Its Chatbots." *NYT*, Oct 29 2025. https://www.nytimes.com/2025/10/29/technology/characterai-underage-users.html
- Brodkin, J. "Character.AI sued over chatbot that claims to be a real doctor with a license." *Ars Technica*, May 5 2026. https://arstechnica.com/tech-policy/2026/05/character-ai-sued-over-chatbot-that-claims-to-be-a-real-doctor-with-a-license/
- Price, R. "When Your AI Girlfriend Says She Loves You." *Business Insider*, Oct 12 2023. https://www.businessinsider.com/when-your-ai-says-she-loves-you-2023-10
- Patel, N. "Replika CEO Eugenia Kuyda…," *The Verge* (Decoder), Aug 12 2024. https://www.theverge.com/24216748/replika-ceo-eugenia-kuyda-ai-companion-chatbots-dating-friendship-decoder-podcast-interview
- Pollina, E. & Coulter, M. "Italy bans U.S.-based AI chatbot Replika from using personal data." *Reuters*, Feb 3 2023. https://www.reuters.com/technology/italy-bans-us-based-ai-chatbot-replika-using-personal-data-2023-02-03/
- Huet, E. "What Happens When Sexting Chatbots Dump Their Human Lovers." *Bloomberg*, Mar 22 2023. https://www.bloomberg.com/news/articles/2023-03-22/replika-ai-causes-reddit-panic-after-chatbots-shift-from-sex
- Sky News. "AI chat bot 'encouraged' Windsor Castle intruder…," 2023. https://news.sky.com/story/windsor-castle-intruder-encouraged-by-ai-chat-bot-in-star-wars-inspired-plot-to-kill-queen-12915353
- Inflection AI. "Introducing Pi, Your Personal AI," May 2 2023. https://inflection.ai/blog/pi
- Kahn, J. "DeepMind cofounder's new A.I. chatbot is a good listener…," *Fortune*, May 3 2023. https://fortune.com/2023/05/03/inflection-ai-deepmind-cofounder-mustafa-suleyman-pi-chatbot/
- Griffith, E. & Metz, C. "The New A.I. Deal: Buy Everything but the Company." *NYT*, Aug 8 2024. https://www.nytimes.com/2024/08/08/technology/ai-start-ups-google-microsoft-amazon.html
- Mozilla Foundation. "Shady Mental Health Apps Inch Toward Privacy and Security Improvements…," May 2 2023. https://foundation.mozilla.org/en/blog/shady-mental-health-apps-inch-toward-privacy-and-security-improvements-but-many-still-siphon-personal-data/
- Maples, B., Cerit, M., Vishwanath, A. & Pea, R. (2024). "Loneliness and suicide mitigation for students using GPT3-enabled chatbots." *npj Mental Health Research* 3(1):4. https://www.ncbi.nlm.nih.gov/pmc/articles/PMC10955814/
- Xie, T. & Pentina, I. (2022). "Attachment Theory as a Framework to Understand Relationships with Social Chatbots: A Case Study of Replika." U. Hawai'i at Mānoa. https://scholarspace.manoa.hawaii.edu/items/5b6ed7af-78c8-49a3-bed2-bf8be1c9e465

**OpenAI**

- OpenAI. "Memory and new controls for ChatGPT," Feb 13 2024 (updated). https://openai.com/index/memory-and-new-controls-for-chatgpt/
- OpenAI Help Center. "Memory FAQ." https://help.openai.com/en/articles/8590148-memory-faq
- OpenAI Help Center. "ChatGPT Custom Instructions." https://help.openai.com/en/articles/8096356-custom-instructions-for-chatgpt

**Anthropic**

- Bai, Y. et al. (2022). *Constitutional AI: Harmlessness from AI Feedback.* arXiv:2212.08073. https://arxiv.org/abs/2212.08073
- Anthropic. "Claude's Constitution." https://www.anthropic.com/constitution
- Anthropic developer docs. "Prompting best practices" (Give Claude a role; external state). https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices
- Anthropic. "Bringing memory to Claude," Sep 11 2025. https://claude.com/blog/memory
- Anthropic Help Center. "Understanding Claude's personalization features," Jul 2026. https://support.anthropic.com/en/articles/10185728-understanding-claude-s-personalization-features
- Sharma, M. et al. (2023). *Towards Understanding Sycophancy in Language Models.* arXiv:2310.13548. https://arxiv.org/abs/2310.13548

**Academic**

- Park, J. S. et al. (2023). *Generative Agents: Interactive Simulacra of Human Behavior.* arXiv:2304.03442. https://arxiv.org/abs/2304.03442
- Zhang, S. et al. (2018). *Personalizing Dialogue Agents: I have a dog, do you have pets too?* arXiv:1801.07243. https://arxiv.org/abs/1801.07243
- Song, H. et al. (2019/2020). *Generating Persona Consistent Dialogues by Exploiting NLI.* arXiv:1911.05889; *Generate, Delete and Rewrite.* arXiv:2004.07672
- Kim, H. et al. (2020). *Will I Sound Like Me?* arXiv:2004.05816. https://arxiv.org/abs/2004.05816
- Shea, R. & Yu, Z. (2023). *Building Persona Consistent Dialogue Agents with Offline RL.* arXiv:2310.10735
- Tu, Q. et al. (2024). *CharacterEval: A Chinese Benchmark for Role-Playing Conversational Agent Evaluation.* arXiv:2401.01275. https://arxiv.org/abs/2401.01275
- Packer, C. et al. (2023). *MemGPT: Towards LLMs as Operating Systems.* arXiv:2310.08560. https://arxiv.org/abs/2310.08560
- Zhang, Z. et al. (2024). *A Survey on the Memory Mechanism of LLM based Agents.* arXiv:2404.13501. https://arxiv.org/abs/2404.13501
- Zhong, W. et al. (2023). *MemoryBank: Enhancing LLMs with Long-Term Memory.* arXiv:2305.10250. https://arxiv.org/abs/2305.10250
- Wu, D. et al. (2024). *LongMemEval: Benchmarking Chat Assistants on Long-Term Interactive Memory.* arXiv:2410.10813. https://arxiv.org/abs/2410.10813
- Joko, H. et al. (2024). *Doing Personal LAPS: LLM-Augmented Dialogue Construction for Personalized Multi-Session Conversational Search.* arXiv:2405.03480. https://arxiv.org/abs/2405.03480
- Mirzaei, I. (2026). *Sample More, Reflect Less: Self-Refine and Reflexion Lose to Repeated Sampling at Equal Token Cost.* arXiv:2607.28576
- Tseng, Y.-M. et al. (2024). *Two Tales of Persona in LLMs: A Survey of Role-Playing and Personalization.* arXiv:2406.01171
- Zhang, Z. et al. (2024). *Personalization of Large Language Models: A Survey.* arXiv:2411.00027. https://arxiv.org/abs/2411.00027
- Vijjini, A. R. et al. (2024/25). *Exploring Safety-Utility Trade-Offs in Personalized Language Models.* arXiv:2406.11107. https://arxiv.org/abs/2406.11107
- Zhang, J. et al. (2024). *The Better Angels of Machine Personality: How Personality Relates to LLM Safety.* arXiv:2407.12344. https://arxiv.org/abs/2407.12344
- Qian, Z. et al. (2025). *Mapping the Parasocial AI Market: User Trends, Engagement and Risks.* arXiv:2507.14226
- Rauh, M. et al. (2026). *Playing Games with My Heart: An Evaluation of AI Companion Apps.* arXiv:2605.08093
- Hwang, A. H.-C. et al. (2025). *How AI Companionship Develops: Evidence from a Longitudinal Study.* arXiv:2510.10079