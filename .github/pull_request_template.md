## Summary

Describe the user-visible or contract-level outcome.

## Linked issue

Use `Closes #N` only when this PR fully resolves the issue. Otherwise use `Refs #N`.

## Stack

Parent PR/branch: <!-- `main` for the stack root -->

- [ ] This PR is one stable contract and is at or below 400 changed lines, or the exception is explained below.

## Contract and documentation impact

- [ ] No product, CLI, API, schema, DSP, or deferment decision changed.
- [ ] Relevant PRD, engineering spec, and `PD-###` records are updated together.

## Validation evidence

Validation tier(s): <!-- Tier 0-6 from docs/VALIDATION.md -->

List exact commands, measured results, fixtures/manifests, build profile, and manual checks.

- [ ] DSP/plugin changes use the shared `MasteringProcessor` path.
- [ ] Audio-callback changes prove no allocation, locks, I/O, logging, or unbounded work.
- [ ] Quality/performance baseline changes include before/after evidence and were not auto-accepted.
- [ ] Nontrivial changes received specification and code-quality review passes.

## Residual and data risk

- [ ] No proprietary audio, unreleased music, credentials, private business information, or vulnerability details are committed.
- [ ] Remaining limitations and unverified behavior are stated.
