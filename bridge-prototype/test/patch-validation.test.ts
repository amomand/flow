import { describe, expect, it } from "vitest";
import { validateFlowRoutinePatch, type RoutineLookup } from "../src/patch-validation.js";
import type { Routine } from "../src/flow-types.js";

const ROUTINE_ID = "D0B696CE-2C78-42E8-9D61-E5DDDD0E0528";
const EXERCISE_ID = "5DE92253-C398-466D-A67E-DC7C7FE4EA8E";
const SECTION_ID = "973249E6-0B69-4C36-9897-7A7DAD5CBA33";
const CONTENT_HASH = "c1-214a4c15b7a3d62b";

const testRoutine: Routine = {
  id: ROUTINE_ID,
  name: "Wednesday — Upper A",
  currentPhase: "base",
  sections: [
    {
      id: SECTION_ID,
      name: "Main Lifts",
      exercises: [
        {
          id: EXERCISE_ID,
          name: "Floor press KB (24kg)",
          sets: 3,
          reps: 10,
          restBetweenSetsSeconds: 90,
          restAfterExerciseSeconds: 90,
          notes: "Two-handed grip.",
          perSide: false,
          phaseOverrides: {},
        },
      ],
    },
  ],
};

function makeLookup(routine: Routine | undefined, contentHash: string | undefined): RoutineLookup {
  return {
    getRoutine: (routineId) => (routine?.id === routineId ? routine : undefined),
    getContentHash: (routineId) => (routine?.id === routineId ? contentHash : undefined),
  };
}

function validPatch(overrides: Record<string, unknown> = {}) {
  return {
    schemaVersion: 2,
    routineId: ROUTINE_ID,
    baseContentHash: CONTENT_HASH,
    rationale: "Test rationale.",
    operations: [
      {
        kind: "replaceExerciseReps",
        exerciseId: EXERCISE_ID,
        expectedIntValue: 10,
        newIntValue: 12,
      },
    ],
    ...overrides,
  };
}

describe("validateFlowRoutinePatch", () => {
  it("accepts a well-formed patch against a matching routine and hash", () => {
    const result = validateFlowRoutinePatch(validPatch(), makeLookup(testRoutine, CONTENT_HASH));
    expect(result.valid).toBe(true);
    expect(result.problems).toEqual([]);
  });

  it("rejects a stale baseContentHash", () => {
    const result = validateFlowRoutinePatch(
      validPatch({ baseContentHash: "c1-0000000000000000" }),
      makeLookup(testRoutine, CONTENT_HASH)
    );
    expect(result.valid).toBe(false);
    expect(result.problems.some((p) => p.path === "baseContentHash")).toBe(true);
  });

  it("rejects an unknown routineId", () => {
    const result = validateFlowRoutinePatch(
      validPatch({ routineId: "00000000-0000-0000-0000-000000000000" }),
      makeLookup(testRoutine, CONTENT_HASH)
    );
    expect(result.valid).toBe(false);
    expect(result.problems.some((p) => p.path === "routineId")).toBe(true);
  });

  it("rejects an unsupported schema version", () => {
    const result = validateFlowRoutinePatch(validPatch({ schemaVersion: 1 }), makeLookup(testRoutine, CONTENT_HASH));
    expect(result.valid).toBe(false);
  });

  it("rejects reps outside the 1-100 range", () => {
    const result = validateFlowRoutinePatch(
      validPatch({
        operations: [
          { kind: "replaceExerciseReps", exerciseId: EXERCISE_ID, expectedIntValue: 10, newIntValue: 250 },
        ],
      }),
      makeLookup(testRoutine, CONTENT_HASH)
    );
    expect(result.valid).toBe(false);
    expect(result.problems.some((p) => p.path === "operations[0].newIntValue")).toBe(true);
  });

  it("rejects notes longer than 500 characters", () => {
    const result = validateFlowRoutinePatch(
      validPatch({
        operations: [
          {
            kind: "updateExerciseNotes",
            exerciseId: EXERCISE_ID,
            expectedStringValue: "Two-handed grip.",
            newStringValue: "x".repeat(501),
          },
        ],
      }),
      makeLookup(testRoutine, CONTENT_HASH)
    );
    expect(result.valid).toBe(false);
    expect(result.problems.some((p) => p.path === "operations[0].newStringValue")).toBe(true);
  });

  it("rejects an unknown operation kind", () => {
    const result = validateFlowRoutinePatch(
      validPatch({ operations: [{ kind: "deleteEverything", exerciseId: EXERCISE_ID }] }),
      makeLookup(testRoutine, CONTENT_HASH)
    );
    expect(result.valid).toBe(false);
  });

  it("rejects an operation referencing an exercise id not in the routine", () => {
    // A well-formed but unrelated UUID (v4), distinct from any id in testRoutine.
    const unknownExerciseId = "3fa85f64-5717-4562-b3fc-2c963f66afa6";
    const result = validateFlowRoutinePatch(
      validPatch({
        operations: [
          {
            kind: "replaceExerciseReps",
            exerciseId: unknownExerciseId,
            expectedIntValue: 10,
            newIntValue: 12,
          },
        ],
      }),
      makeLookup(testRoutine, CONTENT_HASH)
    );
    expect(result.valid).toBe(false);
    expect(result.problems.some((p) => p.path === "operations[0].exerciseId")).toBe(true);
  });

  it("rejects a malformed baseContentHash shape even before hash comparison", () => {
    const result = validateFlowRoutinePatch(
      validPatch({ baseContentHash: "not-a-hash-at-all" }),
      makeLookup(testRoutine, CONTENT_HASH)
    );
    expect(result.valid).toBe(false);
  });
});
