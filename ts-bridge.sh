#!/bin/bash
# ts-bridge.sh - Service manager for TS3/Discord audio bridge
# Usage: ./ts-bridge.sh {start|stop|restart|status|logs} [service]
# Services: music, audio, mic, discord, all (default: all)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
PID_DIR="$SCRIPT_DIR/.pids"
LOG_DIR="$SCRIPT_DIR/.service-logs"

# Load config
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Defaults
TS3_ADDRESS="${TS3_ADDRESS:-147.15.101.89}"
TS3_PORT="${TS3_PORT:-9987}"
DISCORD_TOKEN_FILE="${DISCORD_TOKEN_FILE:-$SCRIPT_DIR/shared/discord-token.txt}"
DISCORD_STREAM_PORT="${DISCORD_STREAM_PORT:-8080}"
TS3_STREAM_PORT="${TS3_STREAM_PORT:-8081}"
DOTNET_SYSTEM_GLOBALIZATION_INVARIANT="${DOTNET_SYSTEM_GLOBALIZATION_INVARIANT:-1}"

export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT
export DISCORD_TOKEN_FILE
export DISCORD_STREAM_PORT
export TS3_STREAM_PORT
export TS3_ADDRESS

mkdir -p "$PID_DIR" "$LOG_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[ts-bridge]${NC} $1"; }
ok()  { echo -e "${GREEN}[ok]${NC} $1"; }
err() { echo -e "${RED}[err]${NC} $1"; }
warn(){ echo -e "${YELLOW}[!]${NC} $1"; }

is_running() {
    local pidfile="$PID_DIR/$1.pid"
    if [ -f "$pidfile" ]; then
        local pid=$(cat "$pidfile")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

get_pid() {
    local pidfile="$PID_DIR/$1.pid"
    if [ -f "$pidfile" ]; then
        cat "$pidfile"
    fi
}

# --- Start functions ---

start_music() {
    if is_running music; then
        warn "Musico-Acosta is already running (PID: $(get_pid music))"
        return
    fi
    log "Starting Musico-Acosta (music bot)..."
    cd "$SCRIPT_DIR/services/musico-acosta"
    ./TS3AudioBot > "$LOG_DIR/music.log" 2>&1 &
    echo $! > "$PID_DIR/music.pid"
    ok "Musico-Acosta started (PID: $!)"
}

start_audio() {
    if is_running audio; then
        warn "BotDiscordAudio is already running (PID: $(get_pid audio))"
        return
    fi
    log "Starting BotDiscordAudio (Discord audio relay)..."
    cd "$SCRIPT_DIR/services/bot-discord-audio"
    ./TS3AudioBot > "$LOG_DIR/audio.log" 2>&1 &
    echo $! > "$PID_DIR/audio.pid"
    ok "BotDiscordAudio started (PID: $!)"
}

start_mic() {
    if is_running mic; then
        warn "BotDiscordMic is already running (PID: $(get_pid mic))"
        return
    fi
    log "Starting BotDiscordMic (TS3 voice capture)..."
    cd "$SCRIPT_DIR/services/bot-discord-mic"
    TS3_NAME="BotDiscordMic" ./ts3-listener > "$LOG_DIR/mic.log" 2>&1 &
    echo $! > "$PID_DIR/mic.pid"
    ok "BotDiscordMic started (PID: $!)"
}

start_discord() {
    if is_running discord; then
        warn "Discord bridge is already running (PID: $(get_pid discord))"
        return
    fi
    log "Starting Discord bridge..."
    cd "$SCRIPT_DIR/services/discord-bridge"
    "$SCRIPT_DIR/bridge-env/bin/python3" discord_bridge.py > "$LOG_DIR/discord.log" 2>&1 &
    echo $! > "$PID_DIR/discord.pid"
    ok "Discord bridge started (PID: $!)"
}

# --- Stop functions ---

stop_service() {
    local name=$1
    local display=$2
    if is_running "$name"; then
        local pid=$(get_pid "$name")
        log "Stopping $display (PID: $pid)..."
        kill "$pid" 2>/dev/null
        for i in $(seq 1 50); do
            if ! kill -0 "$pid" 2>/dev/null; then
                break
            fi
            sleep 0.1
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null
        fi
        rm -f "$PID_DIR/$name.pid"
        ok "$display stopped"
    else
        warn "$display is not running"
    fi
}

stop_music()   { stop_service music "Musico-Acosta"; }
stop_audio()   { stop_service audio "BotDiscordAudio"; }
stop_mic()     { stop_service mic "BotDiscordMic"; }
stop_discord() { stop_service discord "Discord bridge"; }

# --- Status ---

show_status() {
    echo ""
    echo -e "${BLUE}=== TS3/Discord Audio Bridge Status ===${NC}"
    echo ""
    for svc in music audio mic discord; do
        case $svc in
            music)   display="Musico-Acosta    (music bot)" ;;
            audio)   display="BotDiscordAudio  (Discord->TS3)" ;;
            mic)     display="BotDiscordMic    (TS3->Discord)" ;;
            discord) display="Discord Bridge   (Discord bot)" ;;
        esac

        if is_running "$svc"; then
            echo -e "  ${GREEN}* ${display}${NC}  PID: $(get_pid $svc)"
        else
            echo -e "  ${RED}o ${display}${NC}  stopped"
        fi
    done
    echo ""
    echo -e "  Config: $CONFIG_FILE"
    echo -e "  TS3:    $TS3_ADDRESS:$TS3_PORT"
    echo -e "  Ports:  Discord stream :$DISCORD_STREAM_PORT | TS3 stream :$TS3_STREAM_PORT"
    echo ""
}

# --- Logs ---

show_logs() {
    local svc=$1
    local logfile="$LOG_DIR/$svc.log"
    if [ -f "$logfile" ]; then
        tail -f "$logfile"
    else
        err "No log file for '$svc'"
    fi
}

# --- Main ---

ACTION=${1:-help}
SERVICE=${2:-all}

case "$ACTION" in
    start)
        case "$SERVICE" in
            all)
                start_discord
                sleep 1
                start_mic
                sleep 1
                start_audio
                sleep 1
                start_music
                echo ""
                show_status
                ;;
            music)   start_music ;;
            audio)   start_audio ;;
            mic)     start_mic ;;
            discord) start_discord ;;
            *) err "Unknown service: $SERVICE" ;;
        esac
        ;;
    stop)
        case "$SERVICE" in
            all)
                stop_music
                stop_audio
                stop_mic
                stop_discord
                ;;
            music)   stop_music ;;
            audio)   stop_audio ;;
            mic)     stop_mic ;;
            discord) stop_discord ;;
            *) err "Unknown service: $SERVICE" ;;
        esac
        ;;
    restart)
        case "$SERVICE" in
            all)
                stop_music; stop_audio; stop_mic; stop_discord
                sleep 2
                start_discord; sleep 1; start_mic; sleep 1; start_audio; sleep 1; start_music
                echo ""
                show_status
                ;;
            music)   stop_music;   sleep 1; start_music ;;
            audio)   stop_audio;   sleep 1; start_audio ;;
            mic)     stop_mic;     sleep 1; start_mic ;;
            discord) stop_discord; sleep 1; start_discord ;;
            *) err "Unknown service: $SERVICE" ;;
        esac
        ;;
    status)
        show_status
        ;;
    logs)
        if [ "$SERVICE" = "all" ]; then
            err "Specify a service: music, audio, mic, discord"
        else
            show_logs "$SERVICE"
        fi
        ;;
    *)
        echo ""
        echo -e "${BLUE}TS3/Discord Audio Bridge Manager${NC}"
        echo ""
        echo "Usage: $0 {start|stop|restart|status|logs} [service]"
        echo ""
        echo "Services:"
        echo "  music    Musico-Acosta (YouTube/music bot)"
        echo "  audio    BotDiscordAudio (relays Discord audio to TS3)"
        echo "  mic      BotDiscordMic (captures TS3 voice for Discord)"
        echo "  discord  Discord bridge (Discord bot + HTTP stream)"
        echo "  all      All services (default)"
        echo ""
        echo "Examples:"
        echo "  $0 start           Start all services"
        echo "  $0 start music     Start only the music bot"
        echo "  $0 stop all        Stop everything"
        echo "  $0 restart audio   Restart BotDiscordAudio"
        echo "  $0 status          Show running status"
        echo "  $0 logs discord    Tail Discord bridge logs"
        echo ""
        ;;
esac
