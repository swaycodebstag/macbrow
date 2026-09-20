#!/bin/zsh
# macbrow console: start / stop / status / log
# Usage: ./console.sh start|stop|status|log
cd "$(dirname "$0")"
LOG="${MACBROW_LOG:-/tmp/macbrow-console.log}"
case "${1:-start}" in
  start)
    if pgrep -f "agent.py console" >/dev/null; then echo "already running (pid $(pgrep -f 'agent.py console' | head -1))"; exit 0; fi
    set -a; [ -f .env.local ] && source .env.local; set +a
    # Local addition: master.env is the single home for every key on this machine, so it is
    # sourced last and wins. Without this, an unfilled placeholder left in .env.local silently
    # overwrites the real key and the first TTS call dies with a header-validation error.
    set -a; [ -f "$HOME/.config/blackstag/master.env" ] && source "$HOME/.config/blackstag/master.env"; set +a
    # Keys exported only in the interactive shell profile (e.g. ~/.zshrc) aren't visible to a
    # detached start; pull them in when missing.
    for v in TYPESAFE_API_KEY GRADIUM_API_KEY; do
      if [ -z "${(P)v}" ]; then
        val=$(zsh -ic "print -r -- \${$v}" 2>/dev/null); [ -n "$val" ] && export "$v=$val"
      fi
    done
    missing=(); for v in TYPESAFE_API_KEY GRADIUM_API_KEY; do [ -z "${(P)v}" ] && missing+=("$v"); done
    if [ ${#missing[@]} -gt 0 ]; then echo "missing: ${missing[*]} (set in .env.local or your shell profile)"; exit 1; fi
    nohup uv run python agent.py console > "$LOG" 2>&1 &
    sleep 3; echo "started (pid $!), log: $LOG" ;;
  stop)
    pkill -INT -f "agent.py console" 2>/dev/null && sleep 2; pkill -9 -f "agent.py console" 2>/dev/null; echo "stopped" ;;
  status)
    pgrep -fl "agent.py console" || echo "not running" ;;
  log)
    sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOG" | grep -E "user_transcript|macbrow\.router +route|\"role\": \"assistant\"" | sed -E 's/^ *[0-9:.]* *(DEBUG|INFO) *//' ;;
  hud)
    # The desktop pill. Compiled on first use and whenever the source is newer.
    BIN=build/macbrow-hud
    if [ ! -x "$BIN" ] || [ hud/main.swift -nt "$BIN" ]; then
      mkdir -p build
      echo "building the HUD..."
      swiftc -O -o "$BIN" hud/main.swift || { echo "build failed"; exit 1; }
    fi
    pkill -f "$PWD/$BIN" 2>/dev/null
    nohup "$PWD/$BIN" >/dev/null 2>&1 &
    echo "HUD up; click it to mute, drag to move, right-click to quit" ;;
  hud-stop)
    pkill -f "macbrow-hud" 2>/dev/null; echo "HUD closed" ;;
  mute|unmute|toggle)
    MUTE="${MACBROW_MUTE_FILE:-/tmp/macbrow-muted}"
    case "$1" in
      mute)   : > "$MUTE"; echo "muted" ;;
      unmute) rm -f "$MUTE"; echo "live" ;;
      toggle) if [ -f "$MUTE" ]; then rm -f "$MUTE"; echo "live"; else : > "$MUTE"; echo "muted"; fi ;;
    esac ;;
  panel)
    # Live status banner. agent.py rewrites MACBROW_STATE_FILE on every state change;
    # this redraws only when the line changes, so it is cheap to leave open all day.
    STATE="${MACBROW_STATE_FILE:-/tmp/macbrow-state}"
    printf '\033]0;macbrow\007\033[?25l'
    trap 'printf "\033[0m\033[?25h\n"; exit 0' INT TERM
    last=""
    while true; do
      if pgrep -f "agent.py console" >/dev/null 2>&1; then
        s=$(cat "$STATE" 2>/dev/null); [ -z "$s" ] && s="starting"
      else
        s="not running"
      fi
      if [ "$s" != "$last" ]; then
        case "$s" in
          "HEARING YOU") c=$'\033[1;30;42m' ;;   # green: your voice is coming in
          SPEAKING)      c=$'\033[1;30;45m' ;;   # magenta: it is talking
          THINKING)      c=$'\033[1;30;46m' ;;   # cyan: routing or generating
          listening)     c=$'\033[1;37;44m' ;;   # blue: idle, mic open
          MUTED)         c=$'\033[1;37;100m' ;;  # grey: mic cut, nothing reaches it
          *)             c=$'\033[1;37;41m' ;;   # red: stopped or unknown
        esac
        printf '\033[2J\033[H\n   %s  %-13s  \033[0m\n\n   %s\n' "$c" "$s" "ctrl-c to close this panel"
        last="$s"
      fi
      sleep 0.2
    done ;;
  *) echo "usage: $0 start|stop|status|log|hud|hud-stop|panel|mute|unmute|toggle"; exit 1 ;;
esac
