# Orvlet product and execution contract

This consolidates the product decisions behind the prompts. Product examples are acceptance cases, not fixed modes or keyword routes. The assistant must support unfamiliar requests by composing capabilities. Host permissions and receipts are authoritative; prompts express intent and interaction policy.

## Entry, ownership and continuity

- Global Alt-Space input resolves new work versus continuation from meaning, conversation, task purpose and current state. A user-selected conversation is authoritative.
- Replacing parameters/content normally continues the same ongoing purpose. Independent work, explicit additions and side-by-side comparisons remain separate. Category alone does not justify merging.
- New input can correct, redirect, complete or cancel a task. Canceling a draft does not undo a completed external side effect. Superseded work must stop without stale results overwriting the latest state.
- Reuse saved methods, layouts and inputs. Refresh external facts to the requested freshness; cache a method, not a claim that old data is current.

## Capabilities and outcomes

- Prefer existing verified controls, pure local execution, appropriate structured APIs, then browser interaction when required. Explicit sources, authentication and requested browser workflows take precedence over a generic API preference.
- Generate purpose-appropriate interactive tools, not only read-only answers. Prefer composable input/output/action primitives when they fit; custom layouts remain available. Expose adjustable parameters, run ordinary edits locally where possible, fetch only when the source changes or needs refreshing, and keep units/identity bound to actual results.
- One host receipt completes the action. Source verification, computation and presentation are separate: invalid optional presentation can fall back without discarding valid data. Missing evidence cannot be disguised by a successful interface.
- Preserve ongoing work, playback, position and inputs. Changing a setting or content does not require recreating a player or its UI. Unsupported actions stop with a clear explanation instead of destructive retry loops.
- Local runtime scheduling and source freshness are explicit. A snapshot is not monitoring; a clock is not a countdown; daily reference data is not a live quote.

## Conversation and lifecycle

- Brief visible progress describes observable work. Do not expose hidden chain-of-thought. Replies are natural, concise and specific about outcomes, missing details or blockers.
- UI labels and system notices use English. Conversational answers follow the user's language unless requested otherwise.
- Cancellation notices identify the task in very few words. A countdown may Hide a notice; acknowledgment closes it. Hide preserves recoverability; Close ends/removes the active card while history is retained under the established lifecycle.
- The task list edit icon exposes Hide and Close with drag reordering. Compact context menus stay minimal (Chat, Hide); Chat opens the owning task conversation. Dragging out to close must visibly preview the consequence and animate it.

## Calm interface

- Follow CalmVisualStyle: Pearl & Ink, compact, quiet, clear hierarchy, sparse chrome, stable updates, restrained motion.
- Keep direct essential controls and a simple Add entry. Do not create dashboards, permanent drag instructions, redundant controls or search for a handful of tasks.
- Expanded UI is purpose-specific; compact UI shows the key state/action; original webpages remain accessible as sources. Compact music omits video and progress clutter.
- Prebuilt music, clock, currency, weather, timer and calendar cards use local layouts. Currency has named native currency selectors, atomic swap when both selectors support the same choices, local amount recalculation, and an actual source date. Enter edits the field rather than activating an unrelated nearby action.
- Recognized old standard currency layouts upgrade when opened; deliberately edited layouts remain authoritative. Native timer/calendar details size to their measured content and remain available when explicitly expanded after completion. Do not spend a model call decorating these native tasks.
- Settings group related decisions intuitively. Access/readiness is a page, with functional actions and first-run checking. Optional browser pairing remains hidden/disabled for now.

## Readiness and data handling

- Onboarding offers recommended/all available access and checks configured model connectivity and relevant permissions before use. Explain missing setup early. OS revocation, future capability grants and service outages cannot be guaranteed away.
- Jev may advise reasoning budget and routing, directly control existing tasks, or select an existing saved card and every required parameter when confident. Complete matches run the saved method through host verification without main-model interpretation/planning; API cards fetch fresh data. Ambiguity, unsupported methods/parameters, changed recipes/targets and failed execution fall back to the main model. Disabled/unavailable Jev uses default effort and the main route; task ordering retains local rules.
- No duplicate interpretation after successful global routing. Advice is scoped to this request and invalidated by meaningful target changes.
- Credentials are app-owned private local data, never task context, repository content or bundle assets. Do not access the user's Keychain for model keys. Keep publication and bundle secret checks.
- Non-sensitive task context may go to configured model services. Optional Jev task metadata remains anonymous and limited; sensitive content/credentials are not covered by that permission.

## Latency and verification

- Aim for roughly 10–20 seconds end to end when provider/tool latency permits, including moderately complex local tools. Measure from input to verified completion, not just API transport or first token. This is a target, not a universal guarantee.
- Prefer one interpretation and one terminal execution call. Scope prompts/tools by capability. Reuse execution logic for initial output and later interaction. Reusing a saved local tool recalculates fresh inputs with its saved handler and returns a terminal receipt through the same verification path. Batch known steps without guessing dependent results.
- Preserve necessary ownership, permissions, freshness, side-effect and behavior checks. Remove duplicate compilation, identical action checks and duplicate suite invocation; do not reduce correctness to make a timing number.
- Keep explicit fallbacks for genuinely complex or slow work. Avoid arbitrary short deadlines that turn progress into failures. Report measured task categories, model calls, retries and total time.

## Prompt ownership

- AgentPrompts: shared contract plus interpretation/native/local/API/web instructions only as needed.
- Tool schemas: exact argument shape and capability constraints. TaskForm composes reusable controls; custom markup remains available. CardMarkup/CalmVisualStyle own the visual contract.
- AgentController: task context, scoped tools, correction handling and terminal receipts.
- TaskVerification and domain transports: actual outcome/behavior verification, never merely a model assertion. Validation feedback identifies the actual defect; avoid duplicate parameter declarations and arbitrary presentation constraints that force needless repair rounds.
