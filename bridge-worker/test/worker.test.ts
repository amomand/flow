import { beforeEach, describe, expect, it } from "vitest";
import { env, runInDurableObject, SELF } from "cloudflare:test";
import fixtureContext from "../../bridge-prototype/fixtures/coach-context.json";
import { OPERATION_KINDS } from "../src/schemas";

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
    const envelope = snapshot();
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
});
