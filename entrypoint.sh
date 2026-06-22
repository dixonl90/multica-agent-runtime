#!/bin/bash
set -e

# Entrypoint for the dev image.
#   - With MULTICA_TOKEN:    authenticates and starts the multica agent runtime daemon.
#   - Without MULTICA_TOKEN: drops to an interactive shell (use as a dev container).
#
# Optional env vars:
#   MULTICA_TOKEN          Personal access token (mul_... or mcn_...) — required for daemon mode
#   MULTICA_SERVER_URL     Multica API server URL (default: https://api.multica.ai)
#   MULTICA_APP_URL        Web app URL (default: https://multica.ai)
#   MULTICA_WORKSPACE_ID   Workspace to claim tasks from (or set via --workspace-id at runtime)
#   MULTICA_AGENT_RUNTIME_NAME   Display name for this runtime
#   MULTICA_DAEMON_DEVICE_NAME   Human-readable device name
#   STITCH_API_KEY         If set, registers the Stitch MCP server at startup (key stays out of the image)
#   GITHUB_TOKEN           If set, configures git HTTPS auth so the daemon can clone private repos
#
# .env file support:
#   Mount a .env file at /app/.env and it will be sourced automatically.
#   docker run -v $(pwd)/.env:/app/.env ... florence-dev
#   Or use Docker's native --env-file: docker run --env-file .env ... florence-dev

for env_file in /app/.env /.env /run/secrets/multica.env; do
  if [ -f "$env_file" ]; then
    set -a; source "$env_file"; set +a
  fi
done

# Configure git + gh auth so the multica daemon (and agents) can clone/push
# private repos over HTTPS and open/merge PRs. Without this the daemon fails with
# "could not read Username for 'https://github.com'" (terminal prompts disabled).
#   GITHUB_TOKEN  PAT with: Contents RW, Pull requests RW, Metadata R
#                 (+ Workflows RW if editing .github/workflows, + Checks R to gate merges)
if [ -n "$GITHUB_TOKEN" ]; then
  git config --global credential.helper store
  printf 'https://x-access-token:%s@github.com\n' "$GITHUB_TOKEN" > "$HOME/.git-credentials"
  chmod 600 "$HOME/.git-credentials"
  # gh reads GH_TOKEN first, then GITHUB_TOKEN — export GH_TOKEN so it is unambiguous.
  export GH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"
fi

# Register the Stitch MCP server at runtime so the API key is never baked into
# the image. No-op (with a warning) if the key is absent or registration fails.
if [ -n "$STITCH_API_KEY" ]; then
  add-mcp https://stitch.googleapis.com/mcp \
    --header "X-Goog-Api-Key: $STITCH_API_KEY" \
    --name stitch \
    -a claude-code -a codex -a opencode -a gemini-cli -a antigravity \
    -g -y || echo "WARN: failed to register Stitch MCP server" >&2
fi

SERVER_URL="${MULTICA_SERVER_URL:-https://api.multica.ai}"
APP_URL="${MULTICA_APP_URL:-https://multica.ai}"

# Stable daemon identity. The multica runtime is keyed by the daemon id, which
# defaults to the system hostname — and a container's hostname is a fresh random
# id on every `docker run`, so the daemon would register a NEW runtime each time.
# Default it to a stable value so reruns reuse the same runtime. Override with
# -e MULTICA_DAEMON_ID=... (or run distinct runtimes with distinct ids).
export MULTICA_DAEMON_ID="${MULTICA_DAEMON_ID:-${MULTICA_AGENT_RUNTIME_NAME:-florence-dev}}"

# No token -> interactive dev shell (or whatever command was passed to `docker run`).
if [ -z "$MULTICA_TOKEN" ]; then
  echo "No MULTICA_TOKEN set — starting an interactive shell instead of the daemon." >&2
  echo "For headless daemon mode: docker run -e MULTICA_TOKEN=mul_... florence-dev" >&2
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
