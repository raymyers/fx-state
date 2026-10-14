import { describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { existsSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { FX_BIN, runFx } from "../evals/eval-helpers";
import { openRouterCompletion } from "./fixtures/chat-completions";
import { createOpenRouterFixture as fixture, openRouterCatalog } from "./fixtures/openrouter";

type Fixture = ReturnType<typeof fixture>;

// Runs `fx login openrouter`, waits for the authorization URL, then plays the
// browser: `visit` receives the URL and returns a code to paste, or nothing
// when the callback carries the code itself.
async function login(f: Fixture, args: string[], visit: (url: string) => Promise<string | undefined>, env: Record<string, string | undefined> = {}) {
  const childEnv: Record<string, string> = {};
  for (const [key, value] of Object.entries({ ...process.env, ...f.env, OPENROUTER_API_KEY: undefined, ...env })) {
    if (value !== undefined) childEnv[key] = value;
  }
  const proc = spawn(FX_BIN, ["login", "openrouter", ...args], { cwd: f.workspace, env: childEnv, stdio: ["pipe", "pipe", "pipe"] });
  let stdout = "";
  let stderr = "";
  proc.stdout!.on("data", (chunk: Buffer) => { stdout += chunk.toString(); });
  proc.stderr!.on("data", (chunk: Buffer) => { stderr += chunk.toString(); });
  const closed = new Promise<number>((resolve, reject) => {
    proc.once("error", reject);
    proc.once("close", (value) => resolve(value ?? 1));
  });
  const deadline = Date.now() + 15_000;
  let url: string | undefined;
  while (!url && Date.now() < deadline) {
    url = stdout.match(/http:\/\/127\.0\.0\.1:\d+\/auth\?\S+/)?.[0];
    if (!url) await Bun.sleep(20);
  }
  if (!url) {
    proc.kill("SIGTERM");
    throw new Error(`fx login printed no authorization URL: ${stdout}\n${stderr}`);
  }
  const code = await visit(url);
  if (code !== undefined) proc.stdin!.write(`${code}\n`);
  return { code: await closed, stdout, stderr, url: new URL(url) };
}

function savedKey(f: Fixture): string | undefined {
  const path = join(f.home, ".fx", "openrouter-auth.json");
  return existsSync(path) ? JSON.parse(readFileSync(path, "utf8")).api_key : undefined;
}

describe("openrouter provider", () => {
  test("fx ask uses the environment key and the default model", async () => {
    const f = fixture();
    try {
      const result = await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "openrouter" }, timeoutMs: 20000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      expect(result.stderr).toBe("");
      const parsed = JSON.parse(result.stdout);
      expect(parsed.output).toBe("openrouter reply");
      expect(parsed.model).toBe("anthropic/claude-sonnet-5.5");
      const chats = f.requests.filter((request) => request.path === "/api/v1/chat/completions");
      expect(chats).toHaveLength(1);
      expect(chats[0].authorization).toBe("Bearer sk-or-test-key");
      expect(chats[0].body.model).toBe("anthropic/claude-sonnet-5.5");
      const status = JSON.parse((await runFx(["status", "--json"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "openrouter" } })).stdout);
      expect(status.model_source).toBe("OpenRouter");
      expect(status.auth).toBe("OPENROUTER_API_KEY");
      expect(status.connected_providers).toEqual(["openrouter"]);
    } finally { f.close(); }
  }, 30000);

  test("a missing key names OPENROUTER_API_KEY and never falls back to Gateway", async () => {
    const f = fixture();
    try {
      const result = await runFx(["ask", "--no-save", "say hello"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "openrouter", OPENROUTER_API_KEY: undefined, AI_GATEWAY_API_KEY: "gateway-key" }, timeoutMs: 20000 });
      expect(result.code).not.toBe(0);
      expect(result.stderr).toContain("fx needs an OpenRouter API key for this model. Run fx login openrouter or set OPENROUTER_API_KEY");
      expect(f.requests).toHaveLength(0);
    } finally { f.close(); }
  }, 30000);

  test("a custom connection named openrouter must be renamed", async () => {
    const f = fixture();
    try {
      f.settings.providers = { openrouter: { protocol: "openai-chat-completions", base_url: "https://openrouter.ai/api/v1", auth: { type: "bearer", env: "OPENROUTER_API_KEY" } } };
      f.save();
      const result = await runFx(["status"], { cwd: f.workspace, env: f.env });
      expect(result.code).not.toBe(0);
      expect(result.stderr).toContain("the custom connection \"openrouter\" in ~/.fx/settings.json conflicts with the built-in OpenRouter provider; rename or delete it");
      expect(f.requests).toHaveLength(0);
    } finally { f.close(); }
  }, 30000);

  test("fx provider openrouter persists the selection and a saved model wins", async () => {
    const f = fixture();
    try {
      const missing = await runFx(["provider", "openrouter"], { cwd: f.workspace, env: { ...f.env, OPENROUTER_API_KEY: undefined } });
      expect(missing.code).not.toBe(0);
      expect(missing.stderr).toContain("OPENROUTER_API_KEY");
      expect(JSON.parse(readFileSync(f.settingsPath, "utf8")).provider).toBeUndefined();

      const selected = await runFx(["provider", "openrouter"], { cwd: f.workspace, env: f.env });
      if (selected.code !== 0) throw new Error(selected.stdout + selected.stderr);
      expect(selected.stdout).toContain("Provider set to OpenRouter.");
      const saved = JSON.parse(readFileSync(f.settingsPath, "utf8"));
      expect(saved.provider).toBe("openrouter");
      expect(saved.models.openrouter).toBe("anthropic/claude-sonnet-5.5");

      saved.models.openrouter = "openai/gpt-5";
      Object.assign(f.settings, saved);
      f.save();
      const result = await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      expect(f.requests.at(-1)!.body.model).toBe("openai/gpt-5");
    } finally { f.close(); }
  }, 30000);

  test("a saved session resumes on OpenRouter after the default provider changes", async () => {
    const f = fixture();
    try {
      f.settings.provider = "openrouter";
      f.save();
      const first = await runFx(["ask", "--json", "remember the word lantern"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (first.code !== 0) throw new Error(first.stdout + first.stderr);
      const session = JSON.parse(first.stdout).session_id;
      f.settings.provider = "gateway";
      f.save();
      const resumed = await runFx(["ask", "--json", "--resume", session, "what was the word?"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      if (resumed.code !== 0) throw new Error(resumed.stdout + resumed.stderr);
      const chats = f.requests.filter((request) => request.path === "/api/v1/chat/completions");
      expect(chats).toHaveLength(2);
      expect(chats[1].authorization).toBe("Bearer sk-or-test-key");
      expect(JSON.stringify(chats[1].body.messages)).toContain("remember the word lantern");
    } finally { f.close(); }
  }, 45000);

  test("browser sign-in saves a validated key and selects OpenRouter", async () => {
    const f = fixture();
    try {
      const result = await login(f, [], async (url) => {
        const response = await fetch(url, { redirect: "follow" });
        expect(response.status).toBe(200);
        return undefined;
      });
      expect(result.code, result.stdout + result.stderr).toBe(0);
      expect(result.stdout).toContain("Signed in to OpenRouter.");
      expect(result.stderr).toBe("");
      const params = f.authorizations[0]!;
      expect(params.get("code_challenge_method")).toBe("S256");
      expect(params.get("key_label")).toBe("fx");
      expect(params.get("state")?.length).toBeGreaterThan(16);
      expect(params.get("callback_url")).toMatch(/^http:\/\/localhost:\d+\/callback$/);
      expect(savedKey(f)).toBe("sk-or-v1-issued-1");
      expect(statSync(join(f.home, ".fx", "openrouter-auth.json")).mode & 0o077).toBe(0);
      expect(f.requests.filter((request) => request.path === "/api/v1/key").map((request) => request.authorization)).toEqual(["Bearer sk-or-v1-issued-1"]);
      expect(JSON.parse(readFileSync(f.settingsPath, "utf8")).provider).toBe("openrouter");

      const asked = await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env: { ...f.env, OPENROUTER_API_KEY: undefined }, timeoutMs: 20000 });
      if (asked.code !== 0) throw new Error(asked.stdout + asked.stderr);
      expect(f.requests.at(-1)!.authorization).toBe("Bearer sk-or-v1-issued-1");
      // An environment key still wins over the saved one.
      await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
      expect(f.requests.at(-1)!.authorization).toBe("Bearer sk-or-test-key");
      const status = JSON.parse((await runFx(["status", "--json"], { cwd: f.workspace, env: { ...f.env, OPENROUTER_API_KEY: undefined } })).stdout);
      expect(status.auth).toBe("OpenRouter login");
    } finally { f.close(); }
  }, 60000);

  test("headless sign-in exchanges a pasted code without a callback", async () => {
    const f = fixture();
    try {
      const result = await login(f, ["--headless"], async (url) => {
        const page = await (await fetch(url)).text();
        return page.match(/code-\d+/)![0];
      });
      expect(result.code, result.stdout + result.stderr).toBe(0);
      expect(result.stdout).toContain("Paste the code OpenRouter shows");
      expect(result.url.searchParams.get("callback_url")).toBeNull();
      expect(result.url.searchParams.get("state")).toBeNull();
      expect(savedKey(f)).toBe("sk-or-v1-issued-1");
    } finally { f.close(); }
  }, 60000);

  test("a reused authorization code fails with a clear message and saves nothing", async () => {
    const f = fixture();
    try {
      const first = await login(f, ["--headless"], async (url) => (await (await fetch(url)).text()).match(/code-\d+/)![0]);
      expect(first.code).toBe(0);
      const logout = await runFx(["logout", "openrouter"], { cwd: f.workspace, env: f.env });
      expect(logout.stdout).toContain("Signed out of OpenRouter. The key stays active on OpenRouter until you delete it");
      expect(savedKey(f)).toBeUndefined();
      const reused = await login(f, ["--headless"], async () => "code-1");
      expect(reused.code).not.toBe(0);
      expect(reused.stderr).toContain("the authorization code expired or was already used; run fx login openrouter again");
      expect(savedKey(f)).toBeUndefined();
      const again = await runFx(["logout", "openrouter"], { cwd: f.workspace, env: f.env });
      expect(again.stdout).toContain("No saved OpenRouter key found.");
    } finally { f.close(); }
  }, 60000);

  test("--api-key validates a piped key before saving it", async () => {
    const f = fixture();
    try {
      const rejected = await runFx(["login", "openrouter", "--api-key"], { cwd: f.workspace, env: { ...f.env, OPENROUTER_API_KEY: undefined }, stdin: "sk-or-v1-unknown\n" });
      expect(rejected.code).not.toBe(0);
      expect(rejected.stderr).toContain("OpenRouter rejected the API key");
      expect(savedKey(f)).toBeUndefined();
      f.validKeys.add("sk-or-v1-pasted");
      const saved = await runFx(["login", "openrouter", "--api-key"], { cwd: f.workspace, env: { ...f.env, OPENROUTER_API_KEY: undefined }, stdin: "sk-or-v1-pasted\n" });
      expect(saved.code, saved.stdout + saved.stderr).toBe(0);
      expect(saved.stdout).toContain("Signed in to OpenRouter.");
      expect(savedKey(f)).toBe("sk-or-v1-pasted");
      const usage = await runFx(["login", "openrouter", "--bogus"], { cwd: f.workspace, env: f.env });
      expect(usage.code).not.toBe(0);
      expect(usage.stderr).toContain("usage: fx login [vercel|codex|grok|openrouter [--headless|--api-key]]");
    } finally { f.close(); }
  }, 60000);

  test("fx models lists the live catalog and reuses a fresh cached copy", async () => {
    const f = fixture(undefined, [
      { id: "anthropic/claude-sonnet-5.5", context_length: 1_000_000 },
      { id: "z-ai/glm-5", context_length: 200_000 },
    ]);
    try {
      const env = { ...f.env, FX_PROVIDER: "openrouter" };
      const listed = await runFx(["models", "--json"], { cwd: f.workspace, env });
      if (listed.code !== 0) throw new Error(listed.stdout + listed.stderr);
      expect(listed.stdout).toContain("z-ai/glm-5");
      expect(f.requests.filter((request) => request.path === "/api/v1/models")).toHaveLength(1);
      expect(f.requests.find((request) => request.path === "/api/v1/models")!.authorization).toBeNull();
      expect(readFileSync(join(f.home, ".fx", "openrouter-models.json"), "utf8")).toContain("z-ai/glm-5");
      // A fresh cache answers without the network.
      const again = await runFx(["models", "--json"], { cwd: f.workspace, env });
      expect(again.stdout).toContain("z-ai/glm-5");
      expect(f.requests.filter((request) => request.path === "/api/v1/models")).toHaveLength(1);
    } finally { f.close(); }
  }, 30000);

  test("chat requests carry attribution headers and an explicit tool choice", async () => {
    const f = fixture();
    try {
      const result = await runFx(["ask", "--json", "--no-save", "say hello"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "openrouter" }, timeoutMs: 20000 });
      if (result.code !== 0) throw new Error(result.stdout + result.stderr);
      const chat = f.requests.find((request) => request.path === "/api/v1/chat/completions")!;
      expect(chat.headers["http-referer"]).toBe("https://fx.sh");
      expect(chat.headers["x-openrouter-title"]).toBe("fx");
      expect(chat.body.tool_choice).toBe("auto");
    } finally { f.close(); }
  }, 30000);

  test("an expired catalog cache is used when the refetch fails", async () => {
    const f = fixture(undefined, null);
    try {
      const stale = await (openRouterCatalog([{ id: "cached/model" }])).text();
      writeFileSync(join(f.home, ".fx", "openrouter-models.json"), `fx-openrouter-models-v1 1000\n${stale}`, { mode: 0o600 });
      const listed = await runFx(["models", "--json"], { cwd: f.workspace, env: { ...f.env, FX_PROVIDER: "openrouter" } });
      if (listed.code !== 0) throw new Error(listed.stdout + listed.stderr);
      expect(listed.stdout).toContain("cached/model");
      expect(f.requests.filter((request) => request.path === "/api/v1/models")).toHaveLength(1);
    } finally { f.close(); }
  }, 30000);

  test("catalog limits drive automatic compaction and the output cap", async () => {
    const f = fixture(
      (body) => openRouterCompletion(body.model, "long reply " + "detail ".repeat(2000), Math.ceil(JSON.stringify(body).length / 4)),
      [{ id: "tiny/model", context_length: 32_768, max_completion_tokens: 512 }],
    );
    f.settings.provider = "openrouter";
    f.settings.models = { openrouter: "tiny/model" };
    f.save();
    let id: string | undefined;
    try {
      for (let turn = 0; turn < 12; turn++) {
        const result = await runFx(["ask", "--json", ...(id ? ["--resume", id] : []), `Continue turn ${turn}`], { cwd: f.workspace, env: f.env, timeoutMs: 20000 });
        if (result.code !== 0) throw new Error(result.stdout + result.stderr);
        id = JSON.parse(result.stdout).session_id;
      }
      const chats = f.requests.filter((request) => request.path === "/api/v1/chat/completions");
      expect(chats.some((request) => JSON.stringify(request.body.messages).includes("<compacted_conversation>"))).toBe(true);
      expect(chats.every((request) => request.body.model === "tiny/model" && request.body.max_tokens > 0 && request.body.max_tokens <= 512)).toBe(true);
    } finally { f.close(); }
  }, 120000);
});
