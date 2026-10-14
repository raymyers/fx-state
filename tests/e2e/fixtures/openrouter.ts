import { mkdirSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome } from "../../evals/eval-helpers";
import { openRouterCompletion } from "./chat-completions";

export type OpenRouterRequest = { path: string; authorization: string | null; body: any };

// A fake OpenRouter API. fx reaches it through FX_E2E_OPENROUTER_BASE_URL,
// which accepts only loopback URLs.
export function createOpenRouterFixture(respond?: (body: any) => Response | Promise<Response>) {
  const home = realpathSync(createIsolatedTestHome());
  const workspace = join(home, "workspace");
  mkdirSync(workspace);
  mkdirSync(join(home, ".fx"), { mode: 0o700 });
  const requests: OpenRouterRequest[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    async fetch(request) {
      const path = new URL(request.url).pathname;
      const body = request.method === "POST" ? await request.json() : null;
      requests.push({ path, authorization: request.headers.get("authorization"), body });
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
    OPENROUTER_API_KEY: "sk-or-test-key",
    FX_DISABLE_KEYCHAIN: "1", FX_AUTO_UPGRADE: "0", FX_SOUND: "0", NO_COLOR: "1",
  };
  return { home, workspace, requests, env, settings, settingsPath, save, close() { server.stop(true); cleanupIsolatedTestHome(home); } };
}
