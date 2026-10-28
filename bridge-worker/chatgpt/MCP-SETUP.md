# ChatGPT MCP compatibility: procedure and result

This is the ChatGPT side of [#49](https://github.com/amomand/flow/issues/49):
connect ChatGPT to the same provider-neutral `/mcp` endpoint already used by
Claude. Do not create a custom GPT and do not use
`FLOW_COACH_ACTIONS_SECRET`.

**Result (28 October 2026): the custom Flow MCP connector works in ordinary ChatGPT on iOS.**
The user added the existing Flow endpoint as a plugin, and all six tools became
available to the assistant in an *existing personal chat*, without restarting
the conversation or entering ChatGPT Work. A live call to
`get_flow_coach_context` reached the Worker and returned the expected
"No unexpired coach snapshot is available. Sync from Flow first."

**Scope of proof:** tool discovery and a live authenticated call to the
bridge are confirmed. The user had not uploaded a fresh snapshot, so actual
routine reads, training history, patch validation and pending-draft creation
have **not yet been exercised** in ChatGPT iOS. Seeing the write tool does not
prove that an end-to-end write is permitted.

## History: the August product boundary has moved

On 1 August 2026, [#49](https://github.com/amomand/flow/issues/49)
proved the same server from ChatGPT Work, but custom MCP was unavailable in
ordinary Chat and on mobile. Work did not bring the user's ordinary ChatGPT
memory and past conversations, so this was a negative *product* result despite
successful MCP compatibility.

The 28 October iOS observation supersedes the Work-only conclusion **for this
account and connector**. It does not prove availability for every plan or
account, or a pending-draft write. A published directory app and multi-tenant
redesign are not necessary for the observed connection.

- [OpenAI: Plugins and supported surfaces](https://learn.chatgpt.com/docs/plugins)
- [OpenAI: Connect and test an MCP server](https://developers.openai.com/plugins/deploy/connect-chatgpt)
- [OpenAI: MCP authentication](https://developers.openai.com/plugins/build/auth)

## What the Worker already supplies

The person-specific endpoint is:

```text
https://<their-host>/mcp
```

It is public HTTPS with stateless Streamable HTTP. An unauthenticated request
returns a `WWW-Authenticate` challenge pointing at path-aware
protected-resource metadata. The Worker publishes authorization-server
metadata, supports dynamic client registration, authorization code with S256
PKCE, refresh tokens and the MCP `resource` parameter, and advertises
`coach:read` or `patch:propose` on each tool as `securitySchemes`, matching the
shape OpenAI documents. The consent page uses that person's existing
`FLOW_COACH_CONNECT_SECRET`.

No static-token path exists. The `/mcp` edge accepts only an OAuth token the
Worker issued itself; the #46 spike's no-auth `/mcp/<token>` mount is gone.

## Connect from ChatGPT

For ordinary ChatGPT, add the person-specific custom MCP connection in
ChatGPT's plugin settings (web setup may be required). The resulting plugin
was usable in an existing iOS chat on 28 October 2026.

1. Add a custom **Streamable HTTP** MCP server, named for the person.
2. Set the URL to `https://<their-host>/mcp`. For the deployed primary
   mailbox use `https://flow-coach-bridge-primary.aomand.workers.dev/mcp`.
3. Leave bearer-token and custom-header fields empty. The Worker handles OAuth;
   never put a Flow secret in a static-token field.
4. Follow the OAuth consent flow and enter `FLOW_COACH_CONNECT_SECRET` from
   the password manager *on the Worker's consent page*. Do not use the device
   credential or Actions secret.
5. Select the plugin in an ordinary ChatGPT conversation. On 28 October, the
   existing iOS chat could see all six tools immediately.
6. Call `get_flow_coach_context`. If it reports an expired/missing snapshot,
   sync from Flow first; this is an expected application-level response.

If the connection returns a bare 401 without opening consent, investigate
OAuth discovery rather than weakening the server to accept static tokens.
The former ChatGPT Work-only instructions describe an obsolete product
restriction, not the desired connection surface.

## Evaluation

Confirmed on 28 October 2026 from **ordinary ChatGPT iOS**: all six tools
discoverable, and `get_flow_coach_context` invoked successfully enough to
return the Worker's missing-snapshot error.

Still to prove **after a fresh Flow sync**:

1. `Use Flow Coach and list the routines in my current snapshot. Do not propose changes.`
2. `Open <routine> and explain its current structure.`
3. `Summarise my recent training without health metrics.`
4. `Suggest one small improvement to <routine>, but do not send it to Flow.`
5. `Validate that exact proposal.` Confirm no draft appears in Flow.
6. `Send that exact proposal to Flow.` Confirm a pending draft, not an applied routine.
7. Preview and reject or apply the proposal in Flow.

Record the surface, date, successful tools, permission and write behaviour,
and Flow inbox outcome without logging routine details, health data or secrets.

## Refresh after a contract deploy

Open the connection from Plugins, select **Refresh**, confirm the tool metadata
changed, and start a new conversation. Compare the schema versions and
operation kinds in the patch tool with the `capabilities` returned by
`get_flow_coach_context` before sending another proposal.

One renewal caveat, not specific to ChatGPT. The OAuth provider compares the
`resource` on a refresh request to the grant's by exact string, so a client
that later re-derives a different-but-equivalent resource has its refresh
rejected with `invalid_target` and must reauthorise with the connect phrase.
Token use is more lenient than token issue. If a connector demands re-approval
with no deploy behind it, this is the likely cause.

## Remaining proof

No Flow server change was necessary to overcome the previous ChatGPT product
boundary. The next step is to verify real-snapshot reads and a pending-draft
round trip, including any client write restrictions. Only Flow can preview,
validate and apply a proposed routine change.

The private-GPT Actions instructions and OpenAPI schema in this directory
remain fallback smoke coverage only.
