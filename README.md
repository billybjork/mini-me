# MiniMe

A multi-tenant AI assistant platform using Elixir/Phoenix for orchestration and [Fly.io Sprites](https://sprites.dev) for sandboxed execution environments.

## Direct Sprite Access (Debugging)

Install the CLI:
```bash
curl https://sprites.dev/install.sh | bash
sprite login
```

Common commands:
```bash
# Interactive shell
sprite console -s <sprite-name>

# Run a command
sprite exec -s <sprite-name> ls -la /home/sprite

# Check running processes
sprite exec -s <sprite-name> ps aux
```

API access (used by `MiniMe.Sandbox.Client`):
```bash
# List sprites
curl -H "Authorization: Bearer $SPRITES_TOKEN" https://api.sprites.dev/v1/sprites

# Execute command
curl -X POST -H "Authorization: Bearer $SPRITES_TOKEN" \
  "https://api.sprites.dev/v1/sprites/<name>/exec?cmd=/bin/sh&cmd=-c&cmd=ls"
```

The app connects to sprites via WebSocket for streaming exec sessions. See `lib/mini_me/sandbox/client.ex` for the full API wrapper.

## Environment Variables

```bash
SPRITES_TOKEN=           # Required - from sprites.dev
GITHUB_TOKEN=            # Optional - for private repo access
CLAUDE_CODE_OAUTH_TOKEN= # Required - run `claude setup-token` to generate
MINI_ME_PASSWORD=        # Optional - auth password (default: "dev")
```

Create a `.env` file in the project root (loaded automatically in dev).

## Setup

```bash
mix setup
iex -S mix phx.server
```

Visit [`localhost:4000`](http://localhost:4000).

## Key Modules

| Module | Purpose |
|--------|---------|
| `MiniMe.Sessions.UserSession` | GenServer managing user↔sprite connection (outer loop) |
| `MiniMe.Sandbox.Client` | HTTP client for Sprites API |
| `MiniMe.Sandbox.Process` | WebSocket connection to sprite for Claude Code execution |
| `MiniMe.Workspaces` | Workspace CRUD and sprite lifecycle |
| `MiniMeWeb.Live.SessionLive` | LiveView for chat UI |

## Architecture

See [ai_assistant_platform_plan.md](ai_assistant_platform_plan.md) for full design docs.
