import { SELF } from "cloudflare:test";
import { expect } from "vitest";

/** Matches FLOW_COACH_CONNECT_SECRET in vitest.config.ts. */
export const CONNECT_PHRASE = "fixture-connect-phrase-0123456789abcdef";

export const REDIRECT_URI = "https://client.test/callback";

export interface TokenSet {
  clientId: string;
  accessToken: string;
  refreshToken?: string;
}

/**
 * Runs the whole OAuth 2.1 flow a Claude connector would: dynamic client
 * registration, the consent page with the connect phrase, then the
 * authorization-code + PKCE token exchange.
 */
export async function obtainTokens(options: { scope?: string } = {}): Promise<TokenSet> {
  const registration = await SELF.fetch("https://flow.test/oauth/register", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      client_name: "Fixture MCP client",
      redirect_uris: [REDIRECT_URI],
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      token_endpoint_auth_method: "none",
    }),
  });
  expect(registration.status).toBe(201);
  const client = (await registration.json()) as { client_id: string };

  const verifier = randomUrlSafe(64);
  const challenge = await s256(verifier);
  const authorizeUrl = new URL("https://flow.test/oauth/authorize");
  authorizeUrl.searchParams.set("response_type", "code");
  authorizeUrl.searchParams.set("client_id", client.client_id);
  authorizeUrl.searchParams.set("redirect_uri", REDIRECT_URI);
  authorizeUrl.searchParams.set("state", "fixture-state");
  authorizeUrl.searchParams.set("code_challenge", challenge);
  authorizeUrl.searchParams.set("code_challenge_method", "S256");
  if (options.scope !== undefined) authorizeUrl.searchParams.set("scope", options.scope);

  const consent = await SELF.fetch(authorizeUrl, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ connect_phrase: CONNECT_PHRASE }),
    redirect: "manual",
  });
  expect(consent.status).toBe(302);
  const redirected = new URL(consent.headers.get("location")!);
  expect(`${redirected.origin}${redirected.pathname}`).toBe(REDIRECT_URI);
  expect(redirected.searchParams.get("state")).toBe("fixture-state");
  const code = redirected.searchParams.get("code")!;
  expect(code).toBeTruthy();

  const exchange = await SELF.fetch("https://flow.test/oauth/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code,
      client_id: client.client_id,
      redirect_uri: REDIRECT_URI,
      code_verifier: verifier,
    }),
  });
  expect(exchange.status).toBe(200);
  const tokens = (await exchange.json()) as { access_token: string; refresh_token?: string; token_type: string };
  expect(tokens.token_type.toLowerCase()).toBe("bearer");
  return { clientId: client.client_id, accessToken: tokens.access_token, refreshToken: tokens.refresh_token };
}

function randomUrlSafe(length: number): string {
  const bytes = new Uint8Array(length);
  crypto.getRandomValues(bytes);
  return base64Url(bytes).slice(0, length);
}

async function s256(verifier: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return base64Url(new Uint8Array(digest));
}

function base64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}
