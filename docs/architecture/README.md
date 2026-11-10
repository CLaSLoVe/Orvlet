# Architecture map

Orvlet has one native application target. Feature folders define source ownership;
they are not separate Swift packages. `AppModel` is the observable composition
root shared by the shell and feature controllers. It holds application state and
wires services; feature extensions implement task, browser and storage behavior.

## Source ownership

| Directory | Responsibility | Start here |
| --- | --- | --- |
| `Orvlet/App` | Application composition, windows, shortcuts, diagnostics and service adapters | `OrvletApp`, `AppDelegate`, `AppModel`, `RuntimeTaskAdapter`, `DataTaskController` |
| `Orvlet/Core` | Foundation-only errors, JSON text and bounded scalar state | `AppError`, `JSONText`, `TaskValues` |
| `Orvlet/Agent` | Request interpretation, model transport, execution loop, prompts, interface composition | `AgentController`, `RequestInterpreter`, `ModelClient`, `AgentPrompts` |
| `Orvlet/Agent/Execution` | Guarded tool dispatch and capability executors | `ToolDispatcher`, `WorkspaceTools`, `DataTools`, `BrowserTools`, `NativeTools`, `CompletionTools` |
| `Orvlet/Tasks` | Task identity, routing, lifecycle, ranking, local code and continuing execution | `RequestDispatch`, `TaskCollection`, `TaskLifecycle`, `TaskRuntime`, `TaskVerification` |
| `Orvlet/Data` | Public API validation, transport, freshness and calculation | `APIDataSpec`, `PublicDataClient`, `APIDataService` |
| `Orvlet/Browser` | Source WebKit lifetime, observations, actions and filtering | `BrowserController`, `BrowserActions` |
| `Orvlet/Presentation` | Native views, generated surface schemas, styling and shell interaction | `SideScreenView`, `CalmVisualStyle`, `TaskForm`, `APIDataPresentation`, `ShellInteraction` |
| `Orvlet/Configuration` | Provider configuration, model capabilities, settings and readiness | `AppSettings`, `ModelEndpoint`, `ModelProfile`, `SetupReadiness` |
| `Orvlet/Storage` | Conversations, sessions, saved interfaces, private credentials and migration | `ConversationStore`, `SessionRestoration`, `InterfaceMemory`, `LocalCredentials` |
| `Orvlet/Integrations` | Native Calendar and local bridge capabilities | `CalendarService`, `CalendarNativeTransport`, `LocalBridge` |
| `Orvlet/Resources` | Browser bridge and static app resources | `browser.js`, `calendar-event.applescript` |
| `Tests/AppChecks` | Debug-only native fixtures and behavioral checks | `DebugHarness`, `SelfCheck`, `TaskConsistencyCheck` |

## Dependency boundaries

`TaskRuntimeEngine` depends on `RuntimeTaskStore` and `TaskCodeExecuting`, not
`AppModel` or `SideTask`. Its store contract exposes a runtime snapshot and
synchronous edits to runtime-owned fields. `RuntimeTaskAdapter` maps those edits
back to an existing observable task in one update. A missing task is never
recreated. The engine cannot select windows, create tasks, read credentials,
route messages or operate a browser through this interface. A failure callback
lets the app record diagnostics without the engine writing application preferences.

`APIDataService` accepts a public JSON fetch operation, a pure-code executor and
a clock. It owns extraction, source checks, freshness and calculation. Fresh
responses and cached input edits pass through the same output contract.
`DataTaskController` retains UI task ownership, cancellation, revision checks and
user feedback. Fixture tests inject a service at the composition root instead of
adding a test-only branch to the production acquisition path.

The `Core` helpers do not import app or agent types. Serialization, scalar result
validation and ordinary displayable errors are shared primitives; lower layers
must not import `AgentController` or `TaskSurface` just to use those operations.
Domain-specific errors remain separate types.

`ServiceBoundaryCheck` constructs the runtime and data service without an
`AppModel`, browser or window. `scripts/check-services.sh` separately compiles
these services without app, agent, browser or presentation sources. Existing
integration checks cover the adapters,
persistence, cancellation, changed inputs and both rendered presentations.

The browser/request orchestration still uses `AppModel` as the composition root;
this is not a claim that all feature folders are isolated packages. Keep new
service dependencies explicit, and put the mapping to observable application
state in an adapter rather than widening a service's access to the entire model.

## One request, one owner

`RequestDispatch` records a request and resolves its task. `RequestInterpreter`
produces a typed intent, reusing eligible prepared routing decisions. Optional
Jev advice can replace an expensive decision; unavailable advice falls back to
the normal path. `AgentController` owns the execution loop and request revision.

Every model-invoked tool enters `ToolDispatcher`. This boundary enforces intent,
active-request ownership, unavailable paths and disruptive retry limits before
selecting a capability executor. `AgentToolName` defines stable wire names and
executor domains; `AgentToolRegistry` supplies model-facing schemas. Internal
executor methods share actor-isolated controller state and do not independently
authorize new requests. Do not invoke an executor directly from a model response.

Workspace presentation has one private commit path for generated and saved tools.
Only host code marks a saved definition as reused. Both paths execute its action
checks and fresh initializer; only newly generated definitions must demonstrate
inputs different from their initial example. This avoids rejecting legitimate
future inputs which happen to match a saved test case.

Execution produces evidence, not just prose. `TaskVerification` checks the
requested behavior; browser completion checks use observed source state. A
verified terminal tool can finish without another model round. The request owner
receives the reply even if the user has selected another card meanwhile.

## State and lifetime

- `SideTask` is the persisted task model. Compact and expanded views use the same
  task; opening a view does not regenerate its behavior.
- `TaskRevisionLedger` and runtime generations reject stale asynchronous writes.
  Cancellation and Close dispose active work; Hide preserves task execution.
- `TaskRuntimeEngine` owns clocks and scheduled local work. View rendering never
  starts an independent timer or duplicates a recurring calculation.
- `SessionRestoration` reconstructs source tasks. `ConversationStore` owns their
  conversations; `InterfaceMemory` stores reusable definitions, not fresh remote
  facts. API results must be fetched again when freshness requires it.
- `AppSettings` and `Endpoint` have no dependency on the Settings view.
  `LocalCredentials` is separate from settings serialization and task context.

Existing legacy decoding paths remain deliberately: removing an older UI builder
or stored field without migration would break saved tasks. Current construction
paths should use the current schemas; compatibility readers are not alternate
feature implementations.

## Add a capability

Add its typed contract and executor in the owning folder. Register any model tool
in `AgentToolName` and `AgentToolRegistry`, then explicitly expose it through the
relevant `RequestIntent`/`RequestInterpreter` policy. Define what observation or
receipt proves success, how cancellation behaves, and which state persists.
Reuse existing controls and task surfaces where possible. Add one focused
behavioral check, including the failure or stale-result boundary that matters.
The registry check catches missing or duplicated executable tool definitions.

`DebugHarness` is the sole registry of native test launch modes. Its live-service
classification is checked before any mode starts; production startup contains
only Debug-gated hooks. Keep test orchestration out of `AppDelegate`.

See [the request pipeline](request-pipeline.md) for detailed evidence and
restoration rules, [the product contract](product-contract.md) for UX constraints,
and [CONTRIBUTING](../../CONTRIBUTING.md) for build and check commands.
