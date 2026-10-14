import { mkdirSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome } from "../../evals/eval-helpers";
import { openRouterCompletion } from "./chat-completions";

import { createHash } from "node:crypto";

export type OpenRouterRequest = { path: string; authorization: string | null; body: any; headers: Record<string, string>; port: number };

type PendingCode = { challenge: string; method: string; used: boolean };

export type CatalogModel = { id: string; context_length?: number; max_completion_tokens?: number; image?: boolean; reasoning?: boolean };

export const defaultCatalog: CatalogModel[] = [
  { id: "anthropic/claude-sonnet-5.5", context_length: 1_000_000, max_completion_tokens: 128_000, image: true, reasoning: true },
  { id: "openai/gpt-5", context_length: 400_000, max_completion_tokens: 128_000, image: true, reasoning: true },
];

// The shape of GET /api/v1/models?supported_parameters=tools.
export function openRouterCatalog(models: CatalogModel[] = defaultCatalog) {
  return Response.json({
    data: models.map((model) => ({
      id: model.id,
      name: model.id,
      created: 1_790_000_000,
      context_length: model.context_length ?? 128_000,
      architecture: { input_modalities: model.image ? ["text", "image"] : ["text"], output_modalities: ["text"] },
      top_provider: { context_length: model.context_length ?? 128_000, max_completion_tokens: model.max_completion_tokens ?? 16_384 },
      supported_parameters: ["max_tokens", "tool_choice", "tools", ...(model.reasoning ? ["reasoning"] : [])],
      ...(model.reasoning ? { reasoning: { mandatory: true, supported_efforts: ["high", "medium", "low"], default_effort: "medium" } } : {}),
      pricing: { prompt: "0.000003", completion: "0.000015" },
    })),
  });
}

// A fake OpenRouter API. fx reaches it through FX_E2E_OPENROUTER_BASE_URL,
// which accepts only loopback URLs.
// A null catalog makes GET /models fail with 503.
export function createOpenRouterFixture(respond?: (body: any) => Response | Promise<Response>, catalog: CatalogModel[] | null = defaultCatalog) {
  const home = realpathSync(createIsolatedTestHome());
  const workspace = join(home, "workspace");
  mkdirSync(workspace);
  mkdirSync(join(home, ".fx"), { mode: 0o700 });
  const requests: OpenRouterRequest[] = [];
  const authorizations: URLSearchParams[] = [];
  const codes = new Map<string, PendingCode>();
  // Keys this fake has issued, plus the environment key the fixture sets.
  const validKeys = new Set<string>(["sk-or-test-key"]);
  let issued = 0;
  // What GET /key reports; tests may change it.
  const keyInfo: Record<string, unknown> = { label: "fx", limit: null, limit_reset: null, limit_remaining: null, usage: 0, usage_daily: 0, usage_weekly: 0, usage_monthly: 0, is_free_tier: false };
  const server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      const path = url.pathname;
      const body = request.method === "POST" ? await request.json() : null;
      requests.push({ path, authorization: request.headers.get("authorization"), body, headers: Object.fromEntries(request.headers), port: server.requestIP(request)?.port ?? 0 });
      if (path === "/api/v1/models") return catalog ? openRouterCatalog(catalog) : new Response("unavailable", { status: 503 });
      if (path === "/auth") {
        authorizations.push(url.searchParams);
        const code = `code-${++issued}`;
        codes.set(code, { challenge: url.searchParams.get("code_challenge") ?? "", method: url.searchParams.get("code_challenge_method") ?? "", used: false });
        const callback = url.searchParams.get("callback_url");
        if (!callback) return new Response(`<p>Your code: <code>${code}</code></p>`, { headers: { "content-type": "text/html" } });
        const target = new URL(callback);
        target.searchParams.set("code", code);
        const state = url.searchParams.get("state");
        if (state) target.searchParams.set("state", state);
        return Response.redirect(target.toString(), 302);
      }
      if (path === "/api/v1/auth/keys") {
        const pending = codes.get(body?.code);
        if (!pending || pending.used) return Response.json({ error: { code: 403, message: "Invalid code or code_verifier" } }, { status: 403 });
        if (body.code_challenge_method !== pending.method) return Response.json({ error: { code: 400, message: "Invalid code_challenge_method" } }, { status: 400 });
        const challenge = createHash("sha256").update(body.code_verifier ?? "").digest("base64url");
        if (challenge !== pending.challenge) return Response.json({ error: { code: 403, message: "Invalid code or code_verifier" } }, { status: 403 });
        pending.used = true;
        const key = `sk-or-v1-issued-${issued}`;
        validKeys.add(key);
        return Response.json({ key, user_id: "user_fixture" });
      }
      if (path === "/api/v1/key") {
        const key = request.headers.get("authorization")?.replace(/^Bearer /, "") ?? "";
        if (!validKeys.has(key)) return Response.json({ error: { code: 401, message: "No auth credentials found" } }, { status: 401 });
        return Response.json({ data: keyInfo });
      }
      if (path !== "/api/v1/chat/completions") return new Response("unexpected endpoint", { status: 404 });
      return respond ? respond(body) : openRouterCompletion(body.model, "openrouter reply");
    },
  });
  const settingsPath = join(home, ".fx", "settings.json");
  const settings: Record<string, any> = { auto_upgrade: false, permission_mode: "ask" };
  const save = () => writeFileSync(settingsPath, JSON.stringify(settings), { mode: 0o600 });
  save();
  const env: Record<string, string | undefined> = {
    HOME: home, FX_PROVIDER: undefined, FX_MODEL: undefined, FX_AUTH_MODE: undefined,
    AI_GATEWAY_API_KEY: undefined, VERCEL_OIDC_TOKEN: undefined,
    FX_GATEWAY_CHAT_URL: `http://127.0.0.1:${server.port}/unexpected-gateway`,
    FX_GATEWAY_BASE_URL: `http://127.0.0.1:${server.port}/unexpected-gateway`,
    FX_E2E_OPENROUTER_BASE_URL: `http://127.0.0.1:${server.port}/api/v1`,
    FX_E2E_OPENROUTER_AUTH_URL: `http://127.0.0.1:${server.port}/auth`,
    FX_NO_OPEN_BROWSER: "1",
    OPENROUTER_API_KEY: "sk-or-test-key",
    FX_DISABLE_KEYCHAIN: "1", FX_AUTO_UPGRADE: "0", FX_SOUND: "0", NO_COLOR: "1",
  };
  return { home, workspace, requests, authorizations, validKeys, keyInfo, env, settings, settingsPath, save, close() { server.stop(true); cleanupIsolatedTestHome(home); } };
}
