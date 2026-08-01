# ChatGPT MCP compatibility proof

This is the target ChatGPT integration for
[#49](https://github.com/amomand/flow/issues/49): connect ChatGPT to the same
provider-neutral `/mcp` endpoint already used by Claude. Do not create a custom
GPT and do not use `FLOW_COACH_ACTIONS_SECRET`.

## Current OpenAI product boundary

OpenAI currently exposes plugins and custom MCP connections in ChatGPT Work on
the web and in the desktop app. Its documentation says plugins are not
available in ordinary Chat or mobile. This procedure therefore proves that
ChatGPT can authenticate, discover and use Flow's tools; it cannot yet prove
the desired ordinary ChatGPT iPhone experience.

- [OpenAI: Plugins and supported surfaces](https://learn.chatgpt.com/docs/plugins)
- [OpenAI: Connect and test an MCP server](https://developers.openai.com/plugins/deploy/connect-chatgpt)
- [OpenAI: MCP authentication](https://developers.openai.com/plugins/build/auth)

## What the Worker already supplies

The person-specific endpoint is:

```text
https://<their-host>/mcp
```

It is public HTTPS with stateless Streamable HTTP. An unauthenticated request
returns a `WWW-Authenticate` challenge pointing at protected-resource
metadata. The Worker publishes authorization-server metadata, supports dynamic
client registration, authorization code with S256 PKCE, refresh tokens and the
MCP `resource` parameter, and advertises `coach:read` or `patch:propose` on each
tool. The consent page uses that person's existing
`FLOW_COACH_CONNECT_SECRET`.

## Connect from ChatGPT

Use ChatGPT web or the desktop app in **ChatGPT Work**, not ordinary Chat.

1. Open **Settings**, then **Security and login**, and turn on **Developer mode**.
2. Open [ChatGPT Plugins](https://chatgpt.com/plugins) and select the plus button.
3. Name the connection `Flow Coach — Alex` (or the correct person).
4. Choose a public MCP connection and enter the exact person-specific URL,
   including `/mcp`.
5. Create the connection and review the six discovered tools.
6. ChatGPT opens the Flow Coach consent page. Enter that mailbox's existing
   connect phrase from the password manager and approve. Do not enter the
   Actions secret or device credential.
7. Start a new **ChatGPT Work** conversation and add the Flow Coach connection
   from the tools menu.

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

Open the connection from ChatGPT Plugins, select **Refresh**, confirm the tool
metadata changed, and start a new conversation. Compare the schema versions
and operation kinds in the patch tool with the `capabilities` returned by
`get_flow_coach_context` before sending another proposal.

The existing private-GPT Actions instructions and OpenAPI schema remain in this
directory only as fallback smoke coverage.
