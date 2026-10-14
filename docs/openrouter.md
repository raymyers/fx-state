# OpenRouter

`openrouter` is a built-in provider, alongside `gateway`, `codex`, and `grok`.
It runs any tool-capable model on OpenRouter with the user's key and credits.
This page describes the behavior and the decisions behind it, because the
public manual at fx.sh/docs is maintained elsewhere.

## Sign in

* `fx login openrouter` runs OpenRouter's OAuth PKCE flow. fx opens the
  browser on a loopback callback, checks `state`, and exchanges the code at
  `POST /api/v1/auth/keys` for a long-lived API key labeled `fx`.
* `fx login openrouter --headless` omits the callback. The user opens the
  printed URL on any device and pastes the code OpenRouter shows. fx falls
  back to this mode when no browser opens.
* `fx login openrouter --api-key` reads a key with hidden input, or one line
  from piped stdin.
* In the terminal, `/login` then `openrouter` offers `oauth` and `api-key`.
  When a key is already available, choosing `openrouter` switches at once.

fx validates every new key with `GET /api/v1/key` before saving it to
`~/.fx/openrouter-auth.json` with mode 600. `OPENROUTER_API_KEY` takes
precedence over the saved key. The key is a long-lived API key, not an access
token, so there is no refresh or expiry handling.

`fx logout openrouter` and `/logout openrouter` delete the saved key and say
that it stays active until it is deleted at https://openrouter.ai/settings/keys.

## Models

The default model is `anthropic/claude-sonnet-5.5`, pinned rather than an
OpenRouter alias, so it changes only in an fx release.

fx reads `GET /api/v1/models?supported_parameters=tools` without a key, with a
1 MiB cap and a 30-second timeout, only while OpenRouter is the active
provider. The response is cached in `~/.fx/openrouter-models.json` for an
hour. An expired copy is used when a refetch fails. Each entry supplies the
context window, output limit, image and file input, and reasoning efforts,
which drive `max_tokens` and automatic compaction. In the terminal, a model
the catalog lacks gets one warning per model.

## Requests

OpenRouter uses the shared chat completions codec in its `openrouter`
dialect, which a custom connection does not get:

* `reasoning.effort` when the user picks an effort. Efforts come from the
  catalog's `reasoning.supported_efforts`, and `none` is dropped for models
  whose reasoning is mandatory.
* `cache_control` breakpoints for `anthropic/`, `google/`, and `qwen/`
  models: the last system message and the last two user or tool messages.
  OpenRouter documents breakpoints only on content blocks, so tools get none.
* `provider: { order, allow_fallbacks: false }` from `provider_order` and
  `provider_strict`. The slugs pass through unchanged, so they must be
  OpenRouter's provider slugs.
* `tool_choice` always, and the attribution headers `HTTP-Referer:
  https://fx.sh` and `X-OpenRouter-Title: fx`.

Chat requests share one connection pool for the life of the process. A stream
ends at `[DONE]` before the HTTP body does, and std reuses a connection only
once the body is read through, so fx drains the rest under a 2-second watch.
A failed drain closes the connection.

## Side calls

Session titles and auto-mode permission reviews run on `openai/gpt-5-nano`,
so they don't bill the selected model. The model always reasons:

* At its default effort, reasoning spent a title's 128-token budget and every
  live title came back truncated, so title requests ask for `minimal`.
* At `minimal`, reviews held harmless commands such as `chmod 600 notes.txt`
  with `caution`, so reviews keep the default effort.

An agent turn on the same model keeps its default effort. Titles are the side
calls without tools; reviews require their tool.

## Errors, usage, and cost

* A 402 says the credits are exhausted, links to https://openrouter.ai/credits,
  and is not retried. A 408 is retried.
* A 503 under `provider_order` names the order. Under `provider_strict` it is
  not retried, since a retry fails the same way.
* A mid-stream error object, or `finish_reason: "error"`, ends the turn with
  the provider's code and message.
* `/usage` and `fx usage` read `GET /api/v1/key`: spend today, this week, this
  month, and all time, and the key's limit and what is left.
* `fx ask --json` adds `cost` to its usage when a provider reports one, and the
  per-turn usage saved with each session sums it.

## libfx

`createFxEngine()` and `createFxAgent()` accept `provider: "openrouter"` with an
`apiKey` or a `credentials()` function. The key is added in JavaScript at the
fetch edge, to OpenRouter's chat URL only, and never reaches the engine or the
model list. A durable agent never fills a missing OpenRouter key from
`AI_GATEWAY_API_KEY`. Without a key, both throw a `TypeError` with code
`FX_OPENROUTER_KEY_REQUIRED`.

## Compatibility

A profile that defines a custom connection named `openrouter` fails to load
and says to rename or delete it. Before this provider, the public manual's
custom-connections example used that name, so users who followed it hit this
error. A custom provider in libfx can't use the name either.

## Tests

* `FX_E2E_OPENROUTER_BASE_URL` and `FX_E2E_OPENROUTER_AUTH_URL` point the API
  and the authorization page at a loopback fake server. Other URLs are refused.
* `tests/e2e/fixtures/openrouter.ts` fakes `/auth`, `/auth/keys` with S256
  checks and single-use codes, `/key`, `/models`, and `/chat/completions`.
* `src/gateway/testdata/openrouter/` holds streams recorded from Anthropic,
  OpenAI, Google, and Qwen models on 2026-10-14, with generation, tool call,
  and reasoning item ids replaced. No real stream produced a mid-stream error,
  so that shape is covered by synthetic tests only.
* The tmux helper unsets `OPENROUTER_API_KEY` unless a test passes one, so a
  developer's own key, for example in `.env`, can't change results.
