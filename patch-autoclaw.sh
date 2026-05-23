#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${AUTOCLAW_APP_PATH:-/Applications/AutoClaw.app}"
RESOURCES_DIR="$APP_PATH/Contents/Resources"
ASAR_PATH="$RESOURCES_DIR/app.asar"
BACKUP_DIR="${AUTOCLAW_BACKUP_DIR:-$RESOURCES_DIR/autoclaw-patcher-backups}"
STAMP="$(date +%Y%m%d-%H%M%S)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/autoclaw-patch.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

log() {
  printf '[autoclaw-patcher] %s\n' "$*"
}

fail() {
  printf '[autoclaw-patcher] ERROR: %s\n' "$*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "File not found: $1"
}

require_file "$ASAR_PATH"
command -v node >/dev/null 2>&1 || fail "node is required"
command -v npx >/dev/null 2>&1 || fail "npx is required"

log "Using AutoClaw app: $APP_PATH"
log "Working directory: $TMP_DIR"

if [[ "${AUTOCLAW_SKIP_RUNNING_CHECK:-}" != "1" ]] && pgrep -x "AutoClaw" >/dev/null 2>&1; then
  log "AutoClaw appears to be running. Please quit it before patching."
  fail "AutoClaw is still running"
fi

mkdir -p "$BACKUP_DIR"
BACKUP_PATH="$BACKUP_DIR/app.asar.$STAMP.bak"
cp "$ASAR_PATH" "$BACKUP_PATH"
log "Backup created: $BACKUP_PATH"

log "Extracting app.asar"
npx --yes @electron/asar extract "$ASAR_PATH" "$TMP_DIR/app"

MAIN_FILE="$TMP_DIR/app/out/main/index.js"
require_file "$MAIN_FILE"

RENDERER_FILE="$(find "$TMP_DIR/app/out/renderer/assets" -maxdepth 1 -type f -name 'index-*.js' -print | head -n 1)"
[[ -n "${RENDERER_FILE:-}" ]] || fail "Renderer bundle not found"
require_file "$RENDERER_FILE"

log "Patching main process output checker"
node - "$MAIN_FILE" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
let text = fs.readFileSync(file, "utf8");

const marker = "async function agentOutputCheck({ output }) {";
const start = text.indexOf(marker);
if (start < 0) {
  console.error("agentOutputCheck function not found");
  process.exit(2);
}
const next = text.indexOf("\nasync function ", start + marker.length);
if (next < 0) {
  console.error("Could not find end of agentOutputCheck function");
  process.exit(2);
}

const replacement = `async function agentOutputCheck({ output }) {
  return {
    ok: true,
    code: 0,
    msg: "output check disabled by autoclaw-output-check-patcher",
    data: { sensitive: false, answer: "" },
    trace: void 0,
    stage: "local-patch"
  };
}
`;

text = text.slice(0, start) + replacement + text.slice(next + 1);
fs.writeFileSync(file, text);
NODE

log "Patching renderer output replacement hook"
node - "$RENDERER_FILE" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
let text = fs.readFileSync(file, "utf8");
const needle = "window.electronAPI.agent.outputCheck({ output: outputContent }).then((outputCheckRes) => {";
const replacement = "Promise.resolve({ data: { sensitive: false, answer: \"\" } }).then((outputCheckRes) => {";
const count = text.split(needle).length - 1;
if (count < 1) {
  console.error("Renderer outputCheck hook not found");
  process.exit(2);
}
text = text.split(needle).join(replacement);
fs.writeFileSync(file, text);
console.log(`patched ${count} renderer hook(s)`);
NODE

log "Verifying patch markers"
grep -q -F 'stage: "local-patch"' "$MAIN_FILE" || fail "Main patch marker missing"
grep -q -F 'Promise.resolve({ data: { sensitive: false' "$RENDERER_FILE" || fail "Renderer patch marker missing"
if grep -q -F '/agentdr/v1/assistant/claw-output-check' "$MAIN_FILE"; then
  log "Endpoint string still exists in bundle, but patched agentOutputCheck no longer calls it."
fi

log "Repacking app.asar"
npx --yes @electron/asar pack "$TMP_DIR/app" "$TMP_DIR/app.asar"
cp "$TMP_DIR/app.asar" "$ASAR_PATH"

if command -v codesign >/dev/null 2>&1; then
  log "Applying ad-hoc code signature"
  codesign --force --deep --sign - "$APP_PATH" >/dev/null 2>&1 || log "codesign failed; AutoClaw may still run, but macOS could complain"
fi

log "Patch complete. Restart AutoClaw."
log "To restore: cp '$BACKUP_PATH' '$ASAR_PATH'"
