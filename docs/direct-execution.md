# Task ownership and direct execution

Global natural-language requests resolve ownership through Jev. An accepted route (existing task, explicit archive restoration, or new independent task) is transferred to the executor without another ownership decision by the main model. Explicit task conversations already establish ownership. Invalid or stale routes, unavailable Jev, and uncertain references use a small ownership-only main-model fallback; ambiguity can ask the user rather than choose an arbitrary task.

Jev receives bounded, filtered task purposes, eligible titles and activity metadata. The same classification call can suggest which tool family to expose first. Family discovery uses a lower confidence threshold than ownership because the executor can still choose another method. The executor supplies and verifies the actual arguments. A command can only adopt a conversation that existed when it was submitted. Archived candidates are marked separately and can only be selected for explicit restoration. Active compatible activities remain the default for changed content.

The executor loads the resolved task's state, recent conversation and observed action IDs. It calls tools directly. Other capabilities are loaded on demand through `load_tools` in the same loop. New tasks, existing tools, browser work and native actions share that loop; there is no secondary simple-task engine or fallback to the old intent planner.

`control_task(invoke)` accepts partial input changes. Card buttons and model calls use `executeTaskCodeAction`: merge inputs with the execution-before state, run the registered handler, then commit input and output together under the task revision. Reading state is not a mutation. Changes to behavior still require real handler checks. Appearance changes use `manage_task(revise_view)` and preserve behavior.

Completion depends on host tool receipts, not prose or a validated plan. `complete:false` keeps intermediate actions open; a terminal receipt is returned only after the whole submitted batch succeeds. A failed batch does not discard earlier effect receipts. Duplicate effects reuse their receipt, uncertain effects block further mutation, and superseded operations cannot commit. Source identity/behavior verification is specified on the relevant actual tool rather than in a separate universal intent schema. Native creation also requires human-request evidence and retains native permission/readback checks.

For independently usable outcomes, `separate_cards` assigns a distinct quoted focus to each executor. Each receives the full original request, including shared conditions and exceptions elsewhere in the message. The split may attach verbatim conditions to each subject. Siblings can share a verified public endpoint pattern and its field pointers. Each still resolves and verifies its own identity and value. For a scoped numeric card based on eligible user-supplied data, Jev can flag a contradiction before publication and request a recalculation. The review has a bounded timeout and sees only the original request, its quoted focus and the displayed number. Jev can distinguish independent from dependent work in its existing routing call. Dependent workflows keep their intermediate results in the same execution context. For a cross-source snapshot, `inspect_api` returns request-scoped observation handles. `run_code.bindings` resolves JSON pointers on those observations before passing values to the worker.

For a named public reading, `read_value` binds the source identity, value and unit to the standard card. `inspect_api` and acquisition share a recent response within the request, subject to its refresh interval. A calculation is only needed for derived outputs.

After a failed method, the executor can repair the specific step. Two failures on the same method open alternatives and prevent another identical approach. For data this can mean direct binding, another API or an observed webpage. Changing an error field alone does not reset the allowance. Alternative routes share the task owner, source qualifications and effect ledger. If the result still cannot be verified, the user sees a short explanation while the support trace keeps the failure category and field path.

The old fast-method classifier and intent-planning helpers are Debug-only historical fixtures. They are not called by the production loop or included as a production execution alternative.

## Validation

Run `python3 scripts/check.py state-machines model-api` to exercise task ownership and model transport using local fixtures.
