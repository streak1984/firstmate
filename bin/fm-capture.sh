#!/usr/bin/env bash
# fm-capture.sh - serve one declared web build and capture a verified viewport matrix.
#
# The JSON serve contract owns application-specific commands, while this runner
# owns port allocation, bounded readiness, browser waits, /tmp staging,
# post-copy verification, evidence logs, and process-group cleanup.
# The server receives its allocated loopback port through FM_CAPTURE_PORT.
# Static mode is the preferred declaration when built output is representative;
# dev mode is reserved for application runtime behavior that static serving loses.
#
# Usage:
#   bin/fm-capture.sh --contract <serve.json> --matrix <matrix.json> \
#     --workdir <project-worktree> --output-dir <shots-dir> \
#     --task-temp </tmp/task-dir> --session <unique-name> [--deadline <seconds>]
#
# Run with --help for the complete executable contract and examples.
set -eu

usage() {
  cat <<'EOF'
usage: fm-capture.sh --contract <serve.json> --matrix <matrix.json>
       --workdir <project-worktree> --output-dir <shots-dir>
       --task-temp </tmp/task-dir> --session <unique-name>
       [--deadline <seconds>]

Serve contract JSON:
  {
    "mode": "static",
    "buildCommand": "bun run build",
    "serverCommand": "python3 -m http.server --bind 127.0.0.1 \"$FM_CAPTURE_PORT\" --directory dist",
    "readyPath": "/",
    "successStatus": 200,
    "readyText": "optional text proving the intended page is ready"
  }

Fields:
  mode             Required: static or dev. Prefer static when built output is representative.
  buildCommand     Optional shell command run once before serving. Omit for an existing build.
  serverCommand    Required shell command. It must reference $FM_CAPTURE_PORT.
  readyPath        Required absolute URL path used for readiness polling.
  successStatus    Required single acceptable HTTP status from 100 through 599.
  readyText        Optional fixed text that must occur in the readiness response body.

View/viewport matrix JSON:
  [
    {"name":"desktop-hero","path":"/","width":1440,"height":900},
    {"name":"desktop-mid","path":"/","width":1440,"height":900,
     "prepareScript":"() => { window.scrollTo(0, 900); return true; }"},
    {"name":"mobile-hero","path":"/","width":390,"height":844,
     "prepareScript":"() => document.querySelector('[aria-expanded=false]').click()",
     "waitSelector":"[aria-expanded=true]"}
  ]

Each matrix entry produces <output-dir>/<name>.png.
Only the standard 1440x900 and 390x844 viewports are accepted in v1.
path is an absolute URL path on the allocated loopback origin.
prepareScript is optional JavaScript run after navigation and before settling.
waitSelector is optional and must become visible before capture.
Every capture is viewport-sized; full-page capture is deliberately unsupported.

The runner creates a unique evidence directory below --task-temp and keeps it.
The task temp path must be under /tmp or /private/tmp.
It records server PID, process group, ports, URL, and log paths before HTTP polling.
Readiness uses a bounded deadline, default 30 seconds.
On timeout it reports the last HTTP error and the final 40 server-log lines.
Before each screenshot it waits for document fonts, images, animation frames, and any selector.
Screenshots are always written below /tmp first and must be non-empty there.
The browser viewport and staged and copied PNG dimensions must match the matrix exactly.
The runner copies each artifact to --output-dir, requires it to be non-empty again, and byte-compares it with the staged file.
The exit trap terminates only the recorded server process group and never searches by process name or port.
Server, build, browser, metadata, and staged-capture evidence remains in the task temp directory.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

CONTRACT=
MATRIX=
WORKDIR=
OUTPUT_DIR=
TASK_TEMP=
SESSION=
READY_TIMEOUT=30

while [ "$#" -gt 0 ]; do
  case "$1" in
    --contract)
      [ "$#" -ge 2 ] || die "--contract requires a path"
      CONTRACT=$2
      shift 2
      ;;
    --matrix)
      [ "$#" -ge 2 ] || die "--matrix requires a path"
      MATRIX=$2
      shift 2
      ;;
    --workdir)
      [ "$#" -ge 2 ] || die "--workdir requires a path"
      WORKDIR=$2
      shift 2
      ;;
    --output-dir)
      [ "$#" -ge 2 ] || die "--output-dir requires a path"
      OUTPUT_DIR=$2
      shift 2
      ;;
    --task-temp)
      [ "$#" -ge 2 ] || die "--task-temp requires a path"
      TASK_TEMP=$2
      shift 2
      ;;
    --session)
      [ "$#" -ge 2 ] || die "--session requires a name"
      SESSION=$2
      shift 2
      ;;
    --deadline)
      [ "$#" -ge 2 ] || die "--deadline requires seconds"
      READY_TIMEOUT=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$CONTRACT" ] || die "--contract is required"
[ -n "$MATRIX" ] || die "--matrix is required"
[ -n "$WORKDIR" ] || die "--workdir is required"
[ -n "$OUTPUT_DIR" ] || die "--output-dir is required"
[ -n "$TASK_TEMP" ] || die "--task-temp is required"
[ -n "$SESSION" ] || die "--session is required"
[ -f "$CONTRACT" ] || die "serve contract not found: $CONTRACT"
[ -f "$MATRIX" ] || die "view/viewport matrix not found: $MATRIX"
[ -d "$WORKDIR" ] || die "workdir not found: $WORKDIR"

case "$SESSION" in
  *[!A-Za-z0-9._-]*|'') die "session must use only letters, digits, dot, underscore, or dash" ;;
esac
case "$READY_TIMEOUT" in
  *[!0-9]*|'') die "deadline must be an integer from 1 through 600" ;;
esac
[ "$READY_TIMEOUT" -ge 1 ] && [ "$READY_TIMEOUT" -le 600 ] \
  || die "deadline must be an integer from 1 through 600"
case "$TASK_TEMP" in
  /tmp|/tmp/*|/private/tmp|/private/tmp/*) ;;
  *) die "task temp must be an absolute path under /tmp or /private/tmp" ;;
esac

command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v curl >/dev/null 2>&1 || die "curl is required"
CHROME_BIN=$(command -v chrome-devtools-axi 2>/dev/null) \
  || die "chrome-devtools-axi is required"

mkdir -p "$TASK_TEMP" "$OUTPUT_DIR"
WORKDIR=$(cd "$WORKDIR" && pwd -P)
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd -P)
TASK_TEMP=$(cd "$TASK_TEMP" && pwd -P)
RUN_DIR="$TASK_TEMP/fm-capture-$SESSION-$(date +%Y%m%dT%H%M%S)-$$"
mkdir -p "$RUN_DIR/staging" "$RUN_DIR/normalized"

SERVER_PID=
SERVER_PGID=
SERVER_PORT=
BRIDGE_PORT=
PORT_LOCKS=()

group_alive() {
  python3 - "$1" <<'PY' 2>/dev/null
import os
import sys

os.killpg(int(sys.argv[1]), 0)
PY
}

signal_group() {
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import os
import signal
import sys

os.killpg(int(sys.argv[1]), getattr(signal, "SIG" + sys.argv[2]))
PY
}

port_is_free() {
  python3 - "$1" <<'PY'
import socket
import sys

port = int(sys.argv[1])
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
    probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    probe.bind(("127.0.0.1", port))
PY
}

cleanup() {
  local rc=$? lock attempt
  trap - EXIT INT TERM HUP
  set +e

  if [ -n "$SERVER_PGID" ] && group_alive "$SERVER_PGID"; then
    signal_group "$SERVER_PGID" TERM
    attempt=0
    while [ "$attempt" -lt 30 ] && group_alive "$SERVER_PGID"; do
      sleep 0.1
      attempt=$((attempt + 1))
    done
    if group_alive "$SERVER_PGID"; then
      signal_group "$SERVER_PGID" KILL
    fi
  fi
  if [ -n "$SERVER_PID" ]; then
    wait "$SERVER_PID" 2>/dev/null
  fi
  if [ -n "$SERVER_PORT" ] && ! port_is_free "$SERVER_PORT" 2>/dev/null; then
    printf 'warning: allocated server port %s is still occupied after process-group cleanup\n' \
      "$SERVER_PORT" >&2
  fi
  for lock in "${PORT_LOCKS[@]}"; do
    rm -f "$lock/owner"
    rmdir "$lock" 2>/dev/null
  done
  exit "$rc"
}

trap cleanup EXIT
trap 'exit 130' INT TERM HUP

python3 - "$CONTRACT" "$MATRIX" "$RUN_DIR/normalized" <<'PY'
from __future__ import annotations

import json
import re
import sys
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def load_json(path: Path, label: str):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"{label} is unreadable: {exc}")


def text(value, label: str, *, required: bool = True) -> str:
    if value is None and not required:
        return ""
    if not isinstance(value, str) or (required and not value):
        fail(f"{label} must be {'a non-empty' if required else 'an optional'} string")
    if any(ord(char) < 32 and char not in "\t" for char in value):
        fail(f"{label} contains unsupported control characters")
    return value


contract_path = Path(sys.argv[1])
matrix_path = Path(sys.argv[2])
out = Path(sys.argv[3])
contract = load_json(contract_path, "serve contract")
matrix = load_json(matrix_path, "view/viewport matrix")

if not isinstance(contract, dict):
    fail("serve contract must be a JSON object")
allowed_contract = {
    "mode",
    "buildCommand",
    "serverCommand",
    "readyPath",
    "successStatus",
    "readyText",
}
unknown = sorted(set(contract) - allowed_contract)
if unknown:
    fail("serve contract has unknown fields: " + ", ".join(unknown))

mode = text(contract.get("mode"), "mode")
if mode not in {"static", "dev"}:
    fail("mode must be static or dev")
build = text(contract.get("buildCommand"), "buildCommand", required=False)
command = text(contract.get("serverCommand"), "serverCommand")
if "FM_CAPTURE_PORT" not in command:
    fail("serverCommand must reference FM_CAPTURE_PORT")
ready_path = text(contract.get("readyPath"), "readyPath")
if not ready_path.startswith("/"):
    fail("readyPath must begin with /")
status = contract.get("successStatus")
if not isinstance(status, int) or isinstance(status, bool) or not 100 <= status <= 599:
    fail("successStatus must be an integer from 100 through 599")
ready_text = text(contract.get("readyText"), "readyText", required=False)

contract_out = out / "contract"
contract_out.mkdir(parents=True, exist_ok=True)
for name, value in {
    "mode": mode,
    "build": build,
    "command": command,
    "ready_path": ready_path,
    "success_status": str(status),
    "ready_text": ready_text,
}.items():
    (contract_out / name).write_text(value, encoding="utf-8")

if not isinstance(matrix, list) or not matrix:
    fail("view/viewport matrix must be a non-empty JSON array")
seen = set()
allowed_capture = {"name", "path", "width", "height", "prepareScript", "waitSelector"}
viewports = {(1440, 900), (390, 844)}
matrix_out = out / "matrix"
matrix_out.mkdir(parents=True, exist_ok=True)
for index, item in enumerate(matrix):
    if not isinstance(item, dict):
        fail(f"matrix entry {index} must be an object")
    unknown = sorted(set(item) - allowed_capture)
    if unknown:
        fail(f"matrix entry {index} has unknown fields: {', '.join(unknown)}")
    name = text(item.get("name"), f"matrix entry {index} name")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name):
        fail(f"matrix entry {index} name has unsupported characters")
    if name in seen:
        fail(f"matrix contains duplicate name: {name}")
    seen.add(name)
    path = text(item.get("path"), f"matrix entry {index} path")
    if not path.startswith("/"):
        fail(f"matrix entry {index} path must begin with /")
    width = item.get("width")
    height = item.get("height")
    if not isinstance(width, int) or isinstance(width, bool):
        fail(f"matrix entry {index} width must be an integer")
    if not isinstance(height, int) or isinstance(height, bool):
        fail(f"matrix entry {index} height must be an integer")
    if (width, height) not in viewports:
        fail(f"matrix entry {index} must use 1440x900 or 390x844")
    prepare = text(item.get("prepareScript"), f"matrix entry {index} prepareScript", required=False)
    selector = text(item.get("waitSelector"), f"matrix entry {index} waitSelector", required=False)

    capture_out = matrix_out / f"{index:04d}"
    capture_out.mkdir()
    for field, value in {
        "name": name,
        "path": path,
        "width": str(width),
        "height": str(height),
        "prepare": prepare,
        "selector": selector,
    }.items():
        (capture_out / field).write_text(value, encoding="utf-8")
PY

MODE=$(cat "$RUN_DIR/normalized/contract/mode")
BUILD_COMMAND=$(cat "$RUN_DIR/normalized/contract/build")
SERVER_COMMAND=$(cat "$RUN_DIR/normalized/contract/command")
READY_PATH=$(cat "$RUN_DIR/normalized/contract/ready_path")
SUCCESS_STATUS=$(cat "$RUN_DIR/normalized/contract/success_status")
READY_TEXT=$(cat "$RUN_DIR/normalized/contract/ready_text")

PORT_LOCK_ROOT=/tmp/fm-capture-port-locks
mkdir -p "$PORT_LOCK_ROOT"

allocate_port() {
  local purpose=$1 attempt=0 port lock
  while [ "$attempt" -lt 100 ]; do
    port=$(python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)
    lock="$PORT_LOCK_ROOT/$port"
    if mkdir "$lock" 2>/dev/null; then
      printf '%s\n' "$$" > "$lock/owner"
      PORT_LOCKS+=("$lock")
      ALLOCATED_PORT=$port
      return 0
    fi
    attempt=$((attempt + 1))
  done
  die "could not allocate a reserved loopback port for $purpose"
}

ALLOCATED_PORT=
allocate_port server
SERVER_PORT=$ALLOCATED_PORT
allocate_port browser-bridge
BRIDGE_PORT=$ALLOCATED_PORT
[ "$SERVER_PORT" != "$BRIDGE_PORT" ] || die "server and browser bridge ports collided"

BUILD_LOG="$RUN_DIR/build.log"
SERVER_LOG="$RUN_DIR/server.log"
BROWSER_LOG="$RUN_DIR/browser.log"
META="$RUN_DIR/run.meta"
: > "$BUILD_LOG"
: > "$SERVER_LOG"
: > "$BROWSER_LOG"

if [ -n "$BUILD_COMMAND" ]; then
  if ! (cd "$WORKDIR" && /bin/sh -c "$BUILD_COMMAND") > "$BUILD_LOG" 2>&1; then
    printf 'error: build command failed in %s\n' "$WORKDIR" >&2
    tail -n 40 "$BUILD_LOG" >&2
    exit 1
  fi
fi

GROUP_MARKER="$RUN_DIR/server.pgid"
(
  cd "$WORKDIR"
  export FM_CAPTURE_PORT="$SERVER_PORT"
  exec python3 -c '
import os
import sys

command = sys.argv[1]
marker = sys.argv[2]
os.setsid()
with open(marker, "w", encoding="utf-8") as stream:
    stream.write(f"{os.getpid()}\n")
    stream.flush()
    os.fsync(stream.fileno())
os.execv("/bin/sh", ["sh", "-c", command])
' "$SERVER_COMMAND" "$GROUP_MARKER"
) >> "$SERVER_LOG" 2>&1 &
SERVER_PID=$!

GROUP_WAIT=0
while [ ! -s "$GROUP_MARKER" ] && [ "$GROUP_WAIT" -lt 50 ]; do
  kill -0 "$SERVER_PID" 2>/dev/null || break
  sleep 0.02
  GROUP_WAIT=$((GROUP_WAIT + 1))
done
[ -s "$GROUP_MARKER" ] || die "server failed before creating its process group; see $SERVER_LOG"
SERVER_PGID=$(cat "$GROUP_MARKER")
case "$SERVER_PGID" in
  *[!0-9]*|'') die "server process-group marker is invalid: $GROUP_MARKER" ;;
esac
[ "$SERVER_PGID" = "$SERVER_PID" ] \
  || die "server process group $SERVER_PGID does not match recorded pid $SERVER_PID"

READY_URL="http://127.0.0.1:$SERVER_PORT$READY_PATH"
{
  printf 'mode=%s\n' "$MODE"
  printf 'server_pid=%s\n' "$SERVER_PID"
  printf 'server_pgid=%s\n' "$SERVER_PGID"
  printf 'server_port=%s\n' "$SERVER_PORT"
  printf 'browser_session=%s\n' "$SESSION"
  printf 'bridge_port=%s\n' "$BRIDGE_PORT"
  printf 'ready_url=%s\n' "$READY_URL"
  printf 'build_log=%s\n' "$BUILD_LOG"
  printf 'server_log=%s\n' "$SERVER_LOG"
  printf 'browser_log=%s\n' "$BROWSER_LOG"
  printf 'staging_dir=%s\n' "$RUN_DIR/staging"
  printf 'output_dir=%s\n' "$OUTPUT_DIR"
} > "$META"

LAST_HTTP_ERROR='no HTTP response received'
HTTP_BODY="$RUN_DIR/readiness.body"
HTTP_ERROR="$RUN_DIR/readiness.error"
DEADLINE=$((SECONDS + READY_TIMEOUT))
READY=false
while [ "$SECONDS" -lt "$DEADLINE" ]; do
  set +e
  HTTP_STATUS=$(curl --silent --show-error --max-time 2 \
    --output "$HTTP_BODY" --write-out '%{http_code}' "$READY_URL" 2> "$HTTP_ERROR")
  CURL_RC=$?
  set -e
  if [ "$CURL_RC" -eq 0 ]; then
    if [ "$HTTP_STATUS" = "$SUCCESS_STATUS" ]; then
      if [ -z "$READY_TEXT" ] || grep -F -- "$READY_TEXT" "$HTTP_BODY" >/dev/null 2>&1; then
        READY=true
        break
      fi
      LAST_HTTP_ERROR="HTTP $HTTP_STATUS omitted required readyText"
    else
      LAST_HTTP_ERROR="HTTP status $HTTP_STATUS (expected $SUCCESS_STATUS)"
    fi
  else
    LAST_HTTP_ERROR=$(cat "$HTTP_ERROR")
    [ -n "$LAST_HTTP_ERROR" ] || LAST_HTTP_ERROR="curl exited $CURL_RC"
  fi
  group_alive "$SERVER_PGID" || break
  sleep 0.2
done

if ! "$READY"; then
  printf 'error: readiness deadline expired for %s after %ss\n' \
    "$READY_URL" "$READY_TIMEOUT" >&2
  printf 'last HTTP error: %s\n' "$LAST_HTTP_ERROR" >&2
  printf '%s\n' "--- final 40 server-log lines ($SERVER_LOG) ---" >&2
  tail -n 40 "$SERVER_LOG" >&2
  exit 1
fi

run_chrome() {
  {
    printf 'chrome-devtools-axi'
    printf ' %q' "$@"
    printf '\n'
    CHROME_DEVTOOLS_AXI_SESSION="$SESSION" \
    CHROME_DEVTOOLS_AXI_PORT="$BRIDGE_PORT" \
      "$CHROME_BIN" "$@"
  } >> "$BROWSER_LOG" 2>&1
}

assert_png_dimensions() {
  python3 - "$1" "$2" "$3" <<'PY'
import struct
import sys

path = sys.argv[1]
expected = (int(sys.argv[2]), int(sys.argv[3]))
with open(path, "rb") as stream:
    header = stream.read(24)
if len(header) < 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
    raise SystemExit(f"capture is not a readable PNG: {path}")
actual = struct.unpack(">II", header[16:24])
if actual != expected:
    raise SystemExit(
        f"capture dimensions are {actual[0]}x{actual[1]}, expected {expected[0]}x{expected[1]}: {path}"
    )
PY
}

ASSET_WAIT_JS='async () => {
  const settle = async () => {
    if (document.fonts && document.fonts.ready) await document.fonts.ready;
    await Promise.all(Array.from(document.images).map((image) => {
      if (image.complete) return image.decode ? image.decode().catch(() => undefined) : Promise.resolve();
      return new Promise((resolve) => {
        image.addEventListener("load", resolve, { once: true });
        image.addEventListener("error", resolve, { once: true });
      });
    }));
    await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    return true;
  };
  return Promise.race([
    settle(),
    new Promise((_, reject) => setTimeout(() => reject(new Error("fonts and images did not settle within 10000ms")), 10000))
  ]);
}'

CAPTURE_COUNT=0
for CAPTURE_DIR in "$RUN_DIR"/normalized/matrix/*; do
  NAME=$(cat "$CAPTURE_DIR/name")
  VIEW_PATH=$(cat "$CAPTURE_DIR/path")
  WIDTH=$(cat "$CAPTURE_DIR/width")
  HEIGHT=$(cat "$CAPTURE_DIR/height")
  PREPARE_SCRIPT=$(cat "$CAPTURE_DIR/prepare")
  WAIT_SELECTOR=$(cat "$CAPTURE_DIR/selector")
  VIEW_URL="http://127.0.0.1:$SERVER_PORT$VIEW_PATH"
  STAGED="$RUN_DIR/staging/$NAME.png"
  DESTINATION="$OUTPUT_DIR/$NAME.png"

  VIEWPORT_SPEC="${WIDTH}x${HEIGHT}x1"
  if [ "$WIDTH" = 390 ] && [ "$HEIGHT" = 844 ]; then
    VIEWPORT_SPEC="$VIEWPORT_SPEC,mobile,touch"
  fi
  run_chrome emulate --viewport "$VIEWPORT_SPEC" \
    || die "browser viewport emulation failed for $NAME; see $BROWSER_LOG"
  run_chrome open "$VIEW_URL" \
    || die "browser navigation failed for $NAME; see $BROWSER_LOG"
  VIEWPORT_ASSERT_JS="() => {
    const actual = [window.innerWidth, window.innerHeight];
    const expected = [$WIDTH, $HEIGHT];
    if (actual[0] !== expected[0] || actual[1] !== expected[1]) {
      throw new Error('viewport is ' + actual.join('x') + ', expected ' + expected.join('x'));
    }
    return actual.join('x');
  }"
  run_chrome eval "$VIEWPORT_ASSERT_JS" \
    || die "browser viewport does not match ${WIDTH}x${HEIGHT} for $NAME; see $BROWSER_LOG"
  if [ -n "$PREPARE_SCRIPT" ]; then
    run_chrome eval "$PREPARE_SCRIPT" \
      || die "prepareScript failed for $NAME; see $BROWSER_LOG"
  fi
  run_chrome eval "$ASSET_WAIT_JS" \
    || die "fonts or images did not settle for $NAME; see $BROWSER_LOG"
  if [ -n "$WAIT_SELECTOR" ]; then
    SELECTOR_JSON=$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$WAIT_SELECTOR")
    SELECTOR_WAIT_JS="async () => {
      const selector = $SELECTOR_JSON;
      const deadline = performance.now() + 10000;
      while (performance.now() < deadline) {
        const element = document.querySelector(selector);
        if (element) {
          const style = getComputedStyle(element);
          const box = element.getBoundingClientRect();
          if (style.visibility !== 'hidden' && style.display !== 'none' && box.width > 0 && box.height > 0) return true;
        }
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
      throw new Error('selector did not become visible: ' + selector);
    }"
    run_chrome eval "$SELECTOR_WAIT_JS" \
      || die "waitSelector failed for $NAME; see $BROWSER_LOG"
  fi
  run_chrome screenshot "$STAGED" \
    || die "screenshot command failed for $NAME; see $BROWSER_LOG"
  [ -s "$STAGED" ] \
    || die "screenshot command returned without a non-empty staged artifact for $NAME: $STAGED"
  assert_png_dimensions "$STAGED" "$WIDTH" "$HEIGHT" \
    || die "staged screenshot dimensions do not match the matrix for $NAME"

  cp "$STAGED" "$DESTINATION"
  [ -s "$DESTINATION" ] \
    || die "copied capture is missing or empty for $NAME: $DESTINATION"
  cmp -s "$STAGED" "$DESTINATION" \
    || die "copied capture differs from staged artifact for $NAME: $DESTINATION"
  assert_png_dimensions "$DESTINATION" "$WIDTH" "$HEIGHT" \
    || die "destination screenshot dimensions do not match the matrix for $NAME"
  CAPTURE_COUNT=$((CAPTURE_COUNT + 1))
done

printf 'capture complete: %s artifact(s) verified in %s\n' "$CAPTURE_COUNT" "$OUTPUT_DIR"
printf 'capture evidence: %s\n' "$RUN_DIR"
