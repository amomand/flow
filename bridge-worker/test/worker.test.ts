import { beforeEach, describe, expect, it } from "vitest";
import { SELF } from "cloudflare:test";
import fixtureContext from "../../bridge-prototype/fixtures/coach-context.json";

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
