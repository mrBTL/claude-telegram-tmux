#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"

LOG="${SCRIPT_DIR}/bot-tmux.log"
OFFSET_FILE="${SCRIPT_DIR}/.offset-tmux"
BUSY_FILE="${SCRIPT_DIR}/.busy-tmux"
TMUX_SESSION="claude-bot-b"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

tg_send() {
    local text="$1"
    local len=${#text}
    local chunk_size=4000
    local offset=0
    while [ $offset -lt $len ]; do
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
            -H "Content-Type: application/json" \
            --data-raw "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":$(printf '%s' "${text:$offset:$chunk_size}" | jq -Rs .)}" \
            > /dev/null
        offset=$((offset + chunk_size))
    done
}

is_prompt_visible() {
    tmux capture-pane -t "$TMUX_SESSION" -S -200 -p 2>/dev/null | \
        sed 's/\xc2\xa0/ /g' | \
        grep -E '^\s*[>❯]' | tail -1 | grep -qE '^\s*[>❯]\s*$'
}

start_session() {
    tmux has-session -t "$TMUX_SESSION" 2>/dev/null && return 0

    log "Starting Claude session"
    tmux new-session -d -s "$TMUX_SESSION" -x 220 -y 500
    tmux set-option -t "$TMUX_SESSION" history-limit 50000
    tmux send-keys -t "$TMUX_SESSION" "cd '$WORK_DIR' && claude --dangerously-skip-permissions 2>/dev/null" Enter

    for i in $(seq 1 30); do
        sleep 1
        is_prompt_visible && { log "Claude ready (${i}s)"; return 0; }
    done
    log "WARNING: Claude may not be ready after 30s"
}

kill_session() {
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    log "Session killed"
}

send_to_claude() {
    local msg="$1"

    tmux send-keys -t "$TMUX_SESSION" "$msg"
    sleep 1
    tmux send-keys -t "$TMUX_SESSION" "" Enter
    sleep 2

    local hash_last=$(tmux capture-pane -t "$TMUX_SESSION" -p 2>/dev/null | md5sum)
    local stable=0
    local elapsed=0

    while [ $elapsed -lt 300 ]; do
        sleep 1
        elapsed=$((elapsed + 1))
        local hash_cur=$(tmux capture-pane -t "$TMUX_SESSION" -p 2>/dev/null | md5sum)

        if [ "$hash_cur" = "$hash_last" ]; then
            stable=$((stable + 1))
            if [ $stable -ge 2 ] && is_prompt_visible; then
                break
            fi
        else
            stable=0
            hash_last="$hash_cur"
        fi
    done

    local capture
    capture=$(tmux capture-pane -t "$TMUX_SESSION" -S -500 -p 2>/dev/null)
    local msg_prefix="${msg:0:30}"
    local msg_line
    msg_line=$(echo "$capture" | grep -nF "❯ ${msg_prefix}" | tail -1 | cut -d: -f1)

    if [ -z "$msg_line" ]; then
        return
    fi

    local after_msg
    after_msg=$(echo "$capture" | tail -n +$((msg_line + 1)))

    # Znajdź ostatni blok tekstowy ● (nie wywołanie narzędzia)
    local response_offset
    response_offset=$(echo "$after_msg" | grep -n "^●" | \
        grep -vE "^[0-9]+:●[[:space:]]*(Bash|Read|Write|Edit|Glob|Grep|TodoWrite|WebFetch|WebSearch|Agent|mcp)\(" | \
        tail -1 | cut -d: -f1)

    if [ -z "$response_offset" ]; then
        return
    fi

    echo "$after_msg" \
        | tail -n +$((response_offset)) \
        | awk '/^[[:space:]]*[>❯]/{exit} {print}' \
        | sed 's/^● //' \
        | sed 's/^[[:space:]]*\xc2\xa0*//' \
        | grep -vE '^[-─]+$' \
        | grep -v '⏵⏵' \
        | grep -v '<°~°>' \
        | grep -v 'ctrl+o' \
        | sed '/^[[:space:]]*$/d' \
        | head -c 8000
}

handle_message() {
    local text="$1"

    if [ -f "$BUSY_FILE" ]; then
        tg_send "⏳ Jeszcze pracuję nad poprzednią wiadomością..."
        return
    fi

    touch "$BUSY_FILE"
    log "MSG: $text"

    start_session

    local response
    response=$(send_to_claude "$text")

    rm -f "$BUSY_FILE"

    if [ -z "$response" ]; then
        tg_send "❌ Brak odpowiedzi od Claude."
        log "EMPTY response"
        return
    fi

    log "RESPONSE: ${response:0:200}"
    tg_send "$response"
}

get_offset() { cat "$OFFSET_FILE" 2>/dev/null || echo "0"; }
save_offset() { echo "$1" > "$OFFSET_FILE"; }

rm -f "$BUSY_FILE"
log "Bot B (tmux) started (PID $$)"
tg_send "🟢 Bot B (tmux) gotowy!"

while true; do
    offset=$(get_offset)

    updates=$(curl -s --max-time 35 \
        "https://api.telegram.org/bot${TELEGRAM_TOKEN}/getUpdates?offset=${offset}&timeout=30&allowed_updates=%5B%22message%22%5D" \
        2>/dev/null) || { sleep 5; continue; }

    [ -z "$updates" ] && { sleep 2; continue; }

    ok=$(echo "$updates" | jq -r '.ok' 2>/dev/null) || { sleep 2; continue; }
    if [ "$ok" != "true" ]; then
        log "getUpdates error: $updates"
        sleep 5
        continue
    fi

    count=$(echo "$updates" | jq '.result | length' 2>/dev/null) || continue
    [ "$count" -eq 0 ] && continue

    for i in $(seq 0 $((count - 1))); do
        update=$(echo "$updates" | jq ".result[$i]" 2>/dev/null) || continue
        update_id=$(echo "$update" | jq -r '.update_id' 2>/dev/null) || continue
        chat_id=$(echo "$update" | jq -r '.message.chat.id // empty' 2>/dev/null) || continue
        text=$(echo "$update" | jq -r '.message.text // .message.caption // empty' 2>/dev/null) || continue

        save_offset $((update_id + 1))

        [ "$chat_id" != "$TELEGRAM_CHAT_ID" ] && { log "IGNORED msg from $chat_id"; continue; }
        [ -z "$text" ] && { log "IGNORED empty message"; continue; }

        if [ "$text" = "/new" ]; then
            kill_session
            rm -f "$BUSY_FILE"
            tg_send "🔄 Sesja zresetowana."
            continue
        fi

        if [ "$text" = "/start" ]; then
            tg_send "👋 Bot B (tmux). Pisz — Claude działa w persistentnej sesji.\n\n/new — reset sesji"
            continue
        fi

        handle_message "$text"
    done
done
