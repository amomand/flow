import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { env, runInDurableObject, SELF } from "cloudflare:test";
import fixtureContext from "../../bridge-prototype/fixtures/coach-context.json";
import { OPERATION_KINDS, PATCH_SCHEMA_VERSIONS } from "../src/schemas";
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

/**
 * Deliberate reimplementations of the Worker's private digest helpers. The
 * point is that they are NOT imported: a test that reuses the implementation
 * cannot detect the implementation changing, and the digests of rows already
 * sitting in the production Durable Object are fixed by the deployed formula.
 */
function canonicalJsonForTest(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJsonForTest).join(",")}]`;
  if (value !== null && typeof value === "object") {
    return `{${Object.keys(value as Record<string, unknown>).sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJsonForTest((value as Record<string, unknown>)[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

async function sha256ForTest(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
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

  it("lists six tools with accurate safety and OAuth metadata", async () => {
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
      expect(tool.securitySchemes).toEqual([{
        type: "oauth2",
        scopes: [tool.name === "validate_flow_routine_patch" || tool.name === "create_pending_routine_patch"
          ? "patch:propose"
          : "coach:read"],
      }]);
    }
  });

  it("publishes the full patch shape so a client composes it without guessing", async () => {
    const body = await json(await rpc("tools/list"));
    const tools = body.result.tools as Array<Record<string, any>>;
    for (const name of ["validate_flow_routine_patch", "create_pending_routine_patch"]) {
      const patchSchema = tools.find((tool) => tool.name === name)!.inputSchema.properties.patch;
      // baseContentHash is required on the existingRoutine branch only, so it
      // is published as a property with the branch rule in the description
      // rather than as a top-level requirement a valid create would fail.
      expect(patchSchema.properties.baseContentHash.pattern).toBe("^c1-[0-9a-f]{16}$");
      expect(patchSchema.required).not.toContain("baseContentHash");
      expect(patchSchema.description).toContain("newRoutine");
      expect(patchSchema.description).toContain("no baseContentHash");
      const operation = patchSchema.properties.operations.items;
      // Compared against the source of truth rather than a count, so a new
      // operation kind that never reaches the published schema is a failure
      // rather than a number someone bumps.
      expect(operation.properties.kind.enum).toEqual(OPERATION_KINDS);
      // Same reason: a schema version added to the contract but not published
      // here would leave a client composing against a version the bridge no
      // longer agrees is the newest.
      expect(patchSchema.properties.schemaVersion.enum).toEqual(PATCH_SCHEMA_VERSIONS);
      expect(operation.properties.expectedIntValue.type).toBe("integer");
      expect(operation.properties.newIntValue.type).toBe("integer");
      expect(patchSchema.properties.operations.description).toContain("expectedIntValue");
      // A base-value change leaves phase overrides where they were, so a model
      // composing a multi-phase change has to be explicit about it (#61).
      const description = patchSchema.properties.operations.description as string;
      expect(description).toContain("do not cascade into phaseOverrides");
      expect(description).toContain("replacePhaseOverride operation");
    }
  });

  it("runs the full read-propose loop with provider-neutral MCP provenance", async () => {
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
    expect(created.structuredContent.patch.provenance).toBe("mcp");
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
    expect(pulled.patches[0].provenance).toBe("mcp");
  });

  it("keeps per-edge provenance distinct and unspoofable", async () => {
    const envelope = snapshot();
    expect((await upload(envelope)).status).toBe(201);
    const body = JSON.stringify({ contextId: envelope.contextId, patch: validPatch() });

    const viaRest = await SELF.fetch("https://flow.test/actions/pending-patches", {
      method: "POST",
      // A caller-supplied provenance header must be stripped by the Worker.
      headers: { ...auth(ACTIONS_SECRET), "x-flow-provenance": "mcp" },
      body,
    });
    expect(viaRest.status).toBe(201);
    expect((await json(viaRest)).patch.provenance).toBe("chatgpt-actions");

    const viaMcp = await callTool("create_pending_routine_patch", {
      contextId: envelope.contextId,
      patch: validPatch(),
    });
    expect(viaMcp.structuredContent.duplicate).toBe(false);
    expect(viaMcp.structuredContent.patch.provenance).toBe("mcp");

    const pull = await SELF.fetch("https://flow.test/device/pending-patches", {
      headers: auth(DEVICE_SECRET),
    });
    const provenances = (await json(pull)).patches.map((patch: { provenance: string }) => patch.provenance);
    expect(provenances.sort()).toEqual(["chatgpt-actions", "mcp"]);
  });

  it("deduplicates an MCP retry across the provider-neutral provenance cutover", async () => {
    const envelope = snapshot();
    expect((await upload(envelope)).status).toBe(201);
    const patch = validPatch();
    const idempotencyKey = "mcp-cutover-proposal";

    // Simulate the trusted internal translation performed by the deployed
    // Worker before the provenance rename. External callers cannot reach a
    // mailbox object this way or supply these headers through either edge.
    const mailbox = env.FLOW_COACH.get(env.FLOW_COACH.idFromName("flow-coach:fixture-person"));
    const beforeDeploy = await mailbox.fetch("https://mailbox.internal/actions/pending-patches", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "idempotency-key": idempotencyKey,
        "x-flow-edge": "actions",
        "x-flow-principal": "mcp:fixture-person",
        "x-flow-provenance": "claude-mcp",
      },
      body: JSON.stringify({ contextId: envelope.contextId, patch }),
    });
    expect(beforeDeploy.status).toBe(201);
    const legacyPatch = await json(beforeDeploy);
    expect(legacyPatch.patch.provenance).toBe("claude-mcp");

    const afterDeploy = await callTool("create_pending_routine_patch", {
      contextId: envelope.contextId,
      patch,
      idempotencyKey,
    });
    expect(afterDeploy.structuredContent.duplicate).toBe(true);
    expect(afterDeploy.structuredContent.patch.patchId).toBe(legacyPatch.patch.patchId);
    expect(afterDeploy.structuredContent.patch.provenance).toBe("claude-mcp");

    const sameProposalWithoutKey = await callTool("create_pending_routine_patch", {
      contextId: envelope.contextId,
      patch,
    });
    expect(sameProposalWithoutKey.structuredContent.duplicate).toBe(true);
    expect(sameProposalWithoutKey.structuredContent.patch.patchId).toBe(legacyPatch.patch.patchId);

    const pull = await SELF.fetch("https://flow.test/device/pending-patches", {
      headers: auth(DEVICE_SECRET),
    });
    expect((await json(pull)).patches).toHaveLength(1);
  });

  it("keeps the Idempotency-Key conflict intact across the cutover", async () => {
    const envelope = snapshot();
    expect((await upload(envelope)).status).toBe(201);
    const idempotencyKey = "mcp-cutover-conflict";

    const mailbox = env.FLOW_COACH.get(env.FLOW_COACH.idFromName("flow-coach:fixture-person"));
    const beforeDeploy = await mailbox.fetch("https://mailbox.internal/actions/pending-patches", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "idempotency-key": idempotencyKey,
        "x-flow-edge": "actions",
        "x-flow-principal": "mcp:fixture-person",
        "x-flow-provenance": "claude-mcp",
      },
      body: JSON.stringify({ contextId: envelope.contextId, patch: validPatch() }),
    });
    expect(beforeDeploy.status).toBe(201);

    // Reusing a legacy key for a different payload must still conflict rather
    // than silently storing a second draft or reporting a false duplicate.
    const differentPayload = validPatch();
    differentPayload.operations[0]!.newIntValue += 1;
    const conflict = await callTool("create_pending_routine_patch", {
      contextId: envelope.contextId,
      patch: differentPayload,
      idempotencyKey,
    });
    expect(conflict.isError).toBe(true);
    expect(conflict.content[0].text).toContain("Idempotency-Key");

    const pull = await SELF.fetch("https://flow.test/device/pending-patches", {
      headers: auth(DEVICE_SECRET),
    });
    expect((await json(pull)).patches).toHaveLength(1);
  });

  it("does not let the legacy alias leak a draft across principals or swallow new work", async () => {
    const envelope = snapshot();
    expect((await upload(envelope)).status).toBe(201);
    const patch = validPatch();

    const mailbox = env.FLOW_COACH.get(env.FLOW_COACH.idFromName("flow-coach:fixture-person"));
    const legacy = await mailbox.fetch("https://mailbox.internal/actions/pending-patches", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-flow-edge": "actions",
        "x-flow-principal": "mcp:fixture-person",
        "x-flow-provenance": "claude-mcp",
      },
      body: JSON.stringify({ contextId: envelope.contextId, patch }),
    });
    expect(legacy.status).toBe(201);

    // The Actions edge must not dedupe against an MCP draft. This is the
    // provenance anchor only; the principal anchor is proved separately,
    // because within one mailbox the two values always move together.
    const viaActions = await SELF.fetch("https://flow.test/actions/pending-patches", {
      method: "POST",
      headers: auth(ACTIONS_SECRET),
      body: JSON.stringify({ contextId: envelope.contextId, patch }),
    });
    expect(viaActions.status).toBe(201);
    expect((await json(viaActions)).patch.provenance).toBe("chatgpt-actions");

    // A genuinely different MCP proposal is still new work, not a duplicate.
    const different = validPatch();
    different.operations[0]!.newIntValue += 2;
    const fresh = await callTool("create_pending_routine_patch", {
      contextId: envelope.contextId,
      patch: different,
    });
    expect(fresh.structuredContent.duplicate).toBe(false);
    expect(fresh.structuredContent.patch.provenance).toBe("mcp");

    const pull = await SELF.fetch("https://flow.test/device/pending-patches", {
      headers: auth(DEVICE_SECRET),
    });
    const provenances = (await json(pull)).patches.map((row: { provenance: string }) => row.provenance);
    expect(provenances.sort()).toEqual(["chatgpt-actions", "claude-mcp", "mcp"]);
  });

  it("binds the alias digest to the principal, not just the provenance", async () => {
    const envelope = snapshot();
    expect((await upload(envelope)).status).toBe(201);
    const patch = validPatch();

    // Within one mailbox, principal and provenance move together, so a test
    // that uses this mailbox's own MCP principal cannot tell the two anchors
    // apart. Decouple them: a legacy-provenance row owned by a foreign
    // principal must not satisfy this mailbox's proposal.
    const mailbox = env.FLOW_COACH.get(env.FLOW_COACH.idFromName("flow-coach:fixture-person"));
    const foreign = await mailbox.fetch("https://mailbox.internal/actions/pending-patches", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-flow-edge": "actions",
        "x-flow-principal": "mcp:some-other-mailbox",
        "x-flow-provenance": "claude-mcp",
      },
      body: JSON.stringify({ contextId: envelope.contextId, patch }),
    });
    expect(foreign.status).toBe(201);

    const viaMcp = await callTool("create_pending_routine_patch", {
      contextId: envelope.contextId,
      patch,
    });
    expect(viaMcp.structuredContent.duplicate).toBe(false);
    expect(viaMcp.structuredContent.patch.provenance).toBe("mcp");

    const pull = await SELF.fetch("https://flow.test/device/pending-patches", {
      headers: auth(DEVICE_SECRET),
    });
    expect((await json(pull)).patches).toHaveLength(2);
  });

  it("resolves digests computed by the pre-cutover formula, not just by this build", async () => {
    const envelope = snapshot();
    expect((await upload(envelope)).status).toBe(201);
    const patch = validPatch();
    const idempotencyKey = "mcp-cutover-formula";

    const mailbox = env.FLOW_COACH.get(env.FLOW_COACH.idFromName("flow-coach:fixture-person"));
    const created = await mailbox.fetch("https://mailbox.internal/actions/pending-patches", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "idempotency-key": idempotencyKey,
        "x-flow-edge": "actions",
        "x-flow-principal": "mcp:fixture-person",
        "x-flow-provenance": "claude-mcp",
      },
      body: JSON.stringify({ contextId: envelope.contextId, patch }),
    });
    expect(created.status).toBe(201);
    const legacyPatchId = (await json(created)).patch.patchId as string;

    // Overwrite the row with digests computed here rather than by the code
    // under test, so this pins the formula a production row was actually
    // stored with. `target` is a Zod default injected by validatePatch before
    // the payload is canonicalised: cross-deploy dedup depends on schema
    // defaults being stable, not only on the digest string, and this is the
    // one test that would notice either changing.
    const payload = canonicalJsonForTest({ ...patch, target: "existingRoutine" });
    const prefix = `mcp:fixture-person\nclaude-mcp\n${envelope.contextId}`;
    const proposalDigest = await sha256ForTest(`${prefix}\n${payload}`);
    const idempotencyDigest = await sha256ForTest(`${prefix}\n${idempotencyKey}`);
    await runInDurableObject(mailbox, async (_instance: unknown, state: DurableObjectState) => {
      state.storage.sql.exec(
        "UPDATE patches SET proposal_digest = ?, idempotency_digest = ? WHERE patch_id = ?",
        proposalDigest, idempotencyDigest, legacyPatchId,
      );
    });

    const keyedRetry = await callTool("create_pending_routine_patch", {
      contextId: envelope.contextId,
      patch,
      idempotencyKey,
    });
    expect(keyedRetry.structuredContent.duplicate).toBe(true);
    expect(keyedRetry.structuredContent.patch.patchId).toBe(legacyPatchId);

    const keylessRetry = await callTool("create_pending_routine_patch", {
      contextId: envelope.contextId,
      patch,
    });
    expect(keylessRetry.structuredContent.duplicate).toBe(true);
    expect(keylessRetry.structuredContent.patch.patchId).toBe(legacyPatchId);

    const pull = await SELF.fetch("https://flow.test/device/pending-patches", {
      headers: auth(DEVICE_SECRET),
    });
    expect((await json(pull)).patches).toHaveLength(1);
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
