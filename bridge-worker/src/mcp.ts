/**
 * Flow Coach bridge - MCP edge (proved by the #46 spike, hardened for #38).
 *
 * A stateless Streamable HTTP MCP server implemented directly over the
 * Worker fetch API: each POST carries one JSON-RPC message and receives one
 * JSON response. No session id is issued and no SSE stream is opened; the
 * Streamable HTTP transport permits both for stateless servers and Claude's
 * custom connectors accept them. Tool calls translate onto the same domain
 * routes the REST Actions edge uses, so the Durable Object stays the single
 * domain service and nothing forks by provider. Access control lives in
 * index.ts: OAuth 2.1 bearer tokens verified by workers-oauth-provider,
 * with per-tool scope checks here.
 *
 * Six tools, matching the phase 5 prototype contract (#36, PR #43) adapted
 * to the worker's exact-snapshot correlation rules:
 *   get_flow_coach_context, list_routines, get_routine,
 *   get_training_summary, validate_flow_routine_patch,
 *   create_pending_routine_patch.
 */

import { OPERATION_KINDS, PATCH_SCHEMA_VERSIONS, STRING_BOUNDS } from "./schemas";

export const MCP_SUPPORTED_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"] as const;

/**
 * OAuth scopes on the MCP edge (#38). Reads require coach:read; patch
 * validation and pending-patch creation require patch:propose. The split
 * lets a Project be connected read-only if a person wants advice without
 * even draft-level write access.
 */
export const MCP_SCOPES = ["coach:read", "patch:propose"] as const;
export type McpScope = (typeof MCP_SCOPES)[number];

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
  requiredScope: McpScope;
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

// The full FlowRoutinePatch shape, mirrored from schemas.ts so the model can
// compose a correct patch on the first call instead of reverse-engineering
// field names from strict-schema rejections (#46 finding: an opaque
// {type:"object"} here cost five failed guesses on fixture data).
const uuidProperty = { type: "string", format: "uuid" };
const phaseProperty = { type: "string", enum: ["base", "peak", "deload"] };
const phaseOverrideProperty = {
  type: "object",
  properties: {
    sets: { type: "integer", minimum: 1, maximum: 10 },
    reps: { type: "integer", minimum: 1, maximum: 100 },
    durationSeconds: { type: "integer", minimum: 1, maximum: 3600 },
  },
  additionalProperties: false,
};
const exerciseProperty = {
  type: "object",
  description: "A complete new exercise, only for addExercise. Give it a fresh UUID.",
  properties: {
    id: uuidProperty,
    name: { type: "string", minLength: 1, maxLength: STRING_BOUNDS.name },
    sets: { type: "integer", minimum: 1, maximum: 10 },
    reps: { type: "integer", minimum: 1, maximum: 100 },
    durationSeconds: { type: "integer", minimum: 1, maximum: 3600 },
    restBetweenSetsSeconds: { type: "integer", minimum: 0, maximum: 900 },
    restAfterExerciseSeconds: { type: "integer", minimum: 0, maximum: 900 },
    notes: { type: "string", maxLength: STRING_BOUNDS.exerciseNotes },
    perSide: { type: "boolean" },
    phaseOverrides: { type: "object", additionalProperties: phaseOverrideProperty },
  },
  required: ["id", "name", "sets", "reps", "restBetweenSetsSeconds", "restAfterExerciseSeconds", "notes", "perSide"],
  additionalProperties: false,
};
const sectionProperty = {
  type: "object",
  description:
    "A new, empty section, only for addSection. Give it a fresh UUID and add exercises to it with later " +
    "addExercise operations. The name is stored trimmed, and the 1 to 200 character bound is measured " +
    "after trimming.",
  properties: {
    id: uuidProperty,
    name: { type: "string", minLength: 1, maxLength: STRING_BOUNDS.name },
  },
  required: ["id", "name"],
  additionalProperties: false,
};
const routineProperty = {
  type: "object",
  description:
    "A complete new routine, only for createRoutine. Generate every id yourself: the routine's, each " +
    "section's, and each exercise's. Exercise ids must be unique across every routine in the snapshot, " +
    "not just this one. Because you supply the ids, applying the same create twice leaves one routine " +
    "rather than two.",
  properties: {
    id: uuidProperty,
    name: { type: "string", minLength: 1, maxLength: STRING_BOUNDS.proposedRoutineName, description: "Stored trimmed; the bound is measured after trimming." },
    currentPhase: { ...phaseProperty, description: "The phase the routine starts in." },
    sections: {
      type: "array",
      minItems: 1,
      description: "At least one section, holding at least one exercise between them.",
      items: {
        type: "object",
        properties: {
          id: uuidProperty,
          name: { type: "string", minLength: 1, maxLength: STRING_BOUNDS.name },
          exercises: { type: "array", items: exerciseProperty },
        },
        required: ["id", "name", "exercises"],
        additionalProperties: false,
      },
    },
  },
  required: ["id", "name", "currentPhase", "sections"],
  additionalProperties: false,
};
const patchProperty = {
  type: "object",
  description:
    "A FlowRoutinePatch, in one of two shapes chosen by `target`.\n\n" +
    "target 'existingRoutine' (the default, and the only shape in schema 2) edits a routine that is " +
    "already there: copy routineId and baseContentHash exactly from the snapshot you read, and never " +
    "compute or guess a hash.\n\n" +
    "target 'newRoutine' proposes a routine that does not exist yet. It carries no routineId and no " +
    "baseContentHash, because there is nothing to anchor to, and exactly one operation: a createRoutine " +
    "holding the whole routine. Do not follow it with addSection or addExercise operations; a new routine " +
    "arrives whole so the user previews a routine rather than a sequence of edits to one.\n\n" +
    "Use the highest schemaVersion listed in capabilities.patchSchemaVersions from " +
    "get_flow_coach_context, and only operation kinds listed in capabilities.operationKinds: an " +
    "operation belongs to the schema version that introduced it, so renameRoutine, addSection and " +
    "createRoutine require schemaVersion 3 and are rejected under schemaVersion 2.",
  properties: {
    target: {
      type: "string",
      enum: ["existingRoutine", "newRoutine"],
      description: "Defaults to existingRoutine when omitted.",
    },
    // Published from the shared contract, not restated, so the schema a client
    // composes against cannot fall behind what the bridge accepts.
    schemaVersion: { type: "integer", enum: PATCH_SCHEMA_VERSIONS },
    routineId: uuidProperty,
    baseContentHash: {
      type: "string",
      pattern: "^c1-[0-9a-f]{16}$",
      description: "The contentHash for this routine from get_flow_coach_context or list_routines, copied exactly.",
    },
    exportedAt: { type: "string", description: "Optional ISO 8601 timestamp." },
    // A literal, deliberately: the rationale bound is bridge-only, with no
    // Swift counterpart to drift from. It matching constraintsNotes' 2000 is
    // a coincidence, not a contract — do not unify them.
    rationale: { type: "string", minLength: 1, maxLength: 2000, description: "Why this change; shown to the user in Flow's preview." },
    operations: {
      type: "array",
      minItems: 1,
      maxItems: 50,
      description:
        "Required fields by kind: replaceExerciseReps/replaceExerciseSets/replaceTimedDuration/" +
        "replaceRestBetweenSets/replaceRestAfterExercise need exerciseId, expectedIntValue (the current " +
        "value), and newIntValue. updateExerciseNotes needs exerciseId, expectedStringValue, and " +
        "newStringValue. removeExercise needs exerciseId and expectedStringValue (the exercise name). " +
        "addExercise needs sectionId and exercise, optionally afterExerciseId. moveExercise needs " +
        "exerciseId and targetSectionId, optionally afterExerciseId. replacePhaseOverride needs " +
        "exerciseId, phase (peak or deload), and either newPhaseOverride or removePhaseOverride: true. " +
        "renameRoutine (schema 3) needs expectedStringValue (the routine's current name, exactly as the " +
        "snapshot shows it) and newStringValue (1 to 100 characters); it takes no exerciseId. A routine " +
        "name sits outside baseContentHash, so expectedStringValue is the only staleness guard a rename " +
        "has and a wrong one is a conflict, not a detail. " +
        "addSection (schema 3) needs section ({ id: a fresh UUID, name }), optionally afterSectionId to " +
        "place it after an existing section rather than at the end. Sections arrive empty; fill one with " +
        "addExercise operations later in the same patch, referencing the id you just generated. " +
        "Operations apply in array order and each sees what the ones before it did, so addSection then " +
        "addExercise into that section is valid, as is addExercise then moveExercise on the exercise you " +
        "just added, and a second renameRoutine reads the name the first one set. " +
        "createRoutine (schema 3) needs routine, and belongs only in a patch whose target is newRoutine, " +
        "as its single operation. " +
        "Ceilings, which a patch may not push past: 50 routines, 50 sections in a routine, and 100 " +
        "exercises in any one section. Beyond the first the next snapshot upload fails whole and the " +
        "coach stops seeing anything; beyond the others a routine stops fitting in a snapshot and drops " +
        "out of view at the next sync. A patch may also not leave a routine with no exercises at all. " +
        "Timed exercises (those with durationSeconds) take replaceTimedDuration, not replaceExerciseReps. " +
        "Base-value operations (replaceExerciseReps, replaceExerciseSets, replaceTimedDuration) change the " +
        "base value only and do not cascade into phaseOverrides: an exercise with a peak or deload override " +
        "for that same field keeps it, which can leave a phase no longer a step up from base. To move a " +
        "phase as well, add a replacePhaseOverride operation for it in the same patch.",
      items: {
        type: "object",
        properties: {
          kind: { type: "string", enum: OPERATION_KINDS },
          exerciseId: {
            ...uuidProperty,
            description:
              "The exercise being changed; it must already exist in the routine, or have been added " +
              "earlier in this same patch. Not used by addExercise, addSection, or renameRoutine.",
          },
          sectionId: { ...uuidProperty, description: "For addExercise: the section to add into." },
          targetSectionId: { ...uuidProperty, description: "For moveExercise: the destination section." },
          afterSectionId: { ...uuidProperty, description: "Optional anchor for addSection: place after this section." },
          afterExerciseId: {
            ...uuidProperty,
            description:
              "Optional anchor for addExercise and moveExercise: place after this exercise. It must be an " +
              "exercise in the section being added to or moved into, and it cannot be the exercise the " +
              "operation is itself adding or moving. Ignored by every other kind.",
          },
          section: sectionProperty,
          phase: { ...phaseProperty, description: "For replacePhaseOverride: peak or deload only." },
          expectedIntValue: {
            type: "integer",
            description:
              "The current value as shown in the snapshot. Checked, not just required: a value that " +
              "does not match is refused. Where an earlier operation in the same patch changed this " +
              "field, give the value that operation left behind.",
          },
          newIntValue: {
            type: "integer",
            description: "The proposed value. Ranges: reps 1-100, sets 1-10, duration 1-3600, rest 0-900.",
          },
          expectedStringValue: {
            type: "string",
            description:
              "The current value as shown in the snapshot: the notes for updateExerciseNotes, the " +
              "exercise name for removeExercise, the routine name for renameRoutine. Checked, and " +
              "read against anything an earlier operation in the same patch changed.",
          },
          newStringValue: { type: "string", maxLength: STRING_BOUNDS.exerciseNotes },
          expectedPhaseOverride: {
            ...phaseOverrideProperty,
            description:
              "The override currently on this exercise for this phase, checked exactly. Omit it when " +
              "the exercise has no override for the phase; an empty object means something different.",
          },
          newPhaseOverride: phaseOverrideProperty,
          removePhaseOverride: { type: "boolean" },
          exercise: exerciseProperty,
          routine: routineProperty,
        },
        required: ["kind"],
        additionalProperties: false,
      },
    },
  },
  // routineId and baseContentHash are required only on the existingRoutine
  // branch, which the description spells out; listing them here would make a
  // valid create look malformed to a client reading the schema.
  required: ["schemaVersion", "rationale", "operations"],
  additionalProperties: false,
};

const TOOLS: ReadonlyArray<ToolDefinition> = [
  {
    name: "get_flow_coach_context",
    requiredScope: "coach:read",
    title: "Get Flow coach context",
    description:
      "Returns a lean summary of the user's current Flow coach context: the contextId " +
      "to use with every other tool, routine summaries (id, name, phase, exercise " +
      "counts, revision hashes), counts of recent strength and cardio activity, any " +
      "coach constraints notes, and a capabilities block. Deliberately does NOT include " +
      "full routine bodies or full workout history - call list_routines/get_routine to " +
      "drill in. Contains no raw HealthKit data.\n\n" +
      "capabilities.patchSchemaVersions and capabilities.operationKinds are what the " +
      "user's Flow build can actually apply, not just what this bridge accepts, so plan " +
      "a restructure against that list rather than discovering the limit by rejection. " +
      "Anything absent from operationKinds cannot be proposed; say so plainly and " +
      "propose the achievable part. capabilities.deviceReported is false when the " +
      "snapshot came from a Flow build too old to declare anything, in which case the " +
      "conservative schema 2 baseline is reported.",
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
    requiredScope: "coach:read",
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
    requiredScope: "coach:read",
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
    requiredScope: "coach:read",
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
    requiredScope: "patch:propose",
    title: "Validate a Flow routine patch",
    description:
      "Validates a candidate FlowRoutinePatch against one exact snapshot WITHOUT " +
      "storing anything: checks the schema version and operation kinds against what " +
      "the user's Flow build reports it can apply, required fields, per-kind required " +
      "fields and value ranges, that routineId " +
      "exists in the snapshot, and that baseContentHash matches the stored content " +
      "hash for that routine. Returns a structured list of problems rather than " +
      "throwing, so a mostly-valid patch can be diagnosed in one call. This is a " +
      "read-only dry run - call create_pending_routine_patch to actually store a " +
      "draft for Flow to review.",
    inputSchema: {
      type: "object",
      properties: {
        contextId: contextIdProperty,
        patch: patchProperty,
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
    requiredScope: "patch:propose",
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
        patch: patchProperty,
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
 * a 202. The caller owns transport concerns: the OAuth token gate, method
 * check, body size limits, and JSON parse errors. grantedScopes is what the
 * grant behind the presented token was authorised for: tools/list shows
 * only tools the token can call, and tools/call refuses the rest.
 */
export async function handleMcpMessage(
  message: unknown,
  domain: DomainFetch,
  grantedScopes: ReadonlyArray<string>,
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
      // Deliberately not `tools: { listChanged: true }`. That capability
      // promises notifications/tools/list_changed, and this server has no
      // channel to deliver one on: every request gets a single JSON response,
      // GET opens no SSE stream, and no session id ties requests together.
      // Advertising it would not make a client refetch after a contract
      // deploy; it would just be a promise nothing here can keep. Stale
      // cached tool schemas are handled operationally instead: the
      // coach-context payload carries a fresh-per-call advisory, and the
      // runbook's deploy steps say when to refresh the connector (#83).
      capabilities: { tools: {} },
      serverInfo: { name: "flow-coach-bridge", version: "0.1.0" },
      instructions: BRIDGE_INSTRUCTIONS,
    });
  }
  if (rpc.method === "ping") return rpcResult(id, {});
  if (rpc.method === "tools/list") {
    return rpcResult(id, {
      tools: TOOLS
        .filter((tool) => grantedScopes.includes(tool.requiredScope))
        .map(({ name, title, description, requiredScope, inputSchema, annotations }) => ({
          name,
          title,
          description,
          inputSchema,
          annotations,
          // OpenAI's MCP host uses per-tool schemes to explain the scope a
          // tool needs and to drive OAuth linking/reauthorisation UX. The
          // Worker still verifies the bearer token and scope server-side.
          securitySchemes: [{ type: "oauth2", scopes: [requiredScope] }],
        })),
    });
  }
  if (rpc.method === "tools/call") {
    const tool = TOOLS.find((candidate) => candidate.name === params.name);
    if (!tool) return { status: 200, body: rpcError(id, -32602, `Unknown tool: ${String(params.name)}.`) };
    if (!grantedScopes.includes(tool.requiredScope)) {
      return { status: 200, body: rpcError(id, -32602, `${tool.name} requires the ${tool.requiredScope} scope, which this connection was not granted.`) };
    }
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
