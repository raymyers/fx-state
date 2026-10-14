#!/usr/bin/env node
// An OpenRouter agent: the engine's requests reach OpenRouter through the host
// fetch, with the host's key on OpenRouter's chat URL only, and never touch AI
// Gateway. No network: every request is answered here.
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { customProviderDefinition } from "../custom-provider.js";
import { normalizeAgentOptions } from "../fx-sdk.js";
import { createFxAgent, createFxEngine, memory, supportsJspi } from "../node.js";

const backend = process.argv[2] || "native";
if (!new Set(["native", "wasm"]).has(backend)) throw new Error("usage: test-agent-openrouter.mjs [native|wasm]");
if (backend === "wasm" && !supportsJspi()) {
  console.error("Node JSPI is disabled. Run with --experimental-wasm-jspi");
  process.exit(2);
}

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const backendOptions = {
  backend,
  nativeAddon: resolve(scriptDir, "../../zig-out/lib/libfx.node"),
  ...(backend === "wasm" ? { wasm: await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) } : {}),
};

const chatUrl = "https://openrouter.ai/api/v1/chat/completions";
const modelsUrl = "https://openrouter.ai/api/v1/models";
const defaultModel = "anthropic/claude-sonnet-5.5";

const sse = (...chunks) => chunks.map((chunk) => `data: ${JSON.stringify(chunk)}\n\n`).join("") + "data: [DONE]\n\n";
const reply = (text) => sse(
  { id: "gen-1", model: defaultModel, choices: [{ index: 0, delta: { role: "assistant", content: text }, finish_reason: null }] },
  { id: "gen-1", choices: [{ index: 0, delta: {}, finish_reason: "stop" }], usage: { prompt_tokens: 10, completion_tokens: 2, total_tokens: 12, cost: 0.0001 } },
);
const catalog = JSON.stringify({ data: [{ id: defaultModel, context_length: 1000000, architecture: { input_modalities: ["text", "image"] }, top_provider: { max_completion_tokens: 128000 }, supported_parameters: ["tools", "tool_choice", "max_tokens"] }] });

/** A host fetch that plays OpenRouter. */
function server(answer = () => reply("libfx on OpenRouter")) {
  const log = [];
  const fetch = async (input, init = {}) => {
    const url = String(input?.url ?? input);
    const method = (init.method ?? "GET").toUpperCase();
    const headers = new Headers(init.headers);
    const body = init.body === undefined ? undefined : typeof init.body === "string" ? init.body : new TextDecoder().decode(init.body);
    const entry = { method, url, headers, body };
    log.push(entry);
    if (url.startsWith(modelsUrl) && method === "GET") return new Response(catalog, { status: 200, headers: { "content-type": "application/json" } });
    if (url === chatUrl && method === "POST") {
      const answered = answer(entry);
      if (answered instanceof Response) return answered;
      return new Response(answered, { status: 200, headers: { "content-type": "text/event-stream" } });
    }
    return new Response(`unexpected ${method} ${url}`, { status: 599 });
  };
  return { fetch, log };
}

async function runTurn(options, prompt = "say ok") {
  const events = [];
  const engine = await createFxEngine({ ...backendOptions, provider: "openrouter", onEvent: (event) => events.push(event), ...options });
  try {
    const turn = engine.prompt(prompt);
    let text = "";
    for await (const event of turn) if (event.type === "text_delta") text += event.delta;
    return { result: await turn.result, text, events };
  } finally {
    await engine.close();
  }
}

const chatRequests = (log) => log.filter((entry) => entry.url === chatUrl);
const assertNoGateway = (log) => assert.equal(log.some((entry) => entry.url.includes("ai-gateway.vercel.sh")), false, "an OpenRouter agent must not call AI Gateway");

// 1. apiKey reaches only OpenRouter's chat URL, never the engine or the catalog request.
{
  const world = server();
  const { result, text, events } = await runTurn({ fetch: world.fetch, apiKey: "sk-or-host" });
  assert.equal(result.stopReason, "end_turn");
  assert.equal(text, "libfx on OpenRouter");
  assertNoGateway(world.log);
  const [request] = chatRequests(world.log);
  assert.equal(request.headers.get("authorization"), "Bearer sk-or-host");
  assert.equal(request.headers.get("http-referer"), "https://fx.sh");
  assert.equal(request.headers.get("x-openrouter-title"), "fx");
  assert.equal(JSON.parse(request.body).model, defaultModel);
  for (const entry of world.log.filter((logged) => logged.url !== chatUrl)) {
    assert.equal(entry.headers.get("authorization"), null, `${entry.url} must not carry the key`);
  }
  assert.equal(JSON.stringify(events).includes("sk-or-host"), false, "libfx diagnostics must not expose the API key");
}

// 2. credentials() supplies the key per request and learns the provider's name.
{
  const world = server();
  const asked = [];
  const { result } = await runTurn({
    fetch: world.fetch,
    model: "openai/gpt-5",
    credentials: (request) => { asked.push(request); return { apiKey: "sk-or-rotating" }; },
  });
  assert.equal(result.stopReason, "end_turn");
  assert.equal(chatRequests(world.log)[0].headers.get("authorization"), "Bearer sk-or-rotating");
  assert.equal(JSON.parse(chatRequests(world.log)[0].body).model, "openai/gpt-5");
  assert.ok(asked.length > 0 && asked.every((entry) => entry.provider === "openrouter"));
}

// 3. A durable agent never lets a Gateway key from the environment stand in
// for OpenRouter's, with a key of its own or with none.
{
  const saved = process.env.AI_GATEWAY_API_KEY;
  process.env.AI_GATEWAY_API_KEY = "gateway-env-key";
  try {
    const world = server();
    const agent = createFxAgent({ ...backendOptions, durability: memory(), provider: "openrouter", fetch: world.fetch, credentials: () => ({ apiKey: "sk-or-agent" }) });
    try {
      assert.equal((await agent.session().prompt("first").result).stopReason, "end_turn");
    } finally {
      await agent.close();
    }
    assert.equal(chatRequests(world.log)[0].headers.get("authorization"), "Bearer sk-or-agent");
    assert.equal(JSON.stringify(world.log.map((entry) => [...entry.headers])).includes("gateway-env-key"), false);
  } finally {
    if (saved === undefined) delete process.env.AI_GATEWAY_API_KEY;
    else process.env.AI_GATEWAY_API_KEY = saved;
  }
}

// 4. A missing key, or two, is refused before an engine starts.
assert.throws(() => normalizeAgentOptions({ provider: "openrouter" }), (error) => error.code === "FX_OPENROUTER_KEY_REQUIRED");
assert.throws(() => normalizeAgentOptions({ provider: "openrouter", apiKey: "sk-or-a", credentials: () => ({ apiKey: "sk-or-b" }) }), /apiKey or credentials\(\), not both/);
assert.equal(normalizeAgentOptions({ provider: "openrouter", apiKey: "sk-or-a" }).apiKey, undefined, "the key must not reach the engine as a Gateway key");

// 5. A custom provider cannot take the built-in name.
assert.throws(() => customProviderDefinition({ name: "openrouter", baseUrl: "https://openrouter.ai/api/v1" }), /not gateway, codex, grok or openrouter/);

console.log(`test-agent-openrouter ${backend}: ok`);
