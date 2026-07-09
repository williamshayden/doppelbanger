# Agent Workflow

This repository is designed for agent-assisted engineering with human-owned product decisions. The root task remains the operator; subagents widen review coverage but do not own scope, git history, or final claims.

## When To Use Multiple Agents

Use bounded subagents when a change affects at least two of these surfaces:

- product or architecture contracts;
- DSP, analysis, plan generation, or benchmark gates;
- C ABI, plugin lifecycle, real-time behavior, or host state;
- Postgres/PostgREST schema and worker lifecycle;
- cross-platform build, packaging, or release evidence.

Small local fixes should stay in one task.

## Roles

For nontrivial work, use at most the agents that add independent evidence:

| Role | Responsibility | Default access |
| --- | --- | --- |
| operator | accepted scope, plan, file ownership, integration, git, final evidence | write |
| explorer | current code/contracts, risks, analogous patterns | read-only |
| specification reviewer | checks behavior against PRD/spec/decision and issue | read-only |
| quality reviewer | checks correctness, tests, realtime safety, maintainability | read-only |
| implementation worker | one disjoint file/module contract assigned by operator | scoped write |

Do not send multiple agents to solve the same problem unless deliberate independent review is the goal.

## Delivery Loop

1. Read the canonical product, engineering, plugin, validation, and decision documents.
2. State the current truth, user outcome, affected contracts, risks, and first failing tests.
3. Assign read-only exploration or disjoint implementation ownership.
4. Write and observe focused failing tests before production changes.
5. Implement the smallest coherent behavior through the shared processor path.
6. Run the relevant validation tier and retain exact output/provenance.
7. Run separate specification and code-quality reviews for nontrivial changes.
8. Resolve findings, rerun validation, and report residual risk.
9. Keep each PR to one stable contract and stack dependent PRs explicitly.

## Worker Output

Every worker returns:

- scope inspected or owned;
- files touched, if any;
- findings or behavior delivered;
- exact tests/checks run and results;
- blockers, assumptions, and residual risks;
- recommended next action.

The operator verifies claims before repeating them. A worker's assertion is not release evidence without the underlying command or artifact.

## Authority And Safety

- Agents may propose decision records; only the operator accepts and writes product decisions.
- Read-only reviewers do not edit files.
- Implementation workers receive disjoint ownership and never revert concurrent changes.
- The operator alone stages, commits, pushes, opens/updates PRs, and resolves stack topology.
- No agent downloads multi-gigabyte audio, uses private music, changes repository visibility, publishes releases, or runs destructive database/git operations without explicit approval.
- No agent widens a quality threshold or updates a baseline merely to make a branch pass.

## Skills And Hooks

Use installed general skills for brainstorming, TDD, stacked PRs, subagent coordination, verification, and overengineering review. Keep doppelbanger-specific rules here and in `AGENTS.md` rather than duplicating them into a skill.

Hooks are advisory reminders only. They do not start agents, accept decisions, mutate git history, or substitute for CI. Create a new skill or hook only after a repeated failure is reproduced in a pressure scenario and the new mechanism demonstrably prevents it.
