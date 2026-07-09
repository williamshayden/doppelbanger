# doppelbanger PRD v0.1

## Summary

doppelbanger is a free/open-source local mastering assistant for techno/electronic producers. MVP optimizes for reference matching: import a reference track and a target mix, analyze both, generate a mastering plan, render a mastered WAV, and save measurable before/after evidence.

The first shippable surface is CLI + local API. Desktop UI and VST/AU support come later as wrappers over the same pipeline contract.

## MVP Contract

- Input: one stereo reference track and one stereo target mix.
- Import formats: MP3 and WAV.
- Export format: WAV.
- Scope: full stereo mixes only; no stems, batch mastering, cloud processing, or preset library.
- Workflow:
  1. Start local runtime with Docker Compose.
  2. Submit reference + target through CLI/local API.
  3. Analyze both tracks.
  4. Generate a mastering plan from measured differences.
  5. Render mastered WAV.
  6. Save structured machine-readable report.
- User controls expose the generated mastering plan, not generic FX macros.
- Width handling must be band-aware; low-end stereo widening must be constrained.

## System Shape

- One unified mastering pipeline.
- Postgres stores state, jobs, track metadata, analyses, mastering plans, reports, and render records.
- PostgREST exposes local app/API state.
- Worker process runs analysis and rendering jobs.
- DSP engine reads audio files directly from disk and writes structured results back to Postgres.
- Filesystem stores source audio, rendered WAVs, cache files, and artifacts.
- Future Ableton/VST support can use API/DB for setup and persistence, but not for live audio-critical work.

## Quality And Benchmarks

- Quality first, then speed. Performance optimizations must not reduce analysis or render resolution.
- Baseline machine: Apple M5, 10 CPU cores, 16 GB RAM, macOS 26.2.
- Hard MVP floor: full-quality analysis and render must each run at least `1x realtime` on the baseline machine.
- Test suite is local-first; no paid GitHub Actions dependency.
- Public contracts, DSP blocks, pipelines, CLI commands, API schemas, migrations, reports, and benchmarks need purposeful tests.
- Quality gate combines automated metrics with an audition checklist before release.

## Assumptions

- Initial user is an Ableton-adjacent techno/electronic producer mastering their own stereo mixes.
- WAV target input is recommended for serious mastering, even though MP3 import is supported.
- Reports are required as internal evidence; user-facing report UI comes later.
- Reusable reference-derived presets are post-MVP.
- This iteration is MIT-licensed and free/open-source.
