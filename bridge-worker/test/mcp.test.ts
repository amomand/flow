import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { SELF } from "cloudflare:test";
import fixtureContext from "../../bridge-prototype/fixtures/coach-context.json";
import { obtainTokens } from "./oauth-helper";

const ACTIONS_SECRET = "fixture-actions-secret";
const DEVICE_SECRET = "fixture-device-secret";
const MCP_URL = "https://flow.test/mcp";

// One OAuth grant for the whole file: clearing the mailbox between tests
// wipes the Durable Object, not the provider's token storage.
let accessToken = "";

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
    rationale: "Exercise the MCP proposal path.",
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

function mcpHeaders(): HeadersInit {
  return { authorization: `Bearer ${accessToken}`, "content-type": "application/json" };
}

async function rpc(method: string, params?: unknown, id: number | string = 1): Promise<Response> {
  return SELF.fetch(MCP_URL, {
    method: "POST",
    headers: mcpHeaders(),
    body: JSON.stringify({ jsonrpc: "2.0", id, method, params }),
  });
}

async function callTool(name: string, args: Record<string, unknown> = {}): Promise<Record<string, any>> {
  const response = await rpc("tools/call", { name, arguments: args });
  expect(response.status).toBe(200);
  const body = await json(response);
  expect(body.error).toBeUndefined();
  return body.result;
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

describe("Flow Coach bridge MCP edge", () => {
  beforeAll(async () => {
    accessToken = (await obtainTokens()).accessToken;
  });
  beforeEach(clearMailbox);

  it("accepts POST only, even with a valid token", async () => {
    const wrongMethod = await SELF.fetch(MCP_URL, { headers: mcpHeaders() });
    expect(wrongMethod.status).toBe(405);
    expect(wrongMethod.headers.get("allow")).toBe("POST");
  });

  it("initialises statelessly and negotiates the protocol version", async () => {
    const exact = await json(await rpc("initialize", {
      protocolVersion: "2025-03-26",
      capabilities: {},
      clientInfo: { name: "test", version: "0" },
    }));
    expect(exact.result.protocolVersion).toBe("2025-03-26");
    expect(exact.result.capabilities).toEqual({ tools: {} });
    expect(exact.result.serverInfo.name).toBe("flow-coach-bridge");
    expect(exact.result.instructions).toContain("sole authority");

    const unknownVersion = await json(await rpc("initialize", { protocolVersion: "2099-01-01" }));
    expect(unknownVersion.result.protocolVersion).toBe("2025-06-18");

    const initialized = await SELF.fetch(MCP_URL, {
      method: "POST",
      headers: mcpHeaders(),
      body: JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }),
    });
    expect(initialized.status).toBe(202);

    const ping = await json(await rpc("ping"));
    expect(ping.result).toEqual({});
  });

  it("lists six tools with only the proposal tool marked non-read-only", async () => {
    const body = await json(await rpc("tools/list"));
    const tools = body.result.tools as Array<Record<string, any>>;
    expect(tools.map((tool) => tool.name)).toEqual([
      "get_flow_coach_context",
      "list_routines",
      "get_routine",
      "get_training_summary",
      "validate_flow_routine_patch",
      "create_pending_routine_patch",
    ]);
    for (const tool of tools) {
      expect(tool.inputSchema.type).toBe("object");
      expect(tool.annotations.readOnlyHint).toBe(tool.name !== "create_pending_routine_patch");
      expect(tool.annotations.destructiveHint).toBe(false);
      expect(tool.annotations.idempotentHint).toBe(true);
    }
  });

  it("publishes the full patch shape so a client composes it without guessing", async () => {
    const body = await json(await rpc("tools/list"));
    const tools = body.result.tools as Array<Record<string, any>>;
    for (const name of ["validate_flow_routine_patch", "create_pending_routine_patch"]) {
      const patchSchema = tools.find((tool) => tool.name === name)!.inputSchema.properties.patch;
      expect(patchSchema.required).toContain("baseContentHash");
      const operation = patchSchema.properties.operations.items;
      expect(operation.properties.kind.enum).toHaveLength(10);
      expect(operation.properties.expectedIntValue.type).toBe("integer");
      expect(operation.properties.newIntValue.type).toBe("integer");
      expect(patchSchema.properties.operations.description).toContain("expectedIntValue");
    }
  });

  it("runs the full read-propose loop with claude-mcp provenance", async () => {
    const envelope = snapshot();
    expect((await upload(envelope)).status).toBe(201);

    const context = await callTool("get_flow_coach_context");
    expect(context.isError).toBeUndefined();
    expect(context.structuredContent.contextId).toBe(envelope.contextId);
    expect(JSON.parse(context.content[0].text).contextId).toBe(envelope.contextId);

    const routines = await callTool("list_routines", { contextId: envelope.contextId });
    expect(routines.structuredContent.routines).toHaveLength(fixtureContext.routines.length);

    const routineId = routines.structuredContent.routines[0].id as string;
    const routine = await callTool("get_routine", { contextId: envelope.contextId, routineId });
    expect(routine.structuredContent.routine.id).toBe(routineId);

    const summary = await callTool("get_training_summary", { contextId: envelope.contextId, strengthLimit: 3 });
    expect(summary.structuredContent.recentStrengthSummary.length).toBeLessThanOrEqual(3);

    const validation = await callTool("validate_flow_routine_patch", {
      contextId: envelope.contextId,
      patch: validPatch(),
    });
    expect(validation.structuredContent.valid).toBe(true);

    const created = await callTool("create_pending_routine_patch", {
      contextId: envelope.contextId,
      patch: validPatch(),
      idempotencyKey: "mcp-proposal-1",
    });
    expect(created.structuredContent.duplicate).toBe(false);
    expect(created.structuredContent.patch.provenance).toBe("claude-mcp");
    const patchId = created.structuredContent.patch.patchId as string;

    const retried = await callTool("create_pending_routine_patch", {
      contextId: envelope.contextId,
      patch: validPatch(),
      idempotencyKey: "mcp-proposal-1",
    });
    expect(retried.structuredContent.duplicate).toBe(true);
    expect(retried.structuredContent.patch.patchId).toBe(patchId);

    const pull = await SELF.fetch("https://flow.test/device/pending-patches", {
      headers: auth(DEVICE_SECRET),
    });
    const pulled = await json(pull);
    expect(pulled.patches).toHaveLength(1);
    expect(pulled.patches[0].patchId).toBe(patchId);
    expect(pulled.patches[0].provenance).toBe("claude-mcp");
  });

  it("keeps per-edge provenance distinct and unspoofable", async () => {
    const envelope = snapshot();
    expect((await upload(envelope)).status).toBe(201);
    const body = JSON.stringify({ contextId: envelope.contextId, patch: validPatch() });

    const viaRest = await SELF.fetch("https://flow.test/actions/pending-patches", {
      method: "POST",
      // A caller-supplied provenance header must be stripped by the Worker.
      headers: { ...auth(ACTIONS_SECRET), "x-flow-provenance": "claude-mcp" },
      body,
    });
    expect(viaRest.status).toBe(201);
    expect((await json(viaRest)).patch.provenance).toBe("chatgpt-actions");

    const viaMcp = await callTool("create_pending_routine_patch", {
      contextId: envelope.contextId,
      patch: validPatch(),
    });
    expect(viaMcp.structuredContent.duplicate).toBe(false);
    expect(viaMcp.structuredContent.patch.provenance).toBe("claude-mcp");

    const pull = await SELF.fetch("https://flow.test/device/pending-patches", {
      headers: auth(DEVICE_SECRET),
    });
    const provenances = (await json(pull)).patches.map((patch: { provenance: string }) => patch.provenance);
    expect(provenances.sort()).toEqual(["chatgpt-actions", "claude-mcp"]);
  });

  it("surfaces domain failures as tool errors, not protocol errors", async () => {
    const unknownSnapshot = await callTool("list_routines", { contextId: crypto.randomUUID() });
    expect(unknownSnapshot.isError).toBe(true);
    expect(unknownSnapshot.content[0].text).toContain("Unknown coach snapshot");

    const envelope = snapshot();
    expect((await upload(envelope)).status).toBe(201);
    const stale = { ...validPatch(), baseContentHash: "c1-0000000000000000000000000000000000000000000000000000000000000000" };
    const rejected = await callTool("create_pending_routine_patch", { contextId: envelope.contextId, patch: stale });
    expect(rejected.isError).toBe(true);

    const pull = await SELF.fetch("https://flow.test/device/pending-patches", {
      headers: auth(DEVICE_SECRET),
    });
    expect((await json(pull)).patches).toHaveLength(0);
  });

  it("rejects malformed protocol traffic without crashing", async () => {
    const unknownMethod = await json(await rpc("resources/list"));
    expect(unknownMethod.error.code).toBe(-32601);

    const unknownTool = await json(await rpc("tools/call", { name: "drop_tables", arguments: {} }));
    expect(unknownTool.error.code).toBe(-32602);

    const missingArgument = await json(await rpc("tools/call", { name: "list_routines", arguments: {} }));
    expect(missingArgument.error.code).toBe(-32602);
    expect(missingArgument.error.message).toContain("contextId");

    const batch = await SELF.fetch(MCP_URL, {
      method: "POST",
      headers: mcpHeaders(),
      body: JSON.stringify([{ jsonrpc: "2.0", id: 1, method: "ping" }]),
    });
    expect(batch.status).toBe(400);
    expect((await json(batch)).error.code).toBe(-32600);

    const unparseable = await SELF.fetch(MCP_URL, {
      method: "POST",
      headers: mcpHeaders(),
      body: "{not json",
    });
    expect(unparseable.status).toBe(400);
    expect((await json(unparseable)).error.code).toBe(-32700);
  });
});
