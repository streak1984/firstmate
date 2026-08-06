#!/usr/bin/env bash
# fm-dispatch-facts.sh - assemble the per-candidate quota and auth fact table
# for one dispatch intake, data only.
#
# Usage: fm-dispatch-facts.sh [--candidates-file <path>] [--quota-file <path>]
#        [--auth-file <path>] [--json]
# Candidates default to stdin. -h/--help prints this header and exits 0.
#
# Input schema: a JSON array of candidate objects.
#   [{"harness": "claude", "model": "opus", "provider": "claude", "effort": "high"}]
#   harness, model, and provider are required non-empty strings.
#   effort is optional and must be a non-empty string when present.
#   The provider is supplied by the caller and is NEVER inferred from a
#   harness or model name, and a candidate missing harness, model, or provider
#   is refused with an error naming its index.
#
# Snapshots: quota-axi --json and quota-axi auth --json each run exactly once
# and are reused for every candidate. --quota-file and --auth-file substitute
# fixture JSON for tests and offline use and skip the live calls. No vendor
# CLI other than quota-axi is ever launched by this script.
#
# Scope selection: the effectiveAvailability entry whose scope is exactly
# "model:<model>" wins when one exists, otherwise the provider-level entry
# (all_models or all_products) wins, otherwise scope is unknown. The lookup is
# mechanical and never infers a provider, model, or quota relation.
#
# Absence: every fact that the snapshots do not supply renders as the literal
# "unknown", never as a healthy default. Within a present pace summary, quota-
# axi omits empty pace buckets, so an absent bucket list renders as "-" (table)
# or [] (JSON) because the snapshot records no windows in that bucket.
#
# A provider whose quota state is stale is flagged "stale (diagnostic only)":
# its raw windows are diagnostic data, never headroom. A provider
# credits.remaining value passes through labeled "(prepaid)" and is never
# window headroom.
#
# HARD BOUNDARY: this tool assembles facts only. It never ranks candidates,
# never recommends, never marks a "best" candidate, never selects, and never
# starts a vendor CLI other than quota-axi. Selection is firstmate's.
#
# Default output: one aligned table row per candidate in input order, then one
# "unknowns[<index>]:" line per candidate naming the fields that resolved to
# "unknown" (or "none"). --json emits the same facts as a JSON array.
#
# Table columns:
#   #             candidate index in input order, starting at 0
#   harness       candidate harness, verbatim
#   model         candidate model, verbatim
#   provider      candidate provider, verbatim
#   effort        candidate effort, or unknown
#   snapshot      present, or provider-not-in-snapshot
#   scope         applicable scope: model:<model>, all_models, all_products, or unknown
#   eff%          effectivePercentRemaining of the applicable scope, or unknown
#   limiting      limitingWindowIds of the applicable scope, comma-joined
#   pace          aggregate pace status: ahead, on_pace, behind, mixed, or unknown
#   worst-pts     worstReservePercentPoints, the most negative signed reserve
#   worst-win     worstReserveWindowId
#   ahead         aheadWindowIds bucket: comma-joined, "-", or unknown
#   behind        behindWindowIds bucket: comma-joined, "-", or unknown
#   on-pace       onPaceWindowIds bucket: comma-joined, "-", or unknown
#   unknown-wins  unknownWindowIds bucket: comma-joined, "-", or unknown
#   state         provider quota state.status, or unknown
#   auth-status   provider state.authStatus when present, or unknown
#   stale         stale (diagnostic only) when the provider state is stale
#   credits       provider credits.remaining labeled (prepaid), or unknown
#   auth-sources  per-source list from quota-axi auth --json as source=status
#                 pairs (comma-joined), or unknown when the auth snapshot has
#                 no entry for the provider
#
# JSON output fields: index, harness, model, provider, effort,
# providerInSnapshot, scope, effectivePercentRemaining, limitingWindowIds,
# paceStatus, aheadWindowIds, behindWindowIds, onPaceWindowIds,
# unknownWindowIds, worstReservePercentPoints, worstReserveWindowId,
# providerStateStatus, providerAuthStatus, stale, prepaidCreditsRemaining,
# authSources (objects with source, status, and path when present). Absent
# facts are the string "unknown"; window-id lists are arrays when known;
# prepaidCreditsRemaining is a number when known; stale is a boolean when
# known.
#
# Exit codes: 0 on success, 1 when a live quota-axi or auth snapshot cannot be
# acquired or parsed, 2 for usage errors and malformed candidate input.
set -eu

usage() {
  # The whole leading comment block, ending at the first line that is not a
  # comment. Derived rather than a fixed line range, which silently truncated
  # this help mid-sentence every time the header above grew.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

CANDIDATES_FILE=
QUOTA_FILE=
AUTH_FILE=
JSON_MODE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --candidates-file)
      if [ "$#" -lt 2 ]; then
        echo "error: --candidates-file requires a path" >&2
        exit 2
      fi
      CANDIDATES_FILE=$2
      shift 2
      ;;
    --quota-file)
      if [ "$#" -lt 2 ]; then
        echo "error: --quota-file requires a path" >&2
        exit 2
      fi
      QUOTA_FILE=$2
      shift 2
      ;;
    --auth-file)
      if [ "$#" -lt 2 ]; then
        echo "error: --auth-file requires a path" >&2
        exit 2
      fi
      AUTH_FILE=$2
      shift 2
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-dispatch-facts.XXXXXX") || exit 1
trap 'rm -f "$TMP_ERR"' EXIT

# --- candidates --------------------------------------------------------------

if [ -n "$CANDIDATES_FILE" ]; then
  if [ ! -f "$CANDIDATES_FILE" ]; then
    echo "error: candidates file not found: $CANDIDATES_FILE" >&2
    exit 2
  fi
  CANDIDATES=$(cat "$CANDIDATES_FILE")
else
  CANDIDATES=$(cat)
fi
if [ -z "$CANDIDATES" ]; then
  if [ -n "$CANDIDATES_FILE" ]; then
    echo "error: candidates file is empty: $CANDIDATES_FILE" >&2
  else
    echo "error: no candidates provided on stdin" >&2
  fi
  exit 2
fi
if ! printf '%s' "$CANDIDATES" | jq -e 'type == "array"' >/dev/null 2>"$TMP_ERR"; then
  if [ -s "$TMP_ERR" ]; then
    echo "error: candidates input is not valid JSON" >&2
  else
    echo "error: candidates input must be a JSON array" >&2
  fi
  exit 2
fi

# --- quota snapshot ----------------------------------------------------------

if [ -n "$QUOTA_FILE" ]; then
  if [ ! -f "$QUOTA_FILE" ]; then
    echo "error: quota file not found: $QUOTA_FILE" >&2
    exit 2
  fi
  if ! jq -e 'type' "$QUOTA_FILE" >/dev/null 2>"$TMP_ERR"; then
    echo "error: quota snapshot is not valid JSON: $QUOTA_FILE" >&2
    exit 2
  fi
  QUOTA=$(cat "$QUOTA_FILE")
else
  command -v quota-axi >/dev/null 2>&1 \
    || { echo "error: quota-axi is required on PATH (or pass --quota-file)" >&2; exit 1; }
  if ! QUOTA=$(quota-axi --json 2>"$TMP_ERR"); then
    sed 's/^/error: /' "$TMP_ERR" >&2
    echo "error: quota-axi --json failed" >&2
    exit 1
  fi
  if ! printf '%s' "$QUOTA" | jq -e 'type' >/dev/null 2>/dev/null; then
    echo "error: quota-axi --json returned invalid JSON" >&2
    exit 1
  fi
fi

# --- auth snapshot -----------------------------------------------------------

if [ -n "$AUTH_FILE" ]; then
  if [ ! -f "$AUTH_FILE" ]; then
    echo "error: auth file not found: $AUTH_FILE" >&2
    exit 2
  fi
  if ! jq -e 'type' "$AUTH_FILE" >/dev/null 2>"$TMP_ERR"; then
    echo "error: auth snapshot is not valid JSON: $AUTH_FILE" >&2
    exit 2
  fi
  AUTH=$(cat "$AUTH_FILE")
else
  command -v quota-axi >/dev/null 2>&1 \
    || { echo "error: quota-axi is required on PATH (or pass --auth-file)" >&2; exit 1; }
  if ! AUTH=$(quota-axi auth --json 2>"$TMP_ERR"); then
    sed 's/^/error: /' "$TMP_ERR" >&2
    echo "error: quota-axi auth --json failed" >&2
    exit 1
  fi
  if ! printf '%s' "$AUTH" | jq -e 'type' >/dev/null 2>/dev/null; then
    echo "error: quota-axi auth --json returned invalid JSON" >&2
    exit 1
  fi
fi

# --- fact assembly -----------------------------------------------------------

# One jq program assembles every candidate's fact object. Candidate validation
# runs first and aborts the whole run via halt_error, naming the failing
# index. The program never sorts, ranks, or compares candidates; input order
# is preserved by to_entries over the caller's array.
JQ_PROGRAM=$(cat <<'JQ'
def UNKNOWN: "unknown";

def u($v): if $v == null then UNKNOWN else $v end;

# A pace bucket omitted from a present pace summary is quota-axi's empty
# bucket, rendered "-" in the table and [] in JSON.
def bucket($v): if $v == null then [] else $v end;

def providers_map: (($quota.providers // []) | map({key: .provider, value: .}) | from_entries);

def auths_map: (($auth.auth // []) | map({key: .provider, value: .}) | from_entries);

def check_string($obj; $key; $idx):
  if (($obj[$key] | type) != "string") or (($obj[$key] | length) == 0) then
    ("candidate " + ($idx | tostring) + " missing \"" + $key + "\"\n") | halt_error(2)
  else . end;

providers_map as $providers
| auths_map as $auths
| $cand
| to_entries
| map(
    . as $e
    | if ($e.value | type) != "object" then
        ("candidate " + ($e.key | tostring) + " must be an object\n") | halt_error(2)
      else . end
    | check_string($e.value; "harness"; $e.key)
    | check_string($e.value; "model"; $e.key)
    | check_string($e.value; "provider"; $e.key)
    | if (($e.value.effort // null) != null) and
         ( (($e.value.effort | type) != "string") or (($e.value.effort | length) == 0) ) then
        ("candidate " + ($e.key | tostring) + " effort must be a non-empty string\n") | halt_error(2)
      else . end
    | $providers[$e.value.provider] as $p
    | if $p == null then
        {
          effort: (if ($e.value.effort // null) == null then UNKNOWN else $e.value.effort end),
          snapshot: "provider-not-in-snapshot",
          scope: UNKNOWN, eff: UNKNOWN, limiting: UNKNOWN, paceStatus: UNKNOWN,
          ahead: UNKNOWN, behind: UNKNOWN, onPace: UNKNOWN, unknownWins: UNKNOWN,
          worstPts: UNKNOWN, worstWin: UNKNOWN,
          stateStatus: UNKNOWN, authStatus: UNKNOWN, stale: UNKNOWN,
          credits: UNKNOWN, authSources: UNKNOWN
        }
      else
        (($p.quotaSemantics.effectiveAvailability // []) as $ea
         | (first($ea[] | select(.scope == ("model:" + $e.value.model))) // null) as $named
         | (if $named != null then $named
            else (first($ea[] | select(.scope == "all_models" or .scope == "all_products")) // null)
            end) as $scopeEntry
         | ($scopeEntry.pace) as $pace
         | {
             effort: (if ($e.value.effort // null) == null then UNKNOWN else $e.value.effort end),
             snapshot: "present",
             scope: (if $scopeEntry == null then UNKNOWN else $scopeEntry.scope end),
             eff: (if $scopeEntry == null then UNKNOWN else u($scopeEntry.effectivePercentRemaining) end),
             limiting: (if $scopeEntry == null then UNKNOWN else u($scopeEntry.limitingWindowIds) end),
             paceStatus: (if $pace == null then UNKNOWN else u($pace.status) end),
             ahead: (if $pace == null then UNKNOWN else bucket($pace.aheadWindowIds) end),
             behind: (if $pace == null then UNKNOWN else bucket($pace.behindWindowIds) end),
             onPace: (if $pace == null then UNKNOWN else bucket($pace.onPaceWindowIds) end),
             unknownWins: (if $pace == null then UNKNOWN else bucket($pace.unknownWindowIds) end),
             worstPts: (if $pace == null then UNKNOWN else u($pace.worstReservePercentPoints) end),
             worstWin: (if $pace == null then UNKNOWN else u($pace.worstReserveWindowId) end),
             stateStatus: u($p.state.status),
             authStatus: u($p.state.authStatus),
             stale: (($p.state.stale == true) or ($p.state.status == "stale")),
             credits: u($p.credits.remaining),
             authSources: (if ($auths[$e.value.provider] // null) == null then UNKNOWN
                           else [($auths[$e.value.provider].sources // [])[]
                                 | {source, status} + (if has("path") then {path} else {} end)]
                           end)
           }
      )
      end
    | . as $f
    | if $mode == "json" then
        {
          index: $e.key,
          harness: $e.value.harness,
          model: $e.value.model,
          provider: $e.value.provider,
          effort: $f.effort,
          providerInSnapshot: ($f.snapshot == "present"),
          scope: $f.scope,
          effectivePercentRemaining: $f.eff,
          limitingWindowIds: $f.limiting,
          paceStatus: $f.paceStatus,
          aheadWindowIds: $f.ahead,
          behindWindowIds: $f.behind,
          onPaceWindowIds: $f.onPace,
          unknownWindowIds: $f.unknownWins,
          worstReservePercentPoints: $f.worstPts,
          worstReserveWindowId: $f.worstWin,
          providerStateStatus: $f.stateStatus,
          providerAuthStatus: $f.authStatus,
          stale: $f.stale,
          prepaidCreditsRemaining: $f.credits,
          authSources: $f.authSources
        }
      else
        [
          ($e.key | tostring),
          $e.value.harness,
          $e.value.model,
          $e.value.provider,
          $f.effort,
          $f.snapshot,
          $f.scope,
          (if $f.eff == UNKNOWN then UNKNOWN else ($f.eff | tostring) end),
          (if $f.limiting == UNKNOWN then UNKNOWN
           elif ($f.limiting | length) == 0 then "-"
           else ($f.limiting | join(",")) end),
          $f.paceStatus,
          (if $f.worstPts == UNKNOWN then UNKNOWN else ($f.worstPts | tostring) end),
          $f.worstWin,
          (if $f.ahead == UNKNOWN then UNKNOWN elif ($f.ahead | length) == 0 then "-" else ($f.ahead | join(",")) end),
          (if $f.behind == UNKNOWN then UNKNOWN elif ($f.behind | length) == 0 then "-" else ($f.behind | join(",")) end),
          (if $f.onPace == UNKNOWN then UNKNOWN elif ($f.onPace | length) == 0 then "-" else ($f.onPace | join(",")) end),
          (if $f.unknownWins == UNKNOWN then UNKNOWN elif ($f.unknownWins | length) == 0 then "-" else ($f.unknownWins | join(",")) end),
          $f.stateStatus, $f.authStatus,
          (if $f.stale == UNKNOWN then UNKNOWN
           elif $f.stale then "stale (diagnostic only)"
           else "-" end),
          (if $f.credits == UNKNOWN then UNKNOWN
           else ($f.credits | tostring) + " (prepaid)" end),
          (if $f.authSources == UNKNOWN then UNKNOWN
           else ($f.authSources | map(.source + "=" + .status) | join(",")) end)
        ]
        | join("\t")
      end
  )
| if $mode == "table" then .[] else . end
JQ
)

if [ "$JSON_MODE" -eq 1 ]; then
  MODE=json
else
  MODE=table
fi

if ASSEMBLED=$(jq -n -r -c \
  --argjson cand "$CANDIDATES" \
  --argjson quota "$QUOTA" \
  --argjson auth "$AUTH" \
  --arg mode "$MODE" \
  "$JQ_PROGRAM" 2>"$TMP_ERR"); then
  :
else
  rc=$?
  # halt_error(2) already wrote a clean validation message to the error
  # file; other jq failures (compile or runtime errors) get a prefix.
  if [ "$rc" -ne 2 ]; then
    sed 's/^/error: /' "$TMP_ERR" >&2
    echo "error: fact assembly failed" >&2
  else
    cat "$TMP_ERR" >&2
  fi
  exit 2
fi

# --- output ------------------------------------------------------------------

if [ "$MODE" = json ]; then
  printf '%s\n' "$ASSEMBLED"
  exit 0
fi

HEADERS=('#' harness model provider effort snapshot scope 'eff%' limiting pace \
  worst-pts worst-win ahead behind on-pace unknown-wins state auth-status stale \
  credits auth-sources)
UNKNOWN_SHORT=(effort scope eff-pct limiting pace worst-pts worst-win ahead \
  behind on-pace unknown-wins state auth-status stale credits auth-sources)
# Cell index of each UNKNOWN_SHORT entry in a table row.
UNKNOWN_CELLS=(4 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20)

ROWS=()
while IFS= read -r row || [ -n "$row" ]; do
  ROWS+=("$row")
done < <(printf '%s' "$ASSEMBLED")

# Cell width is the longest value per column across header and rows.
widths=()
for h in "${HEADERS[@]}"; do
  widths+=("${#h}")
done
for row in "${ROWS[@]}"; do
  IFS=$'\t' read -r -a cells <<< "$row"
  if [ "${#cells[@]}" -ne "${#HEADERS[@]}" ]; then
    echo "error: internal table cell count mismatch" >&2
    exit 1
  fi
  i=0
  for cell in "${cells[@]}"; do
    if [ "${#cell}" -gt "${widths[$i]}" ]; then
      widths[i]=${#cell}
    fi
    i=$((i + 1))
  done
done

print_padded_row() {
  local -a row=("$@") padded=()
  local i
  for i in "${!row[@]}"; do
    padded+=("$(printf '%-*s' "${widths[$i]}" "${row[$i]}")")
  done
  printf '%s\n' "${padded[*]}"
}

print_padded_row "${HEADERS[@]}"
for row in "${ROWS[@]}"; do
  IFS=$'\t' read -r -a cells <<< "$row"
  print_padded_row "${cells[@]}"
  unknowns=()
  i=0
  for short in "${UNKNOWN_SHORT[@]}"; do
    if [ "${cells[${UNKNOWN_CELLS[$i]}]}" = unknown ]; then
      unknowns+=("$short")
    fi
    i=$((i + 1))
  done
  if [ "${#unknowns[@]}" -eq 0 ]; then
    printf 'unknowns[%s]: none\n' "${cells[0]}"
  else
    printf 'unknowns[%s]: %s\n' "${cells[0]}" "${unknowns[*]}"
  fi
done
