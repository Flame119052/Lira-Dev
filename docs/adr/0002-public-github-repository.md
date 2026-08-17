---
status: accepted
---

# Public GitHub repository

Lira is a native SwiftUI macOS app, so meaningful CI requires macOS runners. On a private repo, GitHub Pro/Student minutes (3,000/month) are consumed by macOS runners at a 10x multiplier — effectively only ~300 macOS-CI-minutes/month — while public repos get unlimited free CI on any runner, including macOS.

Decision: `Lira-Dev` is a public GitHub repository. All code, docs, and ADRs — including design decisions that reflect the owner's own preferences and usage patterns — are publicly visible. Secrets and credentials must never be committed, per the standing security rule; this now carries real consequence since the repo is public rather than merely a best practice.
