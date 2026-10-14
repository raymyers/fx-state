import { mkdirSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome } from "../../evals/eval-helpers";

export function completion(model: string, text = "local reply", inputTokens = 12) {
  const chunks = [
    { id: "chat-local", model, choices: [{ index: 0, delta: { role: "assistant", content: text }, finish_reason: null }] },
    { id: "chat-local", model, choices: [{ index: 0, delta: {}, finish_reason: "stop" }] },
    { id: "chat-local", model, choices: [], usage: { prompt_tokens: inputTokens, completion_tokens: 3, total_tokens: inputTokens + 3 } },
  ];
  return new Response(chunks.map(value => `data: ${JSON.stringify(value)}\n\n`).join("") + "data: [DONE]\n\n", { headers: { "content-type": "text/event-stream" } });
}

export function toolCompletion(model: string, name: string, args: unknown, callId = "call-local") {
  const chunks = [
    { id: "chat-tool", model, choices: [{ index: 0, delta: { tool_calls: [{ index: 0, id: callId, type: "function", function: { name, arguments: JSON.stringify(args) } }] }, finish_reason: null }] },
    { id: "chat-tool", model, choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }] },
  ];
  return new Response(chunks.map(value => `data: ${JSON.stringify(value)}\n\n`).join("") + "data: [DONE]\n\n", { headers: { "content-type": "text/event-stream" } });
}

// OpenRouter's stream shape: keep-alive comments, null fields in deltas, and a
// trailing usage chunk that repeats the finish with an empty delta.
export function openRouterCompletion(model: string, text = "local reply") {
  const choice = (delta: unknown, finish_reason: string | null) => ({ index: 0, delta, finish_reason, native_finish_reason: finish_reason, logprobs: null });
  const chunks = [
    { id: "gen-local", model, choices: [choice({ role: "assistant", content: text, reasoning: null }, null)] },
    { id: "gen-local", model, choices: [choice({ role: "assistant", content: "", reasoning: null }, "stop")] },
    { id: "gen-local", model, choices: [choice({ role: "assistant", content: "", reasoning: null }, "stop")], usage: { prompt_tokens: 12, completion_tokens: 3, total_tokens: 15, cost: 0.000042, is_byok: false, prompt_tokens_details: { cached_tokens: 4, cache_write_tokens: 0 }, completion_tokens_details: { reasoning_tokens: 1 } } },
  ];
  const wire = ": OPENROUTER PROCESSING\n\n" + chunks.map(value => `data: ${JSON.stringify(value)}\n\n: OPENROUTER PROCESSING\n\n`).join("") + "data: [DONE]\n\n";
  return new Response(wire, { headers: { "content-type": "text/event-stream" } });
}

// OpenRouter reports a failure after the 200 status as an error object with
// finish_reason "error", and may close the stream without [DONE].
export function streamError(model: string, code: string | number, message: string, text = "") {
  const chunks = [
    ...(text ? [{ id: "chat-error", model, choices: [{ index: 0, delta: { role: "assistant", content: text }, finish_reason: null }] }] : []),
    { id: "chat-error", model, provider: "upstream", error: { code, message }, choices: [{ index: 0, delta: { content: "" }, finish_reason: "error" }] },
  ];
  return new Response(chunks.map(value => `data: ${JSON.stringify(value)}\n\n`).join(""), { headers: { "content-type": "text/event-stream" } });
}

export function createConfiguredProviderFixture(respond?: (body: any) => Response | Promise<Response>) {
  const home = realpathSync(createIsolatedTestHome());
  const workspace = join(home, "workspace");
  mkdirSync(workspace);
  mkdirSync(join(home, ".fx"), { mode: 0o700 });
  const requests: Array<{ path: string; authorization: string | null; body: any }> = [];
  const server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    async fetch(request) {
      const path = new URL(request.url).pathname;
      const body = request.method === "POST" ? await request.json() : null;
      requests.push({ path, authorization: request.headers.get("authorization"), body });
      if (path !== "/v1/chat/completions") return new Response("unexpected endpoint", { status: 500 });
      return respond ? respond(body) : completion((body as any).model);
    },
  });
  const settingsPath = join(home, ".fx", "settings.json");
  const settings = {
    provider: "local", auto_upgrade: false, permission_mode: "ask",
    providers: {
      local: { protocol: "openai-chat-completions", base_url: `http://127.0.0.1:${server.port}/v1`, auth: { type: "none" }, model_metadata: { "local-model": { context_window: 262144, max_output_tokens: 8192, supports_tool_use: true } } },
      remote: { protocol: "openai-chat-completions", base_url: `http://127.0.0.1:${server.port}/v1`, auth: { type: "bearer", env: "FX_TEST_PROVIDER_TOKEN" }, model_metadata: { "remote-model": { context_window: 262144, max_output_tokens: 8192, supports_tool_use: true } } },
    },
    models: { local: "local-model", remote: "remote-model" },
  };
  const save = () => writeFileSync(settingsPath, JSON.stringify(settings), { mode: 0o600 });
  save();
  const env = {
    HOME: home, FX_PROVIDER: undefined, FX_MODEL: undefined, FX_AUTH_MODE: undefined,
    AI_GATEWAY_API_KEY: "unrelated-gateway-token", VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_CHAT_URL: `http://127.0.0.1:${server.port}/unexpected-gateway`,
    FX_GATEWAY_BASE_URL: `http://127.0.0.1:${server.port}/unexpected-gateway`,
    FX_TEST_PROVIDER_TOKEN: "own-provider-token", FX_AUTO_UPGRADE: "0", FX_SOUND: "0", NO_COLOR: "1",
  };
  return { home, workspace, requests, env, settings, settingsPath, save, close() { server.stop(true); cleanupIsolatedTestHome(home); } };
}
