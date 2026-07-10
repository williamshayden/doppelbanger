# Product Decisions

This ledger preserves product and engineering decisions that materially affect doppelbanger. The PRD remains the product promise and the engineering spec remains the current implementation contract.

Statuses are `proposed`, `accepted`, `deferred`, `rejected`, and `superseded`. Records are append-only: update consequences and links when needed, but supersede rather than erase historical decisions.

## PD-001: Local-first product
- **Status:** `accepted`
- **Date:** 2026-06-26
- **Area:** product
- **Decision:** doppelbanger runs locally and does not require cloud processing.
- **Rationale:** Local execution protects unreleased music and keeps audio processing predictable.
- **Source:** [PRD summary](PRD.md#summary)
- **Consequences:** Installation must provision every required local service and binary.
- **Revisit trigger:** Revisit only if an optional cloud service has a concrete user-owned benefit and privacy model.
- **GitHub:** None.

## PD-002: CLI and local API are the first product surface
- **Status:** `accepted`
- **Date:** 2026-06-26
- **Area:** product
- **Decision:** The first shippable surface is a CLI backed by a local PostgREST API.
- **Rationale:** This proves portable contracts before committing to desktop or plugin UI frameworks.
- **Source:** [PRD summary](PRD.md#summary)
- **Consequences:** Desktop and plugin wrappers consume the same contracts later.
- **Revisit trigger:** None.
- **GitHub:** None.

## PD-003: Postgres and PostgREST own application state
- **Status:** `accepted`
- **Date:** 2026-06-26
- **Area:** architecture
- **Decision:** Postgres stores durable state and PostgREST exposes the local state API.
- **Rationale:** Explicit state and job records support asynchronous work, testing, and future wrappers.
- **Source:** [PRD system shape](PRD.md#system-shape)
- **Consequences:** Schema and RPC behavior are public contracts with integration tests.
- **Revisit trigger:** Revisit only after measured local resource or packaging failures.
- **GitHub:** None.

## PD-004: The filesystem owns audio artifacts
- **Status:** `accepted`
- **Date:** 2026-06-26
- **Area:** architecture
- **Decision:** Source audio, rendered WAVs, and caches remain on disk; audio bytes do not pass through PostgREST.
- **Rationale:** The state service should not sit in the high-volume audio path.
- **Source:** [PRD system shape](PRD.md#system-shape)
- **Consequences:** Workers need filesystem access to canonical local paths.
- **Revisit trigger:** Revisit when sandboxed plugin or desktop packaging requires managed imports.
- **GitHub:** None.

## PD-005: One mastering pipeline
- **Status:** `accepted`
- **Date:** 2026-06-26
- **Area:** architecture
- **Decision:** CLI, worker, future desktop UI, and future plugin wrappers reuse one analysis/plan/render pipeline.
- **Rationale:** Duplicate offline and realtime implementations would create quality drift and test duplication.
- **Source:** [PRD system shape](PRD.md#system-shape)
- **Consequences:** DSP stays independent from CLI, API, database, and UI state.
- **Revisit trigger:** None.
- **GitHub:** None.

## PD-006: Programmatic DSP before machine learning
- **Status:** `accepted`
- **Date:** 2026-06-26
- **Area:** dsp
- **Decision:** Phase 1 uses deterministic signal analysis and processing without LLM or generative-model dependencies.
- **Rationale:** Deterministic behavior is easier to understand, tune, benchmark, and distribute.
- **Source:** [PRD summary](PRD.md#summary)
- **Consequences:** Every recommendation must be traceable to measured inputs and explicit rules.
- **Revisit trigger:** Revisit after deterministic baselines expose a specific unsolved quality gap and a suitable dataset exists.
- **GitHub:** None.

## PD-007: Stereo full mixes only
- **Status:** `accepted`
- **Date:** 2026-06-26
- **Area:** product
- **Decision:** MVP accepts one stereo reference and one stereo target mix; stems and batch jobs are excluded.
- **Rationale:** This is the smallest workflow that solves the user's mastering problem.
- **Source:** [PRD MVP contract](PRD.md#mvp-contract)
- **Consequences:** Mono input fails rather than being silently duplicated.
- **Revisit trigger:** Revisit after the stereo single-pair workflow is release-ready.
- **GitHub:** None.

## PD-008: MP3 and WAV imports, WAV export
- **Status:** `accepted`
- **Date:** 2026-06-26
- **Area:** audio
- **Decision:** Reference and target imports support MP3 and WAV; rendering exports WAV.
- **Rationale:** MP3 supports practical references while WAV preserves mastering output quality.
- **Source:** [PRD MVP contract](PRD.md#mvp-contract)
- **Consequences:** Serious target work recommends WAV even though MP3 is accepted.
- **Revisit trigger:** Revisit additional codecs after the first cross-platform release.
- **GitHub:** None.

## PD-009: Quality precedes speed
- **Status:** `accepted`
- **Date:** 2026-06-26
- **Area:** quality
- **Decision:** Optimizations may not lower analysis or rendering resolution; analysis and render must each meet at least `1x realtime` on the baseline machine.
- **Rationale:** Faster low-quality output would invalidate the product's core promise.
- **Source:** [PRD quality and benchmarks](PRD.md#quality-and-benchmarks)
- **Consequences:** Quality and performance reports are both release evidence.
- **Revisit trigger:** Revisit the performance floor after Windows baseline hardware is selected.
- **GitHub:** None.

## PD-010: Local-first automated quality evidence
- **Status:** `accepted`
- **Date:** 2026-06-26
- **Area:** quality
- **Decision:** Public contracts, DSP stages, pipelines, API/schema behavior, reports, and benchmarks require purposeful local tests without paid hosted CI.
- **Rationale:** Evidence must be runnable by contributors and useful for regressions.
- **Source:** [PRD quality and benchmarks](PRD.md#quality-and-benchmarks)
- **Consequences:** Hosted CI is optional; machine-specific audio benchmarks stay local.
- **Revisit trigger:** Revisit free hosted checks after the local suite stabilizes.
- **GitHub:** None.

## PD-011: VST3 and AU wrappers follow the standalone pipeline
- **Status:** `deferred`
- **Date:** 2026-06-26
- **Area:** plugin
- **Decision:** VST3/AU and Ableton validation do not begin in Phase 1.
- **Rationale:** Plugin integration should wrap a proven pipeline rather than define it.
- **Source:** [PRD summary](PRD.md#summary)
- **Consequences:** DSP contracts must remain block-oriented and independent from database/UI state.
- **Revisit trigger:** Start after the standalone pipeline passes AlbumDB and user-owned techno quality gates.
- **GitHub:** [#5 Deferred: VST3 and AU wrappers with Ableton validation](https://github.com/williamshayden/doppelbanger/issues/5).

## PD-012: Reference-derived presets follow single-pair mastering
- **Status:** `deferred`
- **Date:** 2026-06-26
- **Area:** product
- **Decision:** Saving and reusing reference-derived mastering presets is post-MVP.
- **Rationale:** Reuse semantics are unclear until multiple real references produce stable plans.
- **Source:** [PRD assumptions](PRD.md#assumptions)
- **Consequences:** Phase 1 plans are request-scoped JSON artifacts.
- **Revisit trigger:** Start after at least five user-owned references produce stable, useful plans.
- **GitHub:** [#6 Deferred: reusable reference-derived presets](https://github.com/williamshayden/doppelbanger/issues/6).

## PD-013: Browser workshop UI follows report stability
- **Status:** `deferred`
- **Date:** 2026-07-09
- **Area:** ux
- **Decision:** Phase 1 uses CLI output plus Ableton listening rather than a browser UI.
- **Rationale:** Audio streaming and UI contracts should follow stable plan/report artifacts.
- **Source:** [Engineering spec deferrals](ENGINEERING_SPEC.md#phase-1-deferrals)
- **Consequences:** Manual evaluation uses generated files and structured checklists.
- **Revisit trigger:** Start when `MasteringPlanV1` and render reports pass the fast AlbumDB suite.
- **GitHub:** [#2 Deferred: browser workshop UI](https://github.com/williamshayden/doppelbanger/issues/2).

## PD-014: AlbumDB is the first paired evaluation corpus
- **Status:** `accepted`
- **Date:** 2026-07-09
- **Area:** evaluation
- **Decision:** Download the full AlbumDB mixed-stem and stereo-master archives and evaluate all ten songs.
- **Rationale:** It provides open same-song material with reconstructable premasters and human stereo masters.
- **Source:** [Engineering spec evaluation corpus](ENGINEERING_SPEC.md#evaluation-corpus)
- **Consequences:** The corpus is external, checksummed, attributed, and never committed to git.
- **Revisit trigger:** Add techno-specific paired material when a legally usable source becomes available.
- **GitHub:** None.

## PD-015: Identity is a required no-op
- **Status:** `accepted`
- **Date:** 2026-07-09
- **Area:** quality
- **Decision:** Using the same decoded audio as reference and target yields zero deltas, an explicit bypass plan, and exact decoded WAV samples.
- **Rationale:** A matcher that changes already-matching audio is unsafe.
- **Source:** [Engineering spec mastering plan](ENGINEERING_SPEC.md#mastering-plan-v1)
- **Consequences:** MP3 identity compares canonical decoded PCM rather than encoded bytes.
- **Revisit trigger:** None.
- **GitHub:** None.

## PD-016: Phase 1 ends with a first audible pass
- **Status:** `accepted`
- **Date:** 2026-07-09
- **Area:** product
- **Decision:** Analysis alone does not complete Phase 1; the system must render and support manual listening.
- **Rationale:** The phase must prove that measured differences can drive a useful audible change.
- **Source:** [Engineering spec phase exit](ENGINEERING_SPEC.md#phase-1-exit)
- **Consequences:** Phase 1 includes a conservative processor and report, not only metrics.
- **Revisit trigger:** None.
- **GitHub:** [#3 Phase 1: validate the first audible reference-mastering pass](https://github.com/williamshayden/doppelbanger/issues/3).

## PD-017: One API-backed product path
- **Status:** `accepted`
- **Date:** 2026-07-09
- **Area:** architecture
- **Decision:** The CLI submits and tracks work through PostgREST while a native worker runs DSP.
- **Rationale:** Proving the chosen state boundary now avoids a temporary direct mode becoming permanent.
- **Source:** [Engineering spec public interfaces](ENGINEERING_SPEC.md#public-interfaces)
- **Consequences:** Pure library calls are test seams, not a second product mode.
- **Revisit trigger:** None.
- **GitHub:** None.

## PD-018: Phase 1 processing is safe gain and broad EQ
- **Status:** `accepted`
- **Date:** 2026-07-09
- **Area:** dsp
- **Decision:** The first audible plan uses three broad EQ filters plus true-peak-constrained gain.
- **Rationale:** It tests tonal targeting without introducing nonlinear dynamics artifacts.
- **Source:** [Engineering spec mastering plan](ENGINEERING_SPEC.md#mastering-plan-v1)
- **Consequences:** Loudness may remain below the reference and must report the shortfall.
- **Revisit trigger:** Revisit after the fast-suite listening gate passes.
- **GitHub:** None.

## PD-019: Phase 1 renders 32-bit float at native rate
- **Status:** `accepted`
- **Date:** 2026-07-09
- **Area:** audio
- **Decision:** Render stereo IEEE 32-bit float WAV at the target's sample rate without resampling or dithering.
- **Rationale:** Float output avoids quantization while the DSP and safety limits are being tuned.
- **Source:** [Engineering spec audio contract](ENGINEERING_SPEC.md#audio-contract)
- **Consequences:** Release-oriented 24-bit export remains a later packaging decision.
- **Revisit trigger:** Revisit before the first beta export workflow.
- **GitHub:** None.

## PD-020: Dynamics and limiting follow the safe linear pass
- **Status:** `deferred`
- **Date:** 2026-07-09
- **Area:** dsp
- **Decision:** Compression and limiting are excluded from Phase 1.
- **Rationale:** Nonlinear processing needs separate artifact, loudness, and listening evidence.
- **Source:** [Engineering spec deferrals](ENGINEERING_SPEC.md#phase-1-deferrals)
- **Consequences:** True-peak headroom may prevent full loudness matching.
- **Revisit trigger:** Start after gain/EQ passes automated and manual AlbumDB gates.
- **GitHub:** [#1 Deferred: compression and limiting stage](https://github.com/williamshayden/doppelbanger/issues/1).

## PD-021: Stereo and transient processing follow metric validation
- **Status:** `deferred`
- **Date:** 2026-07-09
- **Area:** dsp
- **Decision:** Phase 1 measures stereo and transient behavior but does not modify either.
- **Rationale:** Measurement correctness must precede processing, especially for low-end stereo safety.
- **Source:** [Engineering spec analysis](ENGINEERING_SPEC.md#analysis-v1)
- **Consequences:** Reports expose these differences for later processor design.
- **Revisit trigger:** Start after metric conformance and repeated real-pair plausibility checks pass.
- **GitHub:** [#4 Deferred: stereo and transient processing](https://github.com/williamshayden/doppelbanger/issues/4).

## PD-022: One-command packaging follows runtime proof
- **Status:** `deferred`
- **Date:** 2026-07-09
- **Area:** packaging
- **Decision:** Curl-based installation and Windows packaging are not Phase 1 deliverables.
- **Rationale:** Packaging unstable contracts would slow DSP and state-plane iteration.
- **Source:** [Engineering spec deferrals](ENGINEERING_SPEC.md#phase-1-deferrals)
- **Consequences:** Phase 1 development uses Cargo and Docker Compose directly.
- **Revisit trigger:** Start after clean Mac and Windows machines pass the API/worker pipeline contract.
- **GitHub:** [#7 Deferred: one-command installation and Windows packaging](https://github.com/williamshayden/doppelbanger/issues/7).

## PD-023: MIT and public-source posture is provisional through Phase 1
- **Status:** `accepted`
- **Date:** 2026-06-26
- **Area:** licensing
- **Decision:** The repository remains public and MIT-licensed during Phase 1.
- **Rationale:** Early public development supports collaboration while the product model remains undecided.
- **Source:** [PRD assumptions](PRD.md#assumptions)
- **Consequences:** Dependencies and committed fixtures must be redistribution-compatible.
- **Revisit trigger:** Review licensing and distribution before the first beta binary release.
- **GitHub:** None.

## PD-024: GitHub Issues before Discussions or boards
- **Status:** `deferred`
- **Date:** 2026-07-09
- **Area:** product-management
- **Decision:** Use Issues plus repository documents; keep Discussions, project boards, and milestones disabled or unused initially.
- **Rationale:** The project does not yet have community volume that justifies additional state surfaces.
- **Source:** [Engineering spec phase exit](ENGINEERING_SPEC.md#phase-1-exit)
- **Consequences:** Proposed decisions and actionable work are triaged through labels and linked documents.
- **Revisit trigger:** Enable Discussions after recurring external ideas or Q&A appear; add a milestone when multiple accepted issues share one release target.
- **GitHub:** None.

## PD-025: Agent instructions and tests before custom skills or hooks
- **Status:** `deferred`
- **Date:** 2026-07-09
- **Area:** developer-experience
- **Decision:** Use `AGENTS.md`, documentation tests, and a PR checklist; do not add a repo-local Codex skill or commit hook yet.
- **Rationale:** Project-specific policy belongs in repository instructions and mechanical invariants belong in tests.
- **Source:** [Engineering spec phase exit](ENGINEERING_SPEC.md#phase-1-exit)
- **Consequences:** A read-only decision-scribe subagent may propose updates, but root agents approve and write them.
- **Revisit trigger:** Reconsider a tested user-local skill after two independent agent runs violate the workflow despite current instructions and checks.
- **GitHub:** None.
