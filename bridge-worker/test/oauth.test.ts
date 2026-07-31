import { beforeEach, describe, expect, it } from "vitest";
import { SELF } from "cloudflare:test";
import fixtureContext from "../../bridge-prototype/fixtures/coach-context.json";
import { CONNECT_PHRASE, REDIRECT_URI, obtainTokens } from "./oauth-helper";

const DEVICE_SECRET = "fixture-device-secret";

async function json(response: Response): Promise<Record<string, any>> {
  return response.json() as Promise<Record<string, any>>;
}

async function clearMailbox(): Promise<void> {
  const response = await SELF.fetch("https://flow.test/device/data", {
    method: "DELETE",
    headers: { authorization: `Bearer ${DEVICE_SECRET}`, "content-type": "application/json" },
  });
  expect(response.status).toBe(200);
}

async function uploadSnapshot(): Promise<string> {
  const contextId = crypto.randomUUID();
  const now = Date.now();
  const response = await SELF.fetch("https://flow.test/device/snapshots", {
    method: "PUT",
    headers: { authorization: `Bearer ${DEVICE_SECRET}`, "content-type": "application/json" },
    body: JSON.stringify({
      contextId,
      createdAt: new Date(now).toISOString(),
      expiresAt: new Date(now + 24 * 60 * 60 * 1000).toISOString(),
      sharingProfile: {
        schemaVersion: 1,
        dataTiers: ["routines", "strengthHistory", "cardioHistory", "healthMetrics"],
      },
      context: fixtureContext,
    }),
  });
  expect(response.status).toBe(201);
  return contextId;
}

async function mcp(accessToken: string, method: string, params?: unknown, id: number | string = 1): Promise<Response> {
  return SELF.fetch("https://flow.test/mcp", {
    method: "POST",
    headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id, method, params }),
  });
}

async function registerClient(): Promise<string> {
  const registration = await SELF.fetch("https://flow.test/oauth/register", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      client_name: "Consent page test client",
      redirect_uris: [REDIRECT_URI],
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      token_endpoint_auth_method: "none",
    }),
  });
  expect(registration.status).toBe(201);
  return ((await registration.json()) as { client_id: string }).client_id;
}

function authorizeUrl(clientId: string, extra: Record<string, string> = {}): URL {
  const url = new URL("https://flow.test/oauth/authorize");
  url.searchParams.set("response_type", "code");
  url.searchParams.set("client_id", clientId);
  url.searchParams.set("redirect_uri", REDIRECT_URI);
  url.searchParams.set("state", "state-1");
  url.searchParams.set("code_challenge", "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
  url.searchParams.set("code_challenge_method", "S256");
  for (const [key, value] of Object.entries(extra)) url.searchParams.set(key, value);
  return url;
}

describe("Flow Coach bridge OAuth edge", () => {
  beforeEach(clearMailbox);

  it("publishes OAuth discovery and protected-resource metadata", async () => {
    const authServer = await json(await SELF.fetch("https://flow.test/.well-known/oauth-authorization-server"));
    expect(authServer.authorization_endpoint).toBe("https://flow.test/oauth/authorize");
    expect(authServer.token_endpoint).toBe("https://flow.test/oauth/token");
    expect(authServer.registration_endpoint).toBe("https://flow.test/oauth/register");
    expect(authServer.scopes_supported).toEqual(["coach:read", "patch:propose"]);
    expect(authServer.code_challenge_methods_supported).toEqual(["S256"]);

    const resource = await json(await SELF.fetch("https://flow.test/.well-known/oauth-protected-resource/mcp"));
    expect(resource.resource).toBe("https://flow.test/mcp");
    expect(resource.authorization_servers).toEqual(["https://flow.test"]);
    expect(resource.scopes_supported).toEqual(["coach:read", "patch:propose"]);
  });

  it("refuses the MCP endpoint without a valid bearer token", async () => {
    const missing = await SELF.fetch("https://flow.test/mcp", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "ping" }),
    });
    expect(missing.status).toBe(401);
    expect(missing.headers.get("www-authenticate")).toContain(
      'resource_metadata="https://flow.test/.well-known/oauth-protected-resource/mcp"',
    );

    const wrong = await SELF.fetch("https://flow.test/mcp", {
      method: "POST",
      headers: { authorization: "Bearer not-a-real-token", "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "ping" }),
    });
    expect(wrong.status).toBe(401);

    // The retired spike mount shares the /mcp prefix, so old URLs are
    // refused by the token gate rather than routed anywhere.
    const spikePath = await SELF.fetch("https://flow.test/mcp/old-spike-token-0123456789abcdef", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "ping" }),
    });
    expect(spikePath.status).toBe(401);
  });

  it("shows a consent page naming the client and the granted access", async () => {
    const clientId = await registerClient();
    const page = await SELF.fetch(authorizeUrl(clientId));
    expect(page.status).toBe(200);
    expect(page.headers.get("content-type")).toContain("text/html");
    const html = await page.text();
    expect(html).toContain("Consent page test client");
    expect(html).toContain("routines and recent training summary");
    expect(html).toContain("draft routine edits");
    expect(html).toContain("connect_phrase");
    expect(html).not.toContain(CONNECT_PHRASE);
  });

  it("lets the browser follow the approval redirect back to the client", async () => {
    // Regression: `form-action 'self'` alone is applied to the redirect target
    // as well as the form target, so the browser aborted the navigation after
    // a correct phrase and the consent page appeared to do nothing.
    const clientId = await registerClient();
    for (const method of ["GET", "POST"] as const) {
      const response = await SELF.fetch(authorizeUrl(clientId), {
        method,
        headers: method === "POST" ? { "content-type": "application/x-www-form-urlencoded" } : undefined,
        body: method === "POST" ? new URLSearchParams({ connect_phrase: "wrong-but-long-enough-to-submit" }) : undefined,
        redirect: "manual",
      });
      const csp = response.headers.get("content-security-policy") ?? "";
      expect(csp).toContain("form-action 'self' https://client.test");
      expect(csp).toContain("default-src 'none'");
      expect(csp).toContain("frame-ancestors 'none'");
    }
  });

  it("omits form-action when a client registers a non-web redirect", async () => {
    // A native-app scheme cannot be expressed as an origin. Blocking the flow
    // would be worse than dropping one directive, so it is dropped.
    const registration = await SELF.fetch("https://flow.test/oauth/register", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        client_name: "Native client",
        redirect_uris: ["myapp://oauth/callback"],
        grant_types: ["authorization_code"],
        response_types: ["code"],
        token_endpoint_auth_method: "none",
      }),
    });
    expect(registration.status).toBe(201);
    const clientId = ((await registration.json()) as { client_id: string }).client_id;

    const url = authorizeUrl(clientId, { redirect_uri: "myapp://oauth/callback" });
    const response = await SELF.fetch(url);
    expect(response.status).toBe(200);
    const csp = response.headers.get("content-security-policy") ?? "";
    expect(csp).not.toContain("form-action");
    expect(csp).toContain("default-src 'none'");
  });

  it("rejects a wrong connect phrase without leaking anything", async () => {
    const clientId = await registerClient();
    const denied = await SELF.fetch(authorizeUrl(clientId), {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ connect_phrase: "not-the-phrase-but-long-enough-to-try" }),
      redirect: "manual",
    });
    expect(denied.status).toBe(403);
    expect(await denied.text()).toContain("not right for this mailbox");
  });

  it("rejects authorization requests for unknown clients and foreign redirect URIs", async () => {
    const unknownClient = await SELF.fetch(authorizeUrl("client-that-was-never-registered"));
    expect(unknownClient.status).toBe(400);

    const clientId = await registerClient();
    const foreignRedirect = await SELF.fetch(
      authorizeUrl(clientId, { redirect_uri: "https://evil.test/steal" }),
    );
    expect(foreignRedirect.status).toBe(400);
  });

  it("completes the code + PKCE flow and serves MCP traffic with the token", async () => {
    const contextId = await uploadSnapshot();
    const { accessToken } = await obtainTokens();

    const initialized = await json(await mcp(accessToken, "initialize", {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: "test", version: "0" },
    }));
    expect(initialized.result.serverInfo.name).toBe("flow-coach-bridge");

    const listed = await json(await mcp(accessToken, "tools/list"));
    expect(listed.result.tools).toHaveLength(6);

    const context = await json(await mcp(accessToken, "tools/call", {
      name: "get_flow_coach_context",
      arguments: {},
    }));
    expect(context.result.structuredContent.contextId).toBe(contextId);
  });

  it("accepts a ChatGPT-shaped DCR callback and resource-bound OAuth flow", async () => {
    const { accessToken } = await obtainTokens({
      clientName: "ChatGPT",
      redirectUri: "https://chatgpt.com/connector/oauth/flow-fixture",
      resource: "https://flow.test/mcp",
    });

    const initialized = await json(await mcp(accessToken, "initialize", {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: "ChatGPT", version: "fixture" },
    }));
    expect(initialized.result.serverInfo.name).toBe("flow-coach-bridge");
  });

  it("enforces the MCP token audience while accepting the legacy origin resource", async () => {
    const foreign = await obtainTokens({ resource: "https://another-resource.test/mcp" });
    const rejected = await mcp(foreign.accessToken, "ping");
    expect(rejected.status).toBe(401);
    expect((await json(rejected)).error_description).toContain("audience");

    // OAuth grants created before path-aware protected-resource discovery
    // used the Worker origin. The provider deliberately treats that parent
    // resource as valid for /mcp, so deploying this change does not force
    // existing Claude connectors to reauthorise.
    const legacy = await obtainTokens({ resource: "https://flow.test" });
    const accepted = await json(await mcp(legacy.accessToken, "ping"));
    expect(accepted.result).toEqual({});
  });

  it("supports refresh tokens so the connector can renew without re-consent", async () => {
    const { clientId, refreshToken } = await obtainTokens();
    expect(refreshToken).toBeTruthy();

    const refreshed = await SELF.fetch("https://flow.test/oauth/token", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "refresh_token",
        refresh_token: refreshToken!,
        client_id: clientId,
      }),
    });
    expect(refreshed.status).toBe(200);
    const tokens = (await refreshed.json()) as { access_token: string };

    const ping = await json(await mcp(tokens.access_token, "ping"));
    expect(ping.result).toEqual({});
  });

  it("limits a read-only grant to the read tools", async () => {
    const contextId = await uploadSnapshot();
    const { accessToken } = await obtainTokens({ scope: "coach:read" });

    const listed = await json(await mcp(accessToken, "tools/list"));
    const names = (listed.result.tools as Array<{ name: string }>).map((tool) => tool.name);
    expect(names).toEqual([
      "get_flow_coach_context",
      "list_routines",
      "get_routine",
      "get_training_summary",
    ]);

    const read = await json(await mcp(accessToken, "tools/call", {
      name: "list_routines",
      arguments: { contextId },
    }));
    expect(read.result.structuredContent.routines.length).toBeGreaterThan(0);

    const refused = await json(await mcp(accessToken, "tools/call", {
      name: "create_pending_routine_patch",
      arguments: { contextId, patch: {} },
    }));
    expect(refused.error.code).toBe(-32602);
    expect(refused.error.message).toContain("patch:propose");

    const pull = await SELF.fetch("https://flow.test/device/pending-patches", {
      headers: { authorization: `Bearer ${DEVICE_SECRET}` },
    });
    expect((await json(pull)).patches).toHaveLength(0);
  });

  it("rejects unsupported scope requests instead of granting nothing", async () => {
    const clientId = await registerClient();
    const response = await SELF.fetch(authorizeUrl(clientId, { scope: "mailbox:admin" }));
    expect(response.status).toBe(400);
  });

  it("never accepts an OAuth token on the Actions or device edges", async () => {
    const { accessToken } = await obtainTokens();
    for (const path of ["/actions/coach-context", "/device/pending-patches"]) {
      const response = await SELF.fetch(`https://flow.test${path}`, {
        headers: { authorization: `Bearer ${accessToken}` },
      });
      expect(response.status).toBe(401);
    }
  });
});
