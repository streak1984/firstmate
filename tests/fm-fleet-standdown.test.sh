#!/usr/bin/env bash
# Behavior tests for the two-phase, byte-preserving subordinate fleet stand-down.
# The suite drives the public command and the teardown owner's public check-only
# interface; it never asserts implementation-source bytes.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmstanddown fmstanddown@example.invalid

STANDDOWN="$ROOT/bin/fm-fleet-standdown.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-standdown)

tree_bytes() {
  local root=$1
  (
    cd "$root" || exit 1
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
  )
}

assert_tree_bytes_equal() {
  local before=$1 root=$2 message=$3 after
  after=$(tree_bytes "$root")
  [ "$before" = "$after" ] || fail "$message"
}

test_teardown_check_only_refuses_dirty_without_mutation() {
  local case_dir="$TMP_ROOT/teardown-dirty" home="$TMP_ROOT/teardown-dirty/home"
  local project="$TMP_ROOT/teardown-dirty/project" wt="$TMP_ROOT/teardown-dirty/wt"
  local before out rc
  mkdir -p "$home/state" "$home/data" "$home/config"
  fm_git_worktree "$project" "$wt" fm/crew-dirty
  printf 'dirty work\n' >> "$wt/README.md"
  fm_write_meta "$home/state/crew-dirty.meta" \
    'window=firstmate:fm-crew-dirty' \
    'endpoint_task_id=crew-dirty' \
    "worktree=$wt" \
    "project=$project" \
    'harness=claude' \
    'kind=ship' \
    'mode=local-only'
  before=$(tree_bytes "$case_dir")
  set +e
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$TEARDOWN" crew-dirty --check-only 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "check-only must refuse an uncommitted worktree"
  assert_contains "$out" "REFUSED: local-only worktree $wt has work not yet merged" \
    "check-only refusal did not use teardown's landed-work owner"
  assert_contains "$out" "uncommitted changes present" \
    "check-only refusal did not identify the dirty bytes"
  assert_not_contains "$out" "teardown crew-dirty complete" \
    "check-only crossed into teardown mutation"
  assert_tree_bytes_equal "$before" "$case_dir" \
    "check-only changed the home, clone, worktree, or task state"
  pass "teardown check-only names dirty work and preserves every inspected byte"
}

test_teardown_check_only_proves_landed_content_without_fetch() {
  local case_dir="$TMP_ROOT/teardown-local-proof" home="$TMP_ROOT/teardown-local-proof/home"
  local project="$TMP_ROOT/teardown-local-proof/project" wt="$TMP_ROOT/teardown-local-proof/wt"
  local fakebin="$TMP_ROOT/teardown-local-proof/fakebin" git_log real_git before out rc
  git_log="$case_dir/git-fetch.log"
  mkdir -p "$home/state" "$home/data" "$home/config" "$fakebin"
  fm_git_worktree "$project" "$wt" fm/crew-landed
  printf 'same landed content\n' > "$wt/landed.txt"
  git -C "$wt" add landed.txt
  git -C "$wt" commit -qm 'crew content'
  printf 'same landed content\n' > "$project/landed.txt"
  git -C "$project" add landed.txt
  git -C "$project" commit -qm 'landed content'
  git -C "$project" remote set-url origin "$project" 2>/dev/null \
    || git -C "$project" remote add origin "$project"
  git -C "$project" update-ref refs/remotes/origin/main refs/heads/main
  git -C "$project" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  fm_write_meta "$home/state/crew-landed.meta" \
    'window=firstmate:fm-crew-landed' \
    'endpoint_task_id=crew-landed' \
    "worktree=$wt" \
    "project=$project" \
    'harness=claude' \
    'kind=ship' \
    'mode=no-mistakes'
  real_git=$(command -v git)
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = fetch ]; then
    printf 'fetch attempted\n' >> "$FM_TEST_GIT_LOG"
  fi
done
exec "$FM_TEST_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  before=$(tree_bytes "$case_dir")
  set +e
  out=$(PATH="$fakebin:$PATH" FM_TEST_REAL_GIT="$real_git" FM_TEST_GIT_LOG="$git_log" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$TEARDOWN" crew-landed --check-only 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "check-only should prove equivalent content from current local refs"
  assert_contains "$out" "teardown check crew-landed safe: no teardown action performed" \
    "check-only did not report its read-only success"
  assert_absent "$git_log" "check-only ran git fetch inside the project"
  assert_tree_bytes_equal "$before" "$case_dir" \
    "local landed-content proof changed a clone, worktree, ref, or home byte"
  pass "teardown check-only uses local refs without fetching or changing project bytes"
}

make_fake_root() {
  local case_dir=$1
  local fake_root="$case_dir/fake-root" fake_bin="$case_dir/fake-root/bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/fm-gate-refuse-lib.sh" <<'SH'
fm_refuse_if_gate_agent() { return 0; }
SH
  cat > "$fake_bin/fm-session-lock-lib.sh" <<'SH'
fm_session_lock_owned_by_self() { return 0; }
SH
  cat > "$fake_bin/fm-backend.sh" <<'SH'
fm_meta_get() {
  sed -n "s/^$2=//p" "$1" | tail -1
}
fm_backend_validate_task_endpoint() {
  local meta=$1 id=$2 target binding
  [ -f "$meta" ] || return 1
  binding=$(fm_meta_get "$meta" endpoint_task_id)
  [ "$binding" = "$id" ] || return 1
  target=$(fm_meta_get "$meta" window)
  [ -n "$target" ] || return 1
  FM_BACKEND_VALIDATED_BACKEND=$(fm_meta_get "$meta" backend)
  [ -n "$FM_BACKEND_VALIDATED_BACKEND" ] || FM_BACKEND_VALIDATED_BACKEND=tmux
  FM_BACKEND_VALIDATED_TARGET=$target
}
fm_backend_agent_state() {
  local target=$2 key
  key=$(printf '%s' "$target" | tr '/:' '__')
  cat "$FM_TEST_CONTROL/$key.agent"
}
fm_backend_send_text_submit() {
  local backend=$1 target=$2 text=$3 key
  key=$(printf '%s' "$target" | tr '/:' '__')
  printf '%s|%s|%s\n' "$backend" "$target" "$text" >> "$FM_TEST_CONTROL/send.log"
  if [ "${FM_TEST_KEEP_AGENT_ALIVE:-0}" != 1 ]; then
    printf 'dead\n' > "$FM_TEST_CONTROL/$key.agent"
  fi
  printf ''
}
SH
  cat > "$fake_bin/fm-wake-lib.sh" <<'SH'
fm_watcher_healthy() {
  local home id state
  home=$4
  id=$(cat "$home/.fm-secondmate-home" 2>/dev/null || true)
  state=$(cat "$FM_TEST_CONTROL/$id.watcher" 2>/dev/null || true)
  [ "$state" = live ] || return 1
  FM_WATCHER_HEALTHY_PID=4242
}
fm_pid_alive() { return 1; }
fm_watcher_lock_matches_pid() { return 1; }
SH
  cat > "$fake_bin/fm-supervision-lib.sh" <<'SH'
fm_supervision_status() {
  local state=$1 meta
  FM_SUP_IN_FLIGHT=0
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done
  FM_SUP_NEEDED=false
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] || [ -f "$state/x-watch.check.sh" ]; then
    FM_SUP_NEEDED=true
  fi
}
SH
  cat > "$fake_bin/fm-home-seed.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = validate ] || exit 2
exit 0
SH
  cat > "$fake_bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
cat "$FM_TEST_SNAPSHOT"
SH
  cat > "$fake_bin/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
id=${1:-}
if [ "$id" = "${FM_TEST_UNLANDED_ID:-}" ]; then
  printf 'REFUSED: worktree %s has uncommitted changes.\n' "${FM_TEST_UNLANDED_PATH:-unknown}" >&2
  exit 1
fi
printf 'teardown check %s safe: no teardown action performed\n' "$id"
SH
  cat > "$fake_bin/fm-lock.sh" <<'SH'
#!/usr/bin/env bash
id=$(cat "$FM_HOME/.fm-secondmate-home" 2>/dev/null || true)
if [ -z "$id" ]; then
  printf 'lock: free\n'
  exit 0
fi
key=$(printf 'fleet:fm-%s' "$id" | tr '/:' '__')
state=$(cat "$FM_TEST_CONTROL/$key.agent" 2>/dev/null || printf 'dead')
if [ "$state" = alive ]; then
  printf 'lock: held by live harness pid 42\n'
else
  printf 'lock: stale (pid 42 dead or not a harness)\n'
fi
SH
  ln -s "$ROOT/bin/fm-harness.sh" "$fake_bin/fm-harness.sh"
  ln -s "$ROOT/bin/fm-pr-lib.sh" "$fake_bin/fm-pr-lib.sh"
  chmod +x "$fake_bin/fm-home-seed.sh" "$fake_bin/fm-fleet-snapshot.sh" \
    "$fake_bin/fm-teardown.sh" "$fake_bin/fm-lock.sh"
  printf '%s\n' "$fake_root"
}

make_main_home() {
  local home=$1
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '12345\n' > "$home/state/.lock"
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  printf '# Secondmates\n' > "$home/data/secondmates.md"
  printf 'primary clone bytes\n' > "$home/projects/primary-clone.dat"
}

make_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects/alpha"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '42\n' > "$home/state/.lock"
  printf '# Backlog\n\n## Queued\n- [ ] future-work queued safely\n' > "$home/data/backlog.md"
  printf 'captain preferences\n' > "$home/data/captain.md"
  printf 'only-copy datastore bytes\n' > "$home/data/only-copy.db"
  printf 'clone bytes\n' > "$home/projects/alpha/content.dat"
}

write_secondmate_meta() {
  local main=$1 home=$2 id=$3 backend=${4:-tmux} harness=${5:-claude}
  fm_write_meta "$main/state/$id.meta" \
    "window=fleet:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$home" \
    "project=$home" \
    "harness=$harness" \
    "backend=$backend" \
    'kind=secondmate' \
    'mode=secondmate' \
    "home=$home"
}

empty_snapshot() {
  jq -n '{
    schema:"fm-fleet-snapshot.v1",
    tasks:[],
    main_inventory:{valid:true,reason:null},
    secondmate_current:{
      registry:{complete:true},records:[],total:0,shown:0,truncated:false
    }
  }'
}

idle_secondmate_snapshot() {
  local main=$1 home=$2 id=$3 state=${4:-no_active_work} source=${5:-backlog}
  local decisions='[]'
  if [ "$state" = captain_decision ]; then
    decisions=$(jq -n --arg source "$source" '[{id:"choice",key:"choice",verb:"captain-hold",summary:"Choose",reason:"Needed",source:$source}]')
  fi
  jq -n --arg id "$id" --arg home "$home" --arg meta "$main/state/$id.meta" \
    --arg state "$state" --argjson decisions "$decisions" '{
      schema:"fm-fleet-snapshot.v1",
      tasks:[{
        id:$id,kind:"secondmate",harness:"claude",backend:"tmux",
        paths:{meta:{path:$meta}},endpoint:{agent_alive:"alive",exists:true}
      }],
      main_inventory:{valid:true,reason:null},
      secondmate_current:{
        registry:{complete:true},total:1,shown:1,truncated:false,
        records:[{
          id:$id,home:$home,current:{state:$state,reason:null},
          provenance:{selected:"structured-home",summary_valid:true},
          contradiction:false,active_children:[],decisions_open:$decisions,
          holds:[],queued:[],omitted:[],counts:{endpoints:0}
        }]
      }
    }'
}

active_secondmate_snapshot() {
  local main=$1 home=$2 id=$3 child=$4
  jq -n --arg id "$id" --arg child "$child" --arg home "$home" \
    --arg meta "$main/state/$id.meta" '{
      schema:"fm-fleet-snapshot.v1",
      tasks:[{
        id:$id,kind:"secondmate",harness:"claude",backend:"tmux",
        paths:{meta:{path:$meta}},endpoint:{agent_alive:"alive",exists:true}
      }],
      main_inventory:{valid:true,reason:null},
      secondmate_current:{
        registry:{complete:true},total:1,shown:1,truncated:false,
        records:[{
          id:$id,home:$home,current:{state:"active_child_work",reason:null},
          provenance:{selected:"structured-home",summary_valid:true},
          contradiction:false,
          active_children:[{id:$child,state:"working",source:"pane"}],
          decisions_open:[],holds:[],queued:[],omitted:[],counts:{endpoints:1}
        }]
      }
    }'
}

ordinary_crew_snapshot() {
  local main=$1 id=$2
  jq -n --arg id "$id" --arg meta "$main/state/$id.meta" '{
    schema:"fm-fleet-snapshot.v1",
    tasks:[{id:$id,kind:"ship",paths:{meta:{path:$meta}}}],
    main_inventory:{valid:true,reason:null},
    secondmate_current:{
      registry:{complete:true},records:[],total:0,shown:0,truncated:false
    }
  }'
}

run_standdown() {
  local fake_root=$1 main=$2 snapshot=$3 control=$4
  shift 4
  FM_HOME="$main" FM_ROOT_OVERRIDE="$fake_root" FM_TEST_SNAPSHOT="$snapshot" \
    FM_TEST_CONTROL="$control" FM_STANDDOWN_WAIT_SECS=2 "$@" "$STANDDOWN"
}

test_unlanded_crewmate_refuses_without_action() {
  local case_dir="$TMP_ROOT/unlanded" main fake_root control snapshot before out rc
  main="$case_dir/main"
  control="$case_dir/control"
  snapshot="$control/snapshot.json"
  mkdir -p "$control"
  make_main_home "$main"
  fake_root=$(make_fake_root "$case_dir")
  fm_write_meta "$main/state/crew-a.meta" \
    'window=fleet:fm-crew-a' 'endpoint_task_id=crew-a' \
    'worktree=/safe/crew-a' 'project=/safe/project-a' \
    'harness=claude' 'kind=ship' 'mode=no-mistakes'
  ordinary_crew_snapshot "$main" crew-a > "$snapshot"
  before=$(tree_bytes "$main")
  set +e
  out=$(run_standdown "$fake_root" "$main" "$snapshot" "$control" \
    env FM_TEST_UNLANDED_ID=crew-a FM_TEST_UNLANDED_PATH=/safe/crew-a 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "unlanded crewmate must refuse fleet stand-down"
  assert_contains "$out" "crewmate crew-a failed the landed-work preflight" \
    "refusal did not name the blocking crewmate"
  assert_contains "$out" "/safe/crew-a has uncommitted changes" \
    "refusal did not name the blocking worktree"
  assert_contains "$out" "no agent received an exit command" \
    "refusal did not state the no-action guarantee"
  assert_absent "$control/send.log" "refusal sent an exit command"
  assert_tree_bytes_equal "$before" "$main" "refusal changed the primary home"
  pass "unlanded crewmate refusal is loud, named, nonzero, and action-free"
}

test_undrained_wake_queue_refuses_without_action() {
  local case_dir="$TMP_ROOT/wake-queue" main control snapshot fake_root before out rc
  main="$case_dir/main"
  control="$case_dir/control"
  snapshot="$control/snapshot.json"
  mkdir -p "$control"
  make_main_home "$main"
  printf '1776038400\t1\tsignal\tcrew-a\tworking: still active\n' > "$main/state/.wake-queue"
  empty_snapshot > "$snapshot"
  fake_root=$(make_fake_root "$case_dir")
  before=$(tree_bytes "$main")
  set +e
  out=$(run_standdown "$fake_root" "$main" "$snapshot" "$control" env 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "an undrained wake queue must refuse stand-down"
  assert_contains "$out" "durable wake queue has 1 undrained record(s)" \
    "wake refusal did not identify the unhandled queue"
  assert_contains "$out" "handle them through fm-wake-drain.sh" \
    "wake refusal did not name the queue owner"
  assert_absent "$control/send.log" "wake refusal sent an exit command"
  assert_tree_bytes_equal "$before" "$main" \
    "wake refusal changed the queue or another primary-home byte"
  pass "undrained wake events refuse without changing or hiding the queue"
}

test_idle_secondmate_stops_and_second_run_is_idempotent() {
  local case_dir="$TMP_ROOT/idle" main home control snapshot fake_root key
  local before_main before_home out_first out_second rc lines
  main="$case_dir/main"
  home="$case_dir/secondmate"
  control="$case_dir/control"
  snapshot="$control/snapshot.json"
  mkdir -p "$control"
  make_main_home "$main"
  make_secondmate_home "$home" sm-one
  write_secondmate_meta "$main" "$home" sm-one
  printf -- '- sm-one - idle domain (home: %s; scope: tests; projects: alpha; added 2026-08-13)\n' "$home" \
    >> "$main/data/secondmates.md"
  idle_secondmate_snapshot "$main" "$home" sm-one > "$snapshot"
  key=$(printf 'fleet:fm-sm-one' | tr '/:' '__')
  printf 'alive\n' > "$control/$key.agent"
  fake_root=$(make_fake_root "$case_dir")
  before_main=$(tree_bytes "$main")
  before_home=$(tree_bytes "$home")

  set +e
  out_first=$(run_standdown "$fake_root" "$main" "$snapshot" "$control" env 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "idle secondmate stand-down should succeed"
  assert_contains "$out_first" "stopped secondmate sm-one cleanly" \
    "successful stand-down did not name the stopped secondmate"
  assert_contains "$out_first" "agent dead" \
    "successful stand-down did not distinguish the surviving dead-shell endpoint"
  assert_contains "$out_first" "left alone: every home, backlog, registry entry" \
    "successful stand-down did not distinguish preserved state"
  assert_contains "$out_first" "not performed: no agent, watcher, home, backend container, or terminal layer was restarted" \
    "successful stand-down did not state the no-restart boundary"
  [ "$(cat "$control/send.log")" = 'tmux|fleet:fm-sm-one|/exit' ] \
    || fail "stand-down did not submit one bare unmarked harness exit command"
  [ "$(cat "$control/$key.agent")" = dead ] \
    || fail "the surviving endpoint did not positively classify as an agent-free shell"
  assert_tree_bytes_equal "$before_main" "$main" \
    "stand-down changed primary home, registry, or metadata bytes"
  assert_tree_bytes_equal "$before_home" "$home" \
    "stand-down changed secondmate home, backlog, clone, or data-store bytes"

  set +e
  out_second=$(run_standdown "$fake_root" "$main" "$snapshot" "$control" env 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "second stand-down run should succeed"
  assert_contains "$out_second" "already dormant secondmate sm-one" \
    "second run did not recognize the dormant secondmate"
  lines=$(wc -l < "$control/send.log" | tr -d ' ')
  [ "$lines" -eq 1 ] || fail "second run sent a duplicate exit command"
  assert_tree_bytes_equal "$before_main" "$main" \
    "second run changed primary home bytes"
  assert_tree_bytes_equal "$before_home" "$home" \
    "second run changed secondmate home bytes"
  pass "idle secondmate stops with dead-shell proof and a second run is byte-identical"
}

test_self_reported_exit_with_live_agent_refuses_completion() {
  local case_dir="$TMP_ROOT/live-after-exit" main home control snapshot fake_root key
  local before_main before_home out rc sends
  main="$case_dir/main"
  home="$case_dir/secondmate"
  control="$case_dir/control"
  snapshot="$control/snapshot.json"
  mkdir -p "$control"
  make_main_home "$main"
  make_secondmate_home "$home" sm-stubborn
  write_secondmate_meta "$main" "$home" sm-stubborn
  idle_secondmate_snapshot "$main" "$home" sm-stubborn > "$snapshot"
  key=$(printf 'fleet:fm-sm-stubborn' | tr '/:' '__')
  printf 'alive\n' > "$control/$key.agent"
  fake_root=$(make_fake_root "$case_dir")
  before_main=$(tree_bytes "$main")
  before_home=$(tree_bytes "$home")

  set +e
  out=$(run_standdown "$fake_root" "$main" "$snapshot" "$control" \
    env FM_TEST_KEEP_AGENT_ALIVE=1 FM_STANDDOWN_WAIT_SECS=1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "a still-live agent after exit submission must refuse completion"
  assert_contains "$out" "secondmate sm-stubborn at fleet:fm-sm-stubborn did not prove both agent exit and session-lock release" \
    "post-exit refusal did not name the missing positive proof"
  assert_contains "$out" "after 1 bounded clean-exit attempt" \
    "post-exit refusal did not state its finite attempt bound"
  assert_contains "$out" "agent=alive" \
    "post-exit refusal did not report the live backend inventory result"
  assert_contains "$out" "captain decision required" \
    "stubborn live agent was not handed back to the captain"
  assert_contains "$out" "no interrupt, force-kill, endpoint close, or terminal restart was attempted" \
    "stubborn live agent refusal did not state the non-destructive boundary"
  assert_not_contains "$out" "subordinate fleet complete" \
    "a self-reported exit was incorrectly relayed as completed"
  assert_contains "$(cat "$control/send.log")" 'tmux|fleet:fm-sm-stubborn|/exit' \
    "the live-agent case never exercised post-exit reconciliation"
  sends=$(wc -l < "$control/send.log" | tr -d ' ')
  [ "$sends" -eq 1 ] \
    || fail "stubborn live agent received $sends exit attempts instead of the bounded one"
  assert_tree_bytes_equal "$before_main" "$main" \
    "live-agent refusal changed primary-home bytes"
  assert_tree_bytes_equal "$before_home" "$home" \
    "live-agent refusal changed secondmate-home bytes"
  pass "an exit assertion cannot outrank positive live-agent inventory"
}

test_ambiguous_or_unreadable_endpoint_refuses_before_exit() {
  local state case_dir main home control snapshot fake_root key out rc
  for state in ambiguous unreadable; do
    case_dir="$TMP_ROOT/$state-endpoint"
    main="$case_dir/main"
    home="$case_dir/secondmate"
    control="$case_dir/control"
    snapshot="$control/snapshot.json"
    mkdir -p "$control"
    make_main_home "$main"
    make_secondmate_home "$home" "sm-$state"
    write_secondmate_meta "$main" "$home" "sm-$state"
    idle_secondmate_snapshot "$main" "$home" "sm-$state" > "$snapshot"
    key=$(printf 'fleet:fm-sm-%s' "$state" | tr '/:' '__')
    printf '%s\n' "$state" > "$control/$key.agent"
    fake_root=$(make_fake_root "$case_dir")
    set +e
    out=$(run_standdown "$fake_root" "$main" "$snapshot" "$control" env 2>&1)
    rc=$?
    set -e
    expect_code 1 "$rc" "$state endpoint state must refuse stand-down"
    assert_contains "$out" "agent state is $state" \
      "$state refusal did not name the unreadable backend evidence"
    assert_absent "$control/send.log" "$state endpoint received an exit command"
  done
  pass "ambiguous and unreadable endpoints fail closed before any exit"
}

test_active_secondmate_refuses_before_exit() {
  local case_dir="$TMP_ROOT/active" main home control snapshot fake_root key before out rc
  main="$case_dir/main"
  home="$case_dir/secondmate"
  control="$case_dir/control"
  snapshot="$control/snapshot.json"
  mkdir -p "$control"
  make_main_home "$main"
  make_secondmate_home "$home" sm-busy
  write_secondmate_meta "$main" "$home" sm-busy
  fm_write_meta "$home/state/child-work.meta" \
    'window=child:fm-child-work' 'endpoint_task_id=child-work' \
    'worktree=/safe/child-work' 'project=/safe/child-project' \
    'harness=claude' 'kind=ship' 'mode=no-mistakes'
  active_secondmate_snapshot "$main" "$home" sm-busy child-work > "$snapshot"
  key=$(printf 'fleet:fm-sm-busy' | tr '/:' '__')
  printf 'alive\n' > "$control/$key.agent"
  fake_root=$(make_fake_root "$case_dir")
  before=$(tree_bytes "$case_dir/main")$(tree_bytes "$case_dir/secondmate")
  set +e
  out=$(run_standdown "$fake_root" "$main" "$snapshot" "$control" env 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "active secondmate must refuse stand-down"
  assert_contains "$out" "secondmate sm-busy reports work in flight: child-work" \
    "active-home refusal did not name the secondmate and child"
  assert_contains "$out" "crewmate child-work remains recorded" \
    "active-home refusal did not name the child metadata gate"
  assert_absent "$control/send.log" "active-home refusal sent an exit command"
  [ "$before" = "$(tree_bytes "$case_dir/main")$(tree_bytes "$case_dir/secondmate")" ] \
    || fail "active-home refusal changed persistent fleet bytes"
  pass "secondmate work in flight refuses before any exit command"
}

test_stale_metadata_keeps_legitimate_watcher_and_refuses_project_writes() {
  local case_dir="$TMP_ROOT/stale-metadata" main home control snapshot fake_root key
  local before out rc
  main="$case_dir/main"
  home="$case_dir/secondmate"
  control="$case_dir/control"
  snapshot="$control/snapshot.json"
  mkdir -p "$control"
  make_main_home "$main"
  make_secondmate_home "$home" sm-stale
  write_secondmate_meta "$main" "$home" sm-stale
  fm_write_meta "$home/state/stale-child.meta" \
    'window=child:fm-stale-child' 'endpoint_task_id=stale-child' \
    'worktree=/safe/stale-child' 'project=/safe/stale-project' \
    'harness=claude' 'kind=ship' 'mode=no-mistakes'
  idle_secondmate_snapshot "$main" "$home" sm-stale \
    | jq '.secondmate_current.records[0].counts.endpoints = 1' > "$snapshot"
  key=$(printf 'fleet:fm-sm-stale' | tr '/:' '__')
  printf 'alive\n' > "$control/$key.agent"
  printf 'live\n' > "$control/sm-stale.watcher"
  fake_root=$(make_fake_root "$case_dir")
  before=$(tree_bytes "$main")$(tree_bytes "$home")

  set +e
  out=$(run_standdown "$fake_root" "$main" "$snapshot" "$control" env 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "stale task metadata with a legitimate watcher must refuse stand-down"
  assert_contains "$out" "secondmate sm-stale still has 1 recorded crewmate task(s)" \
    "stale metadata refusal did not name the authoritative task record"
  assert_contains "$out" "still requires home-scoped supervision for 1 recorded task(s)" \
    "stale metadata refusal did not classify the watcher as legitimate"
  assert_contains "$out" "legitimate supervision, not a leak" \
    "legitimate watcher was mislabeled as leaked"
  assert_contains "$out" "without writing into a project, force-cleaning metadata, or killing the watcher" \
    "stale bookkeeping refusal did not state its non-mutating boundary"
  assert_absent "$control/send.log" "legitimately supervising watcher received an exit command"
  [ "$before" = "$(tree_bytes "$main")$(tree_bytes "$home")" ] \
    || fail "stale metadata reconciliation changed a home, project, or task byte"
  pass "stale metadata keeps its legitimate watcher and receives no project repair"
}

test_unneeded_live_watcher_is_a_named_leak_and_not_killed() {
  local case_dir="$TMP_ROOT/leaked-watcher" main home control snapshot fake_root key out rc
  main="$case_dir/main"
  home="$case_dir/secondmate"
  control="$case_dir/control"
  snapshot="$control/snapshot.json"
  mkdir -p "$control"
  make_main_home "$main"
  make_secondmate_home "$home" sm-leak
  write_secondmate_meta "$main" "$home" sm-leak
  idle_secondmate_snapshot "$main" "$home" sm-leak > "$snapshot"
  key=$(printf 'fleet:fm-sm-leak' | tr '/:' '__')
  printf 'alive\n' > "$control/$key.agent"
  printf 'live\n' > "$control/sm-leak.watcher"
  fake_root=$(make_fake_root "$case_dir")

  set +e
  out=$(run_standdown "$fake_root" "$main" "$snapshot" "$control" env 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "an unneeded live watcher must refuse dormant proof"
  assert_contains "$out" "live home-scoped watcher despite no supervision need" \
    "unneeded watcher was not distinguished from legitimate supervision"
  assert_contains "$out" "treat it as a leak" \
    "unneeded watcher was not named as leaked"
  assert_contains "$out" "No watcher was signaled or killed" \
    "leaked-watcher refusal did not preserve the non-destructive boundary"
  assert_absent "$control/send.log" "leaked-watcher refusal sent an agent exit command"
  pass "an unneeded watcher is named as leaked and left to its lifecycle owner"
}

test_status_only_captain_gate_refuses() {
  local case_dir="$TMP_ROOT/status-gate" main home control snapshot fake_root key out rc
  main="$case_dir/main"
  home="$case_dir/secondmate"
  control="$case_dir/control"
  snapshot="$control/snapshot.json"
  mkdir -p "$control"
  make_main_home "$main"
  make_secondmate_home "$home" sm-gate
  write_secondmate_meta "$main" "$home" sm-gate
  idle_secondmate_snapshot "$main" "$home" sm-gate captain_decision status > "$snapshot"
  key=$(printf 'fleet:fm-sm-gate' | tr '/:' '__')
  printf 'alive\n' > "$control/$key.agent"
  fake_root=$(make_fake_root "$case_dir")
  set +e
  out=$(run_standdown "$fake_root" "$main" "$snapshot" "$control" env 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "status-only captain gate must refuse stand-down"
  assert_contains "$out" "secondmate sm-gate has captain-gated state not yet recorded in its backlog: decision choice" \
    "captain-gate refusal did not name the missing durable backlog record"
  assert_absent "$control/send.log" "captain-gate refusal sent an exit command"
  pass "captain-gated state must be durable in the owning backlog"
}

test_empty_fleet_succeeds_without_action() {
  local case_dir="$TMP_ROOT/empty" main control snapshot fake_root before out rc
  main="$case_dir/main"
  control="$case_dir/control"
  snapshot="$control/snapshot.json"
  mkdir -p "$control"
  make_main_home "$main"
  empty_snapshot > "$snapshot"
  fake_root=$(make_fake_root "$case_dir")
  before=$(tree_bytes "$main")
  set +e
  out=$(run_standdown "$fake_root" "$main" "$snapshot" "$control" env 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "empty fleet stand-down should succeed"
  assert_contains "$out" "subordinate fleet already empty; nothing to stop" \
    "empty fleet did not report its no-op"
  assert_contains "$out" "invoking firstmate session and its live session lock" \
    "empty fleet did not state the primary-session design boundary"
  assert_absent "$control/send.log" "empty fleet sent an exit command"
  assert_tree_bytes_equal "$before" "$main" "empty fleet run changed home bytes"
  pass "empty fleet is a successful, explicit, byte-identical no-op"
}

test_valid_secondmate_id_passes_the_shared_path_safety_check() {
  local case_dir="$TMP_ROOT/id-safety" main home control snapshot fake_root key out rc
  main="$case_dir/main"
  home="$case_dir/secondmate"
  control="$case_dir/control"
  snapshot="$control/snapshot.json"
  mkdir -p "$control"
  make_main_home "$main"
  make_secondmate_home "$home" sm-safe.id-1
  write_secondmate_meta "$main" "$home" sm-safe.id-1
  idle_secondmate_snapshot "$main" "$home" sm-safe.id-1 > "$snapshot"
  key=$(printf 'fleet:fm-sm-safe.id-1' | tr '/:' '__')
  printf 'alive\n' > "$control/$key.agent"
  fake_root=$(make_fake_root "$case_dir")
  set +e
  out=$(run_standdown "$fake_root" "$main" "$snapshot" "$control" env 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "a valid secondmate id must pass the shared path-safety check"
  assert_not_contains "$out" "unsafe secondmate id" \
    "a valid id was refused as unsafe, so the safety helper did not resolve"
  assert_not_contains "$out" "command not found" \
    "stand-down called a safety function no sourced library provides"
  assert_contains "$out" "stopped secondmate sm-safe.id-1 cleanly" \
    "the valid-id fleet did not stand down"
  pass "a valid id resolves the shared path-safety owner instead of a false refusal"
}

test_unsafe_secondmate_id_is_refused_by_name() {
  local case_dir="$TMP_ROOT/id-unsafe" main home control snapshot fake_root out rc
  main="$case_dir/main"
  home="$case_dir/secondmate"
  control="$case_dir/control"
  snapshot="$control/snapshot.json"
  mkdir -p "$control"
  make_main_home "$main"
  make_secondmate_home "$home" sm-evil
  idle_secondmate_snapshot "$main" "$home" '../evil' > "$snapshot"
  fake_root=$(make_fake_root "$case_dir")
  set +e
  out=$(run_standdown "$fake_root" "$main" "$snapshot" "$control" env 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "a path-unsafe secondmate id must refuse stand-down"
  assert_contains "$out" "unsafe secondmate id in fleet snapshot: ../evil" \
    "the unsafe-id refusal did not name the offending id"
  assert_not_contains "$out" "command not found" \
    "the unsafe-id check ran without its safety function resolved"
  assert_absent "$control/send.log" "an unsafe-id fleet received an exit command"
  pass "a genuinely unsafe id is still refused through the real safety owner"
}

test_harness_exit_command_matrix() {
  local harness expected got
  while IFS='|' read -r harness expected; do
    got=$("$ROOT/bin/fm-harness.sh" exit-command "$harness") \
      || fail "exit-command rejected supported harness $harness"
    [ "$got" = "$expected" ] \
      || fail "exit-command mismatch for $harness: expected $expected, got $got"
  done <<'EOF'
claude|/exit
codex|/quit
opencode|/exit
pi|/quit
pi-signed|/quit
grok|/exit
kimi|/exit
EOF
  if "$ROOT/bin/fm-harness.sh" exit-command unknown >/dev/null 2>&1; then
    fail "exit-command accepted an unverified harness"
  fi
  pass "one executable owner covers every verified harness exit command"
}

test_teardown_check_only_refuses_dirty_without_mutation
test_teardown_check_only_proves_landed_content_without_fetch
test_unlanded_crewmate_refuses_without_action
test_undrained_wake_queue_refuses_without_action
test_idle_secondmate_stops_and_second_run_is_idempotent
test_self_reported_exit_with_live_agent_refuses_completion
test_ambiguous_or_unreadable_endpoint_refuses_before_exit
test_active_secondmate_refuses_before_exit
test_stale_metadata_keeps_legitimate_watcher_and_refuses_project_writes
test_unneeded_live_watcher_is_a_named_leak_and_not_killed
test_status_only_captain_gate_refuses
test_empty_fleet_succeeds_without_action
test_valid_secondmate_id_passes_the_shared_path_safety_check
test_unsafe_secondmate_id_is_refused_by_name
test_harness_exit_command_matrix

echo "all fleet stand-down cases passed"
