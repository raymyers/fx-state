import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { runFx } from "../evals/eval-helpers";
import { createOpenRouterFixture as fixture } from "./fixtures/openrouter";

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
      expect(f.requests).toHaveLength(1);
      expect(f.requests[0].path).toBe("/api/v1/chat/completions");
      expect(f.requests[0].authorization).toBe("Bearer sk-or-test-key");
      expect(f.requests[0].body.model).toBe("anthropic/claude-sonnet-5.5");
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
      expect(result.stderr).toContain("fx needs an OpenRouter API key for this model. Set OPENROUTER_API_KEY");
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
      expect(f.requests).toHaveLength(2);
      expect(f.requests[1].authorization).toBe("Bearer sk-or-test-key");
      expect(JSON.stringify(f.requests[1].body.messages)).toContain("remember the word lantern");
    } finally { f.close(); }
  }, 45000);
});
