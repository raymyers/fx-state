# Docs changes for the OpenRouter provider

Paste the `## Docs` section into the pull request description if the manual's repository is not available. Use the release note line in the next release PR's `CHANGELOG.md` entry.

## Docs

- https://fx.sh/docs/configure-fx/custom-model-connections, "Connect a hosted endpoint": replace "For OpenRouter, vLLM, or another endpoint that accepts bearer authentication:" with "For vLLM or another endpoint that accepts bearer authentication. OpenRouter is built in, so use [OpenRouter](/docs/configure-fx/openrouter) instead of a custom connection:".
- https://fx.sh/docs/configure-fx/custom-model-connections, "Connect a hosted endpoint" example: rename the connection from `openrouter` to `hosted` in `"provider"`, `"providers"`, and `"models"`. Replace `"base_url": "https://openrouter.ai/api/v1"` with `"base_url": "https://models.example.com/v1"`, `"env": "OPENROUTER_API_KEY"` with `"env": "HOSTED_API_KEY"`, `"openrouter": "openai/gpt-4.1-mini"` with `"hosted": "your-model-id"`, and `export OPENROUTER_API_KEY="your-api-key"` with `export HOSTED_API_KEY="your-api-key"`.
- https://fx.sh/docs/configure-fx/custom-model-connections, "Connection fields": add "A connection can't be named `gateway`, `codex`, `grok`, or `openrouter`. A profile that still defines a connection named `openrouter` fails to load until you rename or delete it." after the description of the connection name.
- New page https://fx.sh/docs/configure-fx/openrouter, after "Custom model connections" in the configure-fx navigation, with this content:

  ```md
  # OpenRouter

  fx can run any tool-capable model on OpenRouter with your OpenRouter key and credits.

  ## Sign in

  Run `fx login openrouter`. fx opens OpenRouter in your browser, and when you approve, OpenRouter creates a key labeled `fx`. fx checks the key and saves it in `~/.fx/openrouter-auth.json`, readable only by you.

  On a machine without a browser, run `fx login openrouter --headless`, open the printed URL on any device, and paste the code OpenRouter shows. To use a key you already have, run `fx login openrouter --api-key` and paste it; the input is hidden, and a key piped on stdin also works.

  In the interactive terminal, run `/login`, choose `openrouter`, then `oauth` to sign in with the browser or `api-key` to paste a key.

  You can also set `OPENROUTER_API_KEY`. It takes precedence over a saved key.

  ## Choose a model

  Run `fx provider openrouter`, or start fx with `--provider openrouter`. The default model is `anthropic/claude-sonnet-5.5`. `/model` and `fx models` list every OpenRouter model that supports tool calls, with its context window. fx reads OpenRouter's model list when OpenRouter is the active provider and keeps a copy for an hour.

  If you choose a model that OpenRouter's list doesn't include, fx warns once. It doesn't know that model's context window, so it compacts the conversation only when OpenRouter reports that the context is full.

  ## Reasoning and caching

  Reasoning models list their effort levels in `/model`, and the effort you choose is sent to OpenRouter. fx adds prompt-cache breakpoints for Anthropic, Gemini, and Qwen models, which cache only when asked. Other models cache automatically.

  ## Routing

  The `provider_order` and `provider_strict` settings choose which upstream providers OpenRouter may use, as they do for Vercel AI Gateway. Use OpenRouter's provider slugs, such as `anthropic` or `google-vertex`. With `provider_strict`, OpenRouter uses only the listed providers.

  ## Usage and credits

  `/usage` and `fx usage` show the key's spend today, this week, this month, and all time, with its limit and what is left. `fx ask --json` reports each turn's cost. When your credits run out, fx stops the turn and links to https://openrouter.ai/credits.

  Session titles and auto-mode permission reviews run on `openai/gpt-5-nano`, so they don't bill your selected model.

  ## Sign out

  Run `fx logout openrouter`, or `/logout openrouter` in the terminal. fx deletes the saved key from this machine. The key stays active on OpenRouter until you delete it at https://openrouter.ai/settings/keys.
  ```

## Release note line

For the next release's `### Breaking Changes` section:

- A custom connection named `openrouter` now stops fx from loading the profile, because OpenRouter is a built-in provider. Rename or delete the connection under `providers` in `~/.fx/settings.json`, then use `fx login openrouter`.
