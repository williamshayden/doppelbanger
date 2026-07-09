# doppelbanger Agent Notes

Optimize for small, tested contracts.

- Use `rtk` before shell commands in this repo.
- Read `docs/PRD.md`, `docs/ENGINEERING_SPEC.md`, and `docs/DECISIONS.md` before changing product scope, public CLI/API/schema contracts, pipeline architecture, or intentional deferrals.
- Keep document authority clear: the PRD defines the product promise, the engineering spec defines the current phase, and the decision ledger preserves rationale and history.
- Update accepted product decisions in the relevant canonical document and `docs/DECISIONS.md` in the same change. Never infer acceptance from code, delete old decisions, or rewrite history; supersede records explicitly.
- Keep DSP code independent from CLI, PostgREST, and UI state.
- Postgres/PostgREST is the state plane; the filesystem is the audio artifact plane.
- Do not add fake analysis/rendering fallbacks. If real DSP is not implemented, fail with a direct error.
- Add or update tests for every public contract, pipeline, CLI command, API route/schema change, and benchmark.
- Prefer one clear path over duplicate offline/realtime implementations. Future VST work should reuse the same pipeline contract.
