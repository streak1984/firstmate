#!/usr/bin/env bash
# Tests for bin/fm-dispatch-facts.sh: the data-only tool that assembles the
# per-candidate quota and auth fact table firstmate consumes at dispatch
# intake. It must preserve input order, resolve the applicable quota scope
# mechanically, render every absent fact as explicit "unknown" (never a
# healthy default), label prepaid credits and stale states, and refuse
# malformed candidates naming the offending index - all without ever ranking,
# recommending, or selecting.
#
# Matrix:
#   (a) named model:<model> scope wins over the provider-level scope
#   (b) provider-level scope (all_models/all_products) applies when the
#       candidate's model has no model-scoped entry
#   (c) a provider missing from the quota snapshot renders every fact as
#       unknown with the provider-not-in-snapshot marker
#   (d) an older schema with no pace summary renders pace facts as unknown
#       without crashing and keeps the known effective percentage
#   (e) auth lists one healthy and one expired source on the same provider
#   (f) malformed candidates are refused with the index named, nonzero
#   (g) input order is preserved, never sorted
#   (h) --candidates-file and stdin produce identical output
#   (i) -h/--help prints the header usage and exits 0
#   (j) fixture mode never launches a vendor CLI (empty fakebin PATH)
#   (k) --json emits the same facts with "unknown" strings for absent fields
#   (l) a provider without a state object renders stale as unknown, never a
#       healthy "not stale" default
#   (m) an auth source entry missing source/status renders those fields as
#       unknown, never a bare "=" cell or JSON nulls
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FACTS="$ROOT/bin/fm-dispatch-facts.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-facts-tests)
mkdir -p "$TMP_ROOT"

QUOTA_FIXTURE="$TMP_ROOT/quota.json"
AUTH_FIXTURE="$TMP_ROOT/auth.json"

cat > "$QUOTA_FIXTURE" <<'JSON'
{
  "generatedAt": "2026-01-01T00:00:00Z",
  "schemaVersion": 3,
  "providers": [
    {
      "provider": "claude",
      "label": "Claude",
      "source": "oauth",
      "plan": "max",
      "windows": [],
      "state": {"status": "fresh", "stale": false, "sourcesTried": ["oauth-file"]},
      "quotaSemantics": {
        "status": "known",
        "description": "fixture",
        "effectiveAvailability": [
          {"scope": "all_models", "status": "known", "effectivePercentRemaining": 55,
           "boundedBy": ["five_hour"], "limitingWindowIds": ["five_hour"],
           "pace": {"status": "ahead", "aheadWindowIds": ["five_hour"],
                    "worstReservePercentPoints": -28.75, "worstReserveWindowId": "five_hour"}},
          {"scope": "model:opus", "status": "known", "effectivePercentRemaining": 40,
           "boundedBy": ["five_hour", "model:opus"], "limitingWindowIds": ["model:opus"],
           "pace": {"status": "mixed", "aheadWindowIds": ["five_hour"],
                    "behindWindowIds": ["model:opus"], "worstReservePercentPoints": -28.75,
                    "worstReserveWindowId": "five_hour"}}
        ]
      }
    },
    {
      "provider": "codex",
      "label": "Codex",
      "source": "cli-rpc",
      "plan": "pro",
      "windows": [],
      "credits": {"remaining": 42, "unlimited": false, "unit": "credits"},
      "state": {"status": "stale", "stale": true, "sourcesTried": ["cli-rpc"]},
      "quotaSemantics": {
        "status": "known",
        "description": "fixture",
        "effectiveAvailability": [
          {"scope": "all_models", "status": "known", "effectivePercentRemaining": 20,
           "boundedBy": ["weekly"], "limitingWindowIds": ["weekly"],
           "pace": {"status": "on_pace", "onPaceWindowIds": ["weekly"],
                    "worstReservePercentPoints": 0.5, "worstReserveWindowId": "weekly"}}
        ]
      }
    },
    {
      "provider": "legacy",
      "label": "Legacy",
      "source": "unavailable",
      "windows": [],
      "state": {"status": "fresh", "stale": false, "sourcesTried": []},
      "quotaSemantics": {
        "status": "known",
        "description": "fixture without pace (older schema shape)",
        "effectiveAvailability": [
          {"scope": "all_models", "status": "known", "effectivePercentRemaining": 30,
           "boundedBy": ["weekly"], "limitingWindowIds": ["weekly"]}
        ]
      }
    }
  ]
}
JSON

cat > "$AUTH_FIXTURE" <<'JSON'
{
  "generatedAt": "2026-01-01T00:00:00Z",
  "schemaVersion": 1,
  "auth": [
    {"provider": "claude", "sources": [
      {"source": "oauth-file", "path": "/tmp/creds.json", "status": "available"},
      {"source": "keychain", "status": "expired"}
    ]},
    {"provider": "codex", "sources": [
      {"source": "cli-rpc", "status": "available"}
    ]}
  ]
}
JSON

# Run the fact tool with the fixture snapshots and echo stdout; stderr goes to
# the file passed as $1. Candidates arrive on stdin.
run_facts() {
  local err=$1
  shift
  "$FACTS" --quota-file "$QUOTA_FIXTURE" --auth-file "$AUTH_FIXTURE" "$@" 2>"$err"
}

# Run with --json, echo stdout, and assert one jq expression over the array.
assert_json_facts() {  # <candidates> <jq-expression> <msg>
  local cand=$1 expr=$2 msg=$3 out err="$TMP_ROOT/json.err"
  out=$(printf '%s' "$cand" | run_facts "$err" --json) || fail "$msg: fm-dispatch-facts --json failed"
  printf '%s' "$out" | jq -e "$expr" >/dev/null 2>&1 \
    || fail "$msg: json facts failed ($expr): $out"
  pass "fm-dispatch-facts: $msg"
}

CLAUDE_CAND='[{"harness":"claude","model":"opus","provider":"claude","effort":"high"}]'

test_named_model_scope_wins() {
  local out err="$TMP_ROOT/t1.err"
  out=$(printf '%s' "$CLAUDE_CAND" | run_facts "$err") || fail "named-model: fm-dispatch-facts failed"
  assert_contains "$out" "model:opus" "named-model: scope column should be the model-scoped entry"
  assert_contains "$out" "mixed" "named-model: pace status should come from the model-scoped entry"
  assert_contains "$out" "oauth-file=available,keychain=expired" \
    "named-model: auth sources should list both per-source statuses"
  assert_contains "$out" "unknowns[0]: auth-status credits" \
    "named-model: unknowns line should name only the absent auth-status and credits"
  assert_contains "$out" "present" "named-model: snapshot column should mark the provider present"
  assert_json_facts "$CLAUDE_CAND" \
    '.[0].scope == "model:opus" and .[0].effectivePercentRemaining == 40 and .[0].paceStatus == "mixed" and .[0].limitingWindowIds == ["model:opus"] and .[0].behindWindowIds == ["model:opus"] and .[0].worstReserveWindowId == "five_hour" and .[0].providerStateStatus == "fresh" and .[0].stale == false and .[0].prepaidCreditsRemaining == "unknown"' \
    "json: named-model scope carries the model-scoped facts"
}

test_provider_level_fallback_scope() {
  local out err="$TMP_ROOT/t2.err" cand='[{"harness":"codex","model":"other-model","provider":"codex"}]'
  out=$(printf '%s' "$cand" | run_facts "$err") || fail "provider-level: fm-dispatch-facts failed"
  assert_contains "$out" "all_models" "provider-level: scope should fall back to the provider-level entry"
  assert_contains "$out" "42 (prepaid)" "provider-level: credits.remaining should pass through labeled (prepaid)"
  assert_contains "$out" "stale (diagnostic only)" "provider-level: a stale provider state should be flagged"
  assert_contains "$out" "on_pace" "provider-level: pace status should come from the provider-level entry"
  assert_contains "$out" "unknowns[0]: effort auth-status" \
    "provider-level: unknowns line should name absent effort and auth-status"
  assert_json_facts "$cand" \
    '.[0].scope == "all_models" and .[0].effectivePercentRemaining == 20 and .[0].onPaceWindowIds == ["weekly"] and .[0].stale == true and .[0].prepaidCreditsRemaining == 42 and .[0].authSources == [{"source": "cli-rpc", "status": "available"}]' \
    "json: provider-level fallback carries the all_models facts"
}

test_provider_missing_from_snapshot() {
  local out err="$TMP_ROOT/t3.err" cand='[{"harness":"pi","model":"grok-4","provider":"nowhere"}]'
  out=$(printf '%s' "$cand" | run_facts "$err") || fail "provider-missing: fm-dispatch-facts failed"
  assert_contains "$out" "provider-not-in-snapshot" \
    "provider-missing: the snapshot marker should be explicit"
  assert_contains "$out" "unknowns[0]: effort scope eff-pct limiting pace worst-pts worst-win ahead behind on-pace unknown-wins state auth-status stale credits auth-sources" \
    "provider-missing: every quota fact should be listed unknown"
  assert_json_facts "$cand" \
    '.[0].providerInSnapshot == false and .[0].scope == "unknown" and .[0].effectivePercentRemaining == "unknown" and .[0].paceStatus == "unknown" and .[0].aheadWindowIds == "unknown" and .[0].stale == "unknown" and .[0].prepaidCreditsRemaining == "unknown" and .[0].authSources == "unknown"' \
    "json: missing provider renders every fact as the literal unknown"
}

test_pace_absent_older_schema() {
  local out err="$TMP_ROOT/t4.err" cand='[{"harness":"old","model":"legacy-model","provider":"legacy"}]'
  out=$(printf '%s' "$cand" | run_facts "$err") || fail "pace-absent: fm-dispatch-facts failed"
  assert_contains "$out" "unknowns[0]: effort pace worst-pts worst-win ahead behind on-pace unknown-wins auth-status credits" \
    "pace-absent: pace facts should be unknown without fabricating a pace status"
  assert_contains "$out" "30" "pace-absent: the known effective percentage should survive"
  assert_json_facts "$cand" \
    '.[0].effectivePercentRemaining == 30 and .[0].limitingWindowIds == ["weekly"] and .[0].paceStatus == "unknown" and .[0].worstReservePercentPoints == "unknown" and .[0].aheadWindowIds == "unknown"' \
    "json: older schema keeps known quota but renders pace as unknown"
}

test_auth_healthy_and_expired_sources() {
  local out err="$TMP_ROOT/t5.err"
  out=$(printf '%s' "$CLAUDE_CAND" | run_facts "$err") || fail "auth-mixed: fm-dispatch-facts failed"
  assert_contains "$out" "oauth-file=available" "auth-mixed: the healthy source status should be listed"
  assert_contains "$out" "keychain=expired" "auth-mixed: the expired source status should be listed"
  assert_json_facts "$CLAUDE_CAND" \
    '.[0].authSources[0].source == "oauth-file" and .[0].authSources[0].status == "available" and .[0].authSources[0].path == "/tmp/creds.json" and .[0].authSources[1].source == "keychain" and .[0].authSources[1].status == "expired"' \
    "json: both per-source statuses survive on the same provider"
}

test_malformed_candidate_refused() {
  local rc out err="$TMP_ROOT/t6.err"

  set +e
  out=$(printf '%s' '[{"harness":"a","model":"m","provider":"p"},{"harness":"b","provider":"p"}]' | run_facts "$err")
  rc=$?
  set -e
  expect_code 2 "$rc" "malformed: missing model should exit 2"
  assert_grep 'candidate 1 missing "model"' "$err" "malformed: refusal should name the missing field and index"

  set +e
  out=$(printf '%s' '[{"model":"m","provider":"p"}]' | run_facts "$err")
  rc=$?
  set -e
  expect_code 2 "$rc" "malformed: missing harness should exit 2"
  assert_grep 'candidate 0 missing "harness"' "$err" "malformed: refusal should name the missing harness"

  set +e
  out=$(printf '%s' '[{"harness":"a","model":"m"}]' | run_facts "$err")
  rc=$?
  set -e
  expect_code 2 "$rc" "malformed: missing provider should exit 2"
  assert_grep 'candidate 0 missing "provider"' "$err" "malformed: refusal should name the missing provider"

  set +e
  out=$(printf '%s' '[{"harness":"a","model":"m","provider":"p","effort":5}]' | run_facts "$err")
  rc=$?
  set -e
  expect_code 2 "$rc" "malformed: non-string effort should exit 2"
  assert_grep 'candidate 0 effort must be a non-empty string' "$err" \
    "malformed: refusal should explain the effort constraint"

  set +e
  out=$(printf '%s' '{"harness":"a","model":"m","provider":"p"}' | run_facts "$err")
  rc=$?
  set -e
  expect_code 2 "$rc" "malformed: non-array input should exit 2"
  assert_grep 'candidates input must be a JSON array' "$err" "malformed: refusal should explain array input"

  set +e
  out=$(printf '%s' 'not json' | run_facts "$err")
  rc=$?
  set -e
  expect_code 2 "$rc" "malformed: invalid JSON input should exit 2"
  assert_grep 'candidates input is not valid JSON' "$err" "malformed: refusal should explain invalid JSON"

  set +e
  out=$(printf '%s' '' | run_facts "$err")
  rc=$?
  set -e
  expect_code 2 "$rc" "malformed: empty stdin should exit 2"
  assert_grep 'no candidates provided on stdin' "$err" "malformed: refusal should explain empty stdin"
  pass "fm-dispatch-facts refuses malformed candidates naming the index"
}

test_input_order_preserved() {
  local out err="$TMP_ROOT/t7.err" \
    cand='[{"harness":"codex","model":"other-model","provider":"codex"},{"harness":"claude","model":"opus","provider":"claude"}]'
  out=$(printf '%s' "$cand" | run_facts "$err") || fail "input-order: fm-dispatch-facts failed"
  first_row=$(printf '%s\n' "$out" | sed -n '2p')
  second_row=$(printf '%s\n' "$out" | sed -n '4p')
  case "$first_row" in
    "0 "*) : ;;
    *) fail "input-order: the first table row should carry index 0: $first_row" ;;
  esac
  case "$second_row" in
    "1 "*) : ;;
    *) fail "input-order: the second table row should carry index 1: $second_row" ;;
  esac
  assert_json_facts "$cand" \
    '.[0].provider == "codex" and .[1].provider == "claude" and .[0].index == 0 and .[1].index == 1' \
    "json: candidate order matches the input order"
}

test_candidates_file_matches_stdin() {
  local out_file out_stdin err="$TMP_ROOT/t8.err" cand="$CLAUDE_CAND"
  printf '%s' "$cand" > "$TMP_ROOT/candidates.json"
  out_file=$("$FACTS" --candidates-file "$TMP_ROOT/candidates.json" \
    --quota-file "$QUOTA_FIXTURE" --auth-file "$AUTH_FIXTURE" 2>"$err") \
    || fail "candidates-file: fm-dispatch-facts failed"
  out_stdin=$(printf '%s' "$cand" | run_facts "$err") || fail "candidates-file: stdin run failed"
  [ "$out_file" = "$out_stdin" ] \
    || fail "candidates-file: file and stdin output differ: $out_file"
  pass "fm-dispatch-facts: --candidates-file and stdin produce identical output"
}

test_help_prints_usage() {
  local out rc
  out=$("$FACTS" --help 2>&1); rc=$?
  expect_code 0 "$rc" "fm-dispatch-facts.sh --help should exit 0"
  assert_contains "$out" "Usage: fm-dispatch-facts.sh" "help should print the usage line"
  assert_contains "$out" "HARD BOUNDARY" "help should document the data-only boundary"
  assert_contains "$out" '{"harness": "claude", "model": "opus", "provider": "claude", "effort": "high"}' \
    "help should document the input schema"
  assert_contains "$out" "auth-sources" "help should document every output column"
  out=$("$FACTS" -h 2>&1); rc=$?
  expect_code 0 "$rc" "fm-dispatch-facts.sh -h should exit 0"
  pass "fm-dispatch-facts: -h/--help prints the header usage and exits 0"
}

test_absent_state_stale_is_unknown_not_healthy() {
  # A provider entry with NO state object has an unknown staleness. The old
  # code defaulted it to "not stale" - a healthy default for an absent fact -
  # and the table's unknown branch for the stale column was unreachable.
  local quota cand out err="$TMP_ROOT/stale-unknown.err"
  quota="$TMP_ROOT/quota-nostate.json"
  printf '%s' '{"providers":[{"provider":"claude","credits":{"remaining":5}}]}' > "$quota"
  cand='[{"harness":"claude","model":"opus","provider":"claude"}]'
  out=$(printf '%s' "$cand" | "$FACTS" --quota-file "$quota" --auth-file "$AUTH_FIXTURE" --json 2>"$err") \
    || fail "stale-unknown: fm-dispatch-facts failed"
  printf '%s' "$out" | jq -e '.[0].stale == "unknown"' >/dev/null \
    || fail "stale-unknown: absent state must render stale as unknown, got: $out"
  out=$(printf '%s' "$cand" | "$FACTS" --quota-file "$quota" --auth-file "$AUTH_FIXTURE" 2>"$err") \
    || fail "stale-unknown: table mode failed"
  printf '%s\n' "$out" | grep -E '^unknowns\[0\]:' | grep -qw stale \
    || fail "stale-unknown: the unknowns line must name stale, got: $out"
  pass "fm-dispatch-facts: a provider without state renders stale as unknown, never healthy"
}

test_auth_source_missing_fields_render_unknown() {
  # An auth source entry missing source or status renders those fields as
  # "unknown". jq's null + "=" concatenation silently rendered a bare "="
  # table cell before, and the JSON leaked nulls where the contract promises
  # "unknown".
  local auth cand out err="$TMP_ROOT/auth-missing.err"
  auth="$TMP_ROOT/auth-badsource.json"
  printf '%s' '{"auth":[{"provider":"claude","sources":[{"path":"/x/creds"}]}]}' > "$auth"
  cand='[{"harness":"claude","model":"opus","provider":"claude"}]'
  out=$(printf '%s' "$cand" | "$FACTS" --quota-file "$QUOTA_FIXTURE" --auth-file "$auth" --json 2>"$err") \
    || fail "auth-missing: fm-dispatch-facts failed"
  printf '%s' "$out" | jq -e '.[0].authSources[0].source == "unknown" and .[0].authSources[0].status == "unknown" and .[0].authSources[0].path == "/x/creds"' >/dev/null \
    || fail "auth-missing: missing source fields must render unknown, got: $out"
  out=$(printf '%s' "$cand" | "$FACTS" --quota-file "$QUOTA_FIXTURE" --auth-file "$auth" 2>"$err") \
    || fail "auth-missing: table mode failed"
  printf '%s\n' "$out" | grep -q 'unknown=unknown' \
    || fail "auth-missing: the table cell must show unknown=unknown, got: $out"
  pass "fm-dispatch-facts: auth sources with missing fields render unknown, never a bare ="
}

test_fixture_mode_never_launches_vendor_cli() {
  local fakebin out err="$TMP_ROOT/t9.err"
  fakebin=$(fm_fakebin "$TMP_ROOT/no-vendor-cli")
  # An empty fakebin shadows nothing but also provides no quota-axi, so a
  # live snapshot attempt would fail loudly instead of silently passing.
  out=$(printf '%s' "$CLAUDE_CAND" | PATH="$fakebin:$PATH" run_facts "$err") \
    || fail "fixture-mode: fm-dispatch-facts should not need quota-axi when fixtures are given"
  assert_contains "$out" "model:opus" "fixture-mode: fixture facts should still render"
  pass "fm-dispatch-facts: fixture mode assembles facts without launching any vendor CLI"
}

test_named_model_scope_wins
test_provider_level_fallback_scope
test_provider_missing_from_snapshot
test_pace_absent_older_schema
test_auth_healthy_and_expired_sources
test_malformed_candidate_refused
test_input_order_preserved
test_candidates_file_matches_stdin
test_help_prints_usage
test_absent_state_stale_is_unknown_not_healthy
test_auth_source_missing_fields_render_unknown
test_fixture_mode_never_launches_vendor_cli
