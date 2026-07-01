#!/usr/bin/env bash
# setup-android.sh — Install JDK 17 + Android SDK into the Multica runtime.
#
# Idempotent: skips each step when the software is already present, so it
# is safe to use as SETUP_CMD (runs on every container start).
#
# Quickstart — add to .env:
#   SETUP_CMD="bash /home/agent/scripts/setup-android.sh"
#
# To avoid re-downloading on every container recreation, mount a named volume
# at $ANDROID_SDK_ROOT (default: $HOME/android-sdk) in docker-compose.yml:
#   volumes:
#     - android-sdk:/home/agent/android-sdk
#
# Supported env vars (all optional; shown with defaults):
#   ANDROID_SDK_ROOT              $HOME/android-sdk
#   ANDROID_CMDLINE_TOOLS_BUILD   11076708   (pinned; update to upgrade)
#   ANDROID_PLATFORM_VERSION      35
#   ANDROID_BUILD_TOOLS_VERSION   35.0.0

set -euo pipefail

ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/android-sdk}"
CMDLINE_TOOLS_BUILD="${ANDROID_CMDLINE_TOOLS_BUILD:-11076708}"
PLATFORM_VERSION="${ANDROID_PLATFORM_VERSION:-35}"
BUILD_TOOLS_VERSION="${ANDROID_BUILD_TOOLS_VERSION:-35.0.0}"

SDKMANAGER="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"

# ── JDK 17 ────────────────────────────────────────────────────────────────────
# Android Gradle Plugin 8.x+ requires JDK 17.
if ! java -version 2>&1 | grep -q 'version "17'; then
  echo "[setup-android] Installing JDK 17..." >&2
  if [ "$(id -u)" = "0" ]; then
    apt-get update -qq && apt-get install -y --no-install-recommends openjdk-17-jdk-headless
  else
    sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends openjdk-17-jdk-headless
  fi
fi

export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"

# ── Android command-line tools ────────────────────────────────────────────────
if [ ! -x "$SDKMANAGER" ]; then
  echo "[setup-android] Downloading Android command-line tools (build $CMDLINE_TOOLS_BUILD)..." >&2
  mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools"
  curl -fsSL \
    "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_BUILD}_latest.zip" \
    -o /tmp/cmdline-tools.zip
  unzip -q /tmp/cmdline-tools.zip -d /tmp/cmdline-unpack
  mv /tmp/cmdline-unpack/cmdline-tools "$ANDROID_SDK_ROOT/cmdline-tools/latest"
  rm -rf /tmp/cmdline-tools.zip /tmp/cmdline-unpack
fi

export ANDROID_HOME="$ANDROID_SDK_ROOT"
export PATH="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/emulator:$PATH"

# ── SDK packages ──────────────────────────────────────────────────────────────
# Wear OS apps use the standard Android SDK platform packages — no extra
# packages are required to build for Wear OS.
echo "[setup-android] Accepting SDK licences and installing packages..." >&2
yes | sdkmanager --sdk_root="$ANDROID_SDK_ROOT" --licenses > /dev/null
sdkmanager --sdk_root="$ANDROID_SDK_ROOT" \
  "platform-tools" \
  "platforms;android-${PLATFORM_VERSION}" \
  "platforms;android-34" \
  "build-tools;${BUILD_TOOLS_VERSION}" \
  "build-tools;34.0.0"

# ── Persist env vars in shell profile ────────────────────────────────────────
# The daemon and agents inherit this environment on subsequent shells.
PROFILE="$HOME/.bashrc"
if ! grep -q 'ANDROID_SDK_ROOT' "$PROFILE" 2>/dev/null; then
  cat >> "$PROFILE" <<PROFILE_EOF

# Android SDK — added by setup-android.sh
export ANDROID_SDK_ROOT="$ANDROID_SDK_ROOT"
export ANDROID_HOME="\$ANDROID_SDK_ROOT"
export JAVA_HOME="$JAVA_HOME"
export PATH="\$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:\$ANDROID_SDK_ROOT/platform-tools:\$ANDROID_SDK_ROOT/emulator:\$PATH"
PROFILE_EOF
fi

echo "[setup-android] Done. SDK installed at $ANDROID_SDK_ROOT." >&2
