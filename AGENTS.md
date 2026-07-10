# doppelbanger Agent Notes

Optimize for small, tested contracts.

- Use `rtk` before shell commands in this repo.
- Read `docs/PRD.md`, `docs/ENGINEERING_SPEC.md`, and `docs/DECISIONS.md` before changing product scope, public CLI/API/schema contracts, pipeline architecture, or intentional deferrals.
- Read `docs/PLUGIN_ARCHITECTURE.md` and `docs/VALIDATION.md` before changing DSP, FFI, plugin lifecycle, callback behavior, benchmarks, or release evidence.
- Keep document authority clear: the PRD defines the product promise, the engineering spec defines the current phase, and the decision ledger preserves rationale and history.
- Update accepted product decisions in the relevant canonical document and `docs/DECISIONS.md` in the same change. Never infer acceptance from code, delete old decisions, or rewrite history; supersede records explicitly.
- Keep DSP code independent from CLI, PostgREST, and UI state.
- Postgres/PostgREST is the state plane; the filesystem is the audio artifact plane.
- Do not add fake analysis/rendering fallbacks. If real DSP is not implemented, fail with a direct error.
- Add or update tests for every public contract, pipeline, CLI command, API route/schema change, and benchmark.
- Prefer one clear path over duplicate offline/realtime implementations. VST3 is the primary product surface; CLI and renderer code are validation adapters over the same processor.
- For substantial work, follow `docs/AGENT_WORKFLOW.md` and keep agent roles, ownership, validation, and review evidence explicit.
- Treat hooks as advisory. Tests, validators, and CI own mechanical enforcement; hooks never accept product decisions or spawn work implicitly.
