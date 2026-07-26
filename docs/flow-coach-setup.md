# Setting up the Flow Coach bridge for one person

Everything one person needs, once. Repeat it per person against their own deployment. The architecture and the reasoning behind the boundaries are in [flow-coach-bridge-architecture.md](flow-coach-bridge-architecture.md); this is the practical walkthrough.

Doing this for someone else needs their phone and their Claude account both to hand, so it is a sit-down-together job rather than something the operator can prepare in advance.

## Before you start

The operator needs three values for that person's mailbox, generated at deploy time and kept in a password manager:

| Value | Goes into | Never goes into |
|---|---|---|
| Hostname | the pairing screen in Flow, and the connector URL | anywhere untrusted |
| Device credential | the pairing screen in Flow, once | a chat, a note, a commit |
| Connect phrase | the consent web page, once | a chat, a note, a commit |

The device credential and the connect phrase are both 64 hex characters and look identical at a glance. They are not interchangeable, and mixing them up produces a 401 with no clue as to why. If you ever find yourself pasting either into a conversation with an assistant, stop.

Custom connectors work on Free, Pro, Max, Team and Enterprise plans, and on the mobile apps as well as web and desktop. Free is limited to one custom connector, and on Team or Enterprise an Owner has to add it.

## 1. Pair Flow to the mailbox

On the phone, in Flow Coach, under COACH MAILBOX:

1. Tap PAIR MAILBOX.
2. Give the mailbox a name. This is display text so the person can tell theirs apart; it is not an authorization input.
3. Enter the hostname and paste the device credential. Typing 64 characters by hand on a phone is a bad idea: put the credential in the password manager first and paste it from there.
4. Tap PAIR.

Flow checks the address and the credential against the mailbox before it saves anything, so a screen that says paired is one that has worked at least once. The three ways it can fail need different things from you and say which: a rejected credential names the credential, an address nothing answers at names the address, and a deployment with no mailbox configured yet is neither, and not fixable from the phone. Nothing is written unless the check passes, so a failed attempt leaves an existing pairing exactly as it was.

Pairing with no connection still works. It is saved unchecked, the mailbox section says so until something proves it, and the first successful sync settles it. Rotating a credential is the exception: Flow will not replace a working credential it cannot check, so rotate when you have a connection.

## 2. Choose and approve what leaves the device

Nothing uploads until the categories have been seen and approved.

1. Tap REVIEW next to SHARING.
2. Routines and strength history sit under RECOMMENDED and are already selected. Cardio totals and Apple Health derived figures sit under A STEP FURTHER, off unless chosen; turning on health metrics asks again and shows what that tier covers before it goes on.
3. Tap APPROVE THESE CATEGORIES.

Changing the selection later revokes the approval, so a widened selection is always re-confirmed. Narrowing it does not retroactively shrink a snapshot already uploaded: delete the snapshot and sync again. If the selection ends up wider than the recommended pair, the mailbox section says so without anyone having to open the sheet, and one tap in the sheet gets back to exactly the recommendation.

## 3. Sync

Tap SYNC TO COACH. A last-synced time and an expiry appear.

A snapshot lives 24 hours and then the Worker deletes it. There is no background upload and nothing ever nags: the rhythm is sync before a conversation, not sync every day. One sync covers as many conversations as you like within the day, and going a fortnight without talking to the coach means doing nothing for a fortnight. Starting a chat with no live snapshot simply makes the tools tell the assistant to ask for a fresh sync.

A draft the assistant has already proposed does not die with its snapshot. Patch payloads last seven days independently, so a proposal made on Monday is still waiting on Thursday.

## 4. Add the connector

Do this on desktop or web. Connectors are stored against the Claude account, so it appears on that person's phone afterwards.

1. Settings, then Connectors, then add a custom connector rather than browsing the directory.
2. Name it for the person, for example `Flow Coach (Alex)`. The URL is the hostname with `/mcp` on the end.
3. Leave the authentication fields blank. The connector discovers the OAuth endpoints itself.
4. A page served by that person's own Worker opens, headed "Flow Coach bridge". It names the client and lists what it gets: reading routines and training summary, and storing draft edits for Flow to preview. Enter the connect phrase and approve.
5. Approving redirects back to Claude. Six tools should be listed on the connector.

Before the first real conversation, check the data-training setting on that Claude account. Syncing exposes nothing to the assistant; this is the step where the data actually reaches it.

## 5. Decide about tool approval

The assistant asks permission per tool. Five of the six tools are read-only; only `create_pending_routine_patch` writes anything, and even that only stores a draft.

Allowing the five reads permanently and leaving the write to prompt each time turns five prompts per conversation into one, and keeps the prompt on the only call that puts something in the inbox. Make that choice deliberately: the permanent option is account-scoped, applies to every device, and is awkward to reverse. It is a convenience setting, not a safety boundary. Flow's preview and apply is the safety boundary.

## 6. A Project per person

A Claude Project holds its own instructions and conversations. One per person, with only that person's connector enabled, is what stops two people's training context mixing. Give it instructions along these lines:

```text
You help me adjust my strength routines in Flow.

Before suggesting anything, call get_flow_coach_context to see my current
routines and recent sessions. Work from what is actually there, not from
memory of earlier chats.

When you propose a change, use create_pending_routine_patch. Copy routineId
and baseContentHash exactly as they appear in the snapshot; never guess or
construct a hash. Keep changes small and give a clear rationale, because I
read it in Flow before deciding.

Base-value edits do not cascade into phase overrides. If a change should
apply to the peak or deload phase too, say so and patch those explicitly.

You cannot apply changes. Everything you propose waits in Flow for me to
preview and accept or reject. Do not tell me a change is done.

About me: [goals, training days, injuries or exercises to avoid, equipment]
```

That last line is the difference between generic advice and something useful.

## Using it

Sync, then talk. Anything the assistant proposes arrives as a draft in Flow, which pulls automatically whenever the Flow Coach sheet opens. Preview the exact before and after, then apply or reject.

Three things that will come up:

- A snapshot older than 24 hours is gone, so sync again before asking for changes.
- Editing a routine in Flow after a draft was proposed can make that draft stale. Flow shows it as a conflict and clearing it reports `stale` rather than `rejected`.
- Two drafts for the same routine from separate conversations are both kept. Flow warns that applying one makes the others stale.
- A change to a base value does not carry into the phase overrides. Where the exercise overrides the same field, the preview lists what each phase ends up doing and says when one has stopped being a step up from base. It reports rather than blocks: a peak that matches base on sets and carries the progression on reps is a fine thing to want.

## If something goes wrong

| Symptom | Cause |
|---|---|
| Pairing says the credential was rejected | wrong device credential, or it was rotated on the bridge |
| Pairing says nothing answered at that address | wrong hostname |
| Pairing says the mailbox is not set up | that deployment has no mailbox configured; nothing to fix on the phone |
| The mailbox says the pairing has not been checked | paired with no connection; the first sync settles it |
| Sync says the credential was rejected | rotated on the bridge since pairing; rotate it in PAIRING |
| Sync cannot reach the mailbox | no network, or the Worker is down |
| Consent page says the phrase is not right | wrong connect phrase for that mailbox |
| Consent page sits there after approving | see [#59](https://github.com/amomand/flow/pull/59); fixed, but a stale deployment would reproduce it |
| Assistant says there is no snapshot | nothing synced, or the snapshot expired |
| Tools missing from the connector | the grant was scoped to `coach:read` only |

## Turning it off

Removing the connector in Claude stops the assistant reaching the mailbox. Rotating the connect phrase stops new authorisations but leaves existing grants valid, so a full revocation also means deleting that environment's grants from `OAUTH_KV`, as described in the runbook.

SIGN OUT in Flow stops remote calls and leaves routines, inbox and history untouched. WIPE MAILBOX deletes everything the mailbox holds, and cannot retract a draft already pulled into Flow.
