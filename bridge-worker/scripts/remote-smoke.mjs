import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const baseUrl = (process.argv[2] ?? process.env.FLOW_COACH_BASE_URL ?? "").replace(/\/$/, "");
const actionsSecret = process.env.FLOW_COACH_ACTIONS_SECRET;
const deviceSecret = process.env.FLOW_COACH_DEVICE_SECRET;
const keepFixture = process.env.FLOW_COACH_KEEP_FIXTURE === "true";

const isLocalUrl = baseUrl.startsWith("http://127.0.0.1:") || baseUrl.startsWith("http://localhost:");
if (!baseUrl.startsWith("https://") && !isLocalUrl) {
  fail("Pass the deployed HTTPS Worker URL (or a localhost URL for local verification) as the first argument or FLOW_COACH_BASE_URL.");
}
if (!actionsSecret || !deviceSecret) {
  fail("Set FLOW_COACH_ACTIONS_SECRET and FLOW_COACH_DEVICE_SECRET in the current shell.");
}
if (actionsSecret === deviceSecret) {
  fail("The Actions and device secrets must be different.");
}

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const fixturePath = resolve(scriptDirectory, "../../bridge-prototype/fixtures/coach-context.json");
const fixture = JSON.parse(await readFile(fixturePath, "utf8"));
const now = Date.now();
const contextId = crypto.randomUUID();
const context = {
  ...fixture,
  generatedAt: new Date(now).toISOString(),
  recentStrengthSummary: fixture.recentStrengthSummary.map(({ appleWatchMetrics: _, ...entry }) => entry),
  recentCardioSummary: [],
  constraints: { notes: "Synthetic fixture data only; this is not a real person's training history." },
};
const snapshot = {
  contextId,
  createdAt: new Date(now).toISOString(),
  expiresAt: new Date(now + 30 * 60 * 1000).toISOString(),
  sharingProfile: { schemaVersion: 1, dataTiers: ["routines", "strengthHistory"] },
  context,
};

let uploaded = false;
let completed = false;

try {
  await expectStatus("health check", await request("/healthz"), 200);
  await expectStatus("missing Actions credential is rejected", await request("/actions/coach-context"), 401);
  await expectStatus(
    "Actions credential is rejected by the device edge",
    await request("/device/pending-patches", { secret: actionsSecret }),
    401,
  );

  const upload = await request("/device/snapshots", {
    method: "PUT",
    secret: deviceSecret,
    body: snapshot,
  });
  await expectStatus("upload lean fixture snapshot", upload, 201);
  uploaded = true;

  const summary = await json(await expectStatus(
    "read coach context",
    await request("/actions/coach-context", { secret: actionsSecret }),
    200,
  ));
  assert(summary.contextId === contextId, "coach context returned the fixture contextId");
  assert(summary.recentCardioCount === 0, "coach context contains no cardio history");
  assert(summary.sharingProfile?.dataTiers?.includes("healthMetrics") === false, "health metrics are not shared");

  const routines = await json(await expectStatus(
    "list fixture routines",
    await request(`/actions/routines?contextId=${encodeURIComponent(contextId)}`, { secret: actionsSecret }),
    200,
  ));
  assert(routines.routines?.length === context.routines.length, "all fixture routines are available");

  const routineSummary = routines.routines[0];
  const routineResult = await json(await expectStatus(
    "read one complete fixture routine",
    await request(`/actions/routines/${encodeURIComponent(routineSummary.id)}?contextId=${encodeURIComponent(contextId)}`, {
      secret: actionsSecret,
    }),
    200,
  ));
  const exercise = routineResult.routine.sections[0].exercises[0];

  const training = await json(await expectStatus(
    "read non-health fixture training summaries",
    await request(`/actions/training-summary?contextId=${encodeURIComponent(contextId)}&strengthLimit=3&cardioLimit=3`, {
      secret: actionsSecret,
    }),
    200,
  ));
  assert(training.recentStrengthSummary?.length > 0, "strength summaries are available");
  assert(training.recentCardioSummary?.length === 0, "cardio summaries remain excluded");
  assert(
    training.recentStrengthSummary.every((entry) => entry.appleWatchMetrics === undefined),
    "health-derived strength fields remain excluded",
  );

  const patch = {
    schemaVersion: 2,
    routineId: routineSummary.id,
    baseContentHash: routineSummary.contentHash,
    exportedAt: new Date().toISOString(),
    rationale: "Synthetic deployment smoke test; increase the first fixture exercise by one set.",
    operations: [{
      kind: "replaceExerciseSets",
      exerciseId: exercise.id,
      expectedIntValue: exercise.sets,
      newIntValue: exercise.sets === 10 ? 9 : exercise.sets + 1,
    }],
  };
  const envelope = { contextId, patch };

  const validation = await json(await expectStatus(
    "validate a fixture patch",
    await request("/actions/patches/validate", { method: "POST", secret: actionsSecret, body: envelope }),
    200,
  ));
  assert(validation.valid === true, "fixture patch passes server validation");

  const created = await json(await expectStatus(
    "store a fixture draft",
    await request("/actions/pending-patches", {
      method: "POST",
      secret: actionsSecret,
      body: envelope,
      headers: { "idempotency-key": `remote-smoke-${contextId}` },
    }),
    201,
  ));
  assert(created.patch?.provenance === "chatgpt-actions", "draft provenance is derived by the Worker");
  assert(created.message?.includes("has not applied"), "response preserves the local review boundary");

  const pending = await json(await expectStatus(
    "pull the fixture draft through the device edge",
    await request("/device/pending-patches", { secret: deviceSecret }),
    200,
  ));
  assert(pending.patches?.some((entry) => entry.patchId === created.patch.patchId), "device edge sees the fixture draft");

  completed = true;
  console.log("\nRemote Flow Coach smoke test passed.");
  if (keepFixture) {
    console.log(`KEEP  fixture contextId ${contextId}`);
    console.log(`KEEP  fixture expires at ${snapshot.expiresAt}`);
    console.log("KEEP  delete the snapshot through the device edge when the coach client test is finished");
  }
} finally {
  if (uploaded && !(completed && keepFixture)) {
    const cleanup = await request(`/device/snapshots/${encodeURIComponent(contextId)}`, {
      method: "DELETE",
      secret: deviceSecret,
    });
    if (cleanup.status === 200) console.log("PASS  removed fixture snapshot and its draft");
    else console.error(`WARN  fixture cleanup returned ${cleanup.status}; delete context ${contextId} manually`);
  }
}

async function request(path, { method = "GET", secret, body, headers = {} } = {}) {
  const requestHeaders = new Headers(headers);
  if (secret) requestHeaders.set("authorization", `Bearer ${secret}`);
  if (body !== undefined) requestHeaders.set("content-type", "application/json");
  return fetch(`${baseUrl}${path}`, {
    method,
    headers: requestHeaders,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

async function expectStatus(label, response, expected) {
  if (response.status !== expected) {
    const detail = await response.text();
    throw new Error(`${label}: expected ${expected}, received ${response.status}: ${detail}`);
  }
  console.log(`PASS  ${label}`);
  return response;
}

async function json(response) {
  return response.json();
}

function assert(condition, label) {
  if (!condition) throw new Error(`Assertion failed: ${label}`);
  console.log(`PASS  ${label}`);
}

function fail(message) {
  console.error(message);
  process.exit(1);
}
