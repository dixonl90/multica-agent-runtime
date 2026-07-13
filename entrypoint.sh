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
#   GITLAB_TOKEN / GITLAB_HOST GitLab auth for git HTTPS + glab (host defaults to gitlab.com)
#   GITEA_TOKEN / GITEA_HOST   Gitea/Forgejo auth for git HTTPS + tea (host required, no default)
#   AGENT_CONFIG_DIR           Shared dir for agent CLI logins/onboarding (default ~/.agent-config; mount a volume to persist)
#   SETUP_CMD                  Optional one-time bootstrap run before the daemon starts (toolchain, MCPs, ...)
#
# .env support: a file at /app/.env, /.env, or /run/secrets/multica.env is sourced automatically.

for env_file in /app/.env /.env /run/secrets/multica.env; do
  if [ -f "$env_file" ]; then
    set -a; source "$env_file"; set +a
  fi
done

# Codex prefers to sandbox shell commands with bubblewrap. Some container hosts
# still block the required privilege changes even when /usr/bin/bwrap is setuid
# (e.g. `capset failed: Operation not permitted`, `Failed to make / slave:
# Permission denied`), which makes Codex fail before it can do useful work.
# Probe bwrap once at startup and, only when the probe fails, pin Codex's
# sandbox_mode to danger-full-access via its config.toml — the outer container
# is already the sandbox boundary in that case, so Codex's own nested sandbox
# is both redundant and broken. Always overwritten (not just set-if-absent)
# when the probe fails: CODEX_HOME is a persisted volume across container
# recreations, so a stale sandbox_mode from before bwrap broke (or Codex's own
# workspace-write default) would otherwise survive a rebuild and stay broken.
codex_bwrap_ok=1
if command -v bwrap >/dev/null 2>&1; then
  bwrap --ro-bind / / --proc /proc --dev /dev /bin/true >/dev/null 2>&1 || codex_bwrap_ok=0
else
  codex_bwrap_ok=0
fi
if [ "$codex_bwrap_ok" = 0 ]; then
  codex_config="${CODEX_HOME:-$HOME/.codex}/config.toml"
  mkdir -p "$(dirname "$codex_config")"
  touch "$codex_config"
  if [ "$(yq '.sandbox_mode // ""' -p toml -o toml "$codex_config")" != "danger-full-access" ]; then
    yq -i '.sandbox_mode = "danger-full-access"' -p toml -o toml "$codex_config"
    echo "warning: bubblewrap sandboxing is unavailable in this container; set Codex sandbox_mode=danger-full-access in $codex_config" >&2
  fi
fi

# Configure git HTTPS auth + the host CLIs so the daemon (and agents) can
# clone/push private repos and open/merge PRs/MRs. Without git creds the daemon
# fails with "could not read Username for 'https://...'" (terminal prompts disabled).
#
# One token per host platform. GitHub is always github.com; self-hosted Gitea,
# Forgejo and self-managed GitLab live on arbitrary domains, so those take a bare
# *_HOST (hostname only, no scheme; it is interpolated into the credentials URL).
#   GITHUB_TOKEN  classic PAT scope `repo` (+ `workflow`), or a fine-grained PAT
#                 with Contents RW, Pull requests RW, Metadata R.
#   GITLAB_TOKEN  PAT scopes `api` + `write_repository` (+ GITLAB_HOST for self-managed).
#   GITEA_TOKEN   token with repo + PR scopes (+ GITEA_HOST, required, no default).
CRED_FILE="$HOME/.git-credentials"
: > "$CRED_FILE"
chmod 600 "$CRED_FILE"
have_git_creds=0

add_git_cred() {  # $1=host (no scheme)  $2=username  $3=token
  [ -n "$1" ] && [ -n "$3" ] || return 0
  printf 'https://%s:%s@%s\n' "$2" "$3" "$1" >> "$CRED_FILE"
  have_git_creds=1
}

add_git_cred "github.com"                 "x-access-token"        "$GITHUB_TOKEN"
add_git_cred "${GITLAB_HOST:-gitlab.com}" "oauth2"                "$GITLAB_TOKEN"
add_git_cred "$GITEA_HOST"                "${GITEA_USER:-oauth2}" "$GITEA_TOKEN"

if [ "$have_git_creds" = 1 ]; then
# Shared config dir for the agent CLIs. Mount a volume at $AGENT_CONFIG_DIR (see
# docker-compose.yml) to persist each agent's login/onboarding across container
# recreation. Claude and Codex are pointed here by env (set in the Dockerfile);
# OpenCode and Antigravity have no relocation env var, so symlink their fixed
# paths into the same dir. Headless token auth (see .env.example) needs none of
# this; it only matters for interactive logins.
AGENT_CONFIG_DIR="${AGENT_CONFIG_DIR:-$HOME/.agent-config}"
mkdir -p "$AGENT_CONFIG_DIR/claude" "$AGENT_CONFIG_DIR/codex" \
         "$AGENT_CONFIG_DIR/opencode" "$AGENT_CONFIG_DIR/gemini" \
         "$HOME/.local/share"
# OpenCode keeps auth/data under ~/.local/share/opencode; Antigravity under
# ~/.gemini. Replace each fixed path with a symlink into the shared dir (skip if
# it is already the symlink, to stay idempotent across reruns).
for link in ".local/share/opencode:opencode" ".gemini:gemini"; do
  path="$HOME/${link%%:*}"; target="$AGENT_CONFIG_DIR/${link##*:}"
  [ -L "$path" ] || rm -rf "$path"
  ln -sfn "$target" "$path"
done

# Configure git + gh auth so the daemon (and agents) can clone/push private repos
# over HTTPS and open/merge PRs. Without this the daemon fails with
# "could not read Username for 'https://github.com'" (terminal prompts disabled).
#   GITHUB_TOKEN  classic PAT scope `repo` (+ `workflow` if editing .github/workflows),
#                 or a fine-grained PAT with Contents RW, Pull requests RW, Metadata R.
if [ -n "$GITHUB_TOKEN" ]; then
  git config --global credential.helper store
fi

# gh reads GH_TOKEN first, then GITHUB_TOKEN, so export GH_TOKEN to be unambiguous.
if [ -n "$GITHUB_TOKEN" ]; then
  export GH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"
fi

# glab reads GITLAB_TOKEN + GITLAB_HOST straight from the environment (already
# exported via the .env sourcing above), so no extra login step is needed.

# tea keeps auth in a config file, so log in non-interactively when a Gitea token
# is set. Needs the instance URL, so prepend https:// to the bare GITEA_HOST.
if [ -n "$GITEA_TOKEN" ] && [ -n "$GITEA_HOST" ]; then
  case "$GITEA_HOST" in
    http://*|https://*) tea_url="$GITEA_HOST" ;;
    *)                  tea_url="https://$GITEA_HOST" ;;
  esac
  tea login add --name "${GITEA_LOGIN_NAME:-gitea}" --url "$tea_url" --token "$GITEA_TOKEN" >/dev/null 2>&1 \
    || echo "warning: 'tea login add' failed; check GITEA_HOST / GITEA_TOKEN" >&2
fi

# Optional one-time bootstrap. Use to provision a project toolchain or register
# MCP servers without baking them into the image. Examples:
#   SETUP_CMD="mise install"
#   SETUP_CMD="add-mcp https://example.com/mcp --name foo -a claude-code -a codex -g -y"
if [ -n "$SETUP_CMD" ]; then
  echo "Running SETUP_CMD..." >&2
  bash -lc "$SETUP_CMD"
fi
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
