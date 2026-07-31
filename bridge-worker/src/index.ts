import { DurableObject } from "cloudflare:workers";
import OAuthProvider from "@cloudflare/workers-oauth-provider";
import type { AuthRequest, OAuthHelpers } from "@cloudflare/workers-oauth-provider";
import { MCP_SCOPES, handleMcpMessage } from "./mcp";
import type { McpScope } from "./mcp";
import {
  acknowledgementSchema,
  effectiveCapabilities,
  patchEnvelopeSchema,
  snapshotEnvelopeSchema,
  validatePatch,
} from "./schemas";
import type { Capabilities, CoachContext, DeviceCapabilities, SnapshotEnvelope } from "./schemas";

const MAX_REQUEST_BYTES = 512 * 1024;
const MAX_SNAPSHOTS = 8;
const MAX_SNAPSHOT_LIFETIME_MS = 24 * 60 * 60 * 1000;
const PATCH_LIFETIME_MS = 7 * 24 * 60 * 60 * 1000;
const TOMBSTONE_LIFETIME_MS = 7 * 24 * 60 * 60 * 1000;

export interface Env {
  FLOW_COACH: DurableObjectNamespace<FlowCoachMailbox>;
  /** Token, grant, and dynamic-client storage for the OAuth provider (#38). */
  OAUTH_KV: KVNamespace;
  /** Injected by OAuthProvider before either handler runs; never bound in config. */
  OAUTH_PROVIDER: OAuthHelpers;
  FLOW_COACH_MAILBOX_ID?: string;
  FLOW_COACH_ACTIONS_SECRET?: string;
  FLOW_COACH_DEVICE_SECRET?: string;
  /**
   * The per-person connect phrase checked at the OAuth consent page (#38).
   * Knowing this phrase is what authorises a Claude connector to this
   * mailbox, so it must be at least 32 characters of fresh randomness and
   * must never be shared across people or edges. The consent page fails
   * closed (503) while it is unset or too short.
   */
  FLOW_COACH_CONNECT_SECRET?: string;
  /** Test-only: workerd does not implement jurisdiction-restricted namespaces. */
  FLOW_COACH_LOCAL_TEST?: string;
}

type Edge = "actions" | "device";

/** What completeAuthorization stores on the grant and every token minted from it. */
interface McpGrantProps {
  mailboxId: string;
  scopes: McpScope[];
}

const SCOPE_DESCRIPTIONS: Record<McpScope, string> = {
  "coach:read": "Read the routines and recent training summary that Flow has synced here",
  "patch:propose": "Validate and store draft routine edits for Flow to preview",
};

/**
 * Non-OAuth routes: health, the consent page, and the Actions/device edges.
 * OAuthProvider sends every request here except /mcp (which needs a valid
 * bearer token first) and the endpoints it implements itself
 * (/oauth/token, /oauth/register, /.well-known/*).
 */
const defaultHandler = {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const mailboxId = configuredMailboxId(env.FLOW_COACH_MAILBOX_ID);
    if (url.pathname === "/healthz" && request.method === "GET") {
      return mailboxId
        ? json({ ok: true })
        : json({ ok: false, error: "Mailbox deployment is not configured." }, 503);
    }
    if (url.pathname === "/oauth/authorize") return handleAuthorize(request, env, mailboxId);

    const edge: Edge | undefined = url.pathname.startsWith("/actions/")
      ? "actions"
      : url.pathname.startsWith("/device/") ? "device" : undefined;
    if (!edge) return json({ error: "Not found." }, 404);
    if (!mailboxId) return json({ error: "Mailbox deployment is not configured." }, 503);

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
    headers.delete("x-flow-provenance");
    headers.set("x-flow-edge", edge);
    headers.set("x-flow-principal", edge === "actions" ? "actions-primary" : "device-primary");
    if (edge === "actions") headers.set("x-flow-provenance", "chatgpt-actions");
    const forwarded = new Request(request, { headers });
    const response = await mailboxStub(env, mailboxId).fetch(forwarded);
    return withSecurityHeaders(response);
  },
};

/**
 * The MCP edge (#38): OAuthProvider has already required a valid access
 * token before this handler runs, and ctx.props carries what the consent
 * page stored on the grant. Scope enforcement per tool happens inside
 * handleMcpMessage.
 */
const mcpApiHandler = {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const props = (ctx as ExecutionContext & { props?: Partial<McpGrantProps> }).props;
    const mailboxId = configuredMailboxId(env.FLOW_COACH_MAILBOX_ID);
    if (!mailboxId) return json({ error: "Mailbox deployment is not configured." }, 503);
    if (props?.mailboxId !== mailboxId) {
      // A grant minted while this deployment pointed at a different mailbox
      // must not carry over; the connector has to re-authorise.
      return json({ error: "This authorisation does not match the deployment. Reconnect the connector." }, 403);
    }
    const scopes = Array.isArray(props.scopes) ? props.scopes : [];
    if (request.method !== "POST") {
      // Stateless server: no SSE stream to GET, no session to DELETE.
      const response = json({ error: "The MCP endpoint accepts POST only." }, 405);
      response.headers.set("allow", "POST");
      return response;
    }
    let message: unknown;
    try {
      message = await readJson(request, 128 * 1024);
    } catch (caught) {
      if (!(caught instanceof SyntaxError)) throw caught;
      return json({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Request body must be valid JSON." } }, 400);
    }
    if (message instanceof Response) return message;

    const stub = mailboxStub(env, mailboxId);
    const outcome = await handleMcpMessage(message, ({ method, path, body, headers }) => {
      const forwarded = new Headers(headers);
      forwarded.set("x-flow-edge", "actions");
      forwarded.set("x-flow-principal", `mcp:${mailboxId}`);
      // MCP is the provider-neutral primary edge. The authenticated OAuth
      // client may be Claude, ChatGPT, Codex, or another compatible host;
      // none of them may choose the stored provenance value themselves.
      forwarded.set("x-flow-provenance", "mcp");
      if (body !== undefined) forwarded.set("content-type", "application/json");
      return stub.fetch(`https://mailbox.internal${path}`, {
        method,
        headers: forwarded,
        body: body === undefined ? undefined : JSON.stringify(body),
      });
    }, scopes);
    if (!outcome) return withSecurityHeaders(new Response(null, { status: 202 }));
    return json(outcome.body, outcome.status);
  },
};

export default new OAuthProvider({
  apiRoute: "/mcp",
  apiHandler: mcpApiHandler,
  defaultHandler,
  authorizeEndpoint: "/oauth/authorize",
  tokenEndpoint: "/oauth/token",
  clientRegistrationEndpoint: "/oauth/register",
  scopesSupported: [...MCP_SCOPES],
  // OAuth 2.1: S256 only, no implicit flow.
  allowPlainPKCE: false,
});

/**
 * The consent page. GET renders the approval form; POST checks the
 * per-person connect phrase and, on success, records the grant and sends
 * the browser back to the client with an authorization code. The phrase is
 * this page's entire authentication, mirroring how Flow pairs by
 * possession of the device secret: whoever operates the deployment hands
 * the phrase to the one person allowed to connect.
 */
async function handleAuthorize(request: Request, env: Env, mailboxId: string | undefined): Promise<Response> {
  if (request.method !== "GET" && request.method !== "POST") {
    const response = json({ error: "Method not allowed." }, 405);
    response.headers.set("allow", "GET, POST");
    return response;
  }
  if (!mailboxId) return json({ error: "Mailbox deployment is not configured." }, 503);
  const connectSecret = env.FLOW_COACH_CONNECT_SECRET?.trim();
  if (!connectSecret || connectSecret.length < 32) {
    return json({ error: "The connector consent page is not configured." }, 503);
  }

  // OAuth parameters are read from the query string only; the POST body
  // carries the connect phrase and is never handed to the OAuth parser.
  // parseAuthRequest validates the client and redirect URI and throws on
  // anything malformed.
  let authRequest: AuthRequest;
  try {
    authRequest = await env.OAUTH_PROVIDER.parseAuthRequest(new Request(request.url, { method: "GET" }));
  } catch {
    return json({ error: "Invalid authorization request." }, 400);
  }
  const client = await env.OAUTH_PROVIDER.lookupClient(authRequest.clientId);
  if (!client) return json({ error: "Unknown OAuth client." }, 400);

  const requested = authRequest.scope.filter((scope) => (MCP_SCOPES as readonly string[]).includes(scope)) as McpScope[];
  const granted: McpScope[] = authRequest.scope.length === 0 ? [...MCP_SCOPES] : requested;
  if (granted.length === 0) return json({ error: "None of the requested scopes are supported." }, 400);

  const clientName = client.clientName?.trim() || "An MCP client";
  const action = pathnameAndSearch(request.url);
  const formAction = formActionDirective(client.redirectUris);

  if (request.method === "GET") return consentPage(clientName, granted, action, formAction);

  let phrase: string | undefined;
  try {
    const form = await request.formData();
    const field = form.get("connect_phrase");
    phrase = typeof field === "string" ? field.trim() : undefined;
  } catch {
    return json({ error: "The consent form must be submitted as form data." }, 400);
  }
  if (!phrase || !(await secretEqual(phrase, connectSecret))) {
    return consentPage(clientName, granted, action, formAction, "That connect phrase is not right for this mailbox.");
  }

  const { redirectTo } = await env.OAUTH_PROVIDER.completeAuthorization({
    request: authRequest,
    userId: mailboxId,
    metadata: { grantedAt: new Date().toISOString() },
    scope: granted,
    props: { mailboxId, scopes: granted } satisfies McpGrantProps,
  });
  return Response.redirect(redirectTo, 302);
}

function pathnameAndSearch(raw: string): string {
  const url = new URL(raw);
  return `${url.pathname}${url.search}`;
}

/**
 * The consent form posts back to this Worker, but a successful approval answers
 * with a redirect to the client's registered redirect URI. Browsers apply
 * `form-action` to the redirect target as well as the form target, so a bare
 * `form-action 'self'` aborts that final navigation with no visible error: the
 * page simply sits there. The directive therefore has to name the redirect
 * origins, which come from the client registration the OAuth layer has already
 * validated. If any registered URI is not an http(s) origin, such as a native
 * app scheme, the directive is omitted rather than silently breaking the flow.
 */
function formActionDirective(redirectUris: ReadonlyArray<string>): string {
  const origins = new Set<string>();
  for (const uri of redirectUris) {
    let parsed: URL;
    try {
      parsed = new URL(uri);
    } catch {
      return "";
    }
    if (parsed.protocol !== "https:" && parsed.protocol !== "http:") return "";
    origins.add(parsed.origin);
  }
  if (origins.size === 0) return "";
  return `form-action 'self' ${[...origins].sort().join(" ")}`;
}

function consentPage(
  clientName: string,
  scopes: readonly McpScope[],
  action: string,
  formAction: string,
  problem?: string,
): Response {
  const scopeItems = scopes
    .map((scope) => `<li>${escapeHtml(SCOPE_DESCRIPTIONS[scope])}</li>`)
    .join("");
  const body = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Flow Coach bridge</title>
<style>
  body { font-family: -apple-system, system-ui, sans-serif; margin: 0; padding: 2rem 1rem; background: #f5f5f4; color: #1c1917; }
  main { max-width: 26rem; margin: 0 auto; background: #fff; border-radius: 12px; padding: 1.5rem; box-shadow: 0 1px 4px rgba(0,0,0,.08); }
  h1 { font-size: 1.2rem; margin-top: 0; }
  ul { padding-left: 1.2rem; }
  label { display: block; margin: 1rem 0 .35rem; font-weight: 600; }
  input { width: 100%; box-sizing: border-box; padding: .55rem; border: 1px solid #d6d3d1; border-radius: 8px; font-size: 1rem; }
  button { margin-top: 1rem; width: 100%; padding: .65rem; border: 0; border-radius: 8px; background: #1c1917; color: #fff; font-size: 1rem; }
  .error { color: #b91c1c; }
  .quiet { color: #57534e; font-size: .9rem; }
</style>
</head>
<body>
<main>
<h1>Flow Coach bridge</h1>
<p><strong>${escapeHtml(clientName)}</strong> is asking to connect to this Flow Coach mailbox. If you approve, it can:</p>
<ul>${scopeItems}</ul>
<p class="quiet">It can never change a routine. Every proposal waits in Flow for explicit preview and apply, and you can disconnect it at any time from the client's connector settings.</p>
${problem ? `<p class="error">${escapeHtml(problem)}</p>` : ""}
<form method="post" action="${escapeHtml(action)}">
<label for="connect_phrase">Connect phrase for this mailbox</label>
<input id="connect_phrase" name="connect_phrase" type="password" autocomplete="off" required>
<button type="submit">Approve connection</button>
</form>
</main>
</body>
</html>`;
  const response = new Response(body, {
    status: problem ? 403 : 200,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      "referrer-policy": "no-referrer",
      "content-security-policy": [
        "default-src 'none'",
        "style-src 'unsafe-inline'",
        formAction,
        "frame-ancestors 'none'",
        "base-uri 'none'",
      ].filter((directive) => directive !== "").join("; "),
    },
  });
  return response;
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function mailboxStub(env: Env, mailboxId: string): DurableObjectStub<FlowCoachMailbox> {
  const namespace = env.FLOW_COACH_LOCAL_TEST === "true"
    ? env.FLOW_COACH
    : env.FLOW_COACH.jurisdiction("eu");
  // Mailbox selection is trusted deployment configuration, never a model-
  // or device-supplied request parameter. The first household deployment
  // runs one separately authenticated Worker service per person.
  return namespace.get(namespace.idFromName(`flow-coach:${mailboxId}`));
}

function configuredMailboxId(value: string | undefined): string | undefined {
  const candidate = value?.trim();
  if (!candidate || candidate.length > 128) return undefined;
  return /^[A-Za-z0-9][A-Za-z0-9._:-]*$/.test(candidate) ? candidate : undefined;
}

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
  device_capabilities_json: string | null;
};
type PatchRow = {
  seq: number; patch_id: string; context_id: string; routine_id: string | null; base_hash: string | null;
  created_at: number; expires_at: number; status: string; provenance: string; principal_id: string;
  rationale: string | null; patch_json: string | null; pulled_at: number | null; terminal_at: number | null;
  tombstone_expires_at: number | null; idempotency_digest: string | null; proposal_digest: string; payload_digest: string;
};

export class FlowCoachMailbox extends DurableObject<Env> {
  private tail: Promise<void> = Promise.resolve();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.createSchema();
      this.migrateSchema();
    });
  }

  /**
   * Adds columns that later versions introduced. `createSchema` is
   * CREATE TABLE IF NOT EXISTS, so a Durable Object that already exists keeps
   * whatever shape it was created with and never sees an edited definition;
   * new columns have to arrive by ALTER. Additive and idempotent by design:
   * this runs on every construction, including on a brand new object where
   * the columns are already present.
   */
  private migrateSchema(): void {
    const columns = (table: string) => new Set(
      this.ctx.storage.sql.exec<{ name: string }>(`PRAGMA table_info(${table})`).toArray().map((row) => row.name),
    );
    if (!columns("snapshots").has("device_capabilities_json")) {
      this.ctx.storage.sql.exec("ALTER TABLE snapshots ADD COLUMN device_capabilities_json TEXT");
    }
    this.relaxPatchAnchorColumns();
  }

  /**
   * Drops NOT NULL from `patches.routine_id` and `patches.base_hash`.
   *
   * A patch that creates a routine anchors to nothing: there is no routine id
   * to pin to and no content to hash. SQLite cannot relax a constraint with
   * ALTER, so this is the standard table rebuild, run inside a transaction so
   * a failure part-way leaves the old table intact rather than a half-copied
   * new one. Detected by reading the constraint rather than by a version
   * counter, so it is a no-op on every object already in the new shape.
   */
  private relaxPatchAnchorColumns(): void {
    const anchored = this.ctx.storage.sql
      .exec<{ name: string; notnull: number }>("PRAGMA table_info(patches)")
      .toArray()
      .some((column) => (column.name === "routine_id" || column.name === "base_hash") && column.notnull === 1);
    if (!anchored) return;

    // Copying rows with their explicit `seq` leaves the rebuilt table's
    // AUTOINCREMENT counter at the highest surviving row rather than the
    // highest ever issued, so a seq already handed out to a since-expired
    // patch could be issued again. Pull cursors are ordered by seq, so that
    // would quietly break their monotonicity.
    const previousSequence = this.ctx.storage.sql
      .exec<{ seq: number }>("SELECT seq FROM sqlite_sequence WHERE name = 'patches'")
      .toArray()[0]?.seq;

    this.ctx.storage.transactionSync(() => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE patches_rebuilt (
          seq INTEGER PRIMARY KEY AUTOINCREMENT,
          patch_id TEXT NOT NULL UNIQUE,
          context_id TEXT NOT NULL,
          routine_id TEXT,
          base_hash TEXT,
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
        INSERT INTO patches_rebuilt SELECT
          seq, patch_id, context_id, routine_id, base_hash, created_at, expires_at, status,
          provenance, principal_id, rationale, patch_json, pulled_at, terminal_at,
          tombstone_expires_at, idempotency_digest, proposal_digest, payload_digest
        FROM patches;
        DROP TABLE patches;
        ALTER TABLE patches_rebuilt RENAME TO patches;
        CREATE INDEX IF NOT EXISTS patches_pull ON patches(seq, status);
        CREATE INDEX IF NOT EXISTS patches_context ON patches(context_id);
        CREATE INDEX IF NOT EXISTS patches_expiry ON patches(expires_at, tombstone_expires_at);
      `);
      if (previousSequence !== undefined) {
        // Replaced rather than upserted: sqlite_sequence carries no unique
        // constraint on `name`, so there is nothing for ON CONFLICT to match.
        this.ctx.storage.sql.exec("DELETE FROM sqlite_sequence WHERE name = 'patches'");
        this.ctx.storage.sql.exec("INSERT INTO sqlite_sequence(name, seq) VALUES ('patches', ?)", previousSequence);
      }
    });
  }

  private createSchema(): void {
    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS snapshots (
        context_id TEXT PRIMARY KEY,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        sharing_profile_json TEXT NOT NULL,
        context_json TEXT NOT NULL,
        envelope_digest TEXT NOT NULL,
        device_capabilities_json TEXT
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
        -- Null for a patch that creates a routine: it anchors to nothing.
        routine_id TEXT,
        base_hash TEXT,
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
        capabilities: this.capabilitiesFor(selected),
        // Travels in the result rather than the tool description because a
        // result is generated fresh on every call, where a tool description
        // can sit in a client's cached tools/list long after a deploy changed
        // the contract (#83). A coach composing from that cache silently
        // believes an operation does not exist; this is the one message it
        // reads every conversation that can say otherwise.
        advisory:
          "If capabilities.operationKinds or capabilities.patchSchemaVersions include anything " +
          "your patch tool's input schema does not mention, your client is composing against a " +
          "cached tools/list from an older deploy. Trust this block over the cached schema, and " +
          "tell the user to refresh this connector in Claude's settings.",
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
      const validation = validatePatch(envelopeResult.data.patch, context, this.capabilitiesFor(selected));
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

  /** What the coach may propose against this exact snapshot. */
  private capabilitiesFor(snapshot: SnapshotRow): Capabilities {
    const declared = snapshot.device_capabilities_json
      ? JSON.parse(snapshot.device_capabilities_json) as DeviceCapabilities
      : null;
    return effectiveCapabilities(declared);
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
      "INSERT INTO snapshots(context_id, created_at, expires_at, sharing_profile_json, context_json, envelope_digest, device_capabilities_json) VALUES (?, ?, ?, ?, ?, ?, ?)",
      envelope.contextId, createdAt, expiresAt, JSON.stringify(envelope.sharingProfile), JSON.stringify(envelope.context), digest,
      envelope.deviceCapabilities ? JSON.stringify(envelope.deviceCapabilities) : null,
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
    // Provenance is derived per edge by the trusted Worker layer, never from
    // an external caller: it is stored on the row and bound into both digests
    // so proposals cannot masquerade across adapters.
    const provenance = request.headers.get("x-flow-provenance") ?? "chatgpt-actions";
    const idempotencyKey = request.headers.get("idempotency-key");
    if (idempotencyKey && (idempotencyKey.length > 128 || idempotencyKey.trim().length === 0)) return json({ error: "Idempotency-Key must be 1 to 128 characters." }, 400);
    const payload = canonicalJson(patch);
    const payloadDigest = await sha256(payload);
    const proposalDigest = await sha256(`${principal}\n${provenance}\n${snapshot.context_id}\n${payload}`);
    const idempotencyDigest = idempotencyKey
      ? await sha256(`${principal}\n${provenance}\n${snapshot.context_id}\n${idempotencyKey}`)
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
       VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?, ?)`,
      patchId, snapshot.context_id, patch.routineId ?? null, patch.baseContentHash ?? null, now, now + PATCH_LIFETIME_MS,
      provenance, principal, patch.rationale, JSON.stringify(patch), idempotencyDigest, proposalDigest, payloadDigest,
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
  const body = request.body;
  if (!body) throw new SyntaxError("Request body is empty.");

  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let byteLength = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    byteLength += value.byteLength;
    if (byteLength > maxBytes) {
      await reader.cancel("request body exceeded endpoint limit");
      return json({ error: "Request body is too large." }, 413);
    }
    chunks.push(value);
  }

  const bytes = new Uint8Array(byteLength);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return JSON.parse(new TextDecoder().decode(bytes)) as unknown;
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
