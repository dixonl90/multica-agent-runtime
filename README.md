# multica-agent-runtime

Dockerised [Multica.ai](https://multica.ai) connected-agent runtime for the
Florence Tracker project. Bundles the toolchain (Flutter / Dart / Supabase CLI
via `mise`) plus the agent CLIs (Claude Code, Codex, OpenCode, Antigravity) and
the `multica` daemon, so a host can register as a runtime and execute squad tasks.

Extracted from [`dixonl90/go-with-the-flo`](https://github.com/dixonl90/go-with-the-flo).

## Quickstart

```bash
cp .env.example .env          # fill in MULTICA_TOKEN, GITHUB_TOKEN, etc.
docker compose up -d --build  # build + start the daemon
docker compose logs -f        # follow daemon output
docker compose down           # stop (named volumes persist)
```

Without `MULTICA_TOKEN` the entrypoint drops to an interactive shell instead of
starting the daemon.

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Dev image: Flutter + Dart + Supabase CLI + mise + agent CLIs + multica |
| `docker-compose.yml` | Daemon service, named volumes for state + workspaces |
| `entrypoint.sh` | Auth (multica + git/gh), optional MCP registration, daemon start |
| `opencode.json` | OpenCode provider config (DeepSeek) |
| `.env.example` | Required/optional env vars (copy to `.env`) |

## ⚠️ Not yet standalone

This is a verbatim copy of `agent-runtime/` from the app repo. The build is still
coupled to the Florence Flutter project:

- `docker-compose.yml` uses `context: ..` (expects the app repo as the parent dir).
- The Dockerfile references `agent-runtime/<file>` paths and `COPY`s `mise.toml`,
  `pubspec.yaml`, and `lib/`, then runs `flutter pub get` + `build_runner`.

To build from this repo on its own, follow-up work is needed: decouple the image
from a specific app (mount the project at runtime, or parameterise the source),
and update the `context` / `COPY` paths. Tracked as the next step.
