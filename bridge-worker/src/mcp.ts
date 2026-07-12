/**
 * Flow Coach bridge - MCP edge (issue #46, Claude connector spike).
 *
 * A stateless Streamable HTTP MCP server implemented directly over the
 * Worker fetch API: each POST carries one JSON-RPC message and receives one
 * JSON response. No session id is issued and no SSE stream is opened; the
 * Streamable HTTP transport permits both for stateless servers and Claude's
 * custom connectors accept them. Tool calls translate onto the same domain
 * routes the REST Actions edge uses, so the Durable Object stays the single
 * domain service and nothing forks by provider.
 *
 * Six tools, matching the phase 5 prototype contract (#36, PR #43) adapted
 * to the worker's exact-snapshot correlation rules:
 *   get_flow_coach_context, list_routines, get_routine,
 *   get_training_summary, validate_flow_routine_patch,
 *   create_pending_routine_patch.
 */

export const MCP_SUPPORTED_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"] as const;

const BRIDGE_INSTRUCTIONS = `Flow Coach bridge.

This connector gives read access to one Flow user's strength routines and
recent training summary, plus a mailbox for proposed routine edits.

Trust boundary - read this before calling create_pending_routine_patch:
- You may PROPOSE a routine edit. That call only stores a draft; it never
  changes the user's routine.
- Flow (the iOS app) is the sole authority for previewing, confirming,
  persisting, and rolling back routine changes. The user must open Flow and
  explicitly apply a pending patch before anything changes.
- This bridge never receives raw HealthKit data (no route points, no
  per-sample heart rate, no HealthKit object IDs). Training context here is
  pre-aggregated by Flow.
- Routine hashes (c1-.../s1-...) are opaque revision identifiers relayed
  from Flow. Copy them exactly; never compute or guess one.
- Call get_flow_coach_context first. It returns the current contextId; pass
  that exact contextId to every other tool so reads and proposals correlate
  with the snapshot you actually saw. If a tool reports the snapshot
  expired, was deleted, or is unknown, call get_flow_coach_context again and
  re-read before proposing anything.`;

type JsonSchema = Record<string, unknown>;

type DomainCall = {
  method: "GET" | "POST";
  path: string;
  body?: unknown;
  headers?: Record<string, string>;
};

export type DomainFetch = (call: DomainCall) => Promise<Response>;

type ToolArguments = Record<string, unknown>;

interface ToolDefinition {
  name: string;
  title: string;
  description: string;
  inputSchema: JsonSchema;
  annotations: {
    readOnlyHint: boolean;
    destructiveHint: boolean;
    idempotentHint: boolean;
    openWorldHint: boolean;
  };
  required: ReadonlyArray<[name: string, type: "string" | "integer" | "boolean" | "object"]>;
  optional: ReadonlyArray<[name: string, type: "string" | "integer" | "boolean" | "object"]>;
  toCall: (args: ToolArguments) => DomainCall;
}

const contextIdProperty = {
  type: "string",
  description: "The exact contextId returned by get_flow_coach_context.",
};

const TOOLS: ReadonlyArray<ToolDefinition> = [
  {
    name: "get_flow_coach_context",
    title: "Get Flow coach context",
    description:
      "Returns a lean summary of the user's current Flow coach context: the contextId " +
      "to use with every other tool, routine summaries (id, name, phase, exercise " +
      "counts, revision hashes), counts of recent strength and cardio activity, and " +
      "any coach constraints notes. Deliberately does NOT include full routine bodies " +
      "or full workout history - call list_routines/get_routine to drill in. Contains " +
      "no raw HealthKit data.",
    inputSchema: {
      type: "object",
      properties: {
        contextId: {
          type: "string",
          description:
            "Optional. Pass a known contextId to re-read that exact snapshot; omit to read the latest unexpired snapshot.",
        },
      },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    required: [],
    optional: [["contextId", "string"]],
    toCall: (args) => ({
      method: "GET",
      path: withQuery("/actions/coach-context", { contextId: args.contextId }),
    }),
  },
  {
    name: "list_routines",
    title: "List Flow routines",
    description:
      "Lists every routine in one exact snapshot with id, name, current phase, " +
      "revision hashes, and exercise counts. Does not include exercise-level detail - " +
      "call get_routine with a routine id for the full body.",
    inputSchema: {
      type: "object",
      properties: { contextId: contextIdProperty },
      required: ["contextId"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    required: [["contextId", "string"]],
    optional: [],
    toCall: (args) => ({
      method: "GET",
      path: withQuery("/actions/routines", { contextId: args.contextId }),
    }),
  },
  {
    name: "get_routine",
    title: "Get one Flow routine",
    description:
      "Returns the full body of one routine by id, in the same JSON shape Flow itself " +
      "uses (Routine: id, name, currentPhase, sections[].exercises[] with " +
      "sets/reps/duration/rest/notes/phaseOverrides). Use this before proposing a " +
      "patch so exerciseId/sectionId values in the patch are correct.",
    inputSchema: {
      type: "object",
      properties: {
        contextId: contextIdProperty,
        routineId: {
          type: "string",
          description: "The routine id from list_routines or get_flow_coach_context.",
        },
      },
      required: ["contextId", "routineId"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    required: [["contextId", "string"], ["routineId", "string"]],
    optional: [],
    toCall: (args) => ({
      method: "GET",
      path: withQuery(`/actions/routines/${encodeURIComponent(args.routineId as string)}`, { contextId: args.contextId }),
    }),
  },
  {
    name: "get_training_summary",
    title: "Get recent Flow training summary",
    description:
      "Returns a bounded window of recent strength and cardio summaries from one " +
      "exact snapshot. Health-derived metrics are excluded unless the snapshot's " +
      "sharing profile includes them and includeHealthMetrics is true.",
    inputSchema: {
      type: "object",
      properties: {
        contextId: contextIdProperty,
        strengthLimit: { type: "integer", minimum: 1, maximum: 10, description: "Strength entries to return (default 5)." },
        cardioLimit: { type: "integer", minimum: 1, maximum: 12, description: "Cardio entries to return (default 5)." },
        includeHealthMetrics: { type: "boolean", description: "Include health-derived fields when the sharing profile allows them (default false)." },
      },
      required: ["contextId"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    required: [["contextId", "string"]],
    optional: [["strengthLimit", "integer"], ["cardioLimit", "integer"], ["includeHealthMetrics", "boolean"]],
    toCall: (args) => ({
      method: "GET",
      path: withQuery("/actions/training-summary", {
        contextId: args.contextId,
        strengthLimit: args.strengthLimit,
        cardioLimit: args.cardioLimit,
        includeHealthMetrics: args.includeHealthMetrics,
      }),
    }),
  },
  {
    name: "validate_flow_routine_patch",
    title: "Validate a Flow routine patch",
    description:
      "Validates a candidate FlowRoutinePatch (schema 2) against one exact snapshot " +
      "WITHOUT storing anything: checks schema version, required fields, known " +
      "operation kinds, per-kind required fields and value ranges, that routineId " +
      "exists in the snapshot, and that baseContentHash matches the stored content " +
      "hash for that routine. Returns a structured list of problems rather than " +
      "throwing, so a mostly-valid patch can be diagnosed in one call. This is a " +
      "read-only dry run - call create_pending_routine_patch to actually store a " +
      "draft for Flow to review.",
    inputSchema: {
      type: "object",
      properties: {
        contextId: contextIdProperty,
        patch: { type: "object", description: "The candidate FlowRoutinePatch JSON object, schema version 2." },
      },
      required: ["contextId", "patch"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    required: [["contextId", "string"], ["patch", "object"]],
    optional: [],
    toCall: (args) => ({
      method: "POST",
      path: "/actions/patches/validate",
      body: { contextId: args.contextId, patch: args.patch },
    }),
  },
  {
    name: "create_pending_routine_patch",
    title: "Propose a Flow routine patch",
    description:
      "Stores a DRAFT routine patch for Flow to review. This tool does not modify any " +
      "routine - it only writes an entry to a pending-patch mailbox that the Flow app " +
      "later pulls, previews as a diff, and applies only after the user explicitly " +
      "confirms inside Flow. Runs the same validation as validate_flow_routine_patch " +
      "first and rejects invalid input before storing anything; Flow remains the sole " +
      "authority for semantic validation, preview, and apply. Identical retries with " +
      "the same idempotencyKey reuse the same pending patch record (idempotent) and " +
      "never delete or overwrite routine data (not destructive).",
    inputSchema: {
      type: "object",
      properties: {
        contextId: contextIdProperty,
        patch: { type: "object", description: "The candidate FlowRoutinePatch JSON object, schema version 2." },
        idempotencyKey: {
          type: "string",
          maxLength: 128,
          description: "Optional stable key so a retried create reuses the stored draft instead of proposing twice.",
        },
      },
      required: ["contextId", "patch"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
    required: [["contextId", "string"], ["patch", "object"]],
    optional: [["idempotencyKey", "string"]],
    toCall: (args) => ({
      method: "POST",
      path: "/actions/pending-patches",
      body: { contextId: args.contextId, patch: args.patch },
      headers: typeof args.idempotencyKey === "string" ? { "idempotency-key": args.idempotencyKey } : undefined,
    }),
  },
];

/**
 * Handles one decoded JSON-RPC message. Returns the HTTP status and JSON
 * body to send, or null for a notification/response message that only needs
 * a 202. The caller owns transport concerns: token gate, method check, body
 * size limits, and JSON parse errors.
 */
export async function handleMcpMessage(
  message: unknown,
  domain: DomainFetch,
): Promise<{ status: number; body: unknown } | null> {
  if (Array.isArray(message)) {
    return { status: 400, body: rpcError(null, -32600, "Batch requests are not supported.") };
  }
  if (message === null || typeof message !== "object") {
    return { status: 400, body: rpcError(null, -32600, "Request must be a JSON-RPC message object.") };
  }
  const rpc = message as { jsonrpc?: unknown; id?: unknown; method?: unknown; params?: unknown; result?: unknown; error?: unknown };
  if (typeof rpc.method !== "string") {
    // A client-to-server response (e.g. to a server request we never make)
    // is accepted and dropped, per the Streamable HTTP transport.
    if ("result" in rpc || "error" in rpc) return null;
    return { status: 400, body: rpcError(null, -32600, "Request must name a method.") };
  }
  if (rpc.id === undefined) return null;
  if (rpc.jsonrpc !== "2.0" || (typeof rpc.id !== "string" && typeof rpc.id !== "number")) {
    return { status: 400, body: rpcError(null, -32600, "Request must be JSON-RPC 2.0 with a string or number id.") };
  }
  const id = rpc.id;
  const params = (rpc.params ?? {}) as Record<string, unknown>;

  if (rpc.method === "initialize") {
    const requested = typeof params.protocolVersion === "string" ? params.protocolVersion : undefined;
    const protocolVersion = MCP_SUPPORTED_VERSIONS.includes(requested as never)
      ? requested!
      : MCP_SUPPORTED_VERSIONS[0];
    return rpcResult(id, {
      protocolVersion,
      capabilities: { tools: {} },
      serverInfo: { name: "flow-coach-bridge", version: "0.1.0" },
      instructions: BRIDGE_INSTRUCTIONS,
    });
  }
  if (rpc.method === "ping") return rpcResult(id, {});
  if (rpc.method === "tools/list") {
    return rpcResult(id, {
      tools: TOOLS.map(({ name, title, description, inputSchema, annotations }) => ({
        name, title, description, inputSchema, annotations,
      })),
    });
  }
  if (rpc.method === "tools/call") {
    const tool = TOOLS.find((candidate) => candidate.name === params.name);
    if (!tool) return { status: 200, body: rpcError(id, -32602, `Unknown tool: ${String(params.name)}.`) };
    const args = (params.arguments ?? {}) as ToolArguments;
    const problem = argumentProblem(tool, args);
    if (problem) return { status: 200, body: rpcError(id, -32602, problem) };
    return rpcResult(id, await executeTool(tool, args, domain));
  }
  return { status: 200, body: rpcError(id, -32601, `Method not found: ${rpc.method}.`) };
}

function argumentProblem(tool: ToolDefinition, args: ToolArguments): string | undefined {
  if (typeof args !== "object" || args === null || Array.isArray(args)) return "Tool arguments must be an object.";
  for (const [name, type] of tool.required) {
    if (!(name in args)) return `${tool.name} requires ${name}.`;
    if (!matchesType(args[name], type)) return `${tool.name} argument ${name} must be a ${type}.`;
  }
  for (const [name, type] of tool.optional) {
    if (name in args && args[name] !== undefined && !matchesType(args[name], type)) {
      return `${tool.name} argument ${name} must be a ${type}.`;
    }
  }
  return undefined;
}

function matchesType(value: unknown, type: "string" | "integer" | "boolean" | "object"): boolean {
  if (type === "string") return typeof value === "string" && value.length > 0;
  if (type === "integer") return typeof value === "number" && Number.isSafeInteger(value);
  if (type === "boolean") return typeof value === "boolean";
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function executeTool(tool: ToolDefinition, args: ToolArguments, domain: DomainFetch): Promise<unknown> {
  let response: Response;
  try {
    response = await domain(tool.toCall(args));
  } catch {
    return toolError("The Flow Coach mailbox is temporarily unavailable. Try again.");
  }
  let payload: unknown;
  try {
    payload = await response.json();
  } catch {
    return toolError(`The mailbox returned an unreadable response (HTTP ${response.status}).`);
  }
  if (!response.ok) {
    const detail = payload as { error?: unknown; problems?: unknown };
    const messageText = typeof detail.error === "string" ? detail.error : `HTTP ${response.status}.`;
    const problems = detail.problems === undefined ? "" : `\n${JSON.stringify(detail.problems, null, 2)}`;
    return toolError(`${messageText}${problems}`);
  }
  return {
    content: [{ type: "text", text: JSON.stringify(payload, null, 2) }],
    structuredContent: payload as Record<string, unknown>,
  };
}

function toolError(text: string): unknown {
  return { isError: true, content: [{ type: "text", text }] };
}

function withQuery(path: string, params: Record<string, unknown>): string {
  const query = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined) query.set(key, String(value));
  }
  const encoded = query.toString();
  return encoded ? `${path}?${encoded}` : path;
}

function rpcResult(id: string | number, result: unknown): { status: number; body: unknown } {
  return { status: 200, body: { jsonrpc: "2.0", id, result } };
}

function rpcError(id: string | number | null, code: number, message: string): unknown {
  return { jsonrpc: "2.0", id, error: { code, message } };
}
