/**
 * End-to-end smoke test for the ChatGPT Actions facade (issue #46).
 *
 * Starts the real Express server, calls every REST operation with Node's fetch,
 * verifies API-key protection and snapshot correlation, then repeats the same
 * proposal to prove retries do not create duplicate pending patches.
 */
import { randomUUID } from "node:crypto";
import { startServer } from "./server.js";

const PORT = 3941;
const API_KEY = "flow-coach-actions-smoke-key";
const BASE_URL = `http://localhost:${PORT}/actions`;

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

async function call(
  path: string,
  options: RequestInit = {},
  apiKey: string | undefined = API_KEY
): Promise<{ response: Response; body: Record<string, any> }> {
  const headers = new Headers(options.headers);
  if (apiKey) headers.set("X-Flow-Coach-Key", apiKey);
  if (options.body) headers.set("Content-Type", "application/json");
  const response = await fetch(`${BASE_URL}${path}`, { ...options, headers });
  const body = await response.json() as Record<string, any>;
  return { response, body };
}

async function main(): Promise<void> {
  console.log("Flow Coach Actions facade — smoke test");
  const server = startServer(PORT, { actionsApiKey: API_KEY });
  await new Promise((resolve) => setTimeout(resolve, 150));

  try {
    section("Authentication");
    const unauthorized = await call("/coach-context", {}, "");
    ok("missing API key is rejected", unauthorized.response.status === 401);
    const wrongKey = await call("/coach-context", {}, "not-the-key");
    ok("incorrect API key is rejected", wrongKey.response.status === 401);

    section("Coach context");
    const context = await call("/coach-context");
    ok("coach context returns 200", context.response.status === 200);
    ok("coach context is not cacheable", context.response.headers.get("cache-control") === "no-store");
    ok("coach context carries a UUID contextId", typeof context.body.contextId === "string");
    ok("coach context returns two routine summaries", context.body.routines?.length === 2);
    const contextId = context.body.contextId as string;

    section("Snapshot correlation");
    const stale = await call(`/routines?contextId=${randomUUID()}`);
    ok("unknown contextId is rejected", stale.response.status === 409);

    section("Routine drill-down");
    const routines = await call(`/routines?contextId=${contextId}`);
    ok("routine list returns 200", routines.response.status === 200);
    const routineSummary = routines.body.routines?.[0] as {
      id: string;
      contentHash: string;
    } | undefined;
    ok("routine list includes an id and content hash", Boolean(routineSummary?.id && routineSummary?.contentHash));
    const routineResult = await call(`/routines/${routineSummary!.id}?contextId=${contextId}`);
    ok("one routine returns its full body", Array.isArray(routineResult.body.routine?.sections));

    section("Training summary");
    const training = await call(`/training-summary?contextId=${contextId}&strengthLimit=3&cardioLimit=3`);
    ok("training summary returns recent strength entries", training.body.strength?.length === 3);
    ok("training summary returns recent cardio entries", training.body.cardio?.length === 3);
    ok(
      "health-derived metrics are excluded by default",
      training.body.includesHealthMetrics === false &&
        !("appleWatchMetrics" in training.body.strength[0]) &&
        !("averageHeartRate" in training.body.cardio[0])
    );

    const exercise = routineResult.body.routine.sections[0].exercises[0] as {
      id: string;
      sets: number;
    };
    const newSets = exercise.sets === 10 ? 9 : exercise.sets + 1;
    const patch = {
      schemaVersion: 2,
      routineId: routineSummary!.id,
      baseContentHash: routineSummary!.contentHash,
      exportedAt: new Date().toISOString(),
      rationale: "Small fixture-only change for the ChatGPT Actions smoke test.",
      operations: [
        {
          kind: "replaceExerciseSets",
          exerciseId: exercise.id,
          expectedIntValue: exercise.sets,
          newIntValue: newSets,
        },
      ],
    };
    const envelope = JSON.stringify({ contextId, patch });

    section("Patch validation");
    const validation = await call("/patches/validate", { method: "POST", body: envelope });
    ok("valid fixture patch passes validation", validation.response.status === 200 && validation.body.valid === true);

    section("Pending patch creation");
    const created = await call("/pending-patches", { method: "POST", body: envelope });
    ok("first create returns 201", created.response.status === 201);
    ok("first create stores a pending draft", created.body.stored === true && created.body.patch?.status === "pending");
    ok("Actions provenance is derived by the server", created.body.patch?.assistantProvider === "chatgpt-actions");

    const retried = await call("/pending-patches", { method: "POST", body: envelope });
    ok("identical retry returns 200", retried.response.status === 200);
    ok("identical retry is marked duplicate", retried.body.duplicate === true);
    ok("identical retry returns the same patchId", retried.body.patch?.patchId === created.body.patch?.patchId);

    section("Summary");
    console.log(`  ${passCount} passed, ${failCount} failed`);
  } finally {
    await new Promise<void>((resolve, reject) => {
      server.close((error) => error ? reject(error) : resolve());
    });
  }

  process.exit(failCount === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error("Actions smoke test crashed:", error);
  process.exit(1);
});
