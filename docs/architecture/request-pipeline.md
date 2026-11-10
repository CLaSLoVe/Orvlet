# Request pipeline

Orvlet treats a request, a task, a source page, and a visible window as separate identities. Selecting a window does not grant it ownership of an in-flight request.

## Boundaries

1. **Receive and record** — `ConversationStore` persists up to 500 messages per task with message, request and task IDs. `TaskRequestContext` captures the explicitly addressed task and source candidate before asynchronous model work. Preparing and queued tasks retain their purpose before a source or interface exists. Global inputs waiting on routing remain an ordered routing inbox, not provisional independent tasks. Explicit card messages queue with their task ID when another task is running.
2. **Interpret** — Jev triage first checks existing controls and saved methods. A complete, confident saved-method match produces a bounded execution contract directly; all other requests use a compact main-model plan with a deduplicated saved-method catalogue (input contracts and source field names, not code, markup or old results). Unrelated method catalogues are omitted for capabilities that cannot execute them; an addressed workspace always retains its current methods even when the update is classified as a control. Construction schemas are deferred to execution; source-bound page operations and composition schemas are omitted until execution owns a page; webpage-design reuse cannot adopt an unrelated task's source; the interpreter has an explicit `reuse` selection carrying only method ID, fresh inputs and source evidence. The host checks route compatibility and exact input keys before materializing its execution step. Structural, target and method-selection errors share the bounded interpretation repair rather than silently changing the requested capability. A saved-method plan executes without a second planning call. Bundled declarative methods (`Resources/methods.json`) and verified user recipes share the same catalogue and executor. `AgentPrompts.interpretation` produces `RequestIntent`: native capability, requested playback, task target, source qualifiers, first destination, presentation-only intent, local/web route, expected behavior (snapshot/live/advancing/interactive), explicit update cadence, IANA time zones, or a clarification question. An invalid tool response gets one JSON recovery attempt. Invalid output never grants a native capability. Ambiguous task references ask for clarification.
3. **Resolve ownership** — an explicitly addressed conversation or a validated Jev destination cannot be silently redirected by the main model. When routing is resolved, the interpreter receives the selected task rather than the entire task catalogue. A resolved target supplies only its own execution conversation and state. The interpreter receives a small task catalogue and recent request-to-task references to resolve follow-ups. Closing a task invalidates its queued work.
4. **Execute** — `AgentController` executes validated Jev matches directly through `reuse_saved_ui`, or uses the main model for further decisions; `ToolDispatcher` validates model argument types, required fields, nesting and declared bounds before capability execution. A structural error names its field path and has a separate two-repair allowance; it does not consume the source/execution failure budget. Internal capability composition uses the host dispatcher without nesting independently cancellable model calls. A known first destination avoids an extra planning round. Navigation and actions return fresh observations. Timer deadlines retain request time; calculations run in an isolated local worker. An invalid argument rejected before a native write may be repaired; an uncertain write or read-back failure is never retried as a formatting error. API requests remain on the API route: navigation is excluded from both offered tools and host permissions. Repeated source/reuse failures stop after one repair instead of converting into webpage construction. A verified webpage may still fall back to a source-bound presentation.
5. **Present** — pure appearance changes use `reviseTaskInterface`; source, location, data and behavior corrections stay in the execution pipeline. Both automatic composition and visual revision use `StructuredResponse`: validate, repair with internal feedback, then commit. At most three generation attempts occur. A bad candidate leaves the existing card intact. Revision tickets reject late responses.
6. **Verify and finish** — model prose and generated titles are not receipts. Playback requires advancing media time, the required audio/video state, and no ad. A pause needs observed paused media. Page qualifiers need bound source readings: a primary or selected identifying label plus the actual result in the same source region. Navigation links and unrelated regions cannot prove the active result. Once finish succeeds, trailing actions in that response do not execute.
7. **Record** — replies carry the request's owner. Request stage transitions and durations can be logged without including message contents or credentials. These timings separate interpretation, execution, presentation and verification cost. Tool records include request/task IDs and execution revision; structural errors retain a field path, not argument values.

## Model responsibilities

- **Local code:** exact transport controls, timers, code-action execution, state refresh, source validation, revision checks, ownership, persistence and completion receipts.
- **Main model:** task understanding and clarification, source operations, semantic interpretation, generated layout and repair.
- **Jev:** optional background ordering from anonymous allowlisted category/status/aggregate signals. It also classifies eligible short requests using one parallel set of typed choices for target, reasoning effort, direct existing-task control, saved-method fit and each required parameter. It does not generate cards or approve completion. Unavailable credentials/network fall back to local ranking. Changing its setting invalidates pending ranking work.

Visual guidance lives in the existing Pearl & Ink design contract. The main decision context includes it once; the automatic design stage receives it directly. No extra permanent task-list controls are required.

## History terminology

- **Tasks:** saved task state and active task cards.
- **Task history:** an index of active, hidden and closed tasks. Each entry opens only its own conversation. The general composer never renders a mixed transcript. Drafts, queued new requests, replies and clarification context retain task ownership.
- **Closed tasks:** closing disposes execution but saves a paused snapshot and conversation; History can restore the same task. Deleting task history is a separate confirmed action and removes only that task’s card, saved state and messages.
- **Legacy messages:** existing task IDs are retained; request IDs group previously unattributed requests. Older messages without IDs are split at user-request boundaries, without guessing an association to a visible card.
- **Recent pages:** visited URLs and their restore snapshots. Clearing these does not silently delete conversations.
- **Startup restoration:** recreates saved tasks/pages under existing playback policy. A restored design still needs fresh source validation. UI opening and a follow-up execution share one awaited source-restoration job; a saved webpage need not be manually reopened first. Restoration preserves task identity and holds media until explicit play intent.

Settings provides separate clearing actions for recent pages and conversations. Older versions did not persist conversation text, so messages lost before this migration cannot be recovered.

## Verification and limits

`PipelineCheck` covers internal schema repair, cancellation, safe failure text, persisted attribution, queued cross-task messages, source qualifiers, and a real WebKit correction from a New York fixture to a Beijing fixture. It deliberately tries to certify a renamed wrong-source card first; that attempt must fail. Other suites cover live bindings, playback, interruption, settings, window layout and stale generation.

Source-region checks are conservative structural evidence, not a universal semantic proof. Pages lacking usable identifying labels can remain unverified and require source inspection. Arbitrary website behavior and real provider reliability require separate live acceptance; passing deterministic checks does not establish that a public music site played the requested track. Local credential-store failures must be reported separately from model or playback failures.

## Continuing execution

`TaskRuntimeSpec` describes host capabilities rather than arbitrary scripts in the
card. `TaskRuntimeEngine` owns a single scheduler and separate task generations:

- Native clock, elapsed and deadline sources sample once per second, independently
  of any slower scheduled calculation in the same task. Clock zones are real IANA
  zones, not title changes or frozen offsets. The clock uses the Mac's system time. `time` displays HH:mm:ss, including
  seconds; clock `seconds` is a Unix epoch value and cannot prove a requested
  local time zone. That legacy wire format remains readable for saved tasks.
- `refresh` runs pure synchronous code in the existing disposable CPU worker. It
  has a declared 1–3600 second interval and output keys, starts after the first
  interval, never overlaps itself, and receives current inputs and host time.
  It has no browser, network, shell or credential API. Web data continues to use
  observed page bindings; this reducer is not a generic internet polling API.
- Compact, expanded and hidden presentations share the same state. Changing the
  selected card does not change the execution owner. Pause freezes elapsed time;
  resume excludes the paused duration. Stop/close cancels pending workers, and a
  generation check rejects late results. Closing removes the task, hiding does not.
- Failed updates keep the previous value with a stale indication and bounded
  backoff. A separate healthy native source cannot erase a reducer's failure.
- Sources, inputs, code, phase and last values persist. Reducer state checkpoints
  at most every ten seconds and on normal termination/control changes. A forced
  process kill may lose updates since the last checkpoint. Restored running tasks
  resume; paused tasks stay paused. Absolute clocks catch up after sleep; periodic
  reducers execute once when due and do not replay every missed sleep interval.

The initial input values are required in `state`, not only HTML attributes.
Generated local action handlers execute representative changed-input examples
before publication. Non-finite numerical outputs fail explicitly. Invalid user
input preserves the input and last good result and reports to its owning task.
These examples are executable checks, not a proof of arbitrary generated logic;
real changed-input acceptance remains necessary.

`present_ui(complete:true)` asks the host to verify and terminate without another
model round. Short schedules must produce two real executions; requested advancing
outputs must visibly change. Long schedules first dry-run without applying the
result and register the future callback; the receipt says **scheduled**, not that
future data has already arrived. A rejected final candidate restores the previous
task when its generation still belongs to that request. Failed result placeholders
never start automatic interface decoration.

## Operational evidence

Normal builds keep the last 600 diagnostic events (stage, duration, category,
task/request identifiers, method-match decisions, request byte counts and provider-reported token counts). They contain no prompt text, generated code, URLs, data
values or keys and are available through Settings → Copy diagnostics. Detailed
synthetic acceptance traces are explicitly enabled by the Debug harness only. Debug checks use a separate diagnostics store and cannot evict production events.

`scripts/delivery-check.py` runs `DeliveryCheck` against a signed Debug bundle with
the same entitlements as Release. It sends short real requests to the configured
provider, checks both actual WebKit renderings, presses a generated form button,
checks invalid input and task isolation, then exports synthetic state for a second
process restoration check. Evidence is exported through an inherited pipe so the
macOS application sandbox remains enabled. A build or local test count is never
used as a substitute for this provider/UI acceptance.

Both Xcode and the packaged app now declare the same sandbox/network entitlements.
This preserves the existing Xcode app's preference/container identity. The build script uses the sole available Apple Development / Developer ID Application
identity when present (or `ORVLET_SIGNING_IDENTITY`), falling back to ad-hoc signing
when no unambiguous identity is available. The local package is not notarized. A
stable signing identity preserves application continuity across builds; macOS
still owns system permission decisions. Model keys use app-owned local storage,
not the user Keychain.

### Request triage and transfer

Jev routing requires 0.95 confidence and selected probability; direct media controls require 0.98 for the control as well. Budget advice requires 0.8. Unknown options, invalid distributions or ambiguity fall back. One call has a 1.2 s network timeout; failures trigger a 60 s cooldown. Model keys are read from the app-owned private local store. Ordinary complex requests may incur this bounded advisory overhead; direct controls and concurrent global routing can replace a main-model call. No universal speedup is claimed.

The router passes a short-lived PreparedRequest into immediate, queued and steered execution. A matching request, target identity, source/title/intent/lifecycle, method and input signature and 15 s freshness window are required; new-task catalogue changes also invalidate independent-task decisions. Calendar clarification is reinterpreted with its owning conversation. Completion still requires existing host verification.

Budget mappings: known xAI Grok 4.5/4.6/4.7 use low/medium/high reasoning_effort; known SiliconFlow DeepSeek hybrid variants use enable_thinking and thinking_budget. Unknown gateways/models receive no speculative parameters. Standard preserves prior application defaults. A failed execution step raises low advice to normal without increasing retry limits.

Primary API references: https://docs.typesafe.ai/primitives/choice ; https://docs.x.ai/developers/model-capabilities/text/reasoning ; https://docs.siliconflow.com/en/api-reference/chat-completions/chat-completions .

### Direct saved-card reuse

`FastCardReuse` adds bounded saved-method candidates and parameter choices to the
same Jev `/systemone` request. It sends screened purpose/input/output descriptions,
never stored results, handler code, source URLs or persistent IDs. Parameters are
finite choices: numeric literals from the request, declared select options,
quoted/explicitly assigned text, and a bounded set of IANA time zones. It does not
ask Jev to generate arbitrary JSON, code or a new interface.

A direct match requires known task ownership (0.95 route confidence and probability,
or an explicit owning conversation), 0.95 for whole-request fit, and 0.98 confidence and probability for the
card selection and **every** parameter. Select inputs may expose their full native option list while Jev receives at most 64 declared choices, prioritizing literal values in the current request. Missing inputs, additional
requirements or unsupported formats use the main model. Existing targets must own
the same recipe and unchanged design/method. Recipe fingerprints and target input
signatures invalidate obsolete queued decisions. Rendered height is measurement, not method identity. Task destinations and method selections have distinct, catalogue-constrained IDs validated before execution.

Eligible fast methods currently include pure local forms with
one code action and stored behavior checks, and parameterized public-data cards
whose changing source inputs have response identity checks. Webpage navigation,
new music searches, multi-action/agent forms and unsupported parameter shapes keep
the existing main-model path. These limits do not prevent ordinary card reuse by
the main model.

A successful match calls the normal executor without a main-model interpretation
or planning request. API cards fetch fresh data and check identity/freshness. Input requirements are checked against bound inputs; source-changing inputs also require matching response expectations. External facts must match extracted source fields, independently of evidence-array order. Local
cards initialize from new inputs and run their behavior checks. Host verification still decides completion. An execution
failure triggers main-model interpretation once, without trying Jev again for that
request. Main-model credentials are loaded only if that path is needed. The existing
1.2 s Jev timeout, cooldown and disable setting remain in effect.

`FastCardReuseCheck` covers strict decoding, new parameters, ownership, stale advice,
disabling, fresh source reads and failure fallback. `BuiltinCardsCheck` exercises
the actual rendered reused currency card with zero main-model calls. The opt-in
`--fast-reuse-live-check --allow-live-services` probe uses only synthetic methods
and requests against the configured Jev service; it records classifier timing
separately from source-fetch and UI timing.

## Running input and cancellation

The same task remains eligible while preparing, executing or queued. Eligible non-sensitive purpose text is bounded to 240 characters for Jev; private/oversized intent is omitted. Routing validates the candidate set across its await. Preparation-to-resource adoption records an alias and transfers queued requests to the canonical task ID. A request's own newly created placeholder does not invalidate its prepared reuse choice.

A same-task update cancels the complete understanding stage (including Jev and credential preparation), the current decision and the current execution child task. Earlier human inputs remain available to interpret additive requests as well as corrections. Revision checks still reject late results from operations that ignore cancellation. Other tasks retain their own resources. Audio ownership is globally exclusive within the app: the playback coordinator holds all other sources, awaits their native pause, then releases the requested source. Inactive pages cannot autoplay themselves back into ownership; an explicit playback operation can transfer ownership again. Closing a player does not automatically resume a previously held player. Execution of unrelated task requests remains serialized by the existing host; this change does not introduce parallel writers over AppModel's global page state.

The opt-in `--request-pipeline-live --allow-live-services --with-music` check calls the normal `sendCommand` path with configured services and real public data. Task/recipe writes use an isolated defaults suite. Raw traces are local-only. It checks fresh method reuse, stable method/card identity on input changes, overlapping creation/correction/addition, and exactly one playing source after an in-flight replacement. Add `--music-only --execution-replace` to additionally interrupt a replacement after source execution has begun, retaining the same media owner.

### Routing and audio ownership are separate

An existing-task Jev match stays authoritative. A new-task prediction with live candidates remains advisory: main interpretation sees those activities rather than treating the prediction as permission to ignore them. Both stages distinguish a continuing activity from its changing content. `needsBrowserContext` only requests inspection of a resolved existing page; a new source is discovered during execution. Invalid use receives bounded contract feedback instead of asking which unavailable task to continue. Desired actions expressed conversationally are valid instructions; internal source/card selection is not a reason to ask a clarification question.

`PlaybackCoordinator` registers every browser, including parked and discovery pages. Document-start gates hold new/inactive media; native pause acknowledgement covers all frames. Its revision prevents an obsolete or cancelled transfer from releasing a superseded player. Loading an unrelated page does not interrupt existing audio. `ListeningCheck` verifies pause-before-play transfer, blocked background autoplay, explicit resume and cancellation. The opt-in `--request-pipeline-live --allow-live-services --music-only --natural-request` exercises natural requests, same-player content changes, explicitly separate players and exclusive resume against real providers and YouTube.

The mounted pipeline live harness does not register a global shortcut or expose its command panel to user input. It records full local failure traces on timeout, while production support logs remain bounded metadata.
