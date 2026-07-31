# Private ChatGPT GPT setup and proof (fallback)

This package is retained for Actions smoke testing. It is not the target
integration for [#49](https://github.com/amomand/flow/issues/49): private GPTs
do not inherit ordinary ChatGPT memory or previous conversations. For the
provider-neutral MCP route and its current OpenAI surface boundary, use
[`MCP-SETUP.md`](MCP-SETUP.md). The Worker Actions edge still exists; no
ChatGPT developer mode or MCP plugin is involved in this fallback.

## Create the private GPT

1. In ChatGPT on the web, create a GPT and keep its sharing set to private.
2. In the GPT editor, paste [`instructions.md`](instructions.md) into Instructions.
3. Add an Action and import [`openapi.json`](openapi.json).
4. Replace the example server host
   `flow-coach-bridge-person.example.com` in the schema with the hostname of
   the one mailbox this GPT is for. Do not reuse the GPT for another person.
   For the currently paired primary mailbox, that is
   `flow-coach-bridge-primary.aomand.workers.dev`.
5. Set Action authentication to **API key**, choose **Bearer**, and enter that deployment's existing `FLOW_COACH_ACTIONS_SECRET` from the password manager. Do not paste the secret into the schema, instructions, a chat, an issue, or a screenshot.
6. Save the GPT as private. A public listing is out of scope and would introduce separate privacy-policy and review work.

The schema uses ordinary `Authorization: Bearer …`;
[ChatGPT Actions do not support arbitrary custom headers](https://developers.openai.com/api/docs/actions/production).
The validation POST is explicitly non-consequential. Creating a pending patch
is marked `x-openai-isConsequential: true`, so ChatGPT must ask before every
draft write. That confirmation is useful, but Flow's local preview and apply
decision remains the authority.

## Editor smoke test

Use the editor's **Test** control once for each of the six actions:

1. `get_flow_coach_context`
2. `list_flow_routines`
3. `get_flow_routine`
4. `get_flow_training_summary`
5. `validate_flow_routine_patch`
6. `create_pending_flow_routine_patch`

The last two need a patch constructed from a current synthetic or deliberately chosen real snapshot. Agree a harmless, reversible change first. Validation must not create an inbox item. Creation must show ChatGPT's confirmation, return `provenance: chatgpt-actions`, and create only a pending Flow draft.

## Conversation proof

Run a small fixed prompt set in a fresh conversation:

1. “What Flow routines can you see? Do not propose changes.”
2. “Read `<routine>` and explain its current structure.”
3. “Summarise my recent training without health metrics.”
4. “Suggest one small improvement to `<routine>`, but do not send it to Flow.”
5. “Validate that proposal.” Confirm that no draft appears in Flow.
6. “Send that proposal to Flow.” Confirm that ChatGPT asks first, then that Flow shows a pending draft rather than a changed routine.
7. Reject or apply the draft in Flow and confirm the ordinary local preview, validation and history behaviour.

If this fallback is intentionally exercised, repeat the read and one draft proposal from the same private GPT in the ChatGPT iPhone app. Record the date, surfaces, GPT sharing state, confirmation behaviour, returned provenance, and Flow inbox result without including routine content, credentials, or health data. Do not treat success here as the #49 MCP target.

## After the patch contract changes

`npm run check:chatgpt-actions` keeps the checked-in schema aligned with the bridge's shared operation and text-bound contract. It cannot update a GPT that has already imported an older copy.

After a deploy that changes operation kinds, schema versions, input fields, or Action descriptions:

1. Import the current `openapi.json` into each affected private GPT and save it.
2. Start a fresh conversation.
3. Ask the GPT to compare the schema versions and operation kinds it can compose with the `capabilities` returned by `get_flow_coach_context`.
4. If the fresh `advisory` reports a mismatch, stop before creating a patch and refresh the Action schema again.

The private GPT is a per-person client configuration, not an authorization boundary by itself. The person-specific Worker deployment and Actions secret remain the boundary.
