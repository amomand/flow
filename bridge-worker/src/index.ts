import { DurableObject } from "cloudflare:workers";
import {
  acknowledgementSchema,
  patchEnvelopeSchema,
  snapshotEnvelopeSchema,
  validatePatch,
} from "./schemas";
import type { CoachContext, SnapshotEnvelope } from "./schemas";

const SINGLE_USER_OBJECT = "flow-coach-single-user";
const MAX_REQUEST_BYTES = 512 * 1024;
const MAX_SNAPSHOTS = 8;
const MAX_SNAPSHOT_LIFETIME_MS = 24 * 60 * 60 * 1000;
const PATCH_LIFETIME_MS = 7 * 24 * 60 * 60 * 1000;
const TOMBSTONE_LIFETIME_MS = 7 * 24 * 60 * 60 * 1000;

export interface Env {
  FLOW_COACH: DurableObjectNamespace<FlowCoachMailbox>;
  FLOW_COACH_ACTIONS_SECRET?: string;
  FLOW_COACH_DEVICE_SECRET?: string;
  /** Test-only: workerd does not implement jurisdiction-restricted namespaces. */
  FLOW_COACH_LOCAL_TEST?: string;
}

type Edge = "actions" | "device";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/healthz" && request.method === "GET") {
      return json({ ok: true });
    }
    const edge: Edge | undefined = url.pathname.startsWith("/actions/")
      ? "actions"
      : url.pathname.startsWith("/device/") ? "device" : undefined;
    if (!edge) return json({ error: "Not found." }, 404);

    const expected = edge === "actions" ? env.FLOW_COACH_ACTIONS_SECRET : env.FLOW_COACH_DEVICE_SECRET;
    if (!expected) return json({ error: "This API edge is not configured." }, 503);
    const supplied = bearerToken(request.headers.get("authorization"));
    if (!supplied || !(await secretEqual(supplied, expected))) {
      return json({ error: "Invalid or missing credential." }, 401);
    }
    const declaredLength = Number(request.headers.get("content-length") ?? "0");
    if (declaredLength > MAX_REQUEST_BYTES) return json({ error: "Request body is too large." }, 413);

    const headers = new Headers(request.headers);
    headers.delete("authorization");
    headers.delete("cookie");
    headers.set("x-flow-edge", edge);
    headers.set("x-flow-principal", edge === "actions" ? "actions-primary" : "device-primary");
    const forwarded = new Request(request, { headers });
    const namespace = env.FLOW_COACH_LOCAL_TEST === "true"
      ? env.FLOW_COACH
      : env.FLOW_COACH.jurisdiction("eu");
    const stub = namespace.get(namespace.idFromName(SINGLE_USER_OBJECT));
    const response = await stub.fetch(forwarded);
    return withSecurityHeaders(response);
  },
};

function bearerToken(header: string | null): string | undefined {
  if (!header?.startsWith("Bearer ")) return undefined;
  const token = header.slice(7);
  return token.length > 0 ? token : undefined;
}

async function secretEqual(left: string, right: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(left)),
    crypto.subtle.digest("SHA-256", encoder.encode(right)),
  ]);
  const leftBytes = new Uint8Array(a);
  const rightBytes = new Uint8Array(b);
  let difference = 0;
  for (let index = 0; index < leftBytes.length; index++) difference |= leftBytes[index]! ^ rightBytes[index]!;
  return difference === 0;
}

function withSecurityHeaders(response: Response): Response {
  const wrapped = new Response(response.body, response);
  wrapped.headers.set("cache-control", "no-store");
  wrapped.headers.set("x-content-type-options", "nosniff");
  return wrapped;
}

function json(value: unknown, status = 200): Response {
  return withSecurityHeaders(Response.json(value, { status }));
}

function errorFromIssues(message: string, issues: ReadonlyArray<{ path: PropertyKey[]; message: string }>, status = 400) {
  return json({ error: message, problems: issues.map((issue) => ({ path: issue.path.join("."), message: issue.message })) }, status);
}

type SnapshotRow = {
  context_id: string; created_at: number; expires_at: number; sharing_profile_json: string; context_json: string; envelope_digest: string;
};
type PatchRow = {
  seq: number; patch_id: string; context_id: string; routine_id: string; base_hash: string;
  created_at: number; expires_at: number; status: string; provenance: string; principal_id: string;
  rationale: string | null; patch_json: string | null; pulled_at: number | null; terminal_at: number | null;
  tombstone_expires_at: number | null; idempotency_digest: string | null; proposal_digest: string; payload_digest: string;
};

export class FlowCoachMailbox extends DurableObject<Env> {
  private tail: Promise<void> = Promise.resolve();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => this.createSchema());
  }

  private createSchema(): void {
    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS snapshots (
        context_id TEXT PRIMARY KEY,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        sharing_profile_json TEXT NOT NULL,
        context_json TEXT NOT NULL,
        envelope_digest TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS snapshots_expiry ON snapshots(expires_at);
      CREATE TABLE IF NOT EXISTS snapshot_tombstones (
        context_id TEXT PRIMARY KEY,
        status TEXT NOT NULL,
        tombstone_expires_at INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS snapshot_tombstones_expiry ON snapshot_tombstones(tombstone_expires_at);
      CREATE TABLE IF NOT EXISTS patches (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        patch_id TEXT NOT NULL UNIQUE,
        context_id TEXT NOT NULL,
        routine_id TEXT NOT NULL,
        base_hash TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        status TEXT NOT NULL,
        provenance TEXT NOT NULL,
        principal_id TEXT NOT NULL,
        rationale TEXT,
        patch_json TEXT,
        pulled_at INTEGER,
        terminal_at INTEGER,
        tombstone_expires_at INTEGER,
        idempotency_digest TEXT UNIQUE,
        proposal_digest TEXT NOT NULL UNIQUE,
        payload_digest TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS patches_pull ON patches(seq, status);
      CREATE INDEX IF NOT EXISTS patches_context ON patches(context_id);
      CREATE INDEX IF NOT EXISTS patches_expiry ON patches(expires_at, tombstone_expires_at);
    `);
  }

  async fetch(request: Request): Promise<Response> {
    return this.exclusive(() => this.route(request));
  }

  async alarm(): Promise<void> {
    await this.exclusive(async () => {
      this.cleanup(Date.now());
      await this.scheduleAlarm();
    });
  }

  private async exclusive<T>(work: () => Promise<T>): Promise<T> {
    const previous = this.tail;
    let release!: () => void;
    this.tail = new Promise<void>((resolve) => { release = resolve; });
    await previous;
    try { return await work(); } finally { release(); }
  }

  private async route(request: Request): Promise<Response> {
    const edge = request.headers.get("x-flow-edge") as Edge | null;
    if (edge !== "actions" && edge !== "device") return json({ error: "Not found." }, 404);
    const url = new URL(request.url);
    this.cleanup(Date.now());

    let response: Response;
    try {
      response = edge === "actions"
        ? await this.routeActions(request, url)
        : await this.routeDevice(request, url);
    } catch (caught) {
      if (caught instanceof SyntaxError) response = json({ error: "Request body must be valid JSON." }, 400);
      else throw caught;
    }
    await this.scheduleAlarm();
    return response;
  }

  private async routeActions(request: Request, url: URL): Promise<Response> {
    if (request.method === "GET" && url.pathname === "/actions/coach-context") {
      const selected = this.selectSnapshot(url.searchParams.get("contextId"));
      if (selected instanceof Response) return selected;
      const context = JSON.parse(selected.context_json) as CoachContext;
      return json({
        contextId: selected.context_id,
        createdAt: new Date(selected.created_at).toISOString(),
        expiresAt: new Date(selected.expires_at).toISOString(),
        sharingProfile: JSON.parse(selected.sharing_profile_json),
        schemaVersion: context.schemaVersion,
        generatedAt: context.generatedAt,
        app: context.app,
        routines: routineSummaries(context),
        recentStrengthCount: context.recentStrengthSummary.length,
        recentCardioCount: context.recentCardioSummary.length,
        constraints: context.constraints,
      });
    }
    if (request.method === "GET" && url.pathname === "/actions/routines") {
      const selected = this.requireExactSnapshot(url);
      if (selected instanceof Response) return selected;
      const context = JSON.parse(selected.context_json) as CoachContext;
      return json({ contextId: selected.context_id, routines: routineSummaries(context) });
    }
    const routineMatch = url.pathname.match(/^\/actions\/routines\/([^/]+)$/);
    if (request.method === "GET" && routineMatch) {
      const selected = this.requireExactSnapshot(url);
      if (selected instanceof Response) return selected;
      const context = JSON.parse(selected.context_json) as CoachContext;
      const routine = context.routines.find((entry) => entry.id === decodeURIComponent(routineMatch[1]!));
      return routine ? json({ contextId: selected.context_id, routine }) : json({ error: "Routine is absent from this snapshot." }, 404);
    }
    if (request.method === "GET" && url.pathname === "/actions/training-summary") {
      const selected = this.requireExactSnapshot(url);
      if (selected instanceof Response) return selected;
      const context = JSON.parse(selected.context_json) as CoachContext;
      const includeHealth = url.searchParams.get("includeHealthMetrics") === "true";
      const strengthLimit = boundedInt(url.searchParams.get("strengthLimit"), 5, 10);
      const cardioLimit = boundedInt(url.searchParams.get("cardioLimit"), 5, 12);
      return json({
        contextId: selected.context_id,
        recentStrengthSummary: context.recentStrengthSummary.slice(0, strengthLimit).map((entry) => includeHealth ? entry : stripHealth(entry)),
        recentCardioSummary: context.recentCardioSummary.slice(0, cardioLimit).map((entry) => includeHealth ? entry : stripCardioHealth(entry)),
      });
    }
    if (request.method === "POST" && (url.pathname === "/actions/patches/validate" || url.pathname === "/actions/pending-patches")) {
      const body = await readJson(request, 64 * 1024);
      if (body instanceof Response) return body;
      const envelopeResult = patchEnvelopeSchema.safeParse(body);
      if (!envelopeResult.success) return errorFromIssues("Request must contain an exact contextId and patch.", envelopeResult.error.issues);
      const selected = this.selectSnapshot(envelopeResult.data.contextId);
      if (selected instanceof Response) return selected;
      const context = JSON.parse(selected.context_json) as CoachContext;
      const validation = validatePatch(envelopeResult.data.patch, context);
      if (url.pathname.endsWith("/validate")) return json(validation, validation.valid ? 200 : 422);
      if (!validation.valid || !validation.patch) return json({ stored: false, ...validation }, 422);
      return this.createPatch(request, selected, validation.patch);
    }
    return json({ error: "Not found." }, 404);
  }

  private async routeDevice(request: Request, url: URL): Promise<Response> {
    if (request.method === "PUT" && url.pathname === "/device/snapshots") {
      const body = await readJson(request, MAX_REQUEST_BYTES);
      if (body instanceof Response) return body;
      const parsed = snapshotEnvelopeSchema.safeParse(body);
      if (!parsed.success) return errorFromIssues("Snapshot envelope does not match Flow schema 2.", parsed.error.issues, 422);
      return this.putSnapshot(parsed.data);
    }
    const snapshotMatch = url.pathname.match(/^\/device\/snapshots\/([^/]+)$/);
    if (request.method === "DELETE" && snapshotMatch) return this.deleteSnapshot(decodeURIComponent(snapshotMatch[1]!));
    if (request.method === "DELETE" && url.pathname === "/device/data") {
      await this.ctx.storage.deleteAll();
      this.createSchema();
      return json({ deleted: true });
    }
    if (request.method === "GET" && url.pathname === "/device/pending-patches") return this.pullPatches(url);
    const ackMatch = url.pathname.match(/^\/device\/pending-patches\/([^/]+)\/ack$/);
    if (request.method === "POST" && ackMatch) {
      const body = await readJson(request, 8 * 1024);
      if (body instanceof Response) return body;
      const parsed = acknowledgementSchema.safeParse(body);
      if (!parsed.success) return errorFromIssues("Acknowledgement status is invalid.", parsed.error.issues);
      return this.acknowledge(decodeURIComponent(ackMatch[1]!), parsed.data.status);
    }
    return json({ error: "Not found." }, 404);
  }

  private selectSnapshot(contextId: string | null): SnapshotRow | Response {
    if (contextId) {
      const row = this.ctx.storage.sql.exec<SnapshotRow>("SELECT * FROM snapshots WHERE context_id = ?", contextId).toArray()[0];
      if (row) return row;
      const tombstone = this.ctx.storage.sql.exec<{ status: string }>("SELECT status FROM snapshot_tombstones WHERE context_id = ?", contextId).toArray()[0];
      if (tombstone?.status === "expired") return json({ error: "That coach snapshot expired. Sync a fresh snapshot in Flow." }, 410);
      if (tombstone) return json({ error: "That coach snapshot is no longer available. Read coach context again." }, tombstone.status === "deleted" ? 410 : 409);
      return json({ error: "Unknown coach snapshot. Read coach context again." }, 404);
    }
    const latest = this.ctx.storage.sql.exec<SnapshotRow>("SELECT * FROM snapshots ORDER BY created_at DESC LIMIT 1").toArray()[0];
    return latest ?? json({ error: "No unexpired coach snapshot is available. Sync from Flow first." }, 404);
  }

  private requireExactSnapshot(url: URL): SnapshotRow | Response {
    const id = url.searchParams.get("contextId");
    return id ? this.selectSnapshot(id) : json({ error: "contextId is required." }, 400);
  }

  private async putSnapshot(envelope: SnapshotEnvelope): Promise<Response> {
    const createdAt = Date.parse(envelope.createdAt);
    const expiresAt = Date.parse(envelope.expiresAt);
    const now = Date.now();
    if (expiresAt <= now) return json({ error: "Snapshot is already expired." }, 410);
    if (expiresAt <= createdAt || expiresAt - createdAt > MAX_SNAPSHOT_LIFETIME_MS) return json({ error: "Snapshot lifetime must be no more than 24 hours." }, 422);
    if (createdAt > now + 5 * 60 * 1000) return json({ error: "Snapshot creation time is too far in the future." }, 422);
    const digest = await sha256(canonicalJson(envelope));
    const existing = this.ctx.storage.sql.exec<SnapshotRow>("SELECT * FROM snapshots WHERE context_id = ?", envelope.contextId).toArray()[0];
    if (existing) {
      if (existing.envelope_digest !== digest) return json({ error: "contextId is already bound to a different envelope." }, 409);
      return json({ stored: true, duplicate: true, contextId: envelope.contextId });
    }
    this.ctx.storage.sql.exec(
      "INSERT INTO snapshots(context_id, created_at, expires_at, sharing_profile_json, context_json, envelope_digest) VALUES (?, ?, ?, ?, ?, ?)",
      envelope.contextId, createdAt, expiresAt, JSON.stringify(envelope.sharingProfile), JSON.stringify(envelope.context), digest,
    );
    const overflow = this.ctx.storage.sql.exec<{ context_id: string }>(
      "SELECT context_id FROM snapshots ORDER BY created_at DESC LIMIT -1 OFFSET ?", MAX_SNAPSHOTS,
    ).toArray();
    for (const row of overflow) this.removeSnapshot(row.context_id, "superseded", now);
    return json({ stored: true, duplicate: false, contextId: envelope.contextId, expiresAt: envelope.expiresAt }, 201);
  }

  private deleteSnapshot(contextId: string): Response {
    const found = this.ctx.storage.sql.exec<{ context_id: string }>("SELECT context_id FROM snapshots WHERE context_id = ?", contextId).toArray()[0];
    if (!found) return json({ deleted: false, error: "Snapshot was not found." }, 404);
    this.removeSnapshot(contextId, "deleted", Date.now());
    return json({ deleted: true, contextId });
  }

  private removeSnapshot(contextId: string, status: string, now: number): void {
    this.ctx.storage.sql.exec("DELETE FROM snapshots WHERE context_id = ?", contextId);
    this.ctx.storage.sql.exec("DELETE FROM patches WHERE context_id = ?", contextId);
    this.ctx.storage.sql.exec(
      "INSERT INTO snapshot_tombstones(context_id, status, tombstone_expires_at) VALUES (?, ?, ?) ON CONFLICT(context_id) DO UPDATE SET status=excluded.status, tombstone_expires_at=excluded.tombstone_expires_at",
      contextId, status, now + TOMBSTONE_LIFETIME_MS,
    );
  }

  private async createPatch(request: Request, snapshot: SnapshotRow, patch: NonNullable<ReturnType<typeof validatePatch>["patch"]>): Promise<Response> {
    const principal = request.headers.get("x-flow-principal") ?? "actions-primary";
    const idempotencyKey = request.headers.get("idempotency-key");
    if (idempotencyKey && (idempotencyKey.length > 128 || idempotencyKey.trim().length === 0)) return json({ error: "Idempotency-Key must be 1 to 128 characters." }, 400);
    const payload = canonicalJson(patch);
    const payloadDigest = await sha256(payload);
    const proposalDigest = await sha256(`${principal}\nchatgpt-actions\n${snapshot.context_id}\n${payload}`);
    const idempotencyDigest = idempotencyKey
      ? await sha256(`${principal}\nchatgpt-actions\n${snapshot.context_id}\n${idempotencyKey}`)
      : null;
    if (idempotencyDigest) {
      const existing = this.ctx.storage.sql.exec<PatchRow>("SELECT * FROM patches WHERE idempotency_digest = ?", idempotencyDigest).toArray()[0];
      if (existing) {
        if (existing.payload_digest !== payloadDigest) return json({ error: "Idempotency-Key was already used for a different proposal." }, 409);
        return json({ stored: true, duplicate: true, patch: patchMetadata(existing), message: draftMessage }, 200);
      }
    }
    const duplicate = this.ctx.storage.sql.exec<PatchRow>("SELECT * FROM patches WHERE proposal_digest = ?", proposalDigest).toArray()[0];
    if (duplicate) return json({ stored: true, duplicate: true, patch: patchMetadata(duplicate), message: draftMessage }, 200);
    const now = Date.now();
    const patchId = crypto.randomUUID();
    this.ctx.storage.sql.exec(
      `INSERT INTO patches(patch_id, context_id, routine_id, base_hash, created_at, expires_at, status, provenance, principal_id, rationale, patch_json, idempotency_digest, proposal_digest, payload_digest)
       VALUES (?, ?, ?, ?, ?, ?, 'pending', 'chatgpt-actions', ?, ?, ?, ?, ?, ?)`,
      patchId, snapshot.context_id, patch.routineId, patch.baseContentHash, now, now + PATCH_LIFETIME_MS,
      principal, patch.rationale, JSON.stringify(patch), idempotencyDigest, proposalDigest, payloadDigest,
    );
    const row = this.ctx.storage.sql.exec<PatchRow>("SELECT * FROM patches WHERE patch_id = ?", patchId).one();
    return json({ stored: true, duplicate: false, patch: patchMetadata(row), message: draftMessage }, 201);
  }

  private pullPatches(url: URL): Response {
    const cursor = boundedInt(url.searchParams.get("cursor"), 0, Number.MAX_SAFE_INTEGER, true);
    const limit = boundedInt(url.searchParams.get("limit"), 20, 50);
    const rows = this.ctx.storage.sql.exec<PatchRow>(
      "SELECT * FROM patches WHERE seq > ? AND status IN ('pending', 'pulled') AND patch_json IS NOT NULL ORDER BY seq LIMIT ?", cursor, limit,
    ).toArray();
    return json({
      patches: rows.map((row) => ({ ...patchMetadata(row), rationale: row.rationale, patch: JSON.parse(row.patch_json!) })),
      nextCursor: rows.length > 0 ? rows[rows.length - 1]!.seq : cursor,
    });
  }

  private acknowledge(patchId: string, requested: "pulled" | "applied" | "rejected" | "stale"): Response {
    const row = this.ctx.storage.sql.exec<PatchRow>("SELECT * FROM patches WHERE patch_id = ?", patchId).toArray()[0];
    if (!row) return json({ error: "Patch was not found." }, 404);
    if (["expired", "applied", "rejected", "stale"].includes(row.status)) {
      if (row.status === requested || requested === "pulled") return json({ acknowledged: true, duplicate: true, patch: patchMetadata(row) });
      return json({ error: `Patch is already terminal as ${row.status}.`, patch: patchMetadata(row) }, 409);
    }
    if (requested !== "pulled" && row.status !== "pulled") return json({ error: "Patch must be acknowledged as pulled before a terminal result." }, 409);
    if (requested === "pulled") {
      if (row.status === "pulled") return json({ acknowledged: true, duplicate: true, patch: patchMetadata(row) });
      const now = Date.now();
      this.ctx.storage.sql.exec("UPDATE patches SET status='pulled', pulled_at=? WHERE patch_id=?", now, patchId);
    } else {
      const now = Date.now();
      this.ctx.storage.sql.exec(
        "UPDATE patches SET status=?, rationale=NULL, patch_json=NULL, terminal_at=?, tombstone_expires_at=? WHERE patch_id=?",
        requested, now, now + TOMBSTONE_LIFETIME_MS, patchId,
      );
    }
    const updated = this.ctx.storage.sql.exec<PatchRow>("SELECT * FROM patches WHERE patch_id = ?", patchId).one();
    return json({ acknowledged: true, duplicate: false, patch: patchMetadata(updated) });
  }

  private cleanup(now: number): void {
    const expiredSnapshots = this.ctx.storage.sql.exec<{ context_id: string }>("SELECT context_id FROM snapshots WHERE expires_at <= ?", now).toArray();
    for (const row of expiredSnapshots) {
      this.ctx.storage.sql.exec("DELETE FROM snapshots WHERE context_id = ?", row.context_id);
      this.ctx.storage.sql.exec(
        "INSERT INTO snapshot_tombstones(context_id, status, tombstone_expires_at) VALUES (?, 'expired', ?) ON CONFLICT(context_id) DO UPDATE SET status='expired', tombstone_expires_at=excluded.tombstone_expires_at",
        row.context_id, now + TOMBSTONE_LIFETIME_MS,
      );
    }
    this.ctx.storage.sql.exec(
      `UPDATE patches SET status='expired', rationale=NULL, patch_json=NULL, terminal_at=?, tombstone_expires_at=?
       WHERE expires_at <= ? AND status IN ('pending', 'pulled')`, now, now + TOMBSTONE_LIFETIME_MS, now,
    );
    this.ctx.storage.sql.exec("DELETE FROM patches WHERE tombstone_expires_at IS NOT NULL AND tombstone_expires_at <= ?", now);
    this.ctx.storage.sql.exec("DELETE FROM snapshot_tombstones WHERE tombstone_expires_at <= ?", now);
  }

  private async scheduleAlarm(): Promise<void> {
    const candidates = [
      this.ctx.storage.sql.exec<{ at: number | null }>("SELECT MIN(expires_at) AS at FROM snapshots").one().at,
      this.ctx.storage.sql.exec<{ at: number | null }>("SELECT MIN(expires_at) AS at FROM patches WHERE status IN ('pending','pulled')").one().at,
      this.ctx.storage.sql.exec<{ at: number | null }>("SELECT MIN(tombstone_expires_at) AS at FROM patches WHERE tombstone_expires_at IS NOT NULL").one().at,
      this.ctx.storage.sql.exec<{ at: number | null }>("SELECT MIN(tombstone_expires_at) AS at FROM snapshot_tombstones").one().at,
    ].filter((value): value is number => typeof value === "number");
    if (candidates.length === 0) await this.ctx.storage.deleteAlarm();
    else await this.ctx.storage.setAlarm(Math.min(...candidates));
  }
}

const draftMessage = "Flow has not applied this draft. Open Flow Coach to preview and decide.";

function routineSummaries(context: CoachContext) {
  return context.routines.map((routine) => ({
    id: routine.id,
    name: routine.name,
    currentPhase: routine.currentPhase,
    contentHash: context.routineContentHashByRoutineId[routine.id],
    stateHash: context.routineStateHashByRoutineId[routine.id],
    sectionCount: routine.sections.length,
    exerciseCount: routine.sections.reduce((sum, section) => sum + section.exercises.length, 0),
  }));
}

function patchMetadata(row: PatchRow) {
  return {
    cursor: row.seq,
    patchId: row.patch_id,
    contextId: row.context_id,
    routineId: row.routine_id,
    baseContentHash: row.base_hash,
    createdAt: new Date(row.created_at).toISOString(),
    expiresAt: new Date(row.expires_at).toISOString(),
    status: row.status,
    provenance: row.provenance,
    pulledAt: row.pulled_at ? new Date(row.pulled_at).toISOString() : null,
    terminalAt: row.terminal_at ? new Date(row.terminal_at).toISOString() : null,
  };
}

function stripHealth<T extends Record<string, unknown>>(entry: T): Omit<T, "appleWatchMetrics"> {
  const { appleWatchMetrics: _, ...safe } = entry;
  return safe;
}

function stripCardioHealth<T extends Record<string, unknown>>(entry: T): Omit<T, "averageHeartRate" | "maxHeartRate"> {
  const { averageHeartRate: _, maxHeartRate: __, ...safe } = entry;
  return safe;
}

function boundedInt(raw: string | null, fallback: number, max: number, allowZero = false): number {
  if (raw === null) return fallback;
  const parsed = Number.parseInt(raw, 10);
  return Number.isSafeInteger(parsed) ? Math.min(Math.max(parsed, allowZero ? 0 : 1), max) : fallback;
}

async function readJson(request: Request, maxBytes: number): Promise<unknown | Response> {
  const text = await request.text();
  if (new TextEncoder().encode(text).byteLength > maxBytes) return json({ error: "Request body is too large." }, 413);
  return JSON.parse(text) as unknown;
}

function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value !== null && typeof value === "object") {
    return `{${Object.keys(value as Record<string, unknown>).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson((value as Record<string, unknown>)[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
