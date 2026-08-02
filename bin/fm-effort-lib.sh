#!/usr/bin/env bash
# fm-effort-lib.sh - single executable owner of the per-harness reasoning-effort
# vocabulary firstmate accepts at launch.
#
# This list used to live as independent copies in bin/fm-spawn.sh (flag emission)
# and bin/fm-bootstrap.sh (crew-dispatch validation), and the copies drifted:
# codex max was verified and added to one place while the bootstrap validator
# kept rejecting it. Both consumers now read this lib, so an effort-support
# change lands in exactly one place.
#
# Consumers:
#   bin/fm-spawn.sh      gates per-harness effort flag emission on fm_effort_levels
#   bin/fm-bootstrap.sh  validates crew-dispatch profiles against fm_effort_levels_json
# The launch-profile table in .agents/skills/harness-adapters/SKILL.md documents
# the same vocabulary with its per-adapter verification evidence; when a level is
# added or removed here, update that table's evidence in the same change.
#
# Per-adapter evidence (dates and versions live in the harness-adapters table):
#   claude       low|medium|high|xhigh|max via --effort.
#   codex        low|medium|high|xhigh|max via -c model_reasoning_effort. max was
#                verified empirically on codex-cli 0.146.0: a live
#                codex exec -m gpt-5.6-luna -c 'model_reasoning_effort="max"'
#                probe completed correctly with no invalid_request_error.
#   grok         low|medium|high via --reasoning-effort; 0.2.99 rejects xhigh and max.
#   pi/pi-signed low|medium|high|xhigh|max via --thinking.
#   opencode     no verified launch effort flag - no level is accepted.
#   kimi         no reasoning-effort flag - no level is accepted.
#
# No side effects on source. set -u / set -e safe.

# fm_effort_levels <harness>: print the space-separated effort levels the named
# harness accepts at launch, or nothing when the harness has no effort knob.
fm_effort_levels() {
  case "$1" in
    claude) echo "low medium high xhigh max" ;;
    codex) echo "low medium high xhigh max" ;;
    grok) echo "low medium high" ;;
    pi|pi-signed) echo "low medium high xhigh max" ;;
    *) echo "" ;;
  esac
}

# fm_effort_level_supported <harness> <effort>: return 0 when the harness accepts
# the effort level at launch, 1 otherwise.
fm_effort_level_supported() {
  case " $(fm_effort_levels "$1") " in
    *" $2 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# fm_effort_levels_json: print one JSON object mapping every verified harness to
# its accepted effort-level array, for jq --argjson consumers. A harness with no
# effort knob maps to an empty array, so any configured effort for it is invalid.
fm_effort_levels_json() {
  local harness levels first=1
  printf '{'
  for harness in claude codex opencode pi pi-signed grok kimi; do
    [ "$first" = 1 ] || printf ','
    first=0
    printf '"%s":[' "$harness"
    levels=$(fm_effort_levels "$harness")
    if [ -n "$levels" ]; then
      printf '"%s"' "${levels// /\",\"}"
    fi
    printf ']'
  done
  printf '}'
}
