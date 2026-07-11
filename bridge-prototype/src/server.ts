/**
 * Flow Coach bridge prototype — MCP server (issue #36, phase 5).
 *
 * Trust boundary (also declared as the server-level `instructions` below,
 * per the issue's requirement so assistants see it without per-tool
 * repetition):
 *
 *   The assistant PROPOSES routine edits. It never applies them. Flow is the
 *   sole authority for preview, confirmation, persistence, and rollback of
 *   routines.json. This bridge is a low-authority mailbox/cache/API facade:
 *   it stores the latest coach context Flow pushed, and stores pending
 *   patches for Flow to pull, preview, and decide on. It never mutates a
 *   routine directly, never talks to HealthKit, and never becomes the
 *   source of truth for routine content.
 *
 * Six tools, exactly as named in the issue:
 *   get_flow_coach_context, list_routines, get_routine,
 *   validate_flow_routine_patch, create_pending_routine_patch,
 *   list_pending_patches.
 */
import { randomUUID } from "node:crypto";
import type { Server as HTTPServer } from "node:http";
import express from "express";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";
import { registerActionsApi } from "./actions-api.js";
import { ContextStore } from "./context-store.js";
import { PendingPatchStore } from "./pending-patch-store.js";
import { validateFlowRoutinePatch } from "./patch-validation.js";

const BRIDGE_INSTRUCTIONS = `Flow Coach bridge (prototype, issue #36).

This server exposes read access to a Flow user's strength routines and
recent training summary, plus a mailbox for proposed routine edits.

Trust boundary — read this before calling create_pending_routine_patch:
- You may PROPOSE a routine edit by calling create_pending_routine_patch.
  That call only stores a draft. It never changes the user's routine.
- Flow (the iOS app) is the sole authority for previewing, confirming,
  persisting, and rolling back routine changes. The user must open Flow and
  explicitly apply a pending patch before anything changes.
- This bridge does not own HealthKit access and never receives raw
  HealthKit data (no route points, no per-sample heart rate, no HealthKit
  object IDs). Cardio and strength context here is pre-aggregated by Flow.
- Routine hashes (c1-.../s1-...) are opaque revision identifiers relayed
  from Flow, not an authentication or integrity mechanism. Treat them as
  strings to copy, not values to compute.
- get_flow_coach_context is intentionally lean (summaries and counts, not
  full history or full routine bodies). Use list_routines and get_routine
  to drill into routine structure before proposing a patch.`;

function server(contextStore: ContextStore, pendingPatchStore: PendingPatchStore): McpServer {
  const mcp = new McpServer(
    {
      name: "flow-coach-bridge-prototype",
      version: "0.1.0",
    },
    {
      instructions: BRIDGE_INSTRUCTIONS,
      capabilities: {
        tools: {},
      },
    }
  );

  mcp.registerTool(
    "get_flow_coach_context",
    {
      title: "Get Flow coach context",
      description:
        "Returns a lean summary of the user's current Flow coach context: routine " +
        "summaries (id, name, phase, exercise counts, revision hashes), counts and " +
        "short digests of recent strength and cardio activity, and any coach " +
        "constraints notes. Deliberately does NOT include full routine bodies or full " +
        "workout history — call list_routines/get_routine to drill in. Contains no " +
        "raw HealthKit data.",
      inputSchema: {},
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async () => {
      const lean = contextStore.getLeanContext();
      return {
        content: [{ type: "text", text: JSON.stringify(lean, null, 2) }],
        structuredContent: lean as unknown as Record<string, unknown>,
      };
    }
  );

  mcp.registerTool(
    "list_routines",
    {
      title: "List Flow routines",
      description:
        "Lists every stored routine with id, name, current phase, revision hashes, " +
        "and exercise counts. Does not include exercise-level detail — call " +
        "get_routine with a routine id for the full body.",
      inputSchema: {},
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async () => {
      const routines = contextStore.listRoutineSummaries();
      return {
        content: [{ type: "text", text: JSON.stringify(routines, null, 2) }],
        structuredContent: { routines } as unknown as Record<string, unknown>,
      };
    }
  );

  mcp.registerTool(
    "get_routine",
    {
      title: "Get one Flow routine",
      description:
        "Returns the full body of one routine by id, in the same JSON shape Flow " +
        "itself uses (Routine: id, name, currentPhase, sections[].exercises[] with " +
        "sets/reps/duration/rest/notes/phaseOverrides). Use this before proposing a " +
        "patch so exerciseId/sectionId values in the patch are correct.",
      inputSchema: {
        routineId: z.string().uuid().describe("The routine id from list_routines or get_flow_coach_context."),
      },
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async ({ routineId }) => {
      const routine = contextStore.getRoutine(routineId);
      if (!routine) {
        return {
          isError: true,
          content: [{ type: "text", text: `No stored routine matches ${routineId}.` }],
        };
      }
      return {
        content: [{ type: "text", text: JSON.stringify(routine, null, 2) }],
        structuredContent: routine as unknown as Record<string, unknown>,
      };
    }
  );

  mcp.registerTool(
    "validate_flow_routine_patch",
    {
      title: "Validate a Flow routine patch",
      description:
        "Validates a candidate FlowRoutinePatch (schema 2) against the stored coach " +
        "context WITHOUT storing anything: checks schema version, required fields, " +
        "known operation kinds, per-kind required fields and value ranges (reps " +
        "1-100, sets 1-10, duration 1-3600, rest 0-900, notes <=500 chars), that " +
        "routineId exists, and that baseContentHash matches the stored content hash " +
        "for that routine. Returns a structured list of problems rather than " +
        "throwing, so a mostly-valid patch can be diagnosed in one call. This is a " +
        "read-only dry run — call create_pending_routine_patch to actually store a " +
        "draft for Flow to review.",
      inputSchema: {
        patch: z.unknown().describe("A candidate FlowRoutinePatch JSON object, schema version 2."),
      },
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async ({ patch }) => {
      const result = validateFlowRoutinePatch(patch, contextStore);
      return {
        content: [{ type: "text", text: JSON.stringify({ valid: result.valid, problems: result.problems }, null, 2) }],
        structuredContent: { valid: result.valid, problems: result.problems } as unknown as Record<string, unknown>,
      };
    }
  );

  mcp.registerTool(
    "create_pending_routine_patch",
    {
      title: "Propose a Flow routine patch",
      description:
        "Stores a DRAFT routine patch for Flow to review. This tool does not modify " +
        "any routine — it only writes an entry to a pending-patch mailbox that the " +
        "Flow app later pulls, previews as a diff, and applies only after the user " +
        "explicitly confirms inside Flow. Runs the same schema/hash-shape validation " +
        "as validate_flow_routine_patch first and rejects garbage (bad schema " +
        "version, unknown routine, stale or malformed baseContentHash, out-of-range " +
        "values) before storing anything; Flow remains the sole authority for " +
        "semantic validation, preview, and apply. Identical retries reuse the same " +
        "pending patch record (idempotent) and never delete or overwrite routine data " +
        "(not destructive).",
      inputSchema: {
        patch: z.unknown().describe("The candidate FlowRoutinePatch JSON object, schema version 2."),
      },
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async ({ patch }) => {
      const result = validateFlowRoutinePatch(patch, contextStore);
      if (!result.valid || !result.patch) {
        return {
          isError: true,
          content: [
            {
              type: "text",
              text:
                "Patch rejected before storing (no draft was created):\n" +
                JSON.stringify(result.problems, null, 2),
            },
          ],
          structuredContent: { stored: false, problems: result.problems } as unknown as Record<string, unknown>,
        };
      }

      const contextId = contextStore.getContextId();
      const outcome = pendingPatchStore.createOrGet({
        contextId,
        patch: result.patch,
        assistantProvider: "mcp",
      });
      const record = outcome.record;

      return {
        content: [
          {
            type: "text",
            text:
              `${outcome.created ? "Stored" : "Reused"} pending patch ${record.patchId} for routine ${record.routineId} ` +
              `(status: ${record.status}, expires ${record.expiresAt}). ` +
              "Flow has NOT applied this yet — open Flow Coach to preview and confirm it.",
          },
        ],
        structuredContent: { stored: true, duplicate: !outcome.created, patch: record } as unknown as Record<string, unknown>,
      };
    }
  );

  mcp.registerTool(
    "list_pending_patches",
    {
      title: "List pending Flow routine patches",
      description:
        "Lists every pending patch stored by create_pending_routine_patch, with " +
        "lifecycle fields (patchId, contextId, routineId, baseContentHash, " +
        "createdAt, expiresAt, status, assistantProvider, rationale). Read-only; " +
        "does not change any patch's status. Flow itself transitions status as it " +
        "pulls, applies, or rejects a patch.",
      inputSchema: {},
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async () => {
      const records = pendingPatchStore.list();
      return {
        content: [{ type: "text", text: JSON.stringify(records, null, 2) }],
        structuredContent: { patches: records } as unknown as Record<string, unknown>,
      };
    }
  );

  return mcp;
}

/**
 * Starts the Streamable HTTP server. Stateless-per-request McpServer
 * instances would lose the in-memory stores between calls, so instead we
 * keep one McpServer + one stateful transport per HTTP session, following
 * the SDK's documented stateful pattern (session id issued on initialize,
 * reused for subsequent requests).
 */
export interface BridgeServerOptions {
  contextStore?: ContextStore;
  pendingPatchStore?: PendingPatchStore;
  actionsApiKey?: string;
}

export function createApp(options: BridgeServerOptions = {}): ReturnType<typeof express> {
  const contextStore = options.contextStore ?? new ContextStore();
  const pendingPatchStore = options.pendingPatchStore ?? new PendingPatchStore();
  const app = express();
  app.use(express.json({ limit: "100kb" }));
  registerActionsApi(app, {
    contextStore,
    pendingPatchStore,
    apiKey: options.actionsApiKey,
  });

  const transports = new Map<string, StreamableHTTPServerTransport>();

  app.post("/mcp", async (req, res) => {
    const sessionId = req.header("mcp-session-id");
    let transport = sessionId ? transports.get(sessionId) : undefined;

    if (!transport) {
      transport = new StreamableHTTPServerTransport({
        sessionIdGenerator: () => randomUUID(),
        onsessioninitialized: (id) => {
          transports.set(id, transport!);
        },
      });
      transport.onclose = () => {
        if (transport!.sessionId) {
          transports.delete(transport!.sessionId);
        }
      };
      const mcp = server(contextStore, pendingPatchStore);
      await mcp.connect(transport);
    }

    await transport.handleRequest(req, res, req.body);
  });

  app.get("/mcp", async (req, res) => {
    const sessionId = req.header("mcp-session-id");
    const transport = sessionId ? transports.get(sessionId) : undefined;
    if (!transport) {
      res.status(400).json({ error: "Unknown or missing mcp-session-id." });
      return;
    }
    await transport.handleRequest(req, res);
  });

  app.delete("/mcp", async (req, res) => {
    const sessionId = req.header("mcp-session-id");
    const transport = sessionId ? transports.get(sessionId) : undefined;
    if (!transport) {
      res.status(400).json({ error: "Unknown or missing mcp-session-id." });
      return;
    }
    await transport.handleRequest(req, res);
  });

  return app;
}

export function startServer(port: number, options: BridgeServerOptions = {}): HTTPServer {
  const app = createApp(options);
  return app.listen(port, () => {
    console.log(`Flow Coach bridge prototype listening on http://localhost:${port}/mcp`);
    console.log(`Flow Coach Actions facade listening on http://localhost:${port}/actions`);
  });
}

const isMain = process.argv[1] && import.meta.url === `file://${process.argv[1]}`;
if (isMain) {
  const port = Number(process.env.PORT ?? 3939);
  startServer(port, { actionsApiKey: process.env.FLOW_COACH_ACTIONS_API_KEY });
}
