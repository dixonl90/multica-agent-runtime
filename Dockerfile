# Multica.ai connected-agent runtime — generic base image.
#
# Ships the multica daemon + agent CLIs (Claude Code, Codex, OpenCode,
# Antigravity) + git/gh + mise. NO language toolchain is baked in — this image
# is stack-agnostic. Projects provision their own toolchain at runtime via mise,
# a SETUP_CMD bootstrap, or by extending this image (see README).
#
# Build:  docker build -t multica-agent-runtime .
# Run (daemon):  docker run --rm --env-file .env multica-agent-runtime
# Run (shell):   docker run -it --rm multica-agent-runtime        # no token -> shell
#
# Base image pinned by digest for reproducible builds (node:20-bookworm).
FROM node:20-bookworm@sha256:8f693eaa7e0a8e71560c9a82b55fd54c2ae920a2ba5d2cde28bac7d1c01c9ba5

ARG DEBIAN_FRONTEND=noninteractive

# ── System deps (language-agnostic) ──────────────────────────────────────
# build-essential/unzip/xz/zip let mise-provisioned toolchains compile/extract.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    git \
    unzip \
    xz-utils \
    zip \
    ca-certificates \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI (gh) — agents use it to open and merge PRs. Reads GITHUB_TOKEN /
# GH_TOKEN from the environment (the entrypoint exports GH_TOKEN).
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && apt-get install -y --no-install-recommends gh && \
    rm -rf /var/lib/apt/lists/*

# ── Non-root user ─────────────────────────────────────────────────────────
RUN groupadd -r agent && \
    useradd -r -g agent -m -s /bin/bash agent && \
    mkdir -p /home/agent/.local/bin \
             /home/agent/.local/share/mise \
             /home/agent/.local/state/mise \
             /home/agent/.cache \
             /home/agent/.config/mise \
             /home/agent/.config/opencode \
             /home/agent/.codex \
             /home/agent/.multica \
             /home/agent/multica_workspaces \
             /home/agent/.gemini/antigravity && \
    chown -R agent:agent /home/agent
ENV HOME=/home/agent

# ── Agent CLIs (pinned for reproducible builds) ───────────────────────────
# Postinstall scripts run as root and create config/cache dirs; reclaim
# ownership afterwards so the non-root agent user can write them.
RUN npm install -g \
    @anthropic-ai/claude-code@2.1.179 \
    @openai/codex@0.140.0 \
    opencode-ai@1.17.7 \
    add-mcp@1.10.4 \
    && chown -R agent:agent /home/agent

# ── Everything below runs as the non-root agent user ──────────────────────
USER agent

# mise — language-agnostic version manager. Not used to bake any toolchain into
# the image; it is here so a mounted/cloned project with a mise config can
# self-provision (e.g. `SETUP_CMD="mise install"`, or an agent running it per task).
RUN curl -fsSL https://mise.run | bash
ENV PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
RUN echo 'eval "$(mise activate bash)"' >> "$HOME/.bashrc"

# Antigravity CLI (installs `agy` to ~/.local/bin)
RUN curl -fsSL https://antigravity.google/cli/install.sh | bash

# Multica CLI (installs the `multica` binary to ~/.local/bin, which is on PATH)
RUN curl -fsSL https://raw.githubusercontent.com/multica-ai/multica/main/scripts/install.sh \
    | MULTICA_BIN_DIR="$HOME/.local/bin" bash

# Symlink antigravity into a system path (needs root for /usr/local)
USER root
RUN ln -sf "$HOME/.local/bin/agy" /usr/local/bin/agy
USER agent

# OpenCode provider config (DeepSeek example; the API key is supplied at runtime
# via $DEEPSEEK_API_KEY and never baked in). Edit opencode.json to add providers.
COPY --chown=agent:agent opencode.json /home/agent/.config/opencode/opencode.json

# Entrypoint
COPY --chown=agent:agent entrypoint.sh /entrypoint.sh
USER root
RUN chmod +x /entrypoint.sh
USER agent

ENV MULTICA_AGENT_RUNTIME_NAME=multica-agent-runtime
WORKDIR /home/agent
ENTRYPOINT ["/entrypoint.sh"]
