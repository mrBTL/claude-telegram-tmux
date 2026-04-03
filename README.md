# claude-telegram-tmux

Telegram bot providing a persistent Claude Code session via tmux. Unlike a standard approach where each message spawns a new `claude` process, this bot maintains a single long-running interactive session — `CLAUDE.md` and memory are loaded once at startup, reducing token usage on every subsequent message.

## How it works

1. On first message, the bot creates a tmux session (`claude-bot-b`) and starts `claude --dangerously-skip-permissions` interactively
2. Each incoming Telegram message is sent to that session via `tmux send-keys`
3. The bot polls the pane until Claude finishes responding (hash stability + prompt detection)
4. Only the final text response is extracted and forwarded — tool calls (`Bash`, `Read`, etc.) and their output are filtered out
5. The session persists between messages — context is preserved

## Comparison with Bot A (standard approach)

| | Bot A | Bot B (this) |
|---|---|---|
| Process per message | new `claude -c -p` | reuses running session |
| CLAUDE.md loaded | every message | once at startup |
| Memory loaded | every message | once at startup |
| Context between messages | via session file | in-memory |
| Tool output in response | yes | filtered out |

## Requirements

- Claude Code CLI (`claude`) installed and authenticated
- `tmux`
- `jq`
- `curl`
- A Telegram bot token ([@BotFather](https://t.me/BotFather))

## Setup

```bash
git clone https://github.com/mrBTL/claude-telegram-tmux
cd claude-telegram-tmux
cp config.env.example config.env
```

Edit `config.env`:

```bash
TELEGRAM_TOKEN="your-bot-token"
TELEGRAM_CHAT_ID="your-chat-id"   # your Telegram user ID
WORK_DIR="/home/youruser"          # working directory for Claude
```

### Run manually

```bash
bash bot.sh
```

### Run as systemd service

```bash
sudo cp claude-telegram-tmux.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable claude-telegram-tmux
sudo systemctl start claude-telegram-tmux
```

## Usage

Just write or dictate a message — Claude responds with context from the entire conversation.

**`/new`** — reset the session (start fresh conversation, reloads CLAUDE.md and memory)

**`/start`** — show welcome message

## Session lifecycle

- Session starts on first message after bot launch
- Session persists until `/new`, server reboot, or manual `tmux kill-session -t claude-bot-b`
- If the server sleeps and wakes, the bot service restarts automatically (systemd `Restart=always`), but the Claude session is recreated on the first message

## Notes

- First message after session start takes ~5s (Claude initialization)
- Subsequent messages are faster — no startup overhead
- The bot filters out tool call lines (`Bash(...)`, `Read(...)`, etc.) and only sends the final text response
- Long messages are sent as paste — the bot handles this with a delayed Enter
