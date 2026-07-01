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

```bash
cp .env.example .env          # fill in MULTICA_TOKEN (+ GITHUB_TOKEN for private repos)
docker compose up -d --build  # build + start the daemon
docker compose logs -f        # follow daemon output
docker compose down           # stop (named volumes persist)
```

Get a token at https://multica.ai/settings/tokens. Without `MULTICA_TOKEN` the
container drops to an interactive shell instead of starting the daemon — handy as
a plain dev container:

```bash
docker run -it --rm multica-agent-runtime
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

## Android and Wear OS

A pre-built **Android variant** ships as `Dockerfile.android`. It extends the
base image with:

- **JDK 17** — required for Android Gradle Plugin 8.x+
- **Android command-line tools** (`sdkmanager`, `avdmanager`)
- **SDK Platforms 34 and 35** + matching build-tools
- **`adb`** (platform-tools) — connect to a physical device over USB or TCP

Wear OS apps use the standard Android SDK — no extra packages are needed for
building. Wear OS-specific libraries (`androidx.wear`, `androidx.wear.compose`,
etc.) are fetched from Maven by Gradle as usual.

### Build the Android image

The Android image extends the base image, so build the base first:

```bash
docker build -t multica-agent-runtime .
docker build -f Dockerfile.android -t multica-agent-runtime-android .
```

Or with Compose (base is built automatically when the base service is built
first):

```bash
docker compose build runtime
docker compose --profile android build android-runtime
docker compose --profile android up -d android-runtime
```

### Connecting a physical device

Plug the device in before starting the container and forward the USB device,
or use ADB over TCP (enable TCP on the device first):

```bash
# ADB over TCP
docker run --rm --env-file .env \
  multica-agent-runtime-android \
  bash -c "adb connect 192.168.1.42:5555 && exec multica daemon start --foreground"
```

### Emulator support

Android and Wear OS emulators require KVM (hardware virtualisation). Uncomment
the `devices` block in `docker-compose.yml` (or pass `--device /dev/kvm`), then
install system images and create an AVD:

```bash
# Inside the container or via SETUP_CMD:
sdkmanager "system-images;android-34;google_apis;x86_64"                    # Android
sdkmanager "system-images;android-30;google_apis_wear_os;x86_64"            # Wear OS
avdmanager create avd -n android34 -k "system-images;android-34;google_apis;x86_64"
```

### Build args

| Arg | Default | Purpose |
|-----|---------|---------|
| `CMDLINE_TOOLS_BUILD` | `11076708` | Android command-line tools build number |
| `ANDROID_PLATFORM_VERSION` | `35` | Primary SDK platform to install |
| `ANDROID_BUILD_TOOLS_VERSION` | `35.0.0` | Primary build-tools version |

Override at build time with `--build-arg`, e.g.:
```bash
docker build -f Dockerfile.android --build-arg ANDROID_PLATFORM_VERSION=34 .
```

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
