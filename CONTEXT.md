# Lira

Lira is a JARVIS-style, local-first macOS agent: a durable, capable, personal presence — not a chat wrapper — being rebuilt from a clean codebase after the prior implementation attempt was scrapped for poor structure and unverifiable quality. See `docs/adr/` for the decisions behind this rebuild's process and architecture.

## Language

**Owner**:
The one person Lira serves — who directs it, approves high-risk actions, and whose Mac hosts this instance. Distinct from any future general term for a person using a *different* installation of Lira, which hasn't been named yet because multi-install support isn't a live design constraint for v1.
_Avoid_: User, Client, Account holder
