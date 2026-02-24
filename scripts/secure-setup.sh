#!/usr/bin/env bash
set -euo pipefail

# Colors (matches scripts/shell-helpers/clawdock-helpers.sh)
_CLR_RESET='\033[0m'
_CLR_BOLD='\033[1m'
_CLR_DIM='\033[2m'
_CLR_GREEN='\033[0;32m'
_CLR_YELLOW='\033[1;33m'
_CLR_BLUE='\033[0;34m'
_CLR_MAGENTA='\033[0;35m'
_CLR_CYAN='\033[0;36m'
_CLR_RED='\033[0;31m'

info() { echo -e "${_CLR_CYAN}${_CLR_BOLD}[INFO]${_CLR_RESET} $*"; }
ok() { echo -e "${_CLR_GREEN}${_CLR_BOLD}[OK]${_CLR_RESET} $*"; }
warn() { echo -e "${_CLR_YELLOW}${_CLR_BOLD}[WARN]${_CLR_RESET} $*"; }
fail() { echo -e "${_CLR_RED}${_CLR_BOLD}[FAIL]${_CLR_RESET} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="$HOME/.openclaw"
CREDS_DIR="$STATE_DIR/credentials"
WORKSPACE_DIR="$STATE_DIR/workspace"
CONFIG_PATH="$STATE_DIR/openclaw.json"
COMPOSE_BASE="$ROOT_DIR/docker-compose.yml"
COMPOSE_SECURE="$ROOT_DIR/docker-compose.secure.yml"
ENV_FILE="$ROOT_DIR/.env"

USE_SANDBOX=0
for arg in "$@"; do
  case "$arg" in
    --use-sandbox) USE_SANDBOX=1 ;;
    *) ;;
  esac
done

run_compose() {
  if [[ "$USE_SANDBOX" -eq 1 ]]; then
    local cmd="docker compose"
    for arg in "$@"; do
      cmd+=" $(printf '%q' "$arg")"
    done
    docker sandbox run shell "$ROOT_DIR" -- -lc "$cmd"
  else
    docker compose "$@"
  fi
}

suggest_sandbox() {
  if docker sandbox --help >/dev/null 2>&1; then
    warn "Tip: run in Docker sandbox with:"
    echo "  docker sandbox run shell $ROOT_DIR -- -lc 'bash scripts/secure-setup.sh --use-sandbox'"
  fi
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Missing required command: $1"
    exit 1
  fi
}

echo -e "${_CLR_BOLD}${_CLR_CYAN}OpenClaw secure setup${_CLR_RESET}"

require_cmd docker
require_cmd openssl
if [[ "$USE_SANDBOX" -eq 0 ]] && ! docker compose version >/dev/null 2>&1; then
  fail "Docker Compose v2 plugin is required (or rerun with --use-sandbox)."
  suggest_sandbox
  exit 1
fi
if [[ "$USE_SANDBOX" -eq 1 ]] && ! docker sandbox --help >/dev/null 2>&1; then
  fail "--use-sandbox requested but docker sandbox is unavailable."
  exit 1
fi
if [[ ! -f "$COMPOSE_BASE" ]]; then
  fail "Missing $COMPOSE_BASE"
  exit 1
fi

if [[ -d "$STATE_DIR" ]]; then
  warn "$STATE_DIR already exists"
  read -r -p "Back up existing ~/.openclaw first? [Y/n] " backup_choice
  if [[ ! "$backup_choice" =~ ^[Nn]$ ]]; then
    backup_path="${STATE_DIR}.backup.$(date +%Y%m%d-%H%M%S)"
    cp -a "$STATE_DIR" "$backup_path"
    ok "Backed up to $backup_path"
  fi
fi

read -r -p "Telegram bot token (must contain ':'): " TELEGRAM_BOT_TOKEN
while [[ "$TELEGRAM_BOT_TOKEN" != *:* ]]; do
  warn "Token must contain ':'"
  read -r -p "Telegram bot token: " TELEGRAM_BOT_TOKEN
done

read -r -p "Telegram user ID (numeric): " TELEGRAM_USER_ID
while [[ ! "$TELEGRAM_USER_ID" =~ ^[0-9]+$ ]]; do
  warn "User ID must be numeric"
  read -r -p "Telegram user ID (numeric): " TELEGRAM_USER_ID
done

echo "Ollama mode:"
echo "  1) docker"
echo "  2) host"
read -r -p "Choose [1/2] (default 1): " ollama_choice
case "${ollama_choice:-1}" in
  1) OLLAMA_MODE="docker" ;;
  2) OLLAMA_MODE="host" ;;
  *)
    warn "Unknown choice, using docker"
    OLLAMA_MODE="docker"
    ;;
esac

read -r -p "Model to pull (default: llama3.2): " OLLAMA_MODEL
OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.2}"

GATEWAY_TOKEN="$(openssl rand -hex 32)"
ok "Generated gateway token (${#GATEWAY_TOKEN} chars)"

mkdir -p "$CREDS_DIR" "$WORKSPACE_DIR"
chmod 700 "$STATE_DIR" "$CREDS_DIR"
printf '%s' "$TELEGRAM_BOT_TOKEN" >"$CREDS_DIR/telegram-token"
chmod 600 "$CREDS_DIR/telegram-token"

if [[ "$OLLAMA_MODE" == "docker" ]]; then
  OLLAMA_BASE_URL="http://ollama:11434"
else
  OLLAMA_BASE_URL="http://host.docker.internal:11434"
fi

cat >"$CONFIG_PATH" <<EOF_CFG
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "auth": {
      "mode": "token",
      "token": "$GATEWAY_TOKEN"
    }
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "tokenFile": "~/.openclaw/credentials/telegram-token",
      "dmPolicy": "allowlist",
      "allowFrom": ["$TELEGRAM_USER_ID"],
      "groupPolicy": "disabled"
    }
  },
  "models": {
    "providers": {
      "ollama": {
        "baseUrl": "$OLLAMA_BASE_URL",
        "api": "ollama",
        "models": []
      }
    }
  },
  "tools": {
    "exec": {
      "applyPatch": {
        "workspaceOnly": true
      }
    },
    "fs": {
      "workspaceOnly": true
    }
  },
  "logging": {
    "redactSensitive": "tools"
  }
}
EOF_CFG
chmod 600 "$CONFIG_PATH"
ok "Wrote $CONFIG_PATH"

if [[ "$OLLAMA_MODE" == "docker" ]]; then
  cat >"$COMPOSE_SECURE" <<'EOF_COMPOSE'
services:
  openclaw-gateway:
    networks: [openclaw-internal]
    ports: ["127.0.0.1:${OPENCLAW_GATEWAY_PORT:-18789}:18789"]
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    read_only: true
    tmpfs:
      - /tmp:size=256m
      - /home/node/.cache:size=512m
    restart: unless-stopped
    depends_on: [ollama]

  ollama:
    image: ollama/ollama:latest
    networks: [openclaw-internal]
    volumes: [ollama-data:/root/.ollama]

networks:
  openclaw-internal:
    internal: true

volumes:
  ollama-data:
EOF_COMPOSE
else
  cat >"$COMPOSE_SECURE" <<'EOF_COMPOSE'
services:
  openclaw-gateway:
    networks: [openclaw-internal]
    ports: ["127.0.0.1:${OPENCLAW_GATEWAY_PORT:-18789}:18789"]
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    read_only: true
    tmpfs:
      - /tmp:size=256m
      - /home/node/.cache:size=512m
    restart: unless-stopped

networks:
  openclaw-internal:
    internal: true
EOF_COMPOSE
fi
ok "Wrote $COMPOSE_SECURE"

cat >"$ENV_FILE" <<EOF_ENV
OPENCLAW_IMAGE=openclaw:local
OPENCLAW_GATEWAY_TOKEN=$GATEWAY_TOKEN
OPENCLAW_CONFIG_DIR=$STATE_DIR
OPENCLAW_WORKSPACE_DIR=$WORKSPACE_DIR
EOF_ENV
ok "Wrote $ENV_FILE"

info "Building stack"
run_compose -f "$COMPOSE_BASE" -f "$COMPOSE_SECURE" build

info "Starting stack"
run_compose -f "$COMPOSE_BASE" -f "$COMPOSE_SECURE" up -d

if [[ "$OLLAMA_MODE" == "docker" ]]; then
  info "Pulling Ollama model: $OLLAMA_MODEL"
  run_compose -f "$COMPOSE_BASE" -f "$COMPOSE_SECURE" exec -T ollama ollama pull "$OLLAMA_MODEL"
fi

echo
echo -e "${_CLR_BOLD}${_CLR_GREEN}Setup complete${_CLR_RESET}"
echo "Gateway URL: http://127.0.0.1:${OPENCLAW_GATEWAY_PORT:-18789}"
echo "Gateway token: ${GATEWAY_TOKEN:0:8}..."
if [[ "$USE_SANDBOX" -eq 1 ]]; then
  echo "Verify: bash scripts/verify-secure-setup.sh (or run inside sandbox with --use-sandbox)"
else
  echo "Verify: bash scripts/verify-secure-setup.sh"
fi
echo "Logs: docker compose -f docker-compose.yml -f docker-compose.secure.yml logs -f"
