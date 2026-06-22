#!/bin/bash
set -e

# Entrypoint for the multica connected-agent runtime.
#   - With MULTICA_TOKEN:    authenticates and starts the multica daemon.
#   - Without MULTICA_TOKEN: drops to an interactive shell (use as a dev container).
#
# Env vars (see .env.example for the full list):
#   MULTICA_TOKEN              Personal access token (mul_... or mcn_...) — required for daemon mode
#   MULTICA_SERVER_URL         Multica API server URL (default: https://api.multica.ai)
#   MULTICA_APP_URL            Web app URL (default: https://multica.ai)
#   MULTICA_WORKSPACE_ID       Workspace to claim tasks from (or pass --workspace-id at runtime)
#   MULTICA_AGENT_RUNTIME_NAME Display name for this runtime
#   MULTICA_DAEMON_ID          Stable daemon id (defaults to the runtime name)
#   GITHUB_TOKEN               If set, configures git HTTPS auth + gh so agents can clone/push private repos
#   SETUP_CMD                  Optional one-time bootstrap run before the daemon starts (toolchain, MCPs, ...)
#
# .env support: a file at /app/.env, /.env, or /run/secrets/multica.env is sourced automatically.

for env_file in /app/.env /.env /run/secrets/multica.env; do
  if [ -f "$env_file" ]; then
    set -a; source "$env_file"; set +a
  fi
done

# Configure git + gh auth so the daemon (and agents) can clone/push private repos
# over HTTPS and open/merge PRs. Without this the daemon fails with
# "could not read Username for 'https://github.com'" (terminal prompts disabled).
#   GITHUB_TOKEN  classic PAT scope `repo` (+ `workflow` if editing .github/workflows),
#                 or a fine-grained PAT with Contents RW, Pull requests RW, Metadata R.
if [ -n "$GITHUB_TOKEN" ]; then
  git config --global credential.helper store
  printf 'https://x-access-token:%s@github.com\n' "$GITHUB_TOKEN" > "$HOME/.git-credentials"
  chmod 600 "$HOME/.git-credentials"
  # gh reads GH_TOKEN first, then GITHUB_TOKEN — export GH_TOKEN so it is unambiguous.
  export GH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"
fi

# Optional one-time bootstrap. Use to provision a project toolchain or register
# MCP servers without baking them into the image. Examples:
#   SETUP_CMD="mise install"
#   SETUP_CMD="add-mcp https://example.com/mcp --name foo -a claude-code -a codex -g -y"
if [ -n "$SETUP_CMD" ]; then
  echo "Running SETUP_CMD..." >&2
  bash -lc "$SETUP_CMD"
fi

SERVER_URL="${MULTICA_SERVER_URL:-https://api.multica.ai}"
APP_URL="${MULTICA_APP_URL:-https://multica.ai}"

# Stable daemon identity. The multica runtime is keyed by the daemon id, which
# defaults to the system hostname — and a container's hostname is a fresh random
# id on every `docker run`, so the daemon would register a NEW runtime each time.
# Default it to a stable value so reruns reuse the same runtime. Override with
# -e MULTICA_DAEMON_ID=... (or run distinct runtimes with distinct ids).
export MULTICA_DAEMON_ID="${MULTICA_DAEMON_ID:-${MULTICA_AGENT_RUNTIME_NAME:-multica-agent-runtime}}"

# No token -> interactive dev shell (or whatever command was passed to `docker run`).
if [ -z "$MULTICA_TOKEN" ]; then
  echo "No MULTICA_TOKEN set — starting an interactive shell instead of the daemon." >&2
  echo "For headless daemon mode: docker run -e MULTICA_TOKEN=mul_... multica-agent-runtime" >&2
  echo "Generate a token at ${APP_URL}/settings/tokens" >&2
  exec "${@:-bash}"
fi

multica config set server_url "$SERVER_URL"
multica config set app_url "$APP_URL"

if [ -n "$MULTICA_WORKSPACE_ID" ]; then
  multica config set workspace_id "$MULTICA_WORKSPACE_ID"
fi

multica login --token "$MULTICA_TOKEN"

exec multica daemon start --foreground
