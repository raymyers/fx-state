import { mkdirSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome } from "../../evals/eval-helpers";
import { openRouterCompletion } from "./chat-completions";

import { createHash } from "node:crypto";

export type OpenRouterRequest = { path: string; authorization: string | null; body: any };

type PendingCode = { challenge: string; method: string; used: boolean };

// A fake OpenRouter API. fx reaches it through FX_E2E_OPENROUTER_BASE_URL,
// which accepts only loopback URLs.
export function createOpenRouterFixture(respond?: (body: any) => Response | Promise<Response>) {
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
  const server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    async fetch(request) {
      const url = new URL(request.url);
      const path = url.pathname;
      const body = request.method === "POST" ? await request.json() : null;
      requests.push({ path, authorization: request.headers.get("authorization"), body });
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
        return Response.json({ data: { label: "fx", usage: 0, limit: null } });
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
  return { home, workspace, requests, authorizations, validKeys, env, settings, settingsPath, save, close() { server.stop(true); cleanupIsolatedTestHome(home); } };
}
