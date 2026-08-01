# ChatGPT MCP compatibility: procedure and result

This is the ChatGPT side of [#49](https://github.com/amomand/flow/issues/49):
connect ChatGPT to the same provider-neutral `/mcp` endpoint already used by
Claude. Do not create a custom GPT and do not use
`FLOW_COACH_ACTIONS_SECRET`.

**Result: the server side is proved, and the integration is not useful yet.**
ChatGPT authenticates, discovers the six tools and can drive them, but only
from ChatGPT Work, which does not carry the person's ordinary ChatGPT memory
or previous conversations. The reason to want ChatGPT here was that it knows
the person. No available route delivers that, so this is compatibility rather
than capability. Read the boundary below before spending time on it.

## The OpenAI surface boundary

Two separate limits, and the second is the one that actually bites.

**Custom MCP connections are Work-only.** OpenAI's documentation says plugins
are available with ChatGPT Work on the web and with ChatGPT Work or Codex in
the desktop app, and that they "aren't available in Chat, the IDE extension,
or mobile". Configuring the connection and using it are different surfaces:
even once it is saved and authorised, the tools appear only in a ChatGPT Work
conversation.

**ChatGPT Work does not have the person's memory.** This is the same defect
that demoted the private-GPT Actions route to a fallback, arriving by a
different path: a custom GPT does not inherit ordinary ChatGPT memory or
previous conversations, and neither does Work. Both available ChatGPT routes
drop the personal context, and the one surface that has it is the one that
cannot take connectors.

### Why GitHub and Apple Music work in ordinary Chat

Because they are published, reviewed integrations distributed by OpenAI, not
self-hosted custom MCP connections added through developer mode. The
documentation notes that published plugins "can run in ChatGPT and Codex" and
that published plugins with MCP use reviewed metadata snapshots. Same protocol
underneath; different distribution status. Note this is an inference from two
separate statements rather than something OpenAI states directly.

The consequence is what matters: the route into ordinary Chat is publication
and review, not configuration. That is a poor fit for Flow by design. The
bridge is one deployment per person with a person-specific hostname and connect
phrase and no account system (see [`../RUNBOOK.md`](../RUNBOOK.md) on the
household deployment boundary). A directory app is the opposite shape, and
adopting it would mean introducing exactly the multi-tenancy this design
deliberately avoids.

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

Use ChatGPT web or the desktop app in **ChatGPT Work**, not ordinary Chat.

1. Open **Settings**, then **Security and login**, and turn on **Developer mode**.
2. Open **Plugins**, select the **MCPs** tab, and add a connection. The form is
   headed *Connect to a custom MCP*.
3. **Name**: `Flow Coach — Alex` (or the correct person).
4. **Type**: **Streamable HTTP**, not STDIO.
5. **URL**: the exact person-specific URL including the `/mcp` path.
6. Leave **Bearer token env var** empty, and leave both **Headers** sections
   empty. Those fields are for servers using static credentials. Putting any
   Flow secret there would fail against the OAuth gate and would leave a real
   credential in ChatGPT's configuration.
7. **Save**. ChatGPT probes the endpoint, follows the 401 challenge to the
   protected-resource metadata, registers itself dynamically, and opens the
   Flow Coach consent page.
8. Enter that mailbox's connect phrase from the password manager and approve.
   Not the Actions secret, not the device credential.
9. Review the six discovered tools, then start a new **ChatGPT Work**
   conversation and add the connection from the tools menu.

If Save returns a bare 401 with no consent page, the surface is not performing
OAuth discovery. Record that and stop. Do not add a static-token path to the
Worker to work around it; that would undo the auth model built in
[#38](https://github.com/amomand/flow/issues/38).

## Evaluation

Sync Flow first, then type these prompts. Keep the first pass read-only.

1. `Use Flow Coach and list the routines in my current snapshot. Do not propose changes.`
2. `Open <routine> and explain its current structure.`
3. `Summarise my recent training without health metrics.`
4. `Suggest one small improvement to <routine>, but do not send it to Flow.`
5. `Validate that exact proposal.` Confirm no draft appears in Flow.
6. `Send that exact proposal to Flow.` Confirm a pending draft appears and the
   response does not claim that the routine changed.
7. Preview and reject or apply it in Flow.

Record the date, ChatGPT surface and mode, OAuth result, discovered tool names,
selected tool and arguments for each prompt, write confirmation behaviour, and
Flow inbox result on #49. Never include routine contents, credentials, health
data or access tokens in the issue.

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

## What would change the picture

Nothing server-side. Flow is already compatible and needs no work to stay that
way. The blockers are OpenAI's: connectors reaching ordinary Chat or mobile, or
Work gaining access to personal memory. Until one of those moves, Claude
remains the working coach surface, including on iOS (proved in
[#46](https://github.com/amomand/flow/issues/46)).

The private-GPT Actions instructions and OpenAPI schema in this directory
remain fallback smoke coverage only.
