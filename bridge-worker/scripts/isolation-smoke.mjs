/**
 * Two-environment isolation proof (#38, and the ADR's deploy-time isolation
 * test). Run once against the deployed pair, with fixture data only, before
 * either phone pairs and after any credential rotation.
 *
 * It proves the things that would matter most if they were wrong: that no
 * credential works anywhere except its own edge in its own deployment, that
 * neither mailbox can read or resolve the other's records, and that deleting
 * everything in one leaves the other untouched.
 *
 * Usage:
 *   export FLOW_COACH_PRIMARY_ACTIONS_SECRET=... FLOW_COACH_PRIMARY_DEVICE_SECRET=...
 *   export FLOW_COACH_PARTNER_ACTIONS_SECRET=... FLOW_COACH_PARTNER_DEVICE_SECRET=...
 *   node scripts/isolation-smoke.mjs https://<primary-host> https://<partner-host>
 */
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const [primaryUrl, partnerUrl] = process.argv.slice(2).map((value) => (value ?? "").replace(/\/$/, ""));

const env = {
  primaryActions: process.env.FLOW_COACH_PRIMARY_ACTIONS_SECRET,
  primaryDevice: process.env.FLOW_COACH_PRIMARY_DEVICE_SECRET,
  partnerActions: process.env.FLOW_COACH_PARTNER_ACTIONS_SECRET,
  partnerDevice: process.env.FLOW_COACH_PARTNER_DEVICE_SECRET,
};

if (!primaryUrl || !partnerUrl) {
  fail("Pass both deployed HTTPS URLs: node scripts/isolation-smoke.mjs <primary> <partner>");
}
if (primaryUrl === partnerUrl) {
  fail("The two environments must have different hostnames; isolation cannot be proved against one deployment.");
}
for (const [name, value] of Object.entries(env)) {
  if (!value) fail(`Missing ${name} secret in the environment. See the header of this script.`);
}
const distinct = new Set(Object.values(env));
if (distinct.size !== 4) {
  fail("All four credentials must be different values. Reusing one across edges or people defeats the boundary.");
}

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const fixture = JSON.parse(
  await readFile(resolve(scriptDirectory, "../../bridge-prototype/fixtures/coach-context.json"), "utf8")
);

const environments = {
  primary: { url: primaryUrl, actions: env.primaryActions, device: env.primaryDevice },
  partner: { url: partnerUrl, actions: env.partnerActions, device: env.partnerDevice },
};

/** Fixture snapshots are deliberately different so a crossed read is obvious. */
const snapshots = {
  primary: makeSnapshot("PRIMARY fixture only. Synthetic data; not a real person's training history."),
  partner: makeSnapshot("PARTNER fixture only. Synthetic data; not a real person's training history."),
};

let uploaded = [];

try {
  // 1. Both deployments are up, and neither serves the MCP edge anonymously.
  for (const [name, target] of Object.entries(environments)) {
    await expect(`${name}: health check`, await fetch(`${target.url}/healthz`), 200);
    await expect(
      `${name}: MCP edge refuses a tokenless call`,
      await fetch(`${target.url}/mcp`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "ping" }),
      }),
      401
    );
    await expect(
      `${name}: Actions edge refuses an anonymous read`,
      await call(target.url, "/actions/coach-context"),
      401
    );
    const discovery = await (await fetch(`${target.url}/.well-known/oauth-authorization-server`)).json();
    assert(
      Array.isArray(discovery.scopes_supported) && discovery.scopes_supported.includes("patch:propose"),
      `${name}: OAuth discovery advertises the bridge scopes`
    );
  }

  // 2. Every credential is rejected by every boundary except its own.
  const crossings = [
    ["primary Actions secret", "partner", env.primaryActions, "/actions/coach-context"],
    ["partner Actions secret", "primary", env.partnerActions, "/actions/coach-context"],
    ["primary device secret", "partner", env.primaryDevice, "/device/pending-patches"],
    ["partner device secret", "primary", env.partnerDevice, "/device/pending-patches"],
  ];
  for (const [label, target, secret, path] of crossings) {
    await expect(
      `${label} is rejected by ${target}`,
      await call(environments[target].url, path, { secret }),
      401
    );
  }

  const edgeMixes = [
    ["primary", env.primaryActions, "/device/pending-patches", "Actions secret cannot call device routes"],
    ["primary", env.primaryDevice, "/actions/coach-context", "device secret cannot call Actions routes"],
    ["partner", env.partnerActions, "/device/pending-patches", "Actions secret cannot call device routes"],
    ["partner", env.partnerDevice, "/actions/coach-context", "device secret cannot call Actions routes"],
  ];
  for (const [name, secret, path, label] of edgeMixes) {
    await expect(`${name}: ${label}`, await call(environments[name].url, path, { secret }), 401);
  }

  // 3. Each deployment stores its own fixture snapshot.
  for (const [name, target] of Object.entries(environments)) {
    await expect(
      `${name}: uploads its own fixture snapshot`,
      await call(target.url, "/device/snapshots", { method: "PUT", secret: target.device, body: snapshots[name] }),
      201
    );
    uploaded.push(name);
  }

  // 4. Each Actions edge reads only its own snapshot, and cannot resolve the
  //    other's contextId even though it now knows the identifier.
  for (const [name, target] of Object.entries(environments)) {
    const other = name === "primary" ? "partner" : "primary";
    const summary = await json(
      await expect(
        `${name}: reads its own coach context`,
        await call(target.url, "/actions/coach-context", { secret: target.actions }),
        200
      )
    );
    assert(summary.contextId === snapshots[name].contextId, `${name}: read returned its own contextId`);
    assert(
      summary.constraints?.notes?.startsWith(name.toUpperCase()),
      `${name}: read returned its own fixture body`
    );
    await expect(
      `${name}: cannot resolve ${other}'s contextId`,
      await call(
        target.url,
        `/actions/routines?contextId=${encodeURIComponent(snapshots[other].contextId)}`,
        { secret: target.actions }
      ),
      404
    );
  }

  // 5. A proposal created in one mailbox appears only there.
  const created = {};
  for (const [name, target] of Object.entries(environments)) {
    const routineId = fixture.routines[0].id;
    const exercise = fixture.routines[0].sections[0].exercises[0];
    const envelope = {
      contextId: snapshots[name].contextId,
      patch: {
        schemaVersion: 2,
        routineId,
        baseContentHash: fixture.routineContentHashByRoutineId[routineId],
        rationale: `Isolation smoke test in ${name}; fixture data only.`,
        operations: [
          {
            kind: "replaceExerciseSets",
            exerciseId: exercise.id,
            expectedIntValue: exercise.sets,
            newIntValue: exercise.sets === 10 ? 9 : exercise.sets + 1,
          },
        ],
      },
    };
    const response = await json(
      await expect(
        `${name}: stores a fixture draft`,
        await call(target.url, "/actions/pending-patches", {
          method: "POST",
          secret: target.actions,
          body: envelope,
          headers: { "idempotency-key": `isolation-${name}-${snapshots[name].contextId}` },
        }),
        201
      )
    );
    created[name] = response.patch.patchId;

    // Retry-safety: the identical call returns the same record, not a second one.
    const retry = await json(
      await expect(
        `${name}: an identical retry is idempotent`,
        await call(target.url, "/actions/pending-patches", {
          method: "POST",
          secret: target.actions,
          body: envelope,
          headers: { "idempotency-key": `isolation-${name}-${snapshots[name].contextId}` },
        }),
        200
      )
    );
    assert(retry.patch.patchId === created[name], `${name}: retry returned the original patchId`);
  }

  for (const [name, target] of Object.entries(environments)) {
    const other = name === "primary" ? "partner" : "primary";
    const pending = await json(
      await expect(
        `${name}: pulls its own draft`,
        await call(target.url, "/device/pending-patches", { secret: target.device }),
        200
      )
    );
    const ids = (pending.patches ?? []).map((entry) => entry.patchId);
    assert(ids.includes(created[name]), `${name}: sees its own draft`);
    assert(!ids.includes(created[other]), `${name}: does not see ${other}'s draft`);
    assert(ids.length === 1, `${name}: sees exactly one draft`);

    // An acknowledgement for the other mailbox's record must not be accepted.
    await expect(
      `${name}: cannot acknowledge ${other}'s draft`,
      await call(target.url, `/device/pending-patches/${created[other]}/ack`, {
        method: "POST",
        secret: target.device,
        body: { status: "applied" },
      }),
      404
    );

    await expect(
      `${name}: acknowledges its own draft as pulled`,
      await call(target.url, `/device/pending-patches/${created[name]}/ack`, {
        method: "POST",
        secret: target.device,
        body: { status: "pulled" },
      }),
      200
    );
  }

  // 6. Deleting one snapshot in one mailbox leaves the other untouched.
  await expect(
    "primary: deletes its own snapshot",
    await call(primaryUrl, `/device/snapshots/${snapshots.primary.contextId}`, {
      method: "DELETE",
      secret: env.primaryDevice,
    }),
    200
  );
  uploaded = uploaded.filter((name) => name !== "primary");
  const partnerAfterPrimaryDelete = await json(
    await expect(
      "partner: still holds its own snapshot",
      await call(partnerUrl, "/actions/coach-context", { secret: env.partnerActions }),
      200
    )
  );
  assert(
    partnerAfterPrimaryDelete.contextId === snapshots.partner.contextId,
    "partner: snapshot survived a delete in primary"
  );

  // 7. Delete-all is scoped to the authenticated deployment.
  await expect(
    "primary: deletes all of its own data",
    await call(primaryUrl, "/device/data", { method: "DELETE", secret: env.primaryDevice }),
    200
  );
  const partnerDrafts = await json(
    await expect(
      "partner: is unaffected by primary's delete-all",
      await call(partnerUrl, "/device/pending-patches", { secret: env.partnerDevice }),
      200
    )
  );
  assert(
    (partnerDrafts.patches ?? []).some((entry) => entry.patchId === created.partner),
    "partner: still holds its own draft after primary was wiped"
  );

  console.log("\nIsolation smoke test passed. Both mailboxes are separately authenticated and cannot reach each other.");
} finally {
  // Never leave fixture data behind: the next thing to touch these mailboxes
  // should be real pairing.
  for (const name of uploaded) {
    const target = environments[name];
    const cleanup = await call(target.url, "/device/data", { method: "DELETE", secret: target.device });
    if (cleanup.status === 200) console.log(`PASS  cleaned up all fixture data in ${name}`);
    else console.error(`WARN  ${name} cleanup returned ${cleanup.status}; delete its data manually`);
  }
  const finalPrimary = await call(primaryUrl, "/device/data", { method: "DELETE", secret: env.primaryDevice });
  if (finalPrimary.status !== 200) {
    console.error(`WARN  primary final cleanup returned ${finalPrimary.status}; check it manually`);
  }
}

function makeSnapshot(notes) {
  const now = Date.now();
  return {
    contextId: crypto.randomUUID(),
    createdAt: new Date(now).toISOString(),
    expiresAt: new Date(now + 30 * 60 * 1000).toISOString(),
    sharingProfile: { schemaVersion: 1, dataTiers: ["routines", "strengthHistory"] },
    context: {
      ...fixture,
      generatedAt: new Date(now).toISOString(),
      recentStrengthSummary: fixture.recentStrengthSummary.map(({ appleWatchMetrics: _, ...entry }) => entry),
      recentCardioSummary: [],
      constraints: { notes },
    },
  };
}

async function call(baseUrl, path, { method = "GET", secret, body, headers = {} } = {}) {
  const requestHeaders = new Headers(headers);
  if (secret) requestHeaders.set("authorization", `Bearer ${secret}`);
  if (body !== undefined) requestHeaders.set("content-type", "application/json");
  return fetch(`${baseUrl}${path}`, {
    method,
    headers: requestHeaders,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

async function expect(label, response, expected) {
  if (response.status !== expected) {
    throw new Error(`${label}: expected ${expected}, received ${response.status}: ${await response.text()}`);
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
