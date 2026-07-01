# multica-agent-runtime

A generic, Dockerised runtime for [Multica.ai](https://multica.ai) **connected
agents**. Run it on any host (laptop, server, VM, CI) to register that machine as
a Multica agent runtime and let your squad's agents execute tasks there.

Stack-agnostic by design: it ships the agent CLIs and the `multica` daemon, but
**no language toolchain** — your projects bring their own (see
[Provisioning a toolchain](#provisioning-a-toolchain)).

## What's inside

- **Agent CLIs**: Claude Code, OpenAI Codex, OpenCode, Antigravity (`agy`)
- **`multica`** daemon + CLI
- **git** + **GitHub CLI** (`gh`) with token-based HTTPS auth wired up
- **[mise](https://mise.jdx.dev/)** — language-agnostic version manager for per-project toolchains
- **add-mcp** — register MCP servers with the agent CLIs

Base image `node:20-bookworm` (pinned by digest). Runs as a non-root `agent` user.

## Quickstart

A pre-built multi-platform image (`linux/amd64`, `linux/arm64`) is published to
the GitHub Container Registry on every push to `main` and on every version tag:

```bash
docker pull ghcr.io/dixonl90/multica-agent-runtime:latest
```

To run it directly on your server:

```bash
cp .env.example .env   # fill in MULTICA_TOKEN (+ GITHUB_TOKEN for private repos)
docker run -d \
  --env-file .env \
  --restart unless-stopped \
  -v multica-state:/home/agent/.multica \
  -v multica-workspaces:/home/agent/multica_workspaces \
  -v agent-config:/home/agent/.agent-config \
  ghcr.io/dixonl90/multica-agent-runtime:latest
```

Or use Compose (builds locally if the image is not already present):

```bash
cp .env.example .env          # fill in MULTICA_TOKEN (+ GITHUB_TOKEN for private repos)
docker compose up -d          # pull/start the daemon (add --build to build locally)
docker compose logs -f        # follow daemon output
docker compose down           # stop (named volumes persist)
```

Get a token at https://multica.ai/settings/tokens. Without `MULTICA_TOKEN` the
container drops to an interactive shell instead of starting the daemon — handy as
a plain dev container:

```bash
docker run -it --rm ghcr.io/dixonl90/multica-agent-runtime:latest
```

## Configuration

All config is via environment variables — see [`.env.example`](.env.example).
Key ones:

| Var | Purpose |
|-----|---------|
| `MULTICA_TOKEN` | PAT for daemon mode (required to run as a runtime) |
| `MULTICA_WORKSPACE_ID` | Workspace to claim tasks from |
| `MULTICA_AGENT_RUNTIME_NAME` | Display name + default stable daemon id |
| `GITHUB_TOKEN` | git HTTPS + `gh` auth so agents clone/push private repos and open PRs |
| `SETUP_CMD` | Optional one-time bootstrap run before the daemon starts |
| `DEEPSEEK_API_KEY` | Optional — enables the DeepSeek provider in `opencode.json` |

Persistence: three named volumes survive reruns. They hold daemon identity/auth
(`/home/agent/.multica`), the repo cache + agent workdirs
(`/home/agent/multica_workspaces`), and the agent CLIs' own login/onboarding state
(`/home/agent/.agent-config`), so the daemon reuses the same runtime, resumes
tasks, and the agents stay logged in.

### Agent logins

Headless use needs nothing here: pass each agent's API key or token via the
environment and the CLIs authenticate non-interactively. The `agent-config` volume
is for *interactive* logins, which would otherwise reset on every container
recreation. All four agents keep their state in one place: Claude and Codex are
relocated into the volume via `CLAUDE_CONFIG_DIR` / `CODEX_HOME`, and OpenCode and
Antigravity (which have no relocation env var) are symlinked into it by the
entrypoint. The same volume is a convenient home for any other persistent config.

## Provisioning a toolchain

The image has no Flutter/Node-app/Python/etc. toolchain baked in. The daemon
clones each task's repo into `multica_workspaces`, so per-project toolchains are
best handled one of three ways:

1. **Let agents self-provision** — if a repo has a [`mise.toml`](https://mise.jdx.dev/),
   an agent can run `mise install` as part of its task. `mise` is already on PATH.
2. **`SETUP_CMD`** — a one-time bootstrap before the daemon starts, e.g.
   `SETUP_CMD="mise install"` against a mounted project, or to register MCP servers:
   `SETUP_CMD="add-mcp <url> --name foo -a claude-code -a codex -g -y"`.
3. **Extend the image** — `FROM multica-agent-runtime` and add your SDKs/CLIs.

## Working on a local project

By default the daemon clones repos itself. To instead have agents work on a local
checkout in place, mount it (uncomment in `docker-compose.yml`):

```yaml
    volumes:
      - ./your-project:/app
```

## Security

- Tokens are passed via env / `.env` only — none are baked into the image.
- `.env` is git-ignored; only `.env.example` is committed.
- The image runs as a non-root user.
- `GITHUB_TOKEN` grants the daemon repo access — scope it to the minimum
  (`repo`, or a fine-grained PAT limited to the repos you want agents to touch).

## License

[MIT](LICENSE).
