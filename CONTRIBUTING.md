# Contributing To doppelbanger

doppelbanger is an audio product, not a collection of disconnected experiments. Contributions must preserve one processing path, explicit contracts, and reproducible evidence.

## Before Coding

1. Read `docs/PRD.md`, `docs/ENGINEERING_SPEC.md`, and `docs/DECISIONS.md` for product or architecture work.
2. Read `docs/PLUGIN_ARCHITECTURE.md` before touching DSP, FFI, plugin lifecycle, parameters, or host state.
3. Classify the validation tier in `docs/VALIDATION.md` that the change can affect.
4. Search existing code, tests, decisions, and issues before introducing a dependency or abstraction.
5. Link an issue for user-visible features, schema changes, new DSP stages, packaging, or benchmark threshold changes.

## Development Rules

- **Tests first:** write a focused failing test before implementation for behavior changes and defects.
- Every public contract, DSP function, pipeline transition, CLI command, API/schema change, report field, and benchmark gate needs a purposeful test.
- Keep mastering math in the Rust processor. Plugin, CLI, API, and renderer code are adapters.
- The audio callback performs no allocation, locking, waiting, I/O, database/API work, logging, or unbounded computation.
- Do not add fake processing, static analysis responses, tolerance widening, or silent fallback behavior.
- Use generated or redistributable audio in tests. Never commit proprietary references, unreleased music, credentials, or private paths.
- Update the canonical document and append/supersede a `PD-###` record when an accepted product or architecture decision changes.

## Pull Requests

- Keep each PR to one stable contract and at most **400 changed lines** unless generated code, fixtures, or an indivisible boundary is explained in the PR body.
- Use stacked PRs for dependent work. Each PR names its parent and remains independently reviewable.
- Separate contract/docs, DSP core, FFI, plugin shell, control plane, UI, and algorithm stages when they can be reviewed independently.
- Include exact validation commands, measured results, input provenance, and residual risks.
- Run one specification review and one code-quality review for nontrivial changes before requesting human review.
- Never auto-update quality baselines in the same command that evaluates them.

## Local Validation

Start narrow, then run the affected tier:

```bash
cargo fmt --all -- --check
cargo test
cargo clippy --all-targets -- -D warnings
docker compose config
```

API integration requires the local services:

```bash
docker compose up -d --wait
cargo test --test api_integration -- --ignored --test-threads=1
docker compose down
```

Real-audio, plugin, performance, and Ableton requirements are defined in `docs/VALIDATION.md`. State clearly when a required tier could not run.

## Style

### Rust

- Use `rustfmt` and warning-free `clippy`.
- Prefer typed enums and versioned structs over string modes or unstructured maps.
- Keep transformations pure where practical and isolate filesystem, API, and database effects.
- Return field- and operation-specific errors. No panic may cross the plugin ABI.
- Avoid allocation in DSP processing; prove the callback path with the allocation test.

### C++ Plugin Wrapper

- Use the repository-selected C++ standard and iPlug2 conventions.
- Keep ownership explicit with RAII; no naked owning pointers.
- Keep the C ABI in fixed-width C-compatible types with a `db_` prefix.
- Catch exceptions before the ABI and host boundary.
- Do not implement DSP, analysis, plan rules, or persistence logic in the wrapper.

### SQL

- Migrations are append-only once released.
- Constraints enforce lifecycle and referential invariants; PostgREST exposure is deliberate.
- RPCs that claim work must be atomic and integration-tested.

## Agent-Assisted Changes

Agents follow the same contribution rules and `docs/AGENT_WORKFLOW.md`. Agents may propose decisions and evidence updates, but the root task owns accepted scope, file edits, git history, and final claims. Hooks are advisory; tests and CI remain the enforcement layer.

## Reporting Bugs

Use the GitHub bug template with exact versions, reproduction steps, sanitized logs, and fixture provenance. For audio defects, include the smallest legal fixture or signal recipe and a timestamped description; do not upload private music.
