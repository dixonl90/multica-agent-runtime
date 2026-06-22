# Dev image: Flutter + Dart + Supabase CLI + mise + AI agent tools
# For use with Multica.ai connected agents (Claude, Codex, OpenCode, Antigravity)
#
# Toolchain (Flutter, Dart, Supabase) is provisioned by **mise** from the
# project mise.toml — that file is the single source of truth for versions,
# shared with host devs and CI. There are no version literals in this file.
#
# Easiest: cd agent-runtime && cp .env.example .env && docker compose up -d --build
#
# Or directly:
# Build:  docker build -f agent-runtime/Dockerfile -t florence-dev .
# Run (daemon):  docker run --rm --env-file agent-runtime/.env -v $(pwd):/app florence-dev
# Run (shell):   docker run -it --rm -v $(pwd):/app florence-dev        # no token -> interactive shell
#
# Base image pinned by digest for reproducible builds (node:20-bookworm).
FROM node:20-bookworm@sha256:8f693eaa7e0a8e71560c9a82b55fd54c2ae920a2ba5d2cde28bac7d1c01c9ba5

ARG DEBIAN_FRONTEND=noninteractive

# ── Stage 1: System & tools (cached unless base image or pins change) ─────

# System deps. chromium is needed for `flutter run -d chrome` and web tests
# (`flutter test --platform chrome`). openjdk-17 is for the Android Gradle build.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    git \
    unzip \
    xz-utils \
    zip \
    libglu1-mesa \
    openjdk-17-jdk-headless \
    chromium \
    ca-certificates \
    gnupg \
    && rm -rf /var/lib/apt/lists/*
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
# Point Flutter web tooling at the system Chromium.
ENV CHROME_EXECUTABLE=/usr/bin/chromium
ENV FLUTTER_SUPPRESS_ANALYTICS=true

# GitHub CLI (gh) — agents use it to open and merge PRs. It reads GITHUB_TOKEN
# from the environment (the entrypoint also exports GH_TOKEN). Installed from
# GitHub's official apt repository.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && apt-get install -y --no-install-recommends gh && \
    rm -rf /var/lib/apt/lists/*

# Non-root user
RUN groupadd -r florence && \
    useradd -r -g florence -m -s /bin/bash florence && \
    mkdir -p /home/florence/.local/bin \
             /home/florence/.local/share/mise \
             /home/florence/.local/state/mise \
             /home/florence/.cache \
             /home/florence/.config/mise \
             /home/florence/.config/opencode \
             /home/florence/.codex \
             /home/florence/.android \
             /home/florence/.multica \
             /home/florence/multica_workspaces \
             /home/florence/.gemini/antigravity && \
    chown -R florence:florence /home/florence
ENV HOME=/home/florence

# Android SDK (cmdline-tools pinned). Build-tools/platform match Flutter 3.44 +
# AGP 8.11.1 (compileSdk 35). NDK is omitted — add "ndk;<ver>" below if a plugin
# ever needs native compilation. Installed root-side then chowned to florence so
# `flutter build apk` (and any runtime sdkmanager use) works non-root.
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV ANDROID_HOME=/opt/android-sdk
ENV PATH="${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${PATH}"
RUN mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools" && \
    curl -fsSL https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -o /tmp/clt.zip && \
    unzip -q /tmp/clt.zip -d "${ANDROID_SDK_ROOT}/cmdline-tools" && \
    mv "${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools" "${ANDROID_SDK_ROOT}/cmdline-tools/latest" && \
    rm /tmp/clt.zip && \
    chown -R florence:florence "${ANDROID_SDK_ROOT}"

# npm global packages — versions pinned for reproducible builds.
# Postinstall scripts run with HOME=/home/florence and can create config/cache/
# state dirs as root, so reclaim ownership of the home dir afterwards — otherwise
# mise (run as florence) fails to write ~/.local/state/mise.
RUN npm install -g \
    @anthropic-ai/claude-code@2.1.179 \
    @openai/codex@0.140.0 \
    opencode-ai@1.17.7 \
    add-mcp@1.10.4 \
    && chown -R florence:florence /home/florence

# ── Everything below runs as the non-root florence user ───────────────────
USER florence

# Accept Android SDK licenses and install the pinned platform/build-tools.
RUN (yes | sdkmanager --licenses >/dev/null 2>&1 || true) && \
    sdkmanager --install "platform-tools" "platforms;android-35" "build-tools;35.0.0" >/dev/null

# mise — version manager. Provision the toolchain from the project mise.toml,
# copied to the global mise config so flutter/dart/supabase resolve to the
# pinned versions in any directory (and via `mise run <task>`).
RUN curl -fsSL https://mise.run | bash
ENV PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
COPY --chown=florence:florence mise.toml /home/florence/.config/mise/config.toml
RUN mise trust "$HOME/.config/mise/config.toml" 2>/dev/null || true; \
    mise install && mise reshim && \
    echo 'eval "$(mise activate bash)"' >> "$HOME/.bashrc"

# Warm the Flutter cache (web + android only) and accept Flutter's Android
# license records so apk builds don't prompt.
RUN flutter precache --android --web --universal && \
    (yes | flutter doctor --android-licenses >/dev/null 2>&1 || true) && \
    flutter --version && dart --version && supabase --version

# Antigravity CLI (installs to ~/.local/bin)
RUN curl -fsSL https://antigravity.google/cli/install.sh | bash

# Multica CLI (installs the `multica` binary to ~/.local/bin, which is on PATH)
RUN curl -fsSL https://raw.githubusercontent.com/multica-ai/multica/main/scripts/install.sh \
    | MULTICA_BIN_DIR="$HOME/.local/bin" bash

# Symlink antigravity into a system path (needs root for /usr/local)
USER root
RUN ln -sf "$HOME/.local/bin/agy" /usr/local/bin/agy
USER florence

# NOTE: The Stitch MCP server is registered at runtime by the entrypoint using
# $STITCH_API_KEY — the key is never baked into the image.

# opencode config — registers the DeepSeek provider (key supplied at runtime via
# $DEEPSEEK_API_KEY). Pick the model with `/models`, or set MULTICA_OPENCODE_MODEL.
COPY --chown=florence:florence agent-runtime/opencode.json /home/florence/.config/opencode/opencode.json

# Entrypoint
COPY --chown=florence:florence agent-runtime/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENV MULTICA_AGENT_RUNTIME_NAME=florence-dev

# ── Stage 2: Project-specific (invalidated when project files change) ────

USER root
WORKDIR /app
RUN chown florence:florence /app
USER florence

# Copy only dep files first — pub get is cached when deps don't change.
COPY --chown=florence:florence pubspec.yaml pubspec.lock* ./
RUN if [ -f pubspec.yaml ]; then flutter pub get; fi

# Copy everything else — only this layer invalidates on source edits.
COPY --chown=florence:florence . .

# Generate drift code if tables exist (needs full project source).
RUN if [ -f lib/data/local/tables.dart ]; then \
        dart run build_runner build --delete-conflicting-outputs; fi

ENTRYPOINT ["/entrypoint.sh"]
