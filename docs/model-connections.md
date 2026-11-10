# Model connections

Settings → Models → Connection details accepts any provider implementing one of
these wire formats, without a provider or model-name allowlist:

- **Chat Completions**: appends `/chat/completions`; default authentication is Bearer.
- **Responses**: appends `/responses`; default authentication is Bearer.
- **Anthropic Messages**: appends `/messages`; default authentication is `x-api-key`
  with `anthropic-version: 2023-06-01`.

Enter the provider's documented base URL (usually including `/v1`) and exact model
ID. A full standard endpoint is accepted too. **Use URL exactly as entered** supports
custom gateway routes and Azure-style deployment URLs. Query parameters are preserved.
HTTPS and loopback HTTP work by default; remote HTTP requires the per-profile option.

## Advanced settings

Each profile saves its protocol, authentication, reasoning, output limit, temperature,
timeout, tool-choice behavior, and JSON overrides. Existing profiles retain Chat
Completions and their existing credential references. An empty API Key field keeps the
saved key. No authentication works with local services that do not require credentials.

**Reasoning** selects `reasoning_effort` for Chat Completions and `reasoning.effort`
for Responses. **Automatic (Orvlet)** preserves the existing task-budget optimizations
for compatible Chat providers; elsewhere it leaves the provider default. **Provider
default** omits those optimizations. Explicit efforts are sent as selected, so use
only values supported by your provider/model. Messages-specific thinking controls
belong in request parameters because their shape and budget requirements differ.

An empty output limit omits the parameter, except Messages which requires a limit
and defaults to 8192. Chat providers can choose `max_completion_tokens` or `max_tokens`.
Temperature is omitted when blank, including on models that reject it. An explicit
request timeout overrides the normal per-stage timeout. These settings apply to
connection tests and real model requests.

**Force required tool calls** can be turned off for gateways supporting only automatic
tool choice. The result still has to pass Orvlet's normal tool and argument validation.

Request parameters are a JSON object, recursively merged after the options above.
`null` removes a generated default. For example, a Chat gateway can use:

```json
{"reasoning_effort":"none","parallel_tool_calls":null}
```

A provider using a different reasoning switch can use:

```json
{"enable_thinking":false}
```

Select **Provider default** when replacing Orvlet's automatic reasoning behavior.
The host owns model, conversation, tool definitions, non-streaming execution and
conversation chaining; those fields cannot be replaced through JSON overrides.

Request headers are a JSON object with text values. Use `${API_KEY}` to insert the
profile's saved key, rather than writing credentials in the JSON editor:

```json
{"api-key":"${API_KEY}","X-Provider-Feature":"tools"}
```

**Custom header** authentication also accepts a header name and optional key prefix.
Provider headers override default headers case-insensitively. Transport-owned headers
such as Content-Type and Host cannot be overridden. Redirects are rejected so custom
credentials cannot be forwarded to another destination; enter the final endpoint URL.

## Compatibility and verification

The selected model must support function/tool calling. More configurable parameters
cannot add that capability or translate an unrelated proprietary protocol. Native
Gemini `generateContent`, streaming-only servers and asynchronous job APIs are not
implemented; use a supported compatibility endpoint for these services.

Responses retains output items, including encrypted reasoning, across tool rounds.
Messages retains signed thinking blocks and groups parallel tool results correctly.
Screenshots are translated to the selected protocol's image format. HTTP errors show
the status and provider's JSON error message, with current credentials/header values
redacted and bounded text. Connection tests validate an actual tool response, not
merely a successful HTTP status.

`python3 scripts/check.py model-api` tests protocol requests, two-round tool results,
reasoning continuity, images, profile persistence, overrides, validation and error
redaction against a local server. It uses no real credentials or paid model APIs.
