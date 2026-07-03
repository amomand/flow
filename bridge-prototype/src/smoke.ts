/**
 * Smoke test for the Flow Coach bridge prototype (issue #36).
 *
 * Starts the real Streamable HTTP server, connects with the official MCP SDK
 * client (the same transport Claude custom connectors and ChatGPT
 * developer-mode connectors use), and exercises every tool: reads, a valid
 * patch validate + create, a stale-hash rejection, and an unknown-routine
 * rejection. Prints human-readable pass/fail output.
 *
 * Run with: npm run smoke
 */
import { randomUUID } from "node:crypto";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { startServer } from "./server.js";

const PORT = 3940;
const BASE_URL = `http://localhost:${PORT}/mcp`;

let passCount = 0;
let failCount = 0;

function ok(label: string, condition: boolean, detail?: string): void {
  if (condition) {
    passCount++;
    console.log(`  PASS  ${label}`);
  } else {
    failCount++;
    console.log(`  FAIL  ${label}${detail ? ` — ${detail}` : ""}`);
  }
}

function section(title: string): void {
  console.log(`\n=== ${title} ===`);
}

interface ToolTextResult {
  isError?: boolean;
  content: Array<{ type: string; text?: string }>;
  structuredContent?: unknown;
}

function firstText(result: ToolTextResult): string {
  const block = result.content.find((entry) => entry.type === "text");
  return block?.text ?? "";
}

async function main(): Promise<void> {
  console.log("Flow Coach bridge prototype — smoke test");
  console.log(`Starting server on port ${PORT}...`);
  const httpServer = startServer(PORT);

  // Give express a tick to bind before connecting.
  await new Promise((resolve) => setTimeout(resolve, 150));

  const client = new Client({ name: "flow-coach-smoke-client", version: "0.1.0" });
  const transport = new StreamableHTTPClientTransport(new URL(BASE_URL));

  section("Connect");
  await client.connect(transport);
  console.log("  Connected over Streamable HTTP.");

  const serverInstructions = client.getInstructions();
  ok(
    "Server instructions describe the propose-only trust boundary",
    typeof serverInstructions === "string" && serverInstructions.includes("PROPOSE"),
    `instructions: ${serverInstructions?.slice(0, 60)}...`
  );

  section("tools/list — annotations");
  const toolList = await client.listTools();
  console.log(`  ${toolList.tools.length} tools advertised:`);
  for (const tool of toolList.tools) {
    console.log(
      `    - ${tool.name}: readOnlyHint=${tool.annotations?.readOnlyHint} ` +
        `destructiveHint=${tool.annotations?.destructiveHint} ` +
        `idempotentHint=${tool.annotations?.idempotentHint}`
    );
  }
  const byName = new Map(toolList.tools.map((tool) => [tool.name, tool]));
  const expectedTools = [
    "get_flow_coach_context",
    "list_routines",
    "get_routine",
    "validate_flow_routine_patch",
    "create_pending_routine_patch",
    "list_pending_patches",
  ];
  for (const name of expectedTools) {
    ok(`tool "${name}" is advertised`, byName.has(name));
  }
  for (const name of [
    "get_flow_coach_context",
    "list_routines",
    "get_routine",
    "validate_flow_routine_patch",
    "list_pending_patches",
  ]) {
    ok(`"${name}" has readOnlyHint: true`, byName.get(name)?.annotations?.readOnlyHint === true);
  }
  const createTool = byName.get("create_pending_routine_patch");
  ok("create_pending_routine_patch has destructiveHint: false", createTool?.annotations?.destructiveHint === false);
  ok("create_pending_routine_patch has idempotentHint: false", createTool?.annotations?.idempotentHint === false);
  ok(
    "create_pending_routine_patch description states it only stores a draft",
    (createTool?.description ?? "").toLowerCase().includes("does not modify"),
    createTool?.description
  );

  section("get_flow_coach_context");
  const contextResult = (await client.callTool({ name: "get_flow_coach_context", arguments: {} })) as ToolTextResult;
  const contextPayload = JSON.parse(firstText(contextResult)) as {
    routines: Array<{ id: string; name: string; contentHash: string }>;
    recentStrengthSummaryCount: number;
    recentCardioSummaryCount: number;
  };
  ok("get_flow_coach_context returns 2 routine summaries", contextPayload.routines.length === 2);
  ok(
    "get_flow_coach_context returns strength/cardio counts, not full arrays",
    typeof contextPayload.recentStrengthSummaryCount === "number" &&
      typeof contextPayload.recentCardioSummaryCount === "number"
  );
  const payloadBytes = Buffer.byteLength(firstText(contextResult), "utf-8");
  console.log(`  Payload size: ${payloadBytes} bytes`);
  ok("get_flow_coach_context payload is lean (< 4KB)", payloadBytes < 4096, `${payloadBytes} bytes`);

  section("list_routines");
  const listResult = (await client.callTool({ name: "list_routines", arguments: {} })) as ToolTextResult;
  const routines = JSON.parse(firstText(listResult)) as Array<{ id: string; name: string; contentHash: string }>;
  ok("list_routines returns 2 routines", routines.length === 2);
  const wednesday = routines.find((r) => r.name.includes("Wednesday"));
  ok("list_routines includes Wednesday — Upper A", wednesday !== undefined);

  section("get_routine (valid id)");
  const routineId = wednesday!.id;
  const getRoutineResult = (await client.callTool({
    name: "get_routine",
    arguments: { routineId },
  })) as ToolTextResult;
  const fullRoutine = JSON.parse(firstText(getRoutineResult)) as { sections: Array<{ exercises: unknown[] }> };
  ok("get_routine returns full routine body with sections", Array.isArray(fullRoutine.sections) && fullRoutine.sections.length > 0);

  section("get_routine (unknown id) — expect rejection");
  const unknownRoutineId = randomUUID();
  const badRoutineResult = (await client.callTool({
    name: "get_routine",
    arguments: { routineId: unknownRoutineId },
  })) as ToolTextResult;
  ok("get_routine reports isError for unknown routine id", badRoutineResult.isError === true);

  section("validate_flow_routine_patch — valid patch");
  const validPatch = {
    schemaVersion: 2,
    routineId,
    baseContentHash: wednesday!.contentHash,
    exportedAt: new Date().toISOString(),
    rationale: "Bump front plank hold now that base sets feel easy.",
    operations: [
      {
        kind: "replaceTimedDuration",
        exerciseId: "9FB9E3F9-C0B2-4D09-B2F6-8841D56FD75B",
        expectedIntValue: 30,
        newIntValue: 35,
      },
    ],
  };
  const validateGoodResult = (await client.callTool({
    name: "validate_flow_routine_patch",
    arguments: { patch: validPatch },
  })) as ToolTextResult;
  const validateGoodPayload = JSON.parse(firstText(validateGoodResult)) as { valid: boolean; problems: unknown[] };
  ok("validate_flow_routine_patch accepts a well-formed patch", validateGoodPayload.valid === true, JSON.stringify(validateGoodPayload.problems));

  section("validate_flow_routine_patch — stale/garbage hash");
  const staleHashPatch = { ...validPatch, baseContentHash: "c1-0000000000000000" };
  const validateStaleResult = (await client.callTool({
    name: "validate_flow_routine_patch",
    arguments: { patch: staleHashPatch },
  })) as ToolTextResult;
  const validateStalePayload = JSON.parse(firstText(validateStaleResult)) as { valid: boolean; problems: Array<{ path: string }> };
  ok("validate_flow_routine_patch rejects a stale content hash", validateStalePayload.valid === false);
  ok(
    "stale-hash rejection names baseContentHash",
    validateStalePayload.problems.some((p) => p.path === "baseContentHash")
  );

  section("validate_flow_routine_patch — garbage-shaped hash");
  const garbageHashPatch = { ...validPatch, baseContentHash: "not-a-real-hash" };
  const validateGarbageResult = (await client.callTool({
    name: "validate_flow_routine_patch",
    arguments: { patch: garbageHashPatch },
  })) as ToolTextResult;
  const validateGarbagePayload = JSON.parse(firstText(validateGarbageResult)) as { valid: boolean };
  ok("validate_flow_routine_patch rejects a malformed-shape hash", validateGarbagePayload.valid === false);

  section("validate_flow_routine_patch — unknown routine");
  const unknownRoutinePatch = { ...validPatch, routineId: randomUUID(), baseContentHash: "c1-0000000000000000" };
  const validateUnknownResult = (await client.callTool({
    name: "validate_flow_routine_patch",
    arguments: { patch: unknownRoutinePatch },
  })) as ToolTextResult;
  const validateUnknownPayload = JSON.parse(firstText(validateUnknownResult)) as { valid: boolean; problems: Array<{ path: string }> };
  ok("validate_flow_routine_patch rejects an unknown routineId", validateUnknownPayload.valid === false);
  ok(
    "unknown-routine rejection names routineId",
    validateUnknownPayload.problems.some((p) => p.path === "routineId")
  );

  section("create_pending_routine_patch — valid create");
  const createGoodResult = (await client.callTool({
    name: "create_pending_routine_patch",
    arguments: { patch: validPatch, assistantProvider: "claude" },
  })) as ToolTextResult;
  ok("create_pending_routine_patch (valid) does not report isError", createGoodResult.isError !== true);
  const createGoodStructured = createGoodResult.structuredContent as { stored: boolean; patch?: { patchId: string; status: string } } | undefined;
  ok("create_pending_routine_patch (valid) stores a draft with status pending", createGoodStructured?.stored === true && createGoodStructured?.patch?.status === "pending");
  console.log(`  Stored patchId: ${createGoodStructured?.patch?.patchId}`);

  section("create_pending_routine_patch — stale/garbage hash gets rejected");
  const createStaleResult = (await client.callTool({
    name: "create_pending_routine_patch",
    arguments: { patch: staleHashPatch, assistantProvider: "claude" },
  })) as ToolTextResult;
  ok("create_pending_routine_patch (stale hash) reports isError", createStaleResult.isError === true);
  const createStaleStructured = createStaleResult.structuredContent as { stored: boolean } | undefined;
  ok("create_pending_routine_patch (stale hash) does not store a draft", createStaleStructured?.stored === false);

  section("create_pending_routine_patch — unknown routine gets rejected");
  const createUnknownResult = (await client.callTool({
    name: "create_pending_routine_patch",
    arguments: { patch: unknownRoutinePatch, assistantProvider: "chatgpt" },
  })) as ToolTextResult;
  ok("create_pending_routine_patch (unknown routine) reports isError", createUnknownResult.isError === true);
  const createUnknownStructured = createUnknownResult.structuredContent as { stored: boolean } | undefined;
  ok("create_pending_routine_patch (unknown routine) does not store a draft", createUnknownStructured?.stored === false);

  section("list_pending_patches");
  const listPendingResult = (await client.callTool({ name: "list_pending_patches", arguments: {} })) as ToolTextResult;
  const pendingList = JSON.parse(firstText(listPendingResult)) as Array<{ patchId: string; status: string; assistantProvider: string }>;
  ok(
    "list_pending_patches shows exactly the one successfully created patch",
    pendingList.length === 1 && pendingList[0]?.status === "pending" && pendingList[0]?.assistantProvider === "claude"
  );

  section("Summary");
  console.log(`  ${passCount} passed, ${failCount} failed`);

  await client.close();
  httpServer.emit("close");
  process.exit(failCount === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error("Smoke test crashed:", error);
  process.exit(1);
});
