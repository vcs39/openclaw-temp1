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

report() {
  local kind="$1"
  local label="$2"
  case "$kind" in
    PASS)
      echo "[PASS] $label"
      PASS_COUNT=$((PASS_COUNT + 1))
      ;;
    FAIL)
      echo "[FAIL] $label"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      ;;
    WARN)
      echo "[WARN] $label"
      WARN_COUNT=$((WARN_COUNT + 1))
      ;;
  esac
}

perm_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || echo ""
}

check_perm() {
  local path="$1"
  local want="$2"
  local label="$3"
  if [[ ! -e "$path" ]]; then
    report FAIL "$label missing: $path"
    return
  fi
  local got
  got="$(perm_of "$path")"
  if [[ "$got" == "$want" ]]; then
    report PASS "$label = $want"
  else
    report FAIL "$label = $got (expected $want)"
  fi
}

jq_get() {
  jq -r "$1 // empty" "$CONFIG_PATH" 2>/dev/null || true
}

if ! command -v jq >/dev/null 2>&1; then
  report FAIL "jq is required"
fi
if [[ ! -f "$CONFIG_PATH" ]]; then
  report FAIL "Config file missing: $CONFIG_PATH"
fi

# 1-4 Filesystem checks
check_perm "$STATE_DIR" "700" "1) ~/.openclaw permissions"
check_perm "$CONFIG_PATH" "600" "2) openclaw.json permissions"
check_perm "$CREDS_DIR" "700" "3) credentials permissions"
check_perm "$CREDS_DIR/telegram-token" "600" "4) telegram-token permissions"

# 5-12 Config checks
if [[ -f "$CONFIG_PATH" ]]; then
  [[ "$(jq_get '.gateway.auth.mode')" == "token" ]] && report PASS "5) gateway.auth.mode = token" || report FAIL "5) gateway.auth.mode is not token"

  token_len="$(jq -r '.gateway.auth.token | length' "$CONFIG_PATH" 2>/dev/null || echo 0)"
  [[ "$token_len" =~ ^[0-9]+$ ]] && [[ "$token_len" -ge 24 ]] && report PASS "6) gateway token length >= 24" || report FAIL "6) gateway token length < 24"

  [[ "$(jq_get '.channels.telegram.dmPolicy')" == "allowlist" ]] && report PASS "7) telegram dmPolicy = allowlist" || report FAIL "7) telegram dmPolicy is not allowlist"

  allow_count="$(jq -r '.channels.telegram.allowFrom | length' "$CONFIG_PATH" 2>/dev/null || echo 0)"
  wildcard="$(jq -r '.channels.telegram.allowFrom // [] | any(. == "*")' "$CONFIG_PATH" 2>/dev/null || echo true)"
  if [[ "$allow_count" =~ ^[0-9]+$ ]] && [[ "$allow_count" -gt 0 ]] && [[ "$wildcard" == "false" ]]; then
    report PASS "8) telegram allowFrom is non-empty and has no wildcard"
  else
    report FAIL "8) telegram allowFrom invalid"
  fi

  [[ "$(jq_get '.channels.telegram.groupPolicy')" != "open" ]] && report PASS "9) telegram groupPolicy is not open" || report FAIL "9) telegram groupPolicy is open"

  [[ "$(jq_get '.tools.fs.workspaceOnly')" == "true" ]] && report PASS "10) tools.fs.workspaceOnly = true" || report FAIL "10) tools.fs.workspaceOnly is not true"

  [[ "$(jq_get '.tools.exec.applyPatch.workspaceOnly')" == "true" ]] && report PASS "11) tools.exec.applyPatch.workspaceOnly = true" || report FAIL "11) tools.exec.applyPatch.workspaceOnly is not true"

  redact="$(jq_get '.logging.redactSensitive')"
  [[ -n "$redact" && "$redact" != "off" ]] && report PASS "12) logging.redactSensitive is not off" || report FAIL "12) logging.redactSensitive is off/unset"
else
  report FAIL "5-12) config checks skipped (missing config)"
fi

DOCKER_OK=1
if ! command -v docker >/dev/null 2>&1; then
  DOCKER_OK=0
elif ! docker compose version >/dev/null 2>&1; then
  DOCKER_OK=0
fi

if [[ "$DOCKER_OK" -eq 0 ]]; then
  report FAIL "13) docker compose unavailable"
  report FAIL "14) uid check unavailable"
  report FAIL "15) cap_drop check unavailable"
  report FAIL "16) docker.sock check unavailable"
  report FAIL "17) read-only rootfs check unavailable"
  report FAIL "18) gateway port binding check unavailable"
  report WARN "19) ollama host exposure check skipped"
  report WARN "20) ollama reachability check skipped"
  report FAIL "21) security audit check unavailable"
else
  if docker compose -f "$COMPOSE_BASE" -f "$COMPOSE_SECURE" ps --status running openclaw-gateway >/dev/null 2>&1; then
    report PASS "13) gateway container is running"
  else
    report FAIL "13) gateway container is not running"
  fi

  gateway_cid="$(docker compose -f "$COMPOSE_BASE" -f "$COMPOSE_SECURE" ps -q openclaw-gateway 2>/dev/null || true)"

  uid="$(docker compose -f "$COMPOSE_BASE" -f "$COMPOSE_SECURE" exec -T openclaw-gateway id -u 2>/dev/null || true)"
  [[ "$uid" == "1000" ]] && report PASS "14) gateway uid is 1000" || report FAIL "14) gateway uid is '${uid:-unknown}'"

  cap_drop="$(docker inspect --format '{{json .HostConfig.CapDrop}}' "$gateway_cid" 2>/dev/null || true)"
  [[ "$cap_drop" == *"ALL"* ]] && report PASS "15) gateway drops all capabilities" || report FAIL "15) cap_drop does not include ALL"

  mounts="$(docker inspect --format '{{json .Mounts}}' "$gateway_cid" 2>/dev/null || true)"
  [[ "$mounts" == *"docker.sock"* ]] && report FAIL "16) docker.sock is mounted" || report PASS "16) docker.sock is not mounted"

  ro="$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$gateway_cid" 2>/dev/null || true)"
  [[ "$ro" == "true" ]] && report PASS "17) root filesystem is read-only" || report FAIL "17) root filesystem is not read-only"

  port_line="$(docker compose -f "$COMPOSE_BASE" -f "$COMPOSE_SECURE" port openclaw-gateway 18789 2>/dev/null || true)"
  [[ "$port_line" == 127.0.0.1:* ]] && report PASS "18) gateway port bound to 127.0.0.1" || report FAIL "18) gateway port is '${port_line:-missing}'"

  ollama_cid="$(docker compose -f "$COMPOSE_BASE" -f "$COMPOSE_SECURE" ps -q ollama 2>/dev/null || true)"
  if [[ -n "$ollama_cid" ]]; then
    if docker compose -f "$COMPOSE_BASE" -f "$COMPOSE_SECURE" port ollama 11434 >/dev/null 2>&1; then
      report FAIL "19) ollama port 11434 exposed to host"
    else
      report PASS "19) ollama is not exposed to host"
    fi

    if docker compose -f "$COMPOSE_BASE" -f "$COMPOSE_SECURE" exec -T openclaw-gateway curl -fsS http://ollama:11434/api/tags >/dev/null 2>&1; then
      report PASS "20) ollama reachable from gateway container"
    else
      report FAIL "20) ollama not reachable from gateway container"
    fi
  else
    report WARN "19) ollama container absent (host mode likely)"
    report WARN "20) ollama reachability skipped (no ollama container)"
  fi

  audit_json="$(docker compose -f "$COMPOSE_BASE" -f "$COMPOSE_SECURE" exec -T openclaw-gateway node dist/index.js security audit --deep --json 2>/dev/null || true)"
  critical="$(printf '%s' "$audit_json" | jq -r '.summary.critical // .report.summary.critical // empty' 2>/dev/null || true)"
  if [[ -n "$critical" && "$critical" == "0" ]]; then
    report PASS "21) security audit critical findings = 0"
  else
    report FAIL "21) security audit critical findings = ${critical:-unknown}"
  fi
fi

echo "Summary: PASS=$PASS_COUNT FAIL=$FAIL_COUNT WARN=$WARN_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
