import { describe, expect, it } from "vitest";
import corpus from "../src/patch-contract-corpus.json";
import {
  OPERATION_KINDS,
  PATCH_SCHEMA_VERSIONS,
  type Capabilities,
  type CoachContext,
  type Routine,
  validatePatch,
} from "../src/schemas";

type Outcome = "accepted" | "rejected";
type FixtureCase = {
  id: string;
  rule: string;
  patch: unknown;
  routines?: unknown[];
  capabilities?: { patchSchemaVersions: number[]; operationKinds: string[] };
  expected: { swift: Outcome; bridge: Outcome };
};

const CURRENT_HASH = "c1-0123456789abcdef";

function replaceBaseHash<T>(value: T): T {
  return JSON.parse(JSON.stringify(value).replaceAll("{{baseContentHash}}", CURRENT_HASH)) as T;
}

function contextFor(routines: Routine[]): CoachContext {
  return {
    schemaVersion: 2,
    generatedAt: "2026-08-08T12:00:00Z",
    app: "Flow",
    routines,
    currentPhaseByRoutineId: Object.fromEntries(routines.map((routine) => [routine.id, routine.currentPhase])),
    routineContentHashByRoutineId: Object.fromEntries(routines.map((routine) => [routine.id, CURRENT_HASH])),
    routineStateHashByRoutineId: Object.fromEntries(routines.map((routine) => [routine.id, "s1-0123456789abcdef"])),
    recentStrengthSummary: [],
    recentCardioSummary: [],
  };
}

describe("frozen Flow routine patch contract corpus", () => {
  it("advertises the capabilities recorded with the matrix", () => {
    expect(PATCH_SCHEMA_VERSIONS).toEqual(corpus.expectedCapabilities.patchSchemaVersions);
    expect(OPERATION_KINDS).toEqual(corpus.expectedCapabilities.operationKinds);
  });

  for (const fixture of corpus.cases as FixtureCase[]) {
    it(`${fixture.id} (${fixture.rule})`, () => {
      const routines = replaceBaseHash((fixture.routines ?? [corpus.baseRoutine])) as Routine[];
      const capabilities: Capabilities = {
        patchSchemaVersions: fixture.capabilities?.patchSchemaVersions ?? [...PATCH_SCHEMA_VERSIONS],
        operationKinds: (fixture.capabilities?.operationKinds ?? [...OPERATION_KINDS]) as Capabilities["operationKinds"],
        deviceReported: true,
      };
      const result = validatePatch(replaceBaseHash(fixture.patch), contextFor(routines), capabilities);
      const actual: Outcome = result.valid ? "accepted" : "rejected";
      expect(actual, JSON.stringify(result.problems)).toBe(fixture.expected.bridge);
    });
  }
});
