import { timingSafeEqual } from "node:crypto";
import type { Express, NextFunction, Request, Response } from "express";
import { z } from "zod";
import { ContextStore } from "./context-store.js";
import { PendingPatchStore } from "./pending-patch-store.js";
import { validateFlowRoutinePatch } from "./patch-validation.js";

const patchEnvelopeSchema = z.object({
  contextId: z.string().uuid(),
  patch: z.unknown(),
});

export interface ActionsApiOptions {
  contextStore: ContextStore;
  pendingPatchStore: PendingPatchStore;
  apiKey?: string;
}

export function registerActionsApi(app: Express, options: ActionsApiOptions): void {
  app.get("/healthz", (_request, response) => {
    response.json({ ok: true });
  });

  app.use("/actions", noStore, requireApiKey(options.apiKey));

  app.get("/actions/coach-context", (_request, response) => {
    response.json(options.contextStore.getLeanContext());
  });

  app.get("/actions/routines", (request, response) => {
    if (!requireCurrentContext(request, response, options.contextStore)) return;
    response.json({
      contextId: options.contextStore.getContextId(),
      routines: options.contextStore.listRoutineSummaries(),
    });
  });

  app.get("/actions/routines/:routineId", (request, response) => {
    if (!requireCurrentContext(request, response, options.contextStore)) return;
    const routine = options.contextStore.getRoutine(request.params.routineId ?? "");
    if (!routine) {
      response.status(404).json({ error: `No stored routine matches ${request.params.routineId}.` });
      return;
    }
    response.json({ contextId: options.contextStore.getContextId(), routine });
  });

  app.get("/actions/training-summary", (request, response) => {
    if (!requireCurrentContext(request, response, options.contextStore)) return;
    response.json(options.contextStore.getRecentTrainingSummary({
      strengthLimit: parseLimit(request.query.strengthLimit, 5, 10),
      cardioLimit: parseLimit(request.query.cardioLimit, 5, 12),
      includeHealthMetrics: request.query.includeHealthMetrics === "true",
    }));
  });

  app.post("/actions/patches/validate", (request, response) => {
    const envelope = parsePatchEnvelope(request, response);
    if (!envelope) return;
    if (!contextMatches(envelope.contextId, response, options.contextStore)) return;
    response.json(validateFlowRoutinePatch(envelope.patch, options.contextStore));
  });

  app.post("/actions/pending-patches", (request, response) => {
    const envelope = parsePatchEnvelope(request, response);
    if (!envelope) return;
    if (!contextMatches(envelope.contextId, response, options.contextStore)) return;

    const validation = validateFlowRoutinePatch(envelope.patch, options.contextStore);
    if (!validation.valid || !validation.patch) {
      response.status(422).json({ stored: false, valid: false, problems: validation.problems });
      return;
    }

    const outcome = options.pendingPatchStore.createOrGet({
      contextId: envelope.contextId,
      patch: validation.patch,
      assistantProvider: "chatgpt-actions",
    });
    response.status(outcome.created ? 201 : 200).json({
      stored: true,
      duplicate: !outcome.created,
      patch: outcome.record,
      message: "Flow has not applied this draft. Open Flow Coach to preview and decide.",
    });
  });
}

function noStore(_request: Request, response: Response, next: NextFunction): void {
  response.setHeader("Cache-Control", "no-store");
  next();
}

function requireApiKey(expectedKey?: string) {
  return (request: Request, response: Response, next: NextFunction): void => {
    if (!expectedKey) {
      response.status(503).json({ error: "The Actions API is disabled until FLOW_COACH_ACTIONS_API_KEY is set." });
      return;
    }
    const suppliedKey = request.header("x-flow-coach-key") ?? "";
    if (!secureEqual(suppliedKey, expectedKey)) {
      response.status(401).json({ error: "Invalid or missing Flow Coach API key." });
      return;
    }
    next();
  };
}

function secureEqual(left: string, right: string): boolean {
  const leftBytes = Buffer.from(left);
  const rightBytes = Buffer.from(right);
  return leftBytes.length === rightBytes.length && timingSafeEqual(leftBytes, rightBytes);
}

function requireCurrentContext(request: Request, response: Response, contextStore: ContextStore): boolean {
  const contextId = typeof request.query.contextId === "string" ? request.query.contextId : "";
  if (!contextId) {
    response.status(400).json({ error: "contextId is required." });
    return false;
  }
  return contextMatches(contextId, response, contextStore);
}

function contextMatches(contextId: string, response: Response, contextStore: ContextStore): boolean {
  if (!contextStore.isCurrentContextId(contextId)) {
    response.status(409).json({
      error: "That coach snapshot is no longer current in this prototype. Read coach context again before proposing a patch.",
      currentContextId: contextStore.getContextId(),
    });
    return false;
  }
  return true;
}

function parsePatchEnvelope(
  request: Request,
  response: Response
): z.infer<typeof patchEnvelopeSchema> | undefined {
  const parsed = patchEnvelopeSchema.safeParse(request.body);
  if (!parsed.success) {
    response.status(400).json({
      error: "Request body must contain contextId and patch.",
      problems: parsed.error.issues.map((issue) => ({ path: issue.path.join("."), message: issue.message })),
    });
    return undefined;
  }
  return parsed.data;
}

function parseLimit(value: unknown, fallback: number, maximum: number): number {
  if (typeof value !== "string") return fallback;
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(Math.max(parsed, 1), maximum);
}
