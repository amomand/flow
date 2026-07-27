import { beforeEach, describe, expect, it } from "vitest";
import { env, runInDurableObject, SELF } from "cloudflare:test";
import fixtureContext from "../../bridge-prototype/fixtures/coach-context.json";
import {
  coachContextSchema,
  effectiveCapabilities,
  MAX_EXERCISES_PER_SECTION,
  MAX_ROUTINES,
  MAX_SECTIONS,
  OPERATION_KINDS,
  PATCH_SCHEMA_VERSIONS,
  validatePatch,
} from "../src/schemas";

const ACTIONS_SECRET = "fixture-actions-secret";
const DEVICE_SECRET = "fixture-device-secret";

function auth(secret: string): HeadersInit {
  return { authorization: `Bearer ${secret}`, "content-type": "application/json" };
}

function snapshot(contextId = crypto.randomUUID(), now = Date.now()) {
  return {
    contextId,
    createdAt: new Date(now).toISOString(),
    expiresAt: new Date(now + 24 * 60 * 60 * 1000).toISOString(),
    sharingProfile: {
      schemaVersion: 1,
      dataTiers: ["routines", "strengthHistory", "cardioHistory", "healthMetrics"],
    },
    context: fixtureContext,
  };
}

function validPatch() {
  const routine = fixtureContext.routines[0]!;
  const exercise = routine.sections[0]!.exercises[0]!;
  return {
    schemaVersion: 2,
    routineId: routine.id,
    baseContentHash: fixtureContext.routineContentHashByRoutineId[routine.id as keyof typeof fixtureContext.routineContentHashByRoutineId],
    rationale: "Exercise the durable proposal path.",
    operations: [{
      kind: "replaceExerciseSets",
      exerciseId: exercise.id,
      expectedIntValue: exercise.sets,
      newIntValue: exercise.sets + 1,
    }],
  };
}

async function json(response: Response): Promise<Record<string, any>> {
  return response.json() as Promise<Record<string, any>>;
}

async function clearMailbox(): Promise<void> {
  const response = await SELF.fetch("https://flow.test/device/data", {
    method: "DELETE",
    headers: auth(DEVICE_SECRET),
  });
  expect(response.status).toBe(200);
}

async function upload(envelope = snapshot()): Promise<Response> {
  return SELF.fetch("https://flow.test/device/snapshots", {
    method: "PUT",
    headers: auth(DEVICE_SECRET),
    body: JSON.stringify(envelope),
  });
}

describe("Flow Coach bridge Worker", () => {
  beforeEach(clearMailbox);

  it("keeps the Actions and device credentials separate", async () => {
    const missing = await SELF.fetch("https://flow.test/actions/coach-context");
    expect(missing.status).toBe(401);

    const wrongEdge = await SELF.fetch("https://flow.test/device/pending-patches", {
      headers: auth(ACTIONS_SECRET),
    });
    expect(wrongEdge.status).toBe(401);
  });

  it("stores a Swift-shaped snapshot idempotently and requires exact correlation", async () => {
    const envelope = snapshot();
    const first = await upload(envelope);
    expect(first.status).toBe(201);
    expect((await json(first)).duplicate).toBe(false);

    const retry = await upload(envelope);
    expect(retry.status).toBe(200);
    expect((await json(retry)).duplicate).toBe(true);

    const read = await SELF.fetch(`https://flow.test/actions/routines?contextId=${envelope.contextId}`, {
      headers: auth(ACTIONS_SECRET),
    });
    expect(read.status).toBe(200);
    expect((await json(read)).routines).toHaveLength(fixtureContext.routines.length);

    const unknown = await SELF.fetch(`https://flow.test/actions/routines?contextId=${crypto.randomUUID()}`, {
      headers: auth(ACTIONS_SECRET),
    });
    expect(unknown.status).toBe(404);
  });

  it("accepts Swift exercises that omit empty phase overrides", async () => {
    // Cloned before the key goes: `snapshot()` hands out the imported fixture
    // itself, so deleting through it would take the overrides away from every
    // test that runs after this one.
    const envelope = { ...snapshot(), context: structuredClone(fixtureContext) };
    delete (envelope.context.routines[0]!.sections[0]!.exercises[0]! as { phaseOverrides?: unknown }).phaseOverrides;

    expect((await upload(envelope)).status).toBe(201);
  });

  it("rejects duplicate sharing tiers", async () => {
    const envelope = snapshot();
    envelope.sharingProfile.dataTiers = ["routines", "strengthHistory", "routines"];

    const response = await upload(envelope);
    expect(response.status).toBe(422);
    expect((await json(response)).problems).toContainEqual({
      path: "sharingProfile.dataTiers",
      message: "data tiers must not contain duplicates",
    });
  });

  it("keeps differently configured mailbox objects isolated", async () => {
    const mailboxA = env.FLOW_COACH.get(env.FLOW_COACH.idFromName(`mailbox-a-${crypto.randomUUID()}`));
    const mailboxB = env.FLOW_COACH.get(env.FLOW_COACH.idFromName(`mailbox-b-${crypto.randomUUID()}`));
    const envelope = snapshot();
    const internalDeviceHeaders = { "x-flow-edge": "device", "content-type": "application/json" };
    const internalActionsHeaders = { "x-flow-edge": "actions", "x-flow-principal": "actions-primary" };

    const stored = await mailboxA.fetch("https://flow.test/device/snapshots", {
      method: "PUT",
      headers: internalDeviceHeaders,
      body: JSON.stringify(envelope),
    });
    expect(stored.status).toBe(201);

    const absentFromB = await mailboxB.fetch(`https://flow.test/actions/routines?contextId=${envelope.contextId}`, {
      headers: internalActionsHeaders,
    });
    expect(absentFromB.status).toBe(404);
  });

  it("rejects an oversized body without relying on Content-Length", async () => {
    const headers = new Headers(auth(DEVICE_SECRET));
    headers.delete("content-length");
    const response = await SELF.fetch("https://flow.test/device/snapshots", {
      method: "PUT",
      headers,
      body: `{"padding":"${"x".repeat(512 * 1024)}"}`,
    });

    expect(response.status).toBe(413);
  });

  it("rejects an already-expired snapshot", async () => {
    const now = Date.now();
    const envelope = snapshot(crypto.randomUUID(), now - 25 * 60 * 60 * 1000);
    const response = await upload(envelope);
    expect(response.status).toBe(410);
  });

  it("creates proposals retry-safely, pulls once, and acknowledges monotonically", async () => {
    const envelope = snapshot();
    expect((await upload(envelope)).status).toBe(201);
    const body = JSON.stringify({ contextId: envelope.contextId, patch: validPatch() });

    const first = await SELF.fetch("https://flow.test/actions/pending-patches", {
      method: "POST",
      headers: { ...auth(ACTIONS_SECRET), "idempotency-key": "proposal-1" },
      body,
    });
    expect(first.status).toBe(201);
    const firstBody = await json(first);
    const patchId = firstBody.patch.patchId as string;

    const retry = await SELF.fetch("https://flow.test/actions/pending-patches", {
      method: "POST",
      headers: { ...auth(ACTIONS_SECRET), "idempotency-key": "proposal-1" },
      body,
    });
    expect(retry.status).toBe(200);
    expect((await json(retry)).patch.patchId).toBe(patchId);

    const pull = await SELF.fetch("https://flow.test/device/pending-patches", {
      headers: auth(DEVICE_SECRET),
    });
    const pulled = await json(pull);
    expect(pulled.patches).toHaveLength(1);
    expect(pulled.patches[0].patchId).toBe(patchId);

    const premature = await SELF.fetch(`https://flow.test/device/pending-patches/${patchId}/ack`, {
      method: "POST",
      headers: auth(DEVICE_SECRET),
      body: JSON.stringify({ status: "applied" }),
    });
    expect(premature.status).toBe(409);

    const pulledAck = await SELF.fetch(`https://flow.test/device/pending-patches/${patchId}/ack`, {
      method: "POST",
      headers: auth(DEVICE_SECRET),
      body: JSON.stringify({ status: "pulled" }),
    });
    expect(pulledAck.status).toBe(200);
    expect((await json(pulledAck)).duplicate).toBe(false);

    const terminal = await SELF.fetch(`https://flow.test/device/pending-patches/${patchId}/ack`, {
      method: "POST",
      headers: auth(DEVICE_SECRET),
      body: JSON.stringify({ status: "applied" }),
    });
    const terminalBody = await json(terminal);
    expect(terminal.status).toBe(200);
    expect(terminalBody.patch.status).toBe("applied");
    expect(terminalBody.patch).not.toHaveProperty("patch");
    expect(terminalBody.patch).not.toHaveProperty("rationale");

    const terminalRetry = await SELF.fetch(`https://flow.test/device/pending-patches/${patchId}/ack`, {
      method: "POST",
      headers: auth(DEVICE_SECRET),
      body: JSON.stringify({ status: "applied" }),
    });
    expect(terminalRetry.status).toBe(200);
    expect((await json(terminalRetry)).duplicate).toBe(true);

    const afterTerminal = await SELF.fetch("https://flow.test/device/pending-patches", {
      headers: auth(DEVICE_SECRET),
    });
    expect((await json(afterTerminal)).patches).toHaveLength(0);
  });

  it("deletes a snapshot and all proposals derived from it", async () => {
    const envelope = snapshot();
    expect((await upload(envelope)).status).toBe(201);
    const create = await SELF.fetch("https://flow.test/actions/pending-patches", {
      method: "POST",
      headers: auth(ACTIONS_SECRET),
      body: JSON.stringify({ contextId: envelope.contextId, patch: validPatch() }),
    });
    expect(create.status).toBe(201);

    const deleted = await SELF.fetch(`https://flow.test/device/snapshots/${envelope.contextId}`, {
      method: "DELETE",
      headers: auth(DEVICE_SECRET),
    });
    expect(deleted.status).toBe(200);

    const readDeleted = await SELF.fetch(`https://flow.test/actions/routines?contextId=${envelope.contextId}`, {
      headers: auth(ACTIONS_SECRET),
    });
    expect(readDeleted.status).toBe(410);
    const pull = await SELF.fetch("https://flow.test/device/pending-patches", {
      headers: auth(DEVICE_SECRET),
    });
    expect((await json(pull)).patches).toHaveLength(0);
  });
});

describe("Flow Coach bridge capabilities and renameRoutine", () => {
  beforeEach(clearMailbox);

  function capableSnapshot(operationKinds: string[] = [...OPERATION_KINDS], patchSchemaVersions = [2, 3]) {
    return { ...snapshot(), deviceCapabilities: { patchSchemaVersions, operationKinds } };
  }

  function renamePatch(overrides: Record<string, unknown> = {}, operationOverrides: Record<string, unknown> = {}) {
    const routine = fixtureContext.routines[0]!;
    return {
      schemaVersion: 3,
      routineId: routine.id,
      baseContentHash: fixtureContext.routineContentHashByRoutineId[routine.id as keyof typeof fixtureContext.routineContentHashByRoutineId],
      rationale: "The weekday in the name no longer matches the plan.",
      operations: [{
        kind: "renameRoutine",
        expectedStringValue: routine.name,
        newStringValue: "Upper A",
        ...operationOverrides,
      }],
      ...overrides,
    };
  }

  async function validate(contextId: string, patch: unknown): Promise<Response> {
    return SELF.fetch("https://flow.test/actions/patches/validate", {
      method: "POST",
      headers: auth(ACTIONS_SECRET),
      body: JSON.stringify({ contextId, patch }),
    });
  }

  async function readCapabilities(contextId: string): Promise<Record<string, any>> {
    const response = await SELF.fetch(`https://flow.test/actions/coach-context?contextId=${contextId}`, {
      headers: auth(ACTIONS_SECRET),
    });
    expect(response.status).toBe(200);
    return (await json(response)).capabilities;
  }

  it("advertises what the device declares, and accepts a rename against it", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);

    const capabilities = await readCapabilities(envelope.contextId);
    expect(capabilities.deviceReported).toBe(true);
    expect(capabilities.patchSchemaVersions).toEqual([2, 3]);
    expect(capabilities.operationKinds).toEqual(OPERATION_KINDS);

    const checked = await validate(envelope.contextId, renamePatch());
    expect(checked.status).toBe(200);
    expect((await json(checked)).valid).toBe(true);

    const stored = await SELF.fetch("https://flow.test/actions/pending-patches", {
      method: "POST",
      headers: auth(ACTIONS_SECRET),
      body: JSON.stringify({ contextId: envelope.contextId, patch: renamePatch() }),
    });
    expect(stored.status).toBe(201);
  });

  // The failure this whole mechanism exists to prevent: a bridge that accepts
  // an operation the phone in the user's pocket has never heard of.
  it("falls back to the schema 2 baseline when the device declares nothing", async () => {
    const envelope = snapshot();
    expect((await upload(envelope)).status).toBe(201);

    const capabilities = await readCapabilities(envelope.contextId);
    expect(capabilities.deviceReported).toBe(false);
    expect(capabilities.patchSchemaVersions).toEqual([2]);
    expect(capabilities.operationKinds).not.toContain("renameRoutine");

    const checked = await validate(envelope.contextId, renamePatch());
    expect(checked.status).toBe(422);
    expect((await json(checked)).problems[0].path).toBe("schemaVersion");
  });

  it("refuses an operation the device leaves off its list", async () => {
    const envelope = capableSnapshot(OPERATION_KINDS.filter((kind) => kind !== "renameRoutine"));
    expect((await upload(envelope)).status).toBe(201);
    expect(await readCapabilities(envelope.contextId).then((c) => c.operationKinds)).not.toContain("renameRoutine");

    const checked = await validate(envelope.contextId, renamePatch());
    expect(checked.status).toBe(422);
    const problems = (await json(checked)).problems;
    expect(problems[0].path).toBe("operations.0.kind");
    expect(problems[0].message).toContain("renameRoutine");
  });

  it("refuses a schema 3 operation smuggled into a schema 2 patch", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);

    const checked = await validate(envelope.contextId, renamePatch({ schemaVersion: 2 }));
    expect(checked.status).toBe(422);
    const problems = (await json(checked)).problems;
    expect(problems[0].path).toBe("operations.0.kind");
    expect(problems[0].message).toContain("schema 3");
  });

  it("treats a stale expected name as a conflict rather than applying it anyway", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);

    const checked = await validate(envelope.contextId, renamePatch({}, { expectedStringValue: "Some Other Name" }));
    expect(checked.status).toBe(422);
    expect((await json(checked)).problems[0].path).toBe("operations.0.expectedStringValue");
  });

  it("bounds the proposed name", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);

    for (const newStringValue of ["   ", "x".repeat(101)]) {
      const checked = await validate(envelope.contextId, renamePatch({}, { newStringValue }));
      expect(checked.status).toBe(422);
      expect((await json(checked)).problems[0].path).toBe("operations.0.newStringValue");
    }
  });

  /**
   * The version list lives in patch-operations.json and is read by the app,
   * the parser, and the published MCP schema. This pins the parser to it: a
   * version added to the contract that zod still rejects would advertise a
   * capability no patch could actually use.
   */
  it("parses exactly the schema versions the shared contract names", async () => {
    const envelope = capableSnapshot(
      [...OPERATION_KINDS],
      [...PATCH_SCHEMA_VERSIONS],
    );
    expect((await upload(envelope)).status).toBe(201);

    for (const schemaVersion of PATCH_SCHEMA_VERSIONS) {
      const checked = await validate(envelope.contextId, {
        ...renamePatch({ schemaVersion }),
        // renameRoutine only exists from 3, so probe each version with an
        // operation every version has.
        operations: validPatch().operations,
      });
      const body = await json(checked);
      expect(body.problems.filter((problem: any) => problem.path === "schemaVersion")).toEqual([]);
      expect(body.valid).toBe(true);
    }

    const unknown = await validate(envelope.contextId, renamePatch({ schemaVersion: 99 }));
    expect(unknown.status).toBe(422);
    expect((await json(unknown)).problems[0].path).toBe("schemaVersion");
  });

  it("still validates and stores a schema 2 patch unchanged", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);

    const checked = await validate(envelope.contextId, validPatch());
    expect(checked.status).toBe(200);
    expect((await json(checked)).valid).toBe(true);

    const stored = await SELF.fetch("https://flow.test/actions/pending-patches", {
      method: "POST",
      headers: auth(ACTIONS_SECRET),
      body: JSON.stringify({ contextId: envelope.contextId, patch: validPatch() }),
    });
    expect(stored.status).toBe(201);

    const pulled = await SELF.fetch("https://flow.test/device/pending-patches", {
      headers: auth(DEVICE_SECRET),
    });
    expect((await json(pulled)).patches[0].patch.schemaVersion).toBe(2);
  });

  function sectionPatch(operations: unknown[]) {
    const routine = fixtureContext.routines[0]!;
    return {
      schemaVersion: 3,
      routineId: routine.id,
      baseContentHash: fixtureContext.routineContentHashByRoutineId[routine.id as keyof typeof fixtureContext.routineContentHashByRoutineId],
      rationale: "Restructure the block rather than just its numbers.",
      operations,
    };
  }

  function newExercise(id: string, name: string) {
    return {
      id, name, sets: 3, reps: 8,
      restBetweenSetsSeconds: 90, restAfterExerciseSeconds: 120,
      notes: "", perSide: false, phaseOverrides: {},
    };
  }

  /**
   * The reason addSection exists: addExercise needs somewhere to go, and
   * validating every reference against the immutable snapshot made a section
   * created in the same patch invisible.
   */
  it("lets an addExercise target a section created earlier in the same patch", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);
    const sectionId = crypto.randomUUID();

    const checked = await validate(envelope.contextId, sectionPatch([
      { kind: "addSection", section: { id: sectionId, name: "Core" } },
      { kind: "addExercise", sectionId, exercise: newExercise(crypto.randomUUID(), "Hanging Leg Raise") },
    ]));

    expect(checked.status).toBe(200);
    expect((await json(checked)).valid).toBe(true);
  });

  /**
   * Latent before this change: the exercise was in the patch but not in the
   * snapshot, so the move was rejected for referencing something absent.
   */
  it("lets a moveExercise reference an exercise added earlier in the same patch", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);
    const routine = fixtureContext.routines[0]!;
    const exerciseId = crypto.randomUUID();

    const checked = await validate(envelope.contextId, sectionPatch([
      { kind: "addExercise", sectionId: routine.sections[0]!.id, exercise: newExercise(exerciseId, "Face Pull") },
      { kind: "moveExercise", exerciseId, targetSectionId: routine.sections[0]!.id },
    ]));

    expect(checked.status).toBe(200);
    expect((await json(checked)).valid).toBe(true);
  });

  it("names the field when an addSection anchors on a section that does not exist", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);

    const checked = await validate(envelope.contextId, sectionPatch([
      {
        kind: "addSection",
        section: { id: crypto.randomUUID(), name: "Core" },
        afterSectionId: crypto.randomUUID(),
      },
    ]));

    expect(checked.status).toBe(422);
    const problems = (await json(checked)).problems;
    expect(problems.map((problem: any) => problem.path)).toContain("operations.0.afterSectionId");
  });

  it("refuses a section that anchors on itself", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);
    const sectionId = crypto.randomUUID();

    const checked = await validate(envelope.contextId, sectionPatch([
      { kind: "addSection", section: { id: sectionId, name: "Core" }, afterSectionId: sectionId },
    ]));

    expect(checked.status).toBe(422);
    expect((await json(checked)).problems.map((problem: any) => problem.path)).toContain("operations.0.afterSectionId");
  });

  it("refuses a section id that already exists, in the snapshot or in the patch", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);
    const routine = fixtureContext.routines[0]!;

    const existing = await validate(envelope.contextId, sectionPatch([
      { kind: "addSection", section: { id: routine.sections[0]!.id, name: "Core" } },
    ]));
    expect(existing.status).toBe(422);
    expect((await json(existing)).problems.map((problem: any) => problem.path)).toContain("operations.0.section.id");

    const twice = crypto.randomUUID();
    const repeated = await validate(envelope.contextId, sectionPatch([
      { kind: "addSection", section: { id: twice, name: "Core" } },
      { kind: "addSection", section: { id: twice, name: "Also Core" } },
    ]));
    expect(repeated.status).toBe(422);
    expect((await json(repeated)).problems.map((problem: any) => problem.path)).toContain("operations.1.section.id");
  });

  /**
   * Flow resolves the anchor before inserting, so an exercise cannot be placed
   * after itself. Tracking effects as the patch is walked made this reachable
   * for the first time: the id the operation adds is in the working set by the
   * time a naive anchor check runs.
   */
  it("refuses an addExercise anchored on the exercise it is adding", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);
    const routine = fixtureContext.routines[0]!;
    const exerciseId = crypto.randomUUID();

    const checked = await validate(envelope.contextId, sectionPatch([
      {
        kind: "addExercise",
        sectionId: routine.sections[0]!.id,
        afterExerciseId: exerciseId,
        exercise: newExercise(exerciseId, "Face Pull"),
      },
    ]));

    expect(checked.status).toBe(422);
    expect((await json(checked)).problems.map((problem: any) => problem.path)).toContain("operations.0.afterExerciseId");
  });

  it("refuses a moveExercise anchored on the exercise being moved", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);
    const routine = fixtureContext.routines[0]!;
    const exercise = routine.sections[0]!.exercises[0]!;

    const checked = await validate(envelope.contextId, sectionPatch([
      {
        kind: "moveExercise",
        exerciseId: exercise.id,
        targetSectionId: routine.sections[1]!.id,
        afterExerciseId: exercise.id,
      },
    ]));

    expect(checked.status).toBe(422);
    expect((await json(checked)).problems.map((problem: any) => problem.path)).toContain("operations.0.afterExerciseId");
  });

  /**
   * Flow inserts at the anchor's index within the target section, so an anchor
   * living somewhere else has no position to be after.
   */
  it("refuses an anchor that sits in a different section from the target", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);
    const routine = fixtureContext.routines[0]!;
    const elsewhere = routine.sections[1]!.exercises[0]!;

    const added = await validate(envelope.contextId, sectionPatch([
      {
        kind: "addExercise",
        sectionId: routine.sections[0]!.id,
        afterExerciseId: elsewhere.id,
        exercise: newExercise(crypto.randomUUID(), "Face Pull"),
      },
    ]));
    expect(added.status).toBe(422);
    const problems = (await json(added)).problems;
    expect(problems.map((problem: any) => problem.path)).toContain("operations.0.afterExerciseId");
    expect(problems.map((problem: any) => problem.message)).toContain("anchor exercise must be in the target section");

    const moved = await validate(envelope.contextId, sectionPatch([
      {
        kind: "moveExercise",
        exerciseId: routine.sections[0]!.exercises[0]!.id,
        targetSectionId: routine.sections[0]!.id,
        afterExerciseId: elsewhere.id,
      },
    ]));
    expect(moved.status).toBe(422);
    expect((await json(moved)).problems.map((problem: any) => problem.path)).toContain("operations.0.afterExerciseId");
  });

  it("accepts an anchor added earlier in the same patch, in the same section", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);
    const sectionId = crypto.randomUUID();
    const first = crypto.randomUUID();

    const checked = await validate(envelope.contextId, sectionPatch([
      { kind: "addSection", section: { id: sectionId, name: "Core" } },
      { kind: "addExercise", sectionId, exercise: newExercise(first, "Plank") },
      { kind: "addExercise", sectionId, afterExerciseId: first, exercise: newExercise(crypto.randomUUID(), "Dead Bug") },
    ]));

    expect(checked.status).toBe(200);
    expect((await json(checked)).valid).toBe(true);
  });

  it("accepts an addSection anchored on a section created earlier in the same patch", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);
    const first = crypto.randomUUID();

    const checked = await validate(envelope.contextId, sectionPatch([
      { kind: "addSection", section: { id: first, name: "Core" } },
      { kind: "addSection", section: { id: crypto.randomUUID(), name: "Carries" }, afterSectionId: first },
    ]));

    expect(checked.status).toBe(200);
    expect((await json(checked)).valid).toBe(true);
  });

  /**
   * The docs promise that every operation sees what the ones before it did.
   * The routine name has to be part of that or the promise is false for
   * exactly one operation.
   */
  it("reads a second rename against the name the first one set", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);
    const routine = fixtureContext.routines[0]!;

    const chained = await validate(envelope.contextId, sectionPatch([
      { kind: "renameRoutine", expectedStringValue: routine.name, newStringValue: "Upper A" },
      { kind: "renameRoutine", expectedStringValue: "Upper A", newStringValue: "Upper A (heavy)" },
    ]));
    expect(chained.status).toBe(200);
    expect((await json(chained)).valid).toBe(true);

    const stale = await validate(envelope.contextId, sectionPatch([
      { kind: "renameRoutine", expectedStringValue: routine.name, newStringValue: "Upper A" },
      { kind: "renameRoutine", expectedStringValue: routine.name, newStringValue: "Upper A (heavy)" },
    ]));
    expect(stale.status).toBe(422);
    expect((await json(stale)).problems.map((problem: any) => problem.path)).toContain("operations.1.expectedStringValue");
  });

  it("refuses a patch that would push a routine past the section ceiling", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);
    const existing = fixtureContext.routines[0]!.sections.length;

    const upToTheLimit = await validate(envelope.contextId, sectionPatch(
      Array.from({ length: MAX_SECTIONS - existing }, (_, index) => ({
        kind: "addSection",
        section: { id: crypto.randomUUID(), name: `Section ${index}` },
      })),
    ));
    expect(upToTheLimit.status).toBe(200);
    expect((await json(upToTheLimit)).valid).toBe(true);

    const oneTooMany = await validate(envelope.contextId, sectionPatch(
      Array.from({ length: MAX_SECTIONS - existing + 1 }, (_, index) => ({
        kind: "addSection",
        section: { id: crypto.randomUUID(), name: `Section ${index}` },
      })),
    ));
    expect(oneTooMany.status).toBe(422);
    expect((await json(oneTooMany)).problems.map((problem: any) => problem.message))
      .toContain(`a routine may not have more than ${MAX_SECTIONS} sections`);
  });

  /**
   * The same invariant as the section cap: a section past this stops fitting
   * in a snapshot, so the routine would drop out of the coach's view at the
   * next sync rather than fail anywhere visible.
   */
  it("refuses a patch that would push a section past the exercise ceiling", async () => {
    // A patch carries at most 50 operations, so the ceiling is only reachable
    // against a section already near it, which is exactly how it would be
    // reached in practice: one patch at a time, over several conversations.
    const envelope = capableSnapshot();
    const sectionId = crypto.randomUUID();
    const full = {
      ...fixtureContext.routines[0]!,
      id: crypto.randomUUID(),
      name: "Everything",
      sections: [{
        id: sectionId,
        name: "Main",
        exercises: Array.from({ length: MAX_EXERCISES_PER_SECTION }, (_, index) =>
          newExercise(crypto.randomUUID(), `Exercise ${index}`)),
      }],
    };
    envelope.context = {
      ...fixtureContext,
      routines: [full],
      currentPhaseByRoutineId: { [full.id]: "base" },
      routineContentHashByRoutineId: { [full.id]: "c1-0011223344556677" },
      routineStateHashByRoutineId: { [full.id]: "s1-0011223344556677" },
    } as unknown as typeof fixtureContext;
    expect((await upload(envelope)).status).toBe(201);

    const checked = await validate(envelope.contextId, {
      schemaVersion: 3,
      routineId: full.id,
      baseContentHash: "c1-0011223344556677",
      rationale: "One more than will fit.",
      operations: [{ kind: "addExercise", sectionId, exercise: newExercise(crypto.randomUUID(), "One too many") }],
    });

    expect(checked.status).toBe(422);
    expect((await json(checked)).problems.map((problem: any) => problem.message))
      .toContain(`a section may not hold more than ${MAX_EXERCISES_PER_SECTION} exercises`);
  });

  /**
   * A move takes the exercise out before putting it back, so a full section
   * can always still be reordered, while moving one *into* a full section is
   * refused. Flow does exactly this, and the two cases sit either side of the
   * same line.
   */
  it("allows a move within a full section but not into one", async () => {
    const envelope = capableSnapshot();
    const fullId = crypto.randomUUID();
    const spareId = crypto.randomUUID();
    const movingId = crypto.randomUUID();
    const full = {
      ...fixtureContext.routines[0]!,
      id: crypto.randomUUID(),
      name: "Everything",
      sections: [
        {
          id: fullId,
          name: "Full",
          exercises: Array.from({ length: MAX_EXERCISES_PER_SECTION }, (_, index) =>
            newExercise(crypto.randomUUID(), `Exercise ${index}`)),
        },
        { id: spareId, name: "Spare", exercises: [newExercise(movingId, "Movable")] },
      ],
    };
    envelope.context = {
      ...fixtureContext,
      routines: [full],
      currentPhaseByRoutineId: { [full.id]: "base" },
      routineContentHashByRoutineId: { [full.id]: "c1-0011223344556677" },
      routineStateHashByRoutineId: { [full.id]: "s1-0011223344556677" },
    } as unknown as typeof fixtureContext;
    expect((await upload(envelope)).status).toBe(201);

    const patchWith = (operations: unknown[]) => ({
      schemaVersion: 3,
      routineId: full.id,
      baseContentHash: "c1-0011223344556677",
      rationale: "Reorder around a full section.",
      operations,
    });

    const within = await validate(envelope.contextId, patchWith([
      { kind: "moveExercise", exerciseId: full.sections[0]!.exercises[0]!.id, targetSectionId: fullId },
    ]));
    expect(within.status).toBe(200);
    expect((await json(within)).valid).toBe(true);

    const into = await validate(envelope.contextId, patchWith([
      { kind: "moveExercise", exerciseId: movingId, targetSectionId: fullId },
    ]));
    expect(into.status).toBe(422);
    expect((await json(into)).problems.map((problem: any) => problem.message))
      .toContain(`a section may not hold more than ${MAX_EXERCISES_PER_SECTION} exercises`);
  });

  it("does not refuse a patch against a routine that was already empty", async () => {
    const envelope = capableSnapshot();
    const empty = { ...fixtureContext.routines[0]!, id: crypto.randomUUID(), name: "Empty Draft", sections: [] };
    envelope.context = {
      ...fixtureContext,
      routines: [...fixtureContext.routines, empty],
      currentPhaseByRoutineId: { ...fixtureContext.currentPhaseByRoutineId, [empty.id]: "base" },
      routineContentHashByRoutineId: { ...fixtureContext.routineContentHashByRoutineId, [empty.id]: "c1-0011223344556677" },
      routineStateHashByRoutineId: { ...fixtureContext.routineStateHashByRoutineId, [empty.id]: "s1-0011223344556677" },
    } as typeof fixtureContext;
    expect((await upload(envelope)).status).toBe(201);

    const checked = await validate(envelope.contextId, {
      schemaVersion: 3,
      routineId: empty.id,
      baseContentHash: "c1-0011223344556677",
      rationale: "Name the draft before filling it.",
      operations: [{ kind: "renameRoutine", expectedStringValue: "Empty Draft", newStringValue: "Lower A" }],
    });

    expect(checked.status).toBe(200);
    expect((await json(checked)).valid).toBe(true);
  });

  /**
   * The app refuses this and the bridge used not to, so a coach could store a
   * draft that could never be applied.
   */
  it("refuses a patch that would leave the routine with no exercises", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);
    const routine = fixtureContext.routines[0]!;
    const everyExercise = routine.sections.flatMap((section) => section.exercises);

    const checked = await validate(envelope.contextId, sectionPatch(
      everyExercise.map((exercise) => ({
        kind: "removeExercise",
        exerciseId: exercise.id,
        expectedStringValue: exercise.name,
      })),
    ));

    expect(checked.status).toBe(422);
    const problems = (await json(checked)).problems;
    expect(problems.map((problem: any) => problem.message)).toContain("patch would leave the routine with no exercises");
  });

  it("allows a patch that empties a section and refills it", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);
    const routine = fixtureContext.routines[0]!;
    const everyExercise = routine.sections.flatMap((section) => section.exercises);

    const checked = await validate(envelope.contextId, sectionPatch([
      ...everyExercise.map((exercise) => ({
        kind: "removeExercise",
        exerciseId: exercise.id,
        expectedStringValue: exercise.name,
      })),
      { kind: "addExercise", sectionId: routine.sections[0]!.id, exercise: newExercise(crypto.randomUUID(), "Trap Bar Deadlift") },
    ]));

    expect(checked.status).toBe(200);
    expect((await json(checked)).valid).toBe(true);
  });

  function createPatch(overrides: Record<string, unknown> = {}, routineOverrides: Record<string, unknown> = {}) {
    const sectionId = crypto.randomUUID();
    return {
      schemaVersion: 3,
      target: "newRoutine",
      rationale: "The split needs a lower day that does not exist yet.",
      operations: [{
        kind: "createRoutine",
        routine: {
          id: crypto.randomUUID(),
          name: "Lower A",
          currentPhase: "deload",
          sections: [{
            id: sectionId,
            name: "Main Lifts",
            exercises: [newExercise(crypto.randomUUID(), "Trap Bar Deadlift")],
          }],
          ...routineOverrides,
        },
      }],
      ...overrides,
    };
  }

  it("validates and stores a create, and pulls it with no anchor", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);
    const patch = createPatch();

    const checked = await validate(envelope.contextId, patch);
    expect(checked.status).toBe(200);
    expect((await json(checked)).valid).toBe(true);

    const stored = await SELF.fetch("https://flow.test/actions/pending-patches", {
      method: "POST",
      headers: auth(ACTIONS_SECRET),
      body: JSON.stringify({ contextId: envelope.contextId, patch }),
    });
    expect(stored.status).toBe(201);
    // The stored row has no routine to point at and no content to hash, which
    // is what the table migration exists to allow.
    expect((await json(stored)).patch.routineId).toBeNull();
    expect((await json(await SELF.fetch("https://flow.test/device/pending-patches", { headers: auth(DEVICE_SECRET) })))
      .patches[0].patch.target).toBe("newRoutine");
  });

  it("reuses the stored draft when a create is retried with the same key", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);
    const body = JSON.stringify({ contextId: envelope.contextId, patch: createPatch() });
    const headers = { ...auth(ACTIONS_SECRET), "idempotency-key": "create-lower-a" };

    const first = await SELF.fetch("https://flow.test/actions/pending-patches", { method: "POST", headers, body });
    expect(first.status).toBe(201);
    const retry = await SELF.fetch("https://flow.test/actions/pending-patches", { method: "POST", headers, body });
    expect(retry.status).toBe(200);
    const retried = await json(retry);
    expect(retried.duplicate).toBe(true);
    expect(retried.patch.patchId).toBe((await json(first)).patch.patchId);

    const pulled = await json(await SELF.fetch("https://flow.test/device/pending-patches", { headers: auth(DEVICE_SECRET) }));
    expect(pulled.patches).toHaveLength(1);
  });

  /**
   * The two collisions need different advice. "This id is taken" invites
   * regenerating ids and re-proposing, which for a draft that already landed
   * manufactures a duplicate routine the app would happily accept, since
   * every id in it is genuinely fresh.
   */
  it("tells a landed retry apart from a genuine id collision", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);
    const landed = fixtureContext.routines[0]!;

    // The routine already in the snapshot, proposed again unchanged.
    const retry = await validate(envelope.contextId, createPatch({}, {
      id: landed.id,
      name: landed.name,
      currentPhase: fixtureContext.currentPhaseByRoutineId[landed.id as keyof typeof fixtureContext.currentPhaseByRoutineId],
      sections: landed.sections,
    }));
    expect(retry.status).toBe(422);
    expect((await json(retry)).problems[0].message).toContain("do not propose it again");

    // A different routine wearing the same id.
    const collision = await validate(envelope.contextId, createPatch({}, { id: landed.id }));
    expect(collision.status).toBe(422);
    const problems = (await json(collision)).problems;
    expect(problems[0].path).toBe("operations.0.routine.id");
    expect(problems[0].message).toContain("generate a fresh routine id");
  });

  it("still calls a retry a retry when the draft carries an empty phase override", async () => {
    // The landed routine has no deload override on its first exercise and the
    // redraft carries an empty one, which Flow drops before storing. So this
    // is the same routine arriving twice rather than a revision of it. Built
    // on a clone, because every exercise in the fixture carries both phases.
    const context = structuredClone(fixtureContext);
    const landed = context.routines[0]!;
    delete (landed.sections[0]!.exercises[0]!.phaseOverrides as { deload?: unknown }).deload;
    const envelope = { ...capableSnapshot(), context };
    expect((await upload(envelope)).status).toBe(201);

    const retry = await validate(envelope.contextId, createPatch({}, {
      id: landed.id,
      name: `  ${landed.name}  `,
      currentPhase: fixtureContext.currentPhaseByRoutineId[landed.id as keyof typeof fixtureContext.currentPhaseByRoutineId],
      sections: landed.sections.map((section, index) => index > 0 ? section : {
        ...section,
        exercises: section.exercises.map((exercise, position) => position > 0 ? exercise : {
          ...exercise,
          phaseOverrides: { ...exercise.phaseOverrides, deload: {} },
        }),
      }),
    }));

    expect(retry.status).toBe(422);
    expect((await json(retry)).problems[0].message).toContain("do not propose it again");
  });

  it("refuses a create that carries an anchor it cannot have", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);
    const routine = fixtureContext.routines[0]!;

    for (const [field, value] of [["routineId", routine.id], ["baseContentHash", "c1-0011223344556677"]] as const) {
      const checked = await validate(envelope.contextId, createPatch({ [field]: value }));
      expect(checked.status).toBe(422);
      expect((await json(checked)).problems.map((problem: any) => problem.path)).toContain(field);
    }
  });

  it("refuses a create bundled with any other operation", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);
    const patch = createPatch();

    const checked = await validate(envelope.contextId, {
      ...patch,
      operations: [
        ...patch.operations,
        { kind: "addSection", section: { id: crypto.randomUUID(), name: "Core" } },
      ],
    });

    expect(checked.status).toBe(422);
    expect((await json(checked)).problems[0].path).toBe("operations");
  });

  it("refuses a createRoutine smuggled into an existingRoutine patch", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);
    const routine = fixtureContext.routines[0]!;

    const checked = await validate(envelope.contextId, {
      ...sectionPatch([createPatch().operations[0]]),
      target: "existingRoutine",
      routineId: routine.id,
    });

    expect(checked.status).toBe(422);
    expect((await json(checked)).problems[0].path).toBe("target");
  });

  it("refuses a created routine with no exercises anywhere", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);

    const checked = await validate(envelope.contextId, createPatch({}, {
      sections: [{ id: crypto.randomUUID(), name: "Empty", exercises: [] }],
    }));

    expect(checked.status).toBe(422);
    expect((await json(checked)).problems.map((problem: any) => problem.message))
      .toContain("a routine needs at least one exercise");
  });

  /**
   * Whole-routine import has always reassigned ids on the way in, so globally
   * fresh ids are what the rest of the app assumes. History reads more simply
   * when an id means one exercise.
   */
  it("refuses a created routine that reuses an exercise id from elsewhere", async () => {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);
    const borrowed = fixtureContext.routines[0]!.sections[0]!.exercises[0]!.id;

    const checked = await validate(envelope.contextId, createPatch({}, {
      sections: [{
        id: crypto.randomUUID(),
        name: "Main",
        exercises: [newExercise(borrowed, "Borrowed")],
      }],
    }));

    expect(checked.status).toBe(422);
    expect((await json(checked)).problems.map((problem: any) => problem.message))
      .toContain("exercise id already exists in another routine");
  });

  /**
   * The worst of the three ceilings to cross: past this the next snapshot
   * upload fails whole, so the coach stops seeing anything at all rather than
   * losing one routine.
   */
  it("refuses a create once the snapshot already carries as many routines as it can", async () => {
    const envelope = capableSnapshot();
    const filler = Array.from({ length: MAX_ROUTINES }, (_, index) => ({
      id: crypto.randomUUID(),
      name: `Routine ${index}`,
      currentPhase: "base",
      sections: [{
        id: crypto.randomUUID(),
        name: "Main",
        exercises: [newExercise(crypto.randomUUID(), "Press")],
      }],
    }));
    envelope.context = {
      ...fixtureContext,
      routines: filler,
      currentPhaseByRoutineId: Object.fromEntries(filler.map((routine) => [routine.id, "base"])),
      routineContentHashByRoutineId: Object.fromEntries(filler.map((routine) => [routine.id, "c1-0011223344556677"])),
      routineStateHashByRoutineId: Object.fromEntries(filler.map((routine) => [routine.id, "s1-0011223344556677"])),
    } as unknown as typeof fixtureContext;
    expect((await upload(envelope)).status).toBe(201);

    const full = await validate(envelope.contextId, createPatch());
    expect(full.status).toBe(422);
    expect((await json(full)).problems[0].message).toContain(`at most ${MAX_ROUTINES} routines`);

    // One fewer, and the same create is fine, so the ceiling is the reason.
    const roomForOne = { ...envelope, contextId: crypto.randomUUID() };
    roomForOne.context = { ...envelope.context, routines: filler.slice(0, -1) } as typeof envelope.context;
    expect((await upload(roomForOne)).status).toBe(201);
    const fits = await validate(roomForOne.contextId, createPatch());
    expect(fits.status).toBe(200);
    expect((await json(fits)).valid).toBe(true);
  });

  it("refuses a create when the device does not report support for it", async () => {
    const envelope = capableSnapshot(OPERATION_KINDS.filter((kind) => kind !== "createRoutine"));
    expect((await upload(envelope)).status).toBe(201);

    const checked = await validate(envelope.contextId, createPatch());

    expect(checked.status).toBe(422);
    expect((await json(checked)).problems[0].message).toContain("createRoutine");
  });

  /**
   * The one path that runs against Durable Objects that already exist.
   * `createSchema` is CREATE TABLE IF NOT EXISTS, so an object created before
   * this column existed keeps its old shape forever unless the ALTER runs;
   * every other test starts from a fresh object where the column is already
   * there and the migration is a no-op.
   */
  it("adds the capabilities column to a Durable Object created without it", async () => {
    const id = env.FLOW_COACH.idFromName(`flow-coach:migration-${crypto.randomUUID()}`);
    const stub = env.FLOW_COACH.get(id);

    await runInDurableObject(stub, async (instance: any, state: DurableObjectState) => {
      const columnNames = () => state.storage.sql
        .exec<{ name: string }>("PRAGMA table_info(snapshots)").toArray().map((row) => row.name);

      // Wind the object back to the pre-capabilities shape.
      state.storage.sql.exec("ALTER TABLE snapshots DROP COLUMN device_capabilities_json");
      expect(columnNames()).not.toContain("device_capabilities_json");

      instance.migrateSchema();
      expect(columnNames()).toContain("device_capabilities_json");

      // Idempotent: it runs on every construction, including ones where the
      // column is already present.
      instance.migrateSchema();
      expect(columnNames().filter((name) => name === "device_capabilities_json")).toHaveLength(1);
    });
  });

  /**
   * A create anchors to nothing, so the patches table has to accept null
   * where it used to demand a routine id and a content hash. SQLite cannot
   * relax a constraint with ALTER, so this is a table rebuild, and it has to
   * carry existing pending drafts across rather than dropping them.
   */
  it("relaxes the patch anchor columns on a Durable Object created with them NOT NULL", async () => {
    const id = env.FLOW_COACH.idFromName(`flow-coach:anchor-${crypto.randomUUID()}`);
    const stub = env.FLOW_COACH.get(id);

    await runInDurableObject(stub, async (instance: any, state: DurableObjectState) => {
      const anchorColumns = () => state.storage.sql
        .exec<{ name: string; notnull: number }>("PRAGMA table_info(patches)")
        .toArray()
        .filter((column) => column.name === "routine_id" || column.name === "base_hash");

      // Rebuild the pre-create shape, with a pending draft already in it.
      state.storage.sql.exec("DROP TABLE patches");
      state.storage.sql.exec(`
        CREATE TABLE patches (
          seq INTEGER PRIMARY KEY AUTOINCREMENT,
          patch_id TEXT NOT NULL UNIQUE, context_id TEXT NOT NULL,
          routine_id TEXT NOT NULL, base_hash TEXT NOT NULL,
          created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, status TEXT NOT NULL,
          provenance TEXT NOT NULL, principal_id TEXT NOT NULL, rationale TEXT, patch_json TEXT,
          pulled_at INTEGER, terminal_at INTEGER, tombstone_expires_at INTEGER,
          idempotency_digest TEXT UNIQUE, proposal_digest TEXT NOT NULL UNIQUE, payload_digest TEXT NOT NULL
        )`);
      state.storage.sql.exec(
        `INSERT INTO patches(patch_id, context_id, routine_id, base_hash, created_at, expires_at, status,
          provenance, principal_id, rationale, patch_json, proposal_digest, payload_digest)
         VALUES ('patch-1', 'ctx-1', 'routine-1', 'c1-0011223344556677', 1, 2, 'pending', 'claude-mcp', 'p', 'why', '{}', 'd1', 'd2')`,
      );
      expect(anchorColumns().every((column) => column.notnull === 1)).toBe(true);

      instance.migrateSchema();

      expect(anchorColumns().every((column) => column.notnull === 0)).toBe(true);
      const carried = state.storage.sql.exec<{ patch_id: string; rationale: string }>("SELECT * FROM patches").toArray();
      expect(carried).toHaveLength(1);
      expect(carried[0]!.patch_id).toBe("patch-1");
      expect(carried[0]!.rationale).toBe("why");

      // A create can now be stored, which is the point of the whole rebuild.
      state.storage.sql.exec(
        `INSERT INTO patches(patch_id, context_id, routine_id, base_hash, created_at, expires_at, status,
          provenance, principal_id, rationale, patch_json, proposal_digest, payload_digest)
         VALUES ('patch-2', 'ctx-1', NULL, NULL, 1, 2, 'pending', 'claude-mcp', 'p', 'why', '{}', 'd3', 'd4')`,
      );
      expect(state.storage.sql.exec("SELECT COUNT(*) AS n FROM patches").one().n).toBe(2);

      // Idempotent.
      instance.migrateSchema();
      expect(state.storage.sql.exec("SELECT COUNT(*) AS n FROM patches").one().n).toBe(2);
    });
  });

  /**
   * Pull cursors are ordered by seq, so a rebuild that reset the counter to
   * the highest surviving row could hand out a seq it had already issued to a
   * patch that has since expired.
   */
  it("carries the patch sequence counter across the rebuild", async () => {
    const id = env.FLOW_COACH.idFromName(`flow-coach:sequence-${crypto.randomUUID()}`);
    const stub = env.FLOW_COACH.get(id);

    await runInDurableObject(stub, async (instance: any, state: DurableObjectState) => {
      state.storage.sql.exec("DROP TABLE patches");
      state.storage.sql.exec(`
        CREATE TABLE patches (
          seq INTEGER PRIMARY KEY AUTOINCREMENT,
          patch_id TEXT NOT NULL UNIQUE, context_id TEXT NOT NULL,
          routine_id TEXT NOT NULL, base_hash TEXT NOT NULL,
          created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, status TEXT NOT NULL,
          provenance TEXT NOT NULL, principal_id TEXT NOT NULL, rationale TEXT, patch_json TEXT,
          pulled_at INTEGER, terminal_at INTEGER, tombstone_expires_at INTEGER,
          idempotency_digest TEXT UNIQUE, proposal_digest TEXT NOT NULL UNIQUE, payload_digest TEXT NOT NULL
        )`);
      const insert = (patchId: string, digest: string) => state.storage.sql.exec(
        `INSERT INTO patches(patch_id, context_id, routine_id, base_hash, created_at, expires_at, status,
          provenance, principal_id, rationale, patch_json, proposal_digest, payload_digest)
         VALUES (?, 'ctx-1', 'routine-1', 'c1-0011223344556677', 1, 2, 'pending', 'claude-mcp', 'p', 'why', '{}', ?, 'pd')`,
        patchId, digest,
      );
      insert("patch-1", "d1");
      insert("patch-2", "d2");
      insert("patch-3", "d3");
      // Everything but the first has since gone terminal and been swept, so
      // the surviving row's seq is well below the highest ever issued.
      state.storage.sql.exec("DELETE FROM patches WHERE seq > 1");
      const issued = state.storage.sql.exec<{ seq: number }>("SELECT seq FROM sqlite_sequence WHERE name = 'patches'").one().seq;
      expect(issued).toBe(3);

      instance.migrateSchema();

      insert("patch-4", "d4");
      const next = state.storage.sql.exec<{ seq: number }>("SELECT seq FROM patches WHERE patch_id = 'patch-4'").one().seq;
      expect(next).toBeGreaterThan(issued);
    });
  });
});

/**
 * Flow refuses a patch whose expected value does not match what the routine
 * actually holds, as `beforeValueMismatch`. The bridge used to check only that
 * an expected value was present, so a coach that misread the routine got a
 * draft stored and delivered, and found out on the phone. These pin the two
 * sides together.
 */
describe("Flow Coach bridge expected values", () => {
  beforeEach(clearMailbox);

  const routine = fixtureContext.routines[0]!;
  const baseContentHash = fixtureContext.routineContentHashByRoutineId[routine.id as keyof typeof fixtureContext.routineContentHashByRoutineId];
  const pressed = routine.sections[0]!.exercises[0]!;
  const plank = routine.sections[2]!.exercises[0]!;

  function capableSnapshot() {
    return { ...snapshot(), deviceCapabilities: { patchSchemaVersions: [2, 3], operationKinds: [...OPERATION_KINDS] } };
  }

  function patch(operations: Record<string, unknown>[]) {
    return {
      schemaVersion: 3,
      routineId: routine.id,
      baseContentHash,
      rationale: "Check the expected value against the routine.",
      operations,
    };
  }

  async function validate(contextId: string, body: unknown): Promise<Response> {
    return SELF.fetch("https://flow.test/actions/patches/validate", {
      method: "POST",
      headers: auth(ACTIONS_SECRET),
      body: JSON.stringify({ contextId, patch: body }),
    });
  }

  async function paired(): Promise<string> {
    const envelope = capableSnapshot();
    expect((await upload(envelope)).status).toBe(201);
    return envelope.contextId;
  }

  async function problems(contextId: string, body: unknown): Promise<{ path: string; message: string }[]> {
    const response = await validate(contextId, body);
    expect(response.status).toBe(422);
    return (await json(response)).problems;
  }

  async function expectValid(contextId: string, body: unknown): Promise<void> {
    const response = await validate(contextId, body);
    expect(await json(response)).toMatchObject({ valid: true, problems: [] });
    expect(response.status).toBe(200);
  }

  it("refuses each numeric replace whose expected value is not the current one", async () => {
    const contextId = await paired();

    const cases = [
      { kind: "replaceExerciseSets", exerciseId: pressed.id, actual: pressed.sets, newIntValue: 5 },
      { kind: "replaceExerciseReps", exerciseId: pressed.id, actual: pressed.reps, newIntValue: 12 },
      { kind: "replaceRestBetweenSets", exerciseId: pressed.id, actual: pressed.restBetweenSetsSeconds, newIntValue: 60 },
      { kind: "replaceRestAfterExercise", exerciseId: pressed.id, actual: pressed.restAfterExerciseSeconds, newIntValue: 60 },
      { kind: "replaceTimedDuration", exerciseId: plank.id, actual: plank.durationSeconds, newIntValue: 45 },
    ];

    for (const { kind, exerciseId, actual, newIntValue } of cases) {
      const stale = await problems(contextId, patch([{ kind, exerciseId, expectedIntValue: actual! + 1, newIntValue }]));
      expect(stale[0]!.path).toBe("operations.0.expectedIntValue");
      expect(stale[0]!.message).toContain(`${actual}`);

      await expectValid(contextId, patch([{ kind, exerciseId, expectedIntValue: actual, newIntValue }]));
    }
  });

  /**
   * The case most likely to be got wrong, and the reason the working copy has
   * to be written to rather than only read: Flow applies operations one after
   * another, so the second one sees the first one's result.
   */
  it("reads a second operation on the same field against the first one's result", async () => {
    const contextId = await paired();

    await expectValid(contextId, patch([
      { kind: "replaceExerciseSets", exerciseId: pressed.id, expectedIntValue: pressed.sets, newIntValue: 5 },
      { kind: "replaceExerciseSets", exerciseId: pressed.id, expectedIntValue: 5, newIntValue: 6 },
    ]));

    const stale = await problems(contextId, patch([
      { kind: "replaceExerciseSets", exerciseId: pressed.id, expectedIntValue: pressed.sets, newIntValue: 5 },
      { kind: "replaceExerciseSets", exerciseId: pressed.id, expectedIntValue: pressed.sets, newIntValue: 6 },
    ]));
    expect(stale[0]!.path).toBe("operations.1.expectedIntValue");
    expect(stale[0]!.message).toContain("5");
  });

  it("reads an expectation against an exercise the same patch added", async () => {
    const contextId = await paired();
    const added = {
      id: crypto.randomUUID(),
      name: "Band pull-apart",
      sets: 3,
      reps: 15,
      restBetweenSetsSeconds: 45,
      restAfterExerciseSeconds: 60,
      notes: "",
      perSide: false,
      phaseOverrides: {},
    };
    const add = { kind: "addExercise", sectionId: routine.sections[1]!.id, exercise: added };

    await expectValid(contextId, patch([
      add,
      { kind: "replaceExerciseSets", exerciseId: added.id, expectedIntValue: 3, newIntValue: 4 },
    ]));

    const stale = await problems(contextId, patch([
      add,
      { kind: "replaceExerciseSets", exerciseId: added.id, expectedIntValue: 2, newIntValue: 4 },
    ]));
    expect(stale[0]!.path).toBe("operations.1.expectedIntValue");
  });

  it("checks the expected notes, and chains them", async () => {
    const contextId = await paired();

    const stale = await problems(contextId, patch([
      { kind: "updateExerciseNotes", exerciseId: pressed.id, expectedStringValue: "Something else", newStringValue: "Slow lower." },
    ]));
    expect(stale[0]!.path).toBe("operations.0.expectedStringValue");
    expect(stale[0]!.message).toContain(pressed.notes);

    await expectValid(contextId, patch([
      { kind: "updateExerciseNotes", exerciseId: pressed.id, expectedStringValue: pressed.notes, newStringValue: "" },
      { kind: "updateExerciseNotes", exerciseId: pressed.id, expectedStringValue: "", newStringValue: "Slow lower." },
    ]));

    const emptied = await problems(contextId, patch([
      { kind: "updateExerciseNotes", exerciseId: pressed.id, expectedStringValue: pressed.notes, newStringValue: "" },
      { kind: "updateExerciseNotes", exerciseId: pressed.id, expectedStringValue: pressed.notes, newStringValue: "Slow lower." },
    ]));
    expect(emptied[0]!.path).toBe("operations.1.expectedStringValue");
    expect(emptied[0]!.message).toContain("[no notes]");
  });

  it("checks the expected exercise name on a removal", async () => {
    const contextId = await paired();

    const wrong = await problems(contextId, patch([
      { kind: "removeExercise", exerciseId: pressed.id, expectedStringValue: "Bench press" },
    ]));
    expect(wrong[0]!.path).toBe("operations.0.expectedStringValue");
    expect(wrong[0]!.message).toContain(pressed.name);

    await expectValid(contextId, patch([
      { kind: "removeExercise", exerciseId: pressed.id, expectedStringValue: pressed.name },
    ]));
  });

  it("compares the expected phase override as a value, and chains it", async () => {
    const contextId = await paired();
    const current = pressed.phaseOverrides.peak;

    const wrong = await problems(contextId, patch([{
      kind: "replacePhaseOverride",
      exerciseId: pressed.id,
      phase: "peak",
      expectedPhaseOverride: { sets: current.sets + 1, reps: current.reps },
      newPhaseOverride: { sets: 5, reps: 10 },
    }]));
    expect(wrong[0]!.path).toBe("operations.0.expectedPhaseOverride");
    expect(wrong[0]!.message).toContain(`${current.sets} sets`);

    await expectValid(contextId, patch([{
      kind: "replacePhaseOverride",
      exerciseId: pressed.id,
      phase: "peak",
      expectedPhaseOverride: current,
      newPhaseOverride: { sets: 5, reps: 10 },
    }]));

    // Removed, then expected to be gone: Flow drops the override, so the
    // second operation has to see nothing there.
    await expectValid(contextId, patch([
      { kind: "replacePhaseOverride", exerciseId: pressed.id, phase: "peak", expectedPhaseOverride: current, removePhaseOverride: true },
      { kind: "replacePhaseOverride", exerciseId: pressed.id, phase: "peak", newPhaseOverride: { sets: 5 } },
    ]));

    const stillThere = await problems(contextId, patch([
      { kind: "replacePhaseOverride", exerciseId: pressed.id, phase: "peak", expectedPhaseOverride: current, removePhaseOverride: true },
      { kind: "replacePhaseOverride", exerciseId: pressed.id, phase: "peak", expectedPhaseOverride: current, newPhaseOverride: { sets: 5 } },
    ]));
    expect(stillThere[0]!.path).toBe("operations.1.expectedPhaseOverride");
    expect(stillThere[0]!.message).toContain("no override");
  });

  /**
   * Swift compares `Optional<PhaseOverride>`, where "no override" and "an
   * override with nothing set" are different values. Collapsing them here
   * would accept an expectation the phone then refuses.
   */
  it("keeps an absent override distinct from an empty one", async () => {
    const contextId = await paired();
    const bare = {
      id: crypto.randomUUID(),
      name: "Band pull-apart",
      sets: 3,
      reps: 15,
      restBetweenSetsSeconds: 45,
      restAfterExerciseSeconds: 60,
      notes: "",
      perSide: false,
      phaseOverrides: {},
    };
    const add = { kind: "addExercise", sectionId: routine.sections[1]!.id, exercise: bare };

    await expectValid(contextId, patch([
      add,
      { kind: "replacePhaseOverride", exerciseId: bare.id, phase: "deload", newPhaseOverride: { sets: 2 } },
    ]));

    const empty = await problems(contextId, patch([
      add,
      { kind: "replacePhaseOverride", exerciseId: bare.id, phase: "deload", expectedPhaseOverride: {}, newPhaseOverride: { sets: 2 } },
    ]));
    expect(empty[0]!.path).toBe("operations.1.expectedPhaseOverride");
  });

  /**
   * `addExercise` in Flow drops empty overrides before inserting, and Flow's
   * decoder drops any key that is not a phase it knows. An added exercise has
   * to enter the working copy the same way, or a later operation reads an
   * override the phone has already thrown away.
   */
  it("normalises an added exercise's overrides the way Flow stores them", async () => {
    const contextId = await paired();
    const added = {
      id: crypto.randomUUID(),
      name: "Band pull-apart",
      sets: 3,
      reps: 15,
      restBetweenSetsSeconds: 45,
      restAfterExerciseSeconds: 60,
      notes: "",
      perSide: false,
      phaseOverrides: { deload: {}, warmup: { sets: 2 }, peak: { sets: 4 } },
    };
    const add = { kind: "addExercise", sectionId: routine.sections[1]!.id, exercise: added };

    // The empty deload override and the unknown phase both go, so both read
    // as absent. The real peak override stays.
    await expectValid(contextId, patch([
      add,
      { kind: "replacePhaseOverride", exerciseId: added.id, phase: "deload", newPhaseOverride: { sets: 2 } },
      { kind: "replacePhaseOverride", exerciseId: added.id, phase: "peak", expectedPhaseOverride: { sets: 4 }, newPhaseOverride: { sets: 5 } },
    ]));

    const expectingEmpty = await problems(contextId, patch([
      add,
      { kind: "replacePhaseOverride", exerciseId: added.id, phase: "deload", expectedPhaseOverride: {}, newPhaseOverride: { sets: 2 } },
    ]));
    expect(expectingEmpty[0]!.path).toBe("operations.1.expectedPhaseOverride");
  });

  it("does not call an exercise untimed when it is simply not there", async () => {
    const contextId = await paired();

    const missing = await problems(contextId, patch([
      { kind: "replaceTimedDuration", exerciseId: crypto.randomUUID(), expectedIntValue: 30, newIntValue: 45 },
    ]));
    expect(missing).toHaveLength(1);
    expect(missing[0]!.path).toBe("operations.0.exerciseId");
  });

  /**
   * Validation walks a working copy of the routine. If that copy shared its
   * exercises with the snapshot it was built from, a rejected patch would
   * leave its half-applied values in the context the caller passed in.
   */
  it("leaves the context it was given untouched", () => {
    const context = coachContextSchema.parse(structuredClone(fixtureContext));
    const before = JSON.stringify(context);

    const result = validatePatch(
      patch([
        { kind: "replaceExerciseSets", exerciseId: pressed.id, expectedIntValue: pressed.sets, newIntValue: 6 },
        { kind: "updateExerciseNotes", exerciseId: pressed.id, expectedStringValue: pressed.notes, newStringValue: "Changed." },
        { kind: "replacePhaseOverride", exerciseId: pressed.id, phase: "peak", expectedPhaseOverride: pressed.phaseOverrides.peak, removePhaseOverride: true },
        { kind: "removeExercise", exerciseId: plank.id, expectedStringValue: "Wrong name" },
      ]),
      context,
      effectiveCapabilities({ patchSchemaVersions: [2, 3], operationKinds: [...OPERATION_KINDS] }),
    );

    expect(result.valid).toBe(false);
    expect(JSON.stringify(context)).toBe(before);
  });
});
