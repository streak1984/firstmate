#!/usr/bin/env bash
# fm-testcount-check.sh - compare per-file test counts between HEAD and the
# merge-base with a base ref, and flag files whose count dropped.
#
# Why this exists: after a rebase, a test-count drop looks exactly like
# silently deleted tests, and twice the alarm came from comparing against a
# stale base instead of the merge-base.
# This check therefore ALWAYS compares HEAD with `git merge-base HEAD
# <base-ref>`, never with the ref tip directly, so a base that advanced after
# the branch was cut cannot produce a false alarm.
# The resolved merge-base SHA is printed in the output.
#
# The tool is strictly read-only: it runs only git read commands (`git -C
# <repo>` show, ls-tree, merge-base, rev-parse, symbolic-ref, show-ref) and
# never fetches, checks out, or mutates anything.
# The caller's shell is never cd'd into; every git command runs through
# `git -C <repo>`.
#
# <base-ref> defaults to the repository's default branch, resolved the same
# way the fleet sync scripts resolve it: refs/remotes/origin/HEAD when set,
# else a local main or master branch.
#
# Test-file detection (a path is a test file when any rule matches; the list
# is exhaustive):
#   - basename test_*.py or *_test.py
#   - any .py whose path contains a directory named tests/
#   - basename *.test.sh, *.test.ts, *.test.js, *.spec.ts, or *_test.go
#
# Per-file counting heuristics (deterministic, applied identically at both
# commits, always to `git show <sha>:<path>` content, never the working tree):
#   - python: lines matching `def test_`
#   - shell: lines matching a `test_NAME()` function definition
#   - js/ts: occurrences of `it(` plus occurrences of `test(`
#   - go: lines matching `func Test`
#
# A file deleted at HEAD counts as a drop to zero.
# A rename shows as a drop of the old path plus an increase of the new path;
# the tool does not chase renames.
#
# Output is the resolved merge-base line, the dropped table (path, base count,
# head count, delta), and totals (files compared, total base count, total head
# count).
# `--all` prints the full per-file table, including unchanged and increased
# files; the default prints only dropped files.
#
# Exit contract: 0 when no file dropped, 1 when any file dropped, 2 on a usage
# or environment error (not a git repository, unknown base ref) with a clear
# message on stderr.
# Usage: fm-testcount-check.sh [--all] <repo-dir> [<base-ref>]
set -u

usage() {
  # The whole leading comment block, ending at the first line that is not a
  # comment. Derived rather than a fixed line range, which silently truncated
  # this help mid-sentence every time the header above grew.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

ALL=0
REPO=
BASE_REF=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --all)
      ALL=1
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [ -z "$REPO" ]; then
        REPO=$1
      elif [ -z "$BASE_REF" ]; then
        BASE_REF=$1
      else
        echo "error: too many arguments" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
  shift
done
if [ -z "$REPO" ]; then
  echo "error: missing <repo-dir>" >&2
  usage >&2
  exit 2
fi

# Resolve the repo's default branch exactly like the fleet sync scripts:
# origin/HEAD when set, else a local main or master branch.
default_branch() {
  local ref branch
  ref=$(git -C "$REPO" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$REPO" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

if ! git -C "$REPO" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
  echo "error: not a git repository (or no HEAD): $REPO" >&2
  exit 2
fi
if [ -z "$BASE_REF" ]; then
  BASE_REF=$(default_branch) || {
    echo "error: cannot determine the default branch of $REPO (no origin/HEAD and no main or master branch)" >&2
    exit 2
  }
fi
MB_OUT=$(git -C "$REPO" merge-base HEAD "$BASE_REF" 2>&1) || {
  echo "error: cannot resolve base ref '$BASE_REF' in $REPO: $(printf '%s\n' "$MB_OUT" | sed -n '1s/^fatal: //p')" >&2
  exit 2
}
MERGE_BASE=$MB_OUT

is_test_file() {  # <path>
  local name
  name=${1##*/}
  case "$name" in
    test_*.py|*_test.py|*.test.sh|*.test.ts|*.test.js|*.spec.ts|*_test.go) return 0 ;;
  esac
  case "$1" in
    tests/*.py|*/tests/*.py) return 0 ;;
  esac
  return 1
}

count_tests() {  # <content on stdin> <path> -> test count on stdout
  local path=$1 n total content
  content=$(cat)
  case "$path" in
    *.py)
      printf '%s\n' "$content" | grep -cE 'def[[:space:]]+test_' || true
      ;;
    *.sh)
      printf '%s\n' "$content" | grep -cE '^[[:space:]]*test_[A-Za-z0-9_]+\(\)' || true
      ;;
    *.ts|*.js)
      total=0
      for n in '\bit\(' '\btest\('; do
        total=$((total + $(printf '%s\n' "$content" | grep -oE "$n" | wc -l | tr -d '[:space:]')))
      done
      printf '%d\n' "$total"
      ;;
    *_test.go)
      printf '%s\n' "$content" | grep -cE '^[[:space:]]*func[[:space:]]+Test' || true
      ;;
    *)
      printf '0\n'
      ;;
  esac
}

files_at() {  # <sha> -> test file paths at that commit, one per line
  local sha=$1 p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if is_test_file "$p"; then
      printf '%s\n' "$p"
    fi
  done < <(git -C "$REPO" ls-tree -r --name-only "$sha")
}

count_at() {  # <sha> <path> -> test count of that file at that commit
  local sha=$1 path=$2 content
  if content=$(git -C "$REPO" show "$sha:$path" 2>/dev/null); then
    printf '%s\n' "$content" | count_tests "$path"
  else
    printf '0\n'
  fi
}

FILE_LIST=$({
  files_at "$MERGE_BASE"
  files_at HEAD
} | LC_ALL=C sort -u)

rows=()
drops=()
dropped=0
compare_count=0
total_base=0
total_head=0

while IFS= read -r path; do
  [ -n "$path" ] || continue
  base=$(count_at "$MERGE_BASE" "$path")
  head=$(count_at HEAD "$path")
  delta=$((head - base))
  compare_count=$((compare_count + 1))
  total_base=$((total_base + base))
  total_head=$((total_head + head))
  row=$(printf '%-42s %5d %5d %5d' "$path" "$base" "$head" "$delta")
  if [ "$delta" -lt 0 ]; then
    dropped=$((dropped + 1))
    drops+=("$row")
  fi
  rows+=("$row")
done <<< "$FILE_LIST"

head_short=$(git -C "$REPO" rev-parse --short HEAD)
printf 'merge-base: %s (HEAD %s vs %s)\n' "$MERGE_BASE" "$head_short" "$BASE_REF"
if [ "$ALL" -eq 1 ]; then
  printf 'all files (path, base, head, delta):\n'
  for row in ${rows[@]+"${rows[@]}"}; do
    printf '%s\n' "$row"
  done
else
  printf 'dropped (path, base, head, delta):\n'
  if [ "$dropped" -eq 0 ]; then
    printf '(none)\n'
  else
    for row in ${drops[@]+"${drops[@]}"}; do
      printf '%s\n' "$row"
    done
  fi
fi
printf 'totals: files=%d base=%d head=%d\n' "$compare_count" "$total_base" "$total_head"
if [ "$dropped" -gt 0 ]; then
  exit 1
fi
exit 0
