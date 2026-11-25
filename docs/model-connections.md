# Model and decision connections

The main model generates tool calls and task interfaces. The decision service only scores bounded questions and selects from allowed choices; it does not execute tools.

## Main-model compatibility

Official OpenAI GPT-6 profiles using a standard Chat Completions URL are migrated to Responses. The same model, credential reference, and conversation are retained. The runtime also normalizes unsaved connection tests. Other providers and explicitly pinned URLs retain their selected protocol.

Automatic reasoning on Responses uses a supported low effort for connection checks and short extraction calls, and medium/high for corresponding planning budgets. Ordinary requests retain the provider default. It never sets `none` merely to get function tools through Chat Completions. Explicit reasoning settings remain user-controlled. Response reasoning items and function-call results continue through the existing stateless Responses history adapter.

## Models settings

Settings → Models offers **GPT** and **Custom**.

- GPT shows one secure OpenAI API Key field and a model picker. The main model uses Responses; OpenAI Decisions automatically uses `gpt-6-luna` with the same credential reference. One connection test checks both services and identifies which service failed.
- Custom shows the main model's base URL, model ID and key, followed by the Jev key. Protocol, authentication and custom Jev endpoint/model settings remain under Advanced.
- Switching modes preserves saved connections, each provider's credentials and the last selected model. Unsubmitted key edits are retained per credential account. An empty key field keeps the saved key. Third-party GPT gateways remain Custom connections.
- The built-in GPT list follows the [official model catalog](https://developers.openai.com/api/docs/models); saved model IDs outside that list remain selectable.

## Decisions

The selected mode chooses the decision provider. Switching saves each provider's endpoint, model and credential reference separately.

| Provider | Default base | Model | Request path |
| --- | --- | --- | --- |
| Jev | `https://api.typesafe.ai/v1` | `jev-latest` | `/systemone` |
| OpenAI Decisions | `https://api.openai.com/v1` | `gpt-6-luna` | `/decisions` |

OpenAI uses named predicate/choice questions, structured JSON evidence, and an answers array. The adapter validates probabilities, names, duplicate entries and complete choice distributions before passing results to the existing routing thresholds. Refusals provide no actionable decision. A service failure retains the existing main-model/local fallback.

GPT mode shares the active official OpenAI profile's key by reference; it never copies the secret into settings. Existing independent credential slots remain in local storage. Changing a destination invalidates an incompatible shared reference. Switching back to Custom restores Jev and its original credential slot.

Routing, reading review, card grouping, connection checks and anonymous task ranking all use the selected provider. Background requests keep the existing eligibility/privacy checks and require the selected provider's official HTTPS host. No documents, credential values, or new categories of task context are added.

References: [OpenAI reasoning guide](https://developers.openai.com/api/docs/guides/reasoning), [Decisions guide](https://developers.openai.com/api/docs/guides/decisions), [Decisions wire reference](https://developers.openai.com/api/reference/resources/decisions/methods/create).

## Verification

Local HTTP fixtures cover both decision protocols, choice routing, credential-preserving migration, mode round trips, refusals and malformed responses. The complete Models pages are rendered offscreen at production size in both appearances. Tests do not use real credentials or live providers. Run `scripts/check.py model-api state-machines` against a freshly built Debug app.
