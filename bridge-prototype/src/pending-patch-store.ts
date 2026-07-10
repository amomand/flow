/**
 * In-memory pending-patch mailbox.
 *
 * Prototype-only storage; the lifecycle fields and status values are the
 * part meant to carry forward into #37/#38 (see the issue's "Give the
 * pending-patch store the lifecycle fields..." scope line).
 *
 * The bridge is a mailbox, not an authority: storing a patch here never
 * touches a routine. Flow pulls pending patches, previews them locally with
 * `FlowRoutinePatcher`, and only Flow's explicit user confirmation applies
 * anything to `routines.json`.
 */
import { createHash, randomUUID } from "node:crypto";
import type { FlowRoutinePatch } from "./flow-types.js";

export type PendingPatchStatus =
  | "pending"
  | "pulled"
  | "applied"
  | "rejected"
  | "stale"
  | "expired";

export interface PendingPatchRecord {
  patchId: string;
  /** Opaque identity of the coach snapshot this patch was proposed against. */
  contextId: string;
  routineId: string;
  baseContentHash: string;
  createdAt: string;
  expiresAt: string;
  status: PendingPatchStatus;
  /** Server-derived adapter provenance, e.g. "mcp" or "chatgpt-actions". */
  assistantProvider: string;
  rationale: string;
  /** The full patch payload, kept so Flow can pull-and-preview it without a second round trip. */
  patch: FlowRoutinePatch;
}

export interface CreatePendingPatchOutcome {
  record: PendingPatchRecord;
  created: boolean;
}

const DEFAULT_TTL_MS = 24 * 60 * 60 * 1000; // 24 hours — generous for a prototype; a real bridge should tune this.

export class PendingPatchStore {
  private records = new Map<string, PendingPatchRecord>();
  private patchIdByProposalKey = new Map<string, string>();

  createOrGet(params: {
    contextId: string;
    patch: FlowRoutinePatch;
    assistantProvider: string;
    idempotencyKey?: string;
    now?: Date;
    ttlMs?: number;
  }): CreatePendingPatchOutcome {
    const proposalKey = params.idempotencyKey?.trim() || proposalDigest(params);
    const existingPatchId = this.patchIdByProposalKey.get(proposalKey);
    const existing = existingPatchId ? this.records.get(existingPatchId) : undefined;
    if (existing) {
      return { record: existing, created: false };
    }

    const now = params.now ?? new Date();
    const expiresAt = new Date(now.getTime() + (params.ttlMs ?? DEFAULT_TTL_MS));
    const record: PendingPatchRecord = {
      patchId: randomUUID(),
      contextId: params.contextId,
      routineId: params.patch.routineId,
      baseContentHash: params.patch.baseContentHash,
      createdAt: now.toISOString(),
      expiresAt: expiresAt.toISOString(),
      status: "pending",
      assistantProvider: params.assistantProvider,
      rationale: params.patch.rationale,
      patch: params.patch,
    };
    this.records.set(record.patchId, record);
    this.patchIdByProposalKey.set(proposalKey, record.patchId);
    return { record, created: true };
  }

  create(params: {
    contextId: string;
    patch: FlowRoutinePatch;
    assistantProvider: string;
    now?: Date;
    ttlMs?: number;
  }): PendingPatchRecord {
    return this.createOrGet(params).record;
  }

  list(): PendingPatchRecord[] {
    return Array.from(this.records.values()).sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  }

  get(patchId: string): PendingPatchRecord | undefined {
    return this.records.get(patchId);
  }
}

function proposalDigest(params: {
  contextId: string;
  patch: FlowRoutinePatch;
  assistantProvider: string;
}): string {
  return createHash("sha256")
    .update(params.contextId)
    .update("\0")
    .update(params.assistantProvider)
    .update("\0")
    .update(canonicalJSON(params.patch))
    .digest("hex");
}

function canonicalJSON(value: unknown): string {
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJSON).join(",")}]`;
  }
  if (value !== null && typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>)
      .filter(([, entry]) => entry !== undefined)
      .sort(([left], [right]) => left.localeCompare(right));
    return `{${entries.map(([key, entry]) => `${JSON.stringify(key)}:${canonicalJSON(entry)}`).join(",")}}`;
  }
  return JSON.stringify(value) ?? "null";
}
