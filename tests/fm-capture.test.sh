#!/usr/bin/env bash
# Tests for bin/fm-capture.sh through its executable JSON contract and matrix.
# The fixtures use a real loopback HTTP server and a fake browser executable so
# failure semantics, /tmp staging, copy verification, and cleanup stay deterministic.
# tests/fixtures/fm-capture-static is the matching real-browser verification fixture.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CAPTURE="$ROOT/bin/fm-capture.sh"
TMP_ROOT=$(mktemp -d /tmp/fm-capture-tests.XXXXXX)
FAKEBIN="$TMP_ROOT/fakebin"
SERVER_SCRIPT="$TMP_ROOT/static-server.py"
UNRELATED_PID=

cleanup_test() {
  if [ -n "$UNRELATED_PID" ]; then
    kill "$UNRELATED_PID" 2>/dev/null || true
    wait "$UNRELATED_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup_test EXIT

mkdir -p "$FAKEBIN"

cat > "$SERVER_SCRIPT" <<'PY'
from __future__ import annotations

import http.server
import subprocess
import sys


port = int(sys.argv[1])
mode = sys.argv[2]
child_path = sys.argv[3]

if mode == "timeout-with-child":
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"])
    with open(child_path, "w", encoding="utf-8") as stream:
        stream.write(f"{child.pid}\n")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if mode.startswith("timeout"):
            body = b"not ready"
            self.send_response(503)
        else:
            body = b"fixture ready"
            self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args) -> None:
        print("static server fixture: " + (fmt % args), flush=True)


print(f"static server fixture ready on {port} mode={mode}", flush=True)
http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY

cat > "$FAKEBIN/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s|session=%s|port=%s\n' \
  "${1:-}" "${CHROME_DEVTOOLS_AXI_SESSION:-}" "${CHROME_DEVTOOLS_AXI_PORT:-}" \
  >> "${FAKE_BROWSER_COMMANDS:?}"
case "${1:-}" in
  screenshot)
    target=${2:?}
    printf '%s\n' "$target" >> "${FAKE_CAPTURE_TRACE:?}"
    case "${FAKE_CAPTURE_MODE:-write}" in
      write)
        python3 - "$target" 1440 900 <<'PY'
import struct
import sys

with open(sys.argv[1], "wb") as stream:
    stream.write(b"\x89PNG\r\n\x1a\n")
    stream.write(struct.pack(">I", 13))
    stream.write(b"IHDR")
    stream.write(struct.pack(">II", int(sys.argv[2]), int(sys.argv[3])))
PY
        ;;
      wrong-size)
        python3 - "$target" 500 844 <<'PY'
import struct
import sys

with open(sys.argv[1], "wb") as stream:
    stream.write(b"\x89PNG\r\n\x1a\n")
    stream.write(struct.pack(">I", 13))
    stream.write(b"IHDR")
    stream.write(struct.pack(">II", int(sys.argv[2]), int(sys.argv[3])))
PY
        ;;
      missing) ;;
      empty) : > "$target" ;;
      *) exit 64 ;;
    esac
    ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/chrome-devtools-axi"

make_case() {
  local name=$1 mode=$2 case_dir contract matrix child_path
  case_dir="$TMP_ROOT/$name"
  contract="$case_dir/serve.json"
  matrix="$case_dir/matrix.json"
  child_path="$case_dir/server-child.pid"
  mkdir -p "$case_dir/work" "$case_dir/output" "$case_dir/task-temp"
  cat > "$contract" <<EOF
{
  "mode": "static",
  "serverCommand": "python3 \"$SERVER_SCRIPT\" \"\$FM_CAPTURE_PORT\" \"$mode\" \"$child_path\"",
  "readyPath": "/",
  "successStatus": 200
}
EOF
  cat > "$matrix" <<'EOF'
[
  {"name":"desktop-hero","path":"/","width":1440,"height":900}
]
EOF
  printf '%s\n' "$case_dir"
}

run_case() {
  local case_dir=$1 capture_mode=$2 deadline=${3:-3}
  FAKE_CAPTURE_MODE="$capture_mode" \
  FAKE_CAPTURE_TRACE="$case_dir/capture.trace" \
  FAKE_BROWSER_COMMANDS="$case_dir/browser.commands" \
  PATH="$FAKEBIN:$PATH" \
    "$CAPTURE" \
      --contract "$case_dir/serve.json" \
      --matrix "$case_dir/matrix.json" \
      --workdir "$case_dir/work" \
      --output-dir "$case_dir/output" \
      --task-temp "$case_dir/task-temp" \
      --session "$(basename "$case_dir")" \
      --deadline "$deadline"
}

find_meta() {
  find "$1/task-temp" -name run.meta -type f -print -quit
}

process_group_alive() {
  python3 - "$1" <<'PY' 2>/dev/null
import os
import sys

os.killpg(int(sys.argv[1]), 0)
PY
}

test_readiness_timeout_is_bounded_and_diagnostic() {
  local case_dir out rc meta pgid child_pid attempt
  case_dir=$(make_case readiness-timeout timeout-with-child)

  python3 "$SERVER_SCRIPT" 0 ready "$case_dir/unrelated-child.pid" \
    > "$case_dir/unrelated.log" 2>&1 &
  UNRELATED_PID=$!

  out=$(run_case "$case_dir" write 1 2>&1)
  rc=$?

  [ "$rc" -ne 0 ] || fail "readiness timeout must return nonzero"
  assert_contains "$out" 'readiness deadline expired' \
    "readiness timeout must name the bounded deadline"
  assert_contains "$out" 'last HTTP error:' \
    "readiness timeout must report the final HTTP failure"
  assert_contains "$out" 'static server fixture' \
    "readiness timeout must include a bounded server-log tail"

  meta=$(find_meta "$case_dir")
  assert_present "$meta" "run metadata must exist before readiness polling"
  pgid=$(sed -n 's/^server_pgid=//p' "$meta")
  child_pid=$(cat "$case_dir/server-child.pid")
  attempt=0
  while process_group_alive "$pgid" && [ "$attempt" -lt 30 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  ! process_group_alive "$pgid" \
    || fail "cleanup must terminate the recorded server process group"
  ! kill -0 "$child_pid" 2>/dev/null \
    || fail "cleanup must terminate children in the recorded server process group"
  kill -0 "$UNRELATED_PID" 2>/dev/null \
    || fail "cleanup must not terminate an unrelated server process"
  kill "$UNRELATED_PID" 2>/dev/null || true
  wait "$UNRELATED_PID" 2>/dev/null || true
  UNRELATED_PID=
  pass "fm-capture bounds readiness diagnostics and cleans only its recorded process group"
}

test_missing_and_empty_artifacts_fail() {
  local mode case_dir out rc
  for mode in missing empty; do
    case_dir=$(make_case "artifact-$mode" ready)
    out=$(run_case "$case_dir" "$mode" 3 2>&1)
    rc=$?
    [ "$rc" -ne 0 ] || fail "$mode screenshot must return nonzero"
    assert_contains "$out" 'without a non-empty staged artifact' \
      "$mode screenshot must fail loudly after a zero-exit browser command"
    assert_absent "$case_dir/output/desktop-hero.png" \
      "$mode screenshot must not report a destination artifact"
  done
  pass "fm-capture rejects missing and empty screenshot artifacts"
}

test_staging_and_verified_copy() {
  local case_dir out rc staged commands meta staging_dir
  case_dir=$(make_case staging-copy ready)

  out=$(run_case "$case_dir" write 3 2>&1)
  rc=$?

  expect_code 0 "$rc" "successful capture"
  staged=$(cat "$case_dir/capture.trace")
  case "$staged" in
    /tmp/*|/private/tmp/*) ;;
    *) fail "browser screenshot target must be staged under /tmp: $staged" ;;
  esac
  assert_present "$staged" "staged screenshot evidence must be retained"
  [ -s "$staged" ] || fail "staged screenshot evidence must be non-empty"
  [ -s "$case_dir/output/desktop-hero.png" ] \
    || fail "destination screenshot must be non-empty"
  cmp -s "$staged" "$case_dir/output/desktop-hero.png" \
    || fail "destination screenshot must match staged bytes"
  commands=$(cat "$case_dir/browser.commands")
  assert_contains "$commands" 'session=staging-copy' \
    "every browser command must carry the explicit session name"
  assert_contains "$commands" 'port=' \
    "every browser command must carry the explicit bridge port"
  meta=$(find_meta "$case_dir")
  staging_dir=$(sed -n 's/^staging_dir=//p' "$meta")
  [ "$(dirname "$staged")" = "$staging_dir" ] \
    || fail "metadata must record the actual /tmp staging directory"
  assert_contains "$out" 'capture complete: 1 artifact(s) verified' \
    "success must report verified artifact count"
  pass "fm-capture stages under /tmp and verifies the destination copy"
}

test_corrupt_copy_fails_verification() {
  local case_dir out rc
  case_dir=$(make_case corrupt-copy ready)
  cat > "$FAKEBIN/cp" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'different-nonempty-bytes\n' > "${2:?}"
SH
  chmod +x "$FAKEBIN/cp"

  out=$(run_case "$case_dir" write 3 2>&1)
  rc=$?
  rm -f "$FAKEBIN/cp"

  [ "$rc" -ne 0 ] || fail "a corrupt copy must return nonzero"
  assert_contains "$out" 'copied capture differs from staged artifact' \
    "copy verification must compare bytes rather than trusting cp exit zero"
  pass "fm-capture rejects a non-empty but corrupt destination copy"
}

test_mismatched_viewport_artifact_fails() {
  local case_dir out rc
  case_dir=$(make_case mismatched-viewport ready)

  out=$(run_case "$case_dir" wrong-size 3 2>&1)
  rc=$?

  [ "$rc" -ne 0 ] || fail "a screenshot with the wrong dimensions must return nonzero"
  assert_contains "$out" 'capture dimensions are 500x844, expected 1440x900' \
    "dimension verification must report the measured mismatch"
  assert_contains "$out" 'staged screenshot dimensions do not match the matrix' \
    "dimension verification must fail before copying"
  assert_absent "$case_dir/output/desktop-hero.png" \
    "a mismatched viewport artifact must not reach the destination"
  pass "fm-capture rejects screenshots whose pixels do not match the viewport matrix"
}

test_readiness_timeout_is_bounded_and_diagnostic
test_missing_and_empty_artifacts_fail
test_staging_and_verified_copy
test_corrupt_copy_fails_verification
test_mismatched_viewport_artifact_fails
