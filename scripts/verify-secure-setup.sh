#!/usr/bin/env bash
set -euo pipefail

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="$HOME/.openclaw"
CONFIG_PATH="$STATE_DIR/openclaw.json"
CREDS_DIR="$STATE_DIR/credentials"
COMPOSE_BASE="$ROOT_DIR/docker-compose.yml"
COMPOSE_SECURE="$ROOT_DIR/docker-compose.secure.yml"

pass() { echo "[PASS] $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "[FAIL] $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
warn() { echo "[WARN] $*"; WARN_COUNT=$((WARN_COUNT + 1)); }

perm_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || echo ""
}

check_perm() {
  local path="$1"
  local want="$2"
  local label="$3"
  if [[ ! -e "$path" ]]; then
    fail "$label missing: $path"
    return
  fi
  local got
  got="$(perm_of "$path")"
  if [[ "$got" == "$want" ]]; then
    pass "$label permissions are $want"
  else
    fail "$label permissions are $got (expected $want)"
  fi
}

if ! command -v jq >/dev/null 2>&1; then
  fail "jq is required for config checks"
fi

DOCKER_OK=1
if ! command -v docker >/dev/null 2>&1; then
  warn "docker not found; docker/network/audit checks will fail"
  DOCKER_OK=0
elif ! docker compose version >/dev/null 2>&1; then
  warn "docker compose v2 not available; docker/network/audit checks will fail"
  DOCKER_OK=0
fi

check_perm "$STATE_DIR" "700" "~/.openclaw"
check_perm "$CONFIG_PATH" "600" "openclaw.json"
check_perm "$CREDS_DIR" "700" "credentials directory"
check_perm "$CREDS_DIR/telegram-token" "600" "telegram-token"

json_get() {
  jq -r "$1 // empty" "$CONFIG_PATH" 2>/dev/null || true
}

if [[ -f "$CONFIG_PATH" ]]; then
  [[ "$(json_get '.gateway.auth.mode')" == "token" ]] && pass "gateway.auth.mode is token" || fail "gateway.auth.mode is not token"

  token_len="$(jq -r '.gateway.auth.token | length' "$CONFIG_PATH" 2>/dev/null || echo 0)"
  [[ "$token_len" =~ ^[0-9]+$ ]] && [[ "$token_len" -ge 24 ]] && pass "gateway token length >= 24" || fail "gateway token length < 24"

  [[ "$(json_get '.channels.telegram.dmPolicy')" == "allowlist" ]] && pass "telegram dmPolicy is allowlist" || fail "telegram dmPolicy is not allowlist"

  allow_count="$(jq -r '.channels.telegram.allowFrom | length' "$CONFIG_PATH" 2>/dev/null || echo 0)"
  has_wildcard="$(jq -r '.channels.telegram.allowFrom // [] | any(. == "*" or . == "\*")' "$CONFIG_PATH" 2>/dev/null || echo true)"
  if [[ "$allow_count" -gt 0 && "$has_wildcard" == "false" ]]; then
    pass "telegram allowFrom is non-empty and has no wildcard"
  else
    fail "telegram allowFrom invalid"
  fi

  gp="$(json_get '.channels.telegram.groupPolicy')"
  [[ "$gp" != "open" ]] && pass "telegram groupPolicy is not open" || fail "telegram groupPolicy is open"

  [[ "$(json_get '.tools.fs.workspaceOnly')" == "true" ]] && pass "tools.fs.workspaceOnly is true" || fail "tools.fs.workspaceOnly is not true"
  [[ "$(json_get '.tools.exec.applyPatch.workspaceOnly')" == "true" ]] && pass "tools.exec.applyPatch.workspaceOnly is true" || fail "tools.exec.applyPatch.workspaceOnly is not true"

  redact="$(json_get '.logging.redactSensitive')"
  [[ -n "$redact" && "$redact" != "off" ]] && pass "logging.redactSensitive is not off" || fail "logging.redactSensitive is off or unset"
else
  fail "Config file not found: $CONFIG_PATH"
fi

if [[ "$DOCKER_OK" -eq 1 ]]; then
  if docker compose -f "$COMPOSE_BASE" -f "$COMPOSE_SECURE" ps --status running openclaw-gateway >/dev/null 2>&1; then
    pass "openclaw-gateway container is running"
  else
    fail "openclaw-gateway container is not running"
  fi

  gateway_cid="$(docker compose -f "$COMPOSE_BASE" -f "$COMPOSE_SECURE" ps -q openclaw-gateway 2>/dev/null || true)"

  uid="$(docker compose -f "$COMPOSE_BASE" -f "$COMPOSE_SECURE" exec -T openclaw-gateway id -u 2>/dev/null || echo "")"
  [[ "$uid" == "1000" ]] && pass "gateway runs as uid 1000" || fail "gateway uid is '$uid' (expected 1000)"

  cap_drop="$(docker inspect --format '{{json .HostConfig.CapDrop}}' "$gateway_cid" 2>/dev/null || true)"
  [[ "$cap_drop" == *"ALL"* ]] && pass "gateway drops all capabilities" || fail "gateway does not drop all capabilities"

  mounts="$(docker inspect --format '{{json .Mounts}}' "$gateway_cid" 2>/dev/null || true)"
  [[ "$mounts" == *"docker.sock"* ]] && fail "docker.sock is mounted" || pass "docker.sock is not mounted"

  ro="$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$gateway_cid" 2>/dev/null || true)"
  [[ "$ro" == "true" ]] && pass "gateway root filesystem is read-only" || fail "gateway root filesystem is not read-only"

  port_line="$(docker compose -f "$COMPOSE_BASE" -f "$COMPOSE_SECURE" port openclaw-gateway 18789 2>/dev/null || true)"
  if [[ "$port_line" == 127.0.0.1:* ]]; then
    pass "gateway port is bound to 127.0.0.1"
  else
    fail "gateway port is not loopback-only: ${port_line:-missing}"
  fi

  ollama_cid="$(docker compose -f "$COMPOSE_BASE" -f "$COMPOSE_SECURE" ps -q ollama 2>/dev/null || true)"
  if [[ -n "$ollama_cid" ]]; then
    if docker compose -f "$COMPOSE_BASE" -f "$COMPOSE_SECURE" port ollama 11434 >/dev/null 2>&1; then
      fail "ollama has host-exposed port"
    else
      pass "ollama is not exposed to host"
    fi

    if docker compose -f "$COMPOSE_BASE" -f "$COMPOSE_SECURE" exec -T openclaw-gateway curl -fsS http://ollama:11434/api/tags >/dev/null 2>&1; then
      pass "ollama is reachable from gateway container"
    else
      fail "ollama is not reachable from gateway container"
    fi
  else
    warn "ollama container not present (host mode likely); skipping ollama network checks"
  fi

  audit_json="$(docker compose -f "$COMPOSE_BASE" -f "$COMPOSE_SECURE" exec -T openclaw-gateway node dist/index.js security audit --deep --json 2>/dev/null || true)"
  if [[ -z "$audit_json" ]]; then
    fail "security audit command failed"
  else
    critical="$(printf '%s' "$audit_json" | jq -r '.summary.critical // empty' 2>/dev/null || true)"
    if [[ "$critical" == "0" ]]; then
      pass "security audit critical count is 0"
    else
      fail "security audit critical count is ${critical:-unknown}"
    fi
  fi
else
  fail "docker checks unavailable"
  fail "docker uid check unavailable"
  fail "docker capabilities check unavailable"
  fail "docker.sock mount check unavailable"
  fail "docker read-only rootfs check unavailable"
  fail "gateway port binding check unavailable"
  fail "ollama host exposure check unavailable"
  fail "ollama reachability check unavailable"
  fail "security audit check unavailable"
fi

echo
echo "Summary: PASS=$PASS_COUNT FAIL=$FAIL_COUNT WARN=$WARN_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
