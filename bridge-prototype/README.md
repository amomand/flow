# Flow Coach bridge prototype (retired)

This directory used to hold a runnable fixture-backed bridge: an Express server with MCP and REST adapters over its own copy of the patch contract, built to prove the contract in [#36](https://github.com/amomand/flow/issues/36) and [#46](https://github.com/amomand/flow/issues/46). It did that, and the bridge that came out of it is [`bridge-worker`](../bridge-worker), deployed and paired with both Flow installations.

The server, its stores and its patch validator were removed in [#73](https://github.com/amomand/flow/issues/73). The validator had been stuck on schema 2 since 27 July 2026: no `renameRoutine`, no `addSection`, no `createRoutine`, no `target` discriminator and no capability handling, all of which landed in the Worker in [#67](https://github.com/amomand/flow/issues/67), [#68](https://github.com/amomand/flow/issues/68) and [#69](https://github.com/amomand/flow/issues/69). A second copy of the contract that quietly means something older is worse than no second copy, and nothing was running this one.

**`bridge-worker` is the only patch contract.** `bridge-worker/src/patch-operations.json` names the operation set and the schema versions, and both the Worker and `FlowTests` read it. Anything describing the patch format elsewhere is documentation, not an implementation.

## What is still here, and why

| Path | Kept because |
|---|---|
| `fixtures/coach-context.json` | `bridge-worker/test/*` and both smoke scripts import it. It is the synthetic snapshot every Worker test runs against. |
| `openapi.yaml` | The GPT Action schema, with `x-openai-isConsequential` on the write. [#49](https://github.com/amomand/flow/issues/49) says not to rebuild this if the GPT route is ever picked up. |
| `gpt-actions-instructions.md` | The private-GPT instructions, kept for the same reason. |

Both GPT files were written before the Claude pivot, describe the schema 2 operation set, and have never been run against a real GPT. Treat them as a starting point to revalidate, not as a current description of anything. The live REST edge they were aimed at is `/actions/*` in the Worker, which stays alive as a smoke-test surface.

## The fixture

`fixtures/coach-context.json` mirrors Flow's schema-2 context export and uses the two seed routines from `RoutineStore.swift`. The exercise and cardio summaries in it are plausible and invented; none of it is real user data, and it holds no HealthKit routes, samples, workout identifiers, pace buckets or per-sample heart-rate data.

A real export can be placed at `fixtures/coach-context.local.json`, which is gitignored.

## The boundary, which has not moved

**The assistant proposes; Flow decides.** The bridge returns a short-lived coach snapshot and stores a pending routine patch. It never mutates a routine, never talks to HealthKit, and is never the source of truth. Flow pulls a draft, validates it against live app state, shows the difference, and requires explicit confirmation before saving anything.
