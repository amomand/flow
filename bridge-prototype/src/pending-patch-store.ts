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
import { randomUUID } from "node:crypto";
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
  /** Identifies which coach context this patch was proposed against (its generatedAt, as a stable id). */
  contextId: string;
  routineId: string;
  baseContentHash: string;
  createdAt: string;
  expiresAt: string;
  status: PendingPatchStatus;
  /** Which assistant/connector proposed this patch, e.g. "claude", "chatgpt". Free text, not an enum — new providers should not need a schema change. */
  assistantProvider: string;
  rationale: string;
  /** The full patch payload, kept so Flow can pull-and-preview it without a second round trip. */
  patch: FlowRoutinePatch;
}

const DEFAULT_TTL_MS = 24 * 60 * 60 * 1000; // 24 hours — generous for a prototype; a real bridge should tune this.

export class PendingPatchStore {
  private records = new Map<string, PendingPatchRecord>();

  create(params: {
    contextId: string;
    patch: FlowRoutinePatch;
    assistantProvider: string;
    now?: Date;
    ttlMs?: number;
  }): PendingPatchRecord {
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
    return record;
  }

  list(): PendingPatchRecord[] {
    return Array.from(this.records.values()).sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  }

  get(patchId: string): PendingPatchRecord | undefined {
    return this.records.get(patchId);
  }
}
