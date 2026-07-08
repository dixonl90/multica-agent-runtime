# Multica.ai connected-agent runtime — generic base image.
#
# Ships the multica daemon + agent CLIs (Claude Code, Codex, OpenCode,
# Antigravity, Hermes, Pi, OpenClaw) + git and the host CLIs gh/glab/tea + mise. NO language toolchain
# is baked in, so this image is stack-agnostic. Projects provision their own
# toolchain at runtime via mise,
# a SETUP_CMD bootstrap, or by extending this image (see README).
#
# Build:  docker build -t multica-agent-runtime .
# Run (daemon):  docker run --rm --env-file .env multica-agent-runtime
# Run (shell):   docker run -it --rm multica-agent-runtime        # no token -> shell
#
# Base image pinned by digest for reproducible builds (node:22-bookworm-slim).
FROM node:22-bookworm-slim@sha256:53ada149d435c38b14476cb57e4a7da73c15595aba79bd6971b547ceb6d018bf

ARG DEBIAN_FRONTEND=noninteractive

# ── System deps (language-agnostic) ──────────────────────────────────────
# build-essential/unzip/xz/zip let mise-provisioned toolchains compile/extract.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    bubblewrap \
    curl \
    chromium \
    git \
    python3-pip \
    ripgrep \
    unzip \
    xz-utils \
    zip \
    ca-certificates \
    gnupg \
    && rm -rf /var/lib/apt/lists/* \
    # setuid lets bwrap create namespaces when kernel.unprivileged_userns_clone=0 (containers)
    && chmod u+s /usr/bin/bwrap

# GitHub CLI (gh) — agents use it to open and merge PRs. Reads GITHUB_TOKEN /
# GH_TOKEN from the environment (the entrypoint exports GH_TOKEN).
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && apt-get install -y --no-install-recommends gh && \
    rm -rf /var/lib/apt/lists/*

# GitLab CLI (glab): agents use it to open and merge MRs. Reads GITLAB_TOKEN /
# GITLAB_HOST from the environment (the entrypoint configures them). Pinned .deb
# from the official GitLab release, arch matched to the build platform.
RUN v=1.107.0 && arch="$(dpkg --print-architecture)" && \
    curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${v}/downloads/glab_${v}_linux_${arch}.deb" \
      -o /tmp/glab.deb && \
    dpkg -i /tmp/glab.deb && \
    rm /tmp/glab.deb

# Gitea CLI (tea): agents use it to open and merge PRs on Gitea AND Forgejo
# (Forgejo is a Gitea fork and speaks the same API). Authenticated per-run by the
# entrypoint via `tea login add`. Pinned static binary from the official mirror.
RUN v=0.14.2 && arch="$(dpkg --print-architecture)" && \
    curl -fsSL "https://dl.gitea.com/tea/${v}/tea-${v}-linux-${arch}" \
      -o /usr/local/bin/tea && \
    chmod +x /usr/local/bin/tea

# yq (mikefarah v4) — a REAL binary, deliberately NOT managed by mise. Some mise
# plugins shell out to bare `yq` while resolving versions; if `yq` were a mise
# shim that call would re-enter mise and recurse. A plain binary on PATH breaks
# the loop while all toolchains stay mise-managed. Pinned from the GitHub release
# because Debian's apt `yq` is the unrelated kislyuk python wrapper.
ARG YQ_VERSION=v4.53.3
RUN curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_$(dpkg --print-architecture)" \
      -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq

# ── Non-root user ─────────────────────────────────────────────────────────
RUN groupadd -g 10001 agent && \
    useradd -u 10001 -g agent -m -s /bin/bash agent && \
    mkdir -p /home/agent/.local/bin \
             /home/agent/.local/share/mise \
             /home/agent/.local/state/mise \
             /home/agent/.cache \
             /home/agent/.config/mise \
             /home/agent/.config/opencode \
             /home/agent/.codex \
             /home/agent/.agent-config \
             /home/agent/.multica \
             /home/agent/multica_workspaces \
             /home/agent/.gemini/antigravity && \
    chown -R agent:agent /home/agent
ENV HOME=/home/agent

# ── Agent CLIs (pinned for reproducible builds) ───────────────────────────
# Postinstall scripts run as root and create config/cache dirs; reclaim
# ownership afterwards so the non-root agent user can write them.
# PEP 668: Debian bookworm marks its Python as externally-managed, blocking
# pip even as root. Setting this flag is safe inside a container.
ENV PIP_BREAK_SYSTEM_PACKAGES=1
RUN npm install -g \
    @anthropic-ai/claude-code@2.1.204 \
    @openai/codex@0.143.0 \
    opencode-ai@1.17.15 \
    hermes-agent@0.18.2 \
    @earendil-works/pi-coding-agent@0.80.3 \
    openclaw@2026.6.11 \
    add-mcp@1.14.0 \
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

# Stable Chrome wrappers - resolve whichever Playwright chromium /
# chrome-headless-shell revision is installed under PLAYWRIGHT_BROWSERS_PATH
# (see bin/chrome, bin/chrome-headless-shell), so agents do not need to track
# the pinned build number 'playwright install chromium' downloads.
COPY --chown=agent:agent bin/chrome bin/chrome-headless-shell /usr/local/bin/
USER root
RUN chmod +x /usr/local/bin/chrome /usr/local/bin/chrome-headless-shell
USER agent

# OpenCode provider config (DeepSeek example; the API key is supplied at runtime
# via $DEEPSEEK_API_KEY and never baked in). Edit opencode.json to add providers.
COPY --chown=agent:agent opencode.json /home/agent/.config/opencode/opencode.json

# Entrypoint
COPY --chown=agent:agent entrypoint.sh /entrypoint.sh
USER root
RUN chmod +x /entrypoint.sh
USER agent

# Shared, persistable config dir for the agent CLIs. Mount a volume here (see
# docker-compose.yml) to keep each agent's login/onboarding across recreations.
# Claude and Codex relocate into it via env; OpenCode and Antigravity have no
# relocation env var and are symlinked in by the entrypoint. Pre-created above as
# agent-owned so an empty named volume mounted here inherits write permission.
ENV AGENT_CONFIG_DIR=/home/agent/.agent-config \
    CLAUDE_CONFIG_DIR=/home/agent/.agent-config/claude \
    CODEX_HOME=/home/agent/.agent-config/codex

ENV MULTICA_AGENT_RUNTIME_NAME=multica-agent-runtime
WORKDIR /home/agent
ENTRYPOINT ["/entrypoint.sh"]
