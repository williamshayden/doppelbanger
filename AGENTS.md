# doppelbanger Agent Notes

Optimize for small, tested contracts.

- Use `rtk` before shell commands in this repo.
- Keep DSP code independent from CLI, PostgREST, and UI state.
- Postgres/PostgREST is the state plane; the filesystem is the audio artifact plane.
- Do not add fake analysis/rendering fallbacks. If real DSP is not implemented, fail with a direct error.
- Add or update tests for every public contract, pipeline, CLI command, API route/schema change, and benchmark.
- Prefer one clear path over duplicate offline/realtime implementations. Future VST work should reuse the same pipeline contract.
