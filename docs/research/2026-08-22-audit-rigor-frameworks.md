# Audit Rigor Frameworks: Analysis Dimensions Beyond Line-by-Line Correctness (2026-08-22)

*Research snapshot, 2026-08-22. Question: what dimensions do expert review/audit methodologies require beyond correctness checking — future implications, failure foresight, blast radius, second-order effects? Every claim below links to the primary source actually read; where a canonical text is paywalled or unreachable, that is stated explicitly.*

## 1. Pre-mortem analysis (Gary Klein)

[Performing a Project Premortem](https://hbr.org/2007/09/performing-a-project-premortem) (HBR, Sept 2007, Gary Klein). The article body is subscriber-only; the publisher's own abstract states the mechanism: team members "assume that the project they are planning has just failed—as so many do—and then generate plausible" reasons, making it safe for knowledgeable dissenters to speak up during planning. The underlying science is Mitchell, Russo & Pennington's [prospective-hindsight paper](https://onlinelibrary.wiley.com/doi/10.1002/bdm.3960020103) (*Journal of Behavioral Decision Making*, 1989 — note the actual title is "Back to the future: Temporal perspective in the *explanation* of events," pp. 25–38): generating an explanation for a future event *as if it had already happened* changes the number and type of reasons produced, driven mainly by outcome certainty. Distinct lens: **inverted time perspective + licensed dissent** — reviewing a change from inside its imagined failure instead of auditing its intent.

Questions through this lens:

1. This change shipped and six months later it failed catastrophically — what is the single most plausible cause, stated as a specific narrative, not a risk category?
2. Which of the generated failure stories do we have *no* current mitigation or monitoring for?
3. Which failure reasons came only from the person closest to the weakest part of the design, and were they previously unsaid?
4. Are we imagining the failure as certain (which the 1989 experiments show unlocks more concrete, episodic reasons) or hedging with "might fail" language?
5. What would each reviewer name privately if disagreement were free — and why isn't it in the review record?

## 2. FMEA — severity / occurrence / detection ranking

Owner: AIAG + VDA jointly. The [AIAG & VDA FMEA Handbook](https://www.aiag.org/training-and-resources/manuals/details/FMEAAV-1) is the automotive-industry reference manual for Design FMEA, Process FMEA, and supplemental FMEA-Monitoring & System Response. Per [AIAG's announcement](https://blog.aiag.org/its-here...claim-your-copy-of-the-new-aiag-vda-fmea-handbook-today), the harmonized edition introduces a mandatory 7-step flow (Planning & Preparation → Structure → Function → Failure → Risk → Optimization → Results Documentation), revised severity/occurrence/detection tables, and **Action Priority (AP) tables replacing RPN arithmetic**. Distinct lens: **enumerated failure modes ranked by effect severity, frequency, and detectability-before-impact** — a forced sweep that makes "what happens when this fails" answerable per element.

Questions through this lens:

1. For every element in scope, have we named its failure mode *and* traced the effect one level up (function → customer impact), or only locally?
2. Which failure modes fall into the highest Action Priority class, and what specific optimization action retires each — or are we shipping accepted risk untracked?
3. Are detection credits claimed for controls that fire only *after* customer impact (the trap AP tables were designed to expose)?
4. Did the analysis follow structure → function → failure, i.e., could two reviewers independently produce the same failure chain?
5. What new failure modes does *this change itself* introduce into previously analyzed functions?
6. Who independently verified that each cited prevention/detection control actually exists and works as documented?

## 3. STRIDE threat modeling (Microsoft)

Owner: Microsoft, part of its Security Development Lifecycle. The [Microsoft Threat Modeling Tool threats reference](https://learn.microsoft.com/en-us/azure/security/develop/threat-modeling-tool-threats) defines the six categories — Spoofing, Tampering, Repudiation, Information Disclosure, Denial of Service, Elevation of Privilege — as a way "to formulate pointed questions" per diagram element. Distinct lens: **adversarial enumeration by fixed threat category**, asking of each trust boundary and data flow what an attacker gains.

Questions through this lens:

1. Can an actor impersonate another's identity anywhere credentials or tokens cross a boundary?
2. Can persisted data or in-flight data be modified undetected — for an append-only ledger specifically: is immutability enforced and tamper-evident, not merely conventional?
3. Can anyone deny an action because identity-to-action binding is missing — does the ledger make repudiation impossible?
4. Where could information reach parties who shouldn't hold it (exports, logs, replicas)?
5. What does the system do when any single component is flooded or unavailable — fail open or closed?
6. Where does a low-privilege actor gain elevated rights, including via confused-deputy flows through our own tooling?

## 4. Production readiness reviews (Google SRE)

Owners: Google (Betsy Beyer et al., O'Reilly 2016). The operational-review canon is [Chapter 27, Reliable Product Launches at Scale](https://sre.google/sre-book/reliable-product-launches/): a dedicated Launch Coordination Engineering team audits services against a curated launch checklist and signs off launches deemed "safe"; [Chapter 8](https://sre.google/sre-book/release-engineering/) adds gated, reviewed release processes with archived change reports. Checklist curation discipline matters as much as content: "Every question's importance must be substantiated, ideally by a previous launch disaster." Distinct lens: **operational fitness-for-launch** — the reviewer audits the service as a future operator, not as a code checker.

Questions through this lens:

1. Where are the single points of failure, and can the service serve degraded if each dependency dies — at startup as well as runtime?
2. What traffic ramp is assumed, and is capacity validated against spikes (Google saw launches 15× over estimate)?
3. Could a user abuse this service — are rate limits and quotas implemented before launch?
4. Do clients back off exponentially *and* jitter, so retry storms can't synchronize?
5. Is every required manual procedure documented so any team member can execute it in an emergency?
6. What is the staged-rollout/canary plan, and what observation triggers automatic rollback?
7. For each checklist item imposed on this change: which past incident proves it necessary?

## 5. Amazon Operational Readiness Review (ORR) / Working Backwards

Owner: AWS. Note: no Builder's Library article titled "Operational Readiness Reviews" exists; the first-party source is the [AWS Well-Architected ORR whitepaper](https://docs.aws.amazon.com/wellarchitected/latest/operational-readiness-reviews/wa-operational-readiness-reviews.html) with its [example question bank](https://docs.aws.amazon.com/wellarchitected/latest/operational-readiness-reviews/appendix-b-example-orr-questions.html). ORR "distills the learnings from AWS operational incidents into curated questions"; question sources must be real incidents, near-misses, and feared-but-unseen failure modes; checklist areas include architecture, release quality, event management — with explicit subcategories like **blast-radius containment** and forensics. Distinct lens: **institutionalized scar tissue** — reviews encode prior incidents so known failure causes cannot recur unnoticed.

Questions through this lens:

1. What in this design exists specifically to reduce blast radius, and what happens in the largest blast-radius unit (cell/AZ/region) outage?
2. Produce the table: every customer-impacting API, its components and dependencies — then the failure model with soft/hard modes per dependency and customer impact per column.
3. Do deployments automatically roll back incorrect changes before they breach internal SLAs?
4. Is every change to production (code, config, infra) approved by someone other than the author?
5. Can the workload survive loss of an availability zone *statically* — without emergency scaling or deploys?
6. When was this checklist last updated from a new incident, and which incident is this change silently ignoring?

## 6. Architecture Tradeoff Analysis Method (ATAM) — SEI/CMU

Owner: Software Engineering Institute, Carnegie Mellon. The [SEI ATAM collection](https://www.sei.cmu.edu/library/architecture-tradeoff-analysis-method-collection/) describes the method: business drivers and architecture are refined into quality-attribute scenarios; analyzing decisions yields **risks, non-risks, sensitivity points, and tradeoff points**; risks are synthesized into risk themes threatening business drivers. The founding paper ([Kazman et al., CMU/SEI-98-TR-008](https://www.sei.cmu.edu/documents/1186/1998_005_001_16646.pdf)) defines the core insight: architectural elements that *multiple* quality attributes depend on are tradeoff points where attributes move inversely (their worked example: server count improves performance/availability but worsens security). Distinct lens: **multi-attribute interaction analysis** — the reviewer hunts for decisions that silently price one quality against another.

Questions through this lens:

1. What are the priority scenarios (concrete stimulus → environment → response) the architecture must satisfy, ranked by stakeholders?
2. Which elements are sensitivity points — where small design changes swing a measured quality attribute significantly?
3. Which elements are tradeoff points — improving one attribute while degrading another — and were those trades made consciously?
4. What risks did scenario analysis expose, and how does each aggregate into a theme that threatens a stated business goal?
5. Which "non-risks" were confirmed safe only under assumptions nobody has re-checked recently?

## 7. Hyrum's Law + semantic versioning forward-compatibility

Primary: [hyrumslaw.com](https://hyrumslaw.com/) — "With a sufficient number of users of an API, it does not matter what you promise in the contract: all observable behaviors of your system will be depended on by somebody." Hyrum Wright (ex-Google) names the consequence "bug-for-bug compatibility": the implicit interface grows until "the implementation has become the interface." Counterweight: the [SemVer 2.0.0 spec](https://semver.org/) requires declaring a precise public API, bumping MAJOR for any backward-incompatible change, MINOR for deprecations (with ≥1 release of warning before removal), and never modifying released versions. Its FAQ calls the major-bump cost "responsible development and foresight." Distinct lens: **unspecified-behavior exposure** — reviewers assess what consumers already rely on beyond the written contract.

Questions through this lens:

1. Which observable behaviors (latency profiles, ordering, error strings, timestamp formats) are consumed today although unspecified?
2. Which parts of this system's *implementation* have de facto become its interface?
3. Would every existing consumer keep working if all documented promises held but undocumented behaviors shifted?
4. Is this change backward-compatible against a *declared* API, or against vibes?
5. Any breaking change → major bump consciously accepted, with upgrade cost evaluated?
6. Are released artifacts immutable once published?

## 8. Chesterton's Fence as change-review heuristic

Source: G.K. Chesterton, [*The Thing* (1929), chapter "The Drift from Domesticity"](https://www.gkc.org.uk/gkc/books/The_Thing.txt) (full text at gkc.org.uk). Verbatim principle: a fence stands across a road; the modern reformer says "I don't see the use of this; let us clear it away"; the intelligent answer is: "If you don't see the use of it, I certainly won't let you clear it away. Go away and think. Then, when you can come back and tell me that you do see the use of it, I may allow you to destroy it." Because "some person had some reason for thinking it would be a good thing for somebody… until we know what the reason was, we really cannot judge whether the reason was reasonable." Distinct lens: **historical justification burden for removal** — no deletion or simplification without reconstructing why the thing existed.

Questions through this lens:

1. Who introduced this rule/flag/workaround, when, and against what failure?
2. Can the removal proponent state that original purpose in their own words — not "probably legacy"?
3. Has the purpose genuinely expired (evidence: the guarded failure can no longer occur), or merely faded from memory?
4. Which current behaviors would regress silently if the fence fell?
5. Are we implicitly assuming our predecessors were fools — and is that assumption ever load-bearing elsewhere?

## 9. Independent peer review in safety-critical standards (DO-178C)

Canonical text: RTCA [DO-178C](https://www.rtca.org/do-178/) — per RTCA, "the core document for defining both design assurance and product assurance for airborne software"; the standard itself is commercial and was **not directly readable for this snapshot**. The [FAA's AC 20-115D](https://www.faa.gov/regulations_policies/advisory_circulars/index.cfm/go/document.information/documentID/1032046) recognizes DO-178C/ED-12C as an acceptable means of compliance; [EASA's AMC 20-115](https://www.easa.europa.eu/en/downloads/2038/en) describes its structure: guidance delivered as *objectives* for life-cycle processes plus "descriptions of the evidence that indicates that the objectives have been satisfied," with rigor scaled by software level. Independence specifics are confirmed by regulator material: Australia's CASA [AC 21-50](https://www.casa.gov.au/sites/default/files/2021-08/advisory-circular-21-50-approval-of-software-and-electronic-hardware-parts.pdf) defines independence as "verification activity … performed by a competent person(s) other than the developer of the item being verified," and notes objective counts vary sharply by DAL; the joint FAA/EASA [Abstraction Layer report](https://www.faa.gov/aircraft/air_cert/design_approvals/air_software/abstraction_layer_report_1) states independence is expected such that VERIFY is independent from REALIZE and process assurance independent of other processes, at higher safety levels. Distinct lens: **structural separation of judge from author** — rigor as an org-design property, not a diligence property.

Questions through this lens:

1. Was every reviewed artifact examined by someone other than its author — including test results reviewed by someone other than the tester?
2. Which review objectives apply at this work's criticality level, and is the mapping documented like Annex A, not improvised?
3. Is traceability (requirements ↔ code ↔ tests) complete enough that an independent party could re-verify coverage claims?
4. Does process assurance report outside the engineering line that produced the work?
5. Where independence was waived or diluted, was the waiver explicit and recorded?

## 10. Second-order thinking (Howard Marks, Oaktree)

Owner: Oaktree Capital. There is no memo literally titled "Second-Level Thinking"; the concept is chapter one of *The Most Important Thing*, reproduced and discussed in Marks' own memo ["It's Not Easy"](https://www.oaktreecapital.com/docs/default-source/memos/2015-09-09-its-not-easy.pdf?sfvrsn=2) (Oaktree site, Sept 2015): first-level thinking says "It's a good company; let's buy the stock"; second-level asks what the consensus already believes and how reality will compare to expectations — "your thinking has to be different and better." His ["I Beg to Differ"](https://www.oaktreecapital.com/insights/memo/i-beg-to-differ) memo confirms the origin story. Distinct lens: **consensus-relative consequence analysis** — evaluating a decision by what happens *next*, and what is already priced in.

Questions through this lens:

1. After the intended first-order benefit lands, what second-order behavior changes (users, dependencies, attackers, teammates)?
2. What is the range of likely outcomes here, not just the planned one?
3. What part of this "improvement" is already consensus among everyone who built similar systems — and therefore worth less than it looks?
4. If our forecast is wrong, which downstream commitment breaks first?

## 11. Event-sourcing schema-evolution hazards (append-only ledgers)

Practitioner-primary source read: Martin Fowler's [Event Sourcing](https://martinfowler.com/eaaDev/EventSourcing.html) (bliki, 2005). Key hazards for an append-only event ledger: replays must not leak side effects — "gateways" wrap external systems and suppress sends during replay; external *queries* must be journaled so a rebuilt state sees the exchange rate "on Dec 5 not the later one"; code changes split into three classes — new features (safe to reprocess), defect fixes (require reverse-and-replay of consequences), and temporal logic ("charge $10 before November 18 and $15 afterwards"), which must live in the model keyed by event time; reversal requires events to carry prior-state or be cast as differences; and mixing bug-fix replay with changed rules "can get very messy, don't go down this path unless you really need to." Distinct lens: **replay-determinism and retroactivity** — the audit question unique to systems whose history is executable.

Questions through this lens:

1. If we delete all projections and replay the ledger tomorrow, does today's state reproduce bit-for-bit?
2. Which event handlers perform external side effects, and are they provably inert during replay?
3. Are external query results captured at event time so old events reprocess against old facts?
4. Is every handler change classified: additive, fix-requiring-replay, or temporal — with the replay plan written down before merge?
5. Do old events remain interpretable forever (versioned/upcast), or does reading history silently depend on current code shape?

## SYNTHESIS

| Framework | One distinct audit lens | Three sharpest reviewer questions |
| --- | --- | --- |
| Pre-mortem ([Klein/HBR](https://hbr.org/2007/09/performing-a-project-premortem); [Mitchell et al. 1989](https://onlinelibrary.wiley.com/doi/10.1002/bdm.3960020103)) | Inverted time perspective: review from inside the imagined failure | 1. It failed six months from now — narrate the most plausible cause specifically. 2. Which failure stories have no mitigation or monitor today? 3. Which concern surfaced only because dissent was made safe? |
| FMEA ([AIAG-VDA](https://www.aiag.org/training-and-resources/manuals/details/FMEAAV-1)) | Enumerated failure modes ranked by severity × occurrence × detection (Action Priority) | 1. Is each failure mode traced to next-level effect, not judged locally? 2. Which top-AP modes ship as untracked accepted risk? 3. Is detection credited for controls that fire after customer impact? |
| STRIDE ([Microsoft Learn](https://learn.microsoft.com/en-us/azure/security/develop/threat-modeling-tool-threats)) | Adversarial sweep by fixed threat category across trust boundaries | 1. Can ledger rows be tampered with undetected despite append-only design? 2. Can any actor repudiate an action the ledger should bind to them? 3. Where does flooding or unavailability flip behavior fail-open? |
| Google PRR / launch checklist ([SRE ch. 27](https://sre.google/sre-book/reliable-product-launches/)) | Operational fitness: audit as the future on-call operator | 1. How does the service degrade when each dependency dies? 2. Are rollout stages, canaries, and rollback triggers defined? 3. Which checklist item lacks a substantiating past disaster? |
| AWS ORR ([Well-Architected whitepaper](https://docs.aws.amazon.com/wellarchitected/latest/operational-readiness-reviews/wa-operational-readiness-reviews.html)) | Institutionalized incident memory: known failure causes can't recur unnoticed | 1. What exists purely to shrink blast radius, and what's the largest-unit outage story? 2. Do bad deployments self-rollback before breaching SLAs? 3. Which of real incidents / near-misses / feared modes is missing from the checklist? |
| ATAM ([SEI collection](https://www.sei.cmu.edu/library/architecture-tradeoff-analysis-method-collection/); [CMU/SEI-98-TR-008](https://www.sei.cmu.edu/documents/1186/1998_005_001_16646.pdf)) | Multi-attribute interaction: find sensitivity and tradeoff points | 1. Which scenarios define success, ranked by stakeholders? 2. Where is one element sensitive to multiple quality attributes moving inversely? 3. Which risks aggregate into themes threatening business drivers? |
| Hyrum's Law + SemVer ([hyrumslaw.com](https://hyrumslaw.com/); [semver.org](https://semver.org/)) | Unspecified-behavior exposure: the implicit interface consumers actually depend on | 1. Which observable behaviors are relied on though unpromised? 2. Is compatibility defined against a declared API or against current behavior? 3. Is any breaking change consciously paid for (major bump, immutability preserved)? |
| Chesterton's Fence ([The Thing, 1929](https://www.gkc.org.uk/gkc/books/The_Thing.txt)) | Removal requires reconstructed historical justification | 1. Why does this exist — who added it, against what failure? 2. Has that purpose demonstrably expired, or just faded from memory? 3. What regresses silently if the fence falls? |
| DO-178C-style independence ([FAA AC 20-115D](https://www.faa.gov/regulations_policies/advisory_circulars/index.cfm/go/document.information/documentID/1032046); [EASA AMC 20-115](https://www.easa.europa.eu/en/downloads/2038/en); [CASA AC 21-50](https://www.casa.gov.au/sites/default/files/2021-08/advisory-circular-21-50-approval-of-software-and-electronic-hardware-parts.pdf)) | Structural separation of verifier from author, scaled by criticality | 1. Was every artifact reviewed by a non-author, incl. test results? 2. Which review objectives apply at this criticality level, and is that mapped explicitly? 3. Does process assurance sit outside the producing line? |
| Second-level thinking (["It's Not Easy"](https://www.oaktreecapital.com/docs/default-source/memos/2015-09-09-its-not-easy.pdf?sfvrsn=2), Oaktree) | Consensus-relative consequence analysis | 1. What happens *after* the intended benefit lands? 2. What's the realistic range of outcomes beyond the plan? 3. Which part of the gain is already consensus, hence worthless as differentiation? |
| Event-sourcing evolution hazards ([Fowler](https://martinfowler.com/eaaDev/EventSourcing.html)) | Replay determinism and retroactivity of an executable history | 1. Does a full ledger replay reproduce today's state exactly? 2. Are external side effects and queries inert/as-of-event-time during replay? 3. Is every handler change classified additive / fix-needing-replay / temporal, with a written replay plan? |

**Overlap and uniqueness.** Four clusters overlap heavily: (a) *hindsight-mining-forward* — pre-mortem and ORR are the same move run in opposite directions (imagined failure vs. recorded failure); (b) *categorized failure sweeps* — FMEA and STRIDE both force exhaustive enumeration, differing only in adversary (entropy vs. attacker), and both feed severity-style ranking; (c) *future-evolution pressure* — ATAM, Hyrum's Law/SemVer, and event-sourcing replay hazards all evaluate the artifact against its own future modification, ATAM via competing quality attributes, Hyrum via accumulated implicit contracts, Fowler via replayable history; (d) *anti-shallow-judgment* — Chesterton's fence and second-level thinking both block confident conclusions drawn from an incomplete model of the present (one temporal-historical, one consensus-relative). Genuinely unique contributions: pre-mortem alone targets the psychology of dissent (certainty-framing unlocking unstated knowledge); DO-178C-style independence alone is a social/structural control rather than an analytic one — it assumes analysis is biased by authorship and fixes the bias organizationally; Google PRR and AWS ORR alone operationalize *blast radius* concretely (largest-unit outage, AZ loss, rollback-before-SLA-breach); and the event-sourcing lens alone asks whether the audit trail itself re-executes correctly, which for an append-only event-ledger system makes it the only lens that audits the auditor's substrate.
