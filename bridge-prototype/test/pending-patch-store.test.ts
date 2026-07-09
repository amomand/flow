import { describe, expect, it } from "vitest";
import type { FlowRoutinePatch } from "../src/flow-types.js";
import { PendingPatchStore } from "../src/pending-patch-store.js";

const patch: FlowRoutinePatch = {
  schemaVersion: 2,
  routineId: "D0B696CE-2C78-42E8-9D61-E5DDDD0E0528",
  baseContentHash: "c1-214a4c15b7a3d62b",
  rationale: "Test proposal.",
  operations: [
    {
      kind: "replaceExerciseSets",
      exerciseId: "5DE92253-C398-466D-A67E-DC7C7FE4EA8E",
      expectedIntValue: 3,
      newIntValue: 4,
    },
  ],
};

describe("PendingPatchStore", () => {
  it("returns the existing record for an identical retried proposal", () => {
    const store = new PendingPatchStore();
    const first = store.createOrGet({
      contextId: "context-1",
      patch,
      assistantProvider: "chatgpt-actions",
    });
    const retry = store.createOrGet({
      contextId: "context-1",
      patch: JSON.parse(JSON.stringify(patch)) as FlowRoutinePatch,
      assistantProvider: "chatgpt-actions",
    });

    expect(first.created).toBe(true);
    expect(retry.created).toBe(false);
    expect(retry.record.patchId).toBe(first.record.patchId);
    expect(store.list()).toHaveLength(1);
  });

  it("creates a new record when the patch content changes", () => {
    const store = new PendingPatchStore();
    const first = store.createOrGet({ contextId: "context-1", patch, assistantProvider: "chatgpt-actions" });
    const second = store.createOrGet({
      contextId: "context-1",
      patch: { ...patch, rationale: "A different proposal." },
      assistantProvider: "chatgpt-actions",
    });

    expect(first.created).toBe(true);
    expect(second.created).toBe(true);
    expect(second.record.patchId).not.toBe(first.record.patchId);
    expect(store.list()).toHaveLength(2);
  });
});
