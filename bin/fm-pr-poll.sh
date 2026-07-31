#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits exactly one merged line for a merged PR or MR and stays silent on
# every lookup error, so a failed lookup can never be read as a merge. The
# provider-tagged identity and the optional GitHub account login are data in
# the sidecar and are never interpolated into this source: these bytes are
# identical for every task.
# When a GitHub record names an account, its token is resolved fresh on every
# run through gh's own store (gh auth token -u <account>) and passed to gh for
# that one command only; no token is ever written anywhere. A poll that cannot
# resolve the named account's token does NOT fall back to ambient credentials:
# under a different ambient account a private repository reads as not found,
# which is indistinguishable from never-merged, so the poll would go silently
# blind forever. Instead it emits one "gh-account-token-unavailable <account>"
# line so the watcher wakes firstmate with the concrete repair. That line
# repeats at the watcher's slow check cadence until the account is signed in
# again or the poll is re-armed, and it is never the word "merged", so a
# credential failure can never be read as a merge either.
# Each provider is read through its own standard CLI, gh for GitHub and glab
# for GitLab, so an upstream checkout needs no extra tooling to follow either.
set -u
LC_ALL=C
export LC_ALL

account=
if [ "$#" -ge 6 ] && [ "$#" -le 7 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
  account=${7-}
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  # A sixth line is the optional account; it must be non-empty, complete with
  # its newline, and final. Anything else is a malformed record, not data.
  if IFS= read -r account <&3; then
    [ -n "$account" ] || exit 0
    if IFS= read -r _extra <&3; then
      exit 0
    fi
  elif [ -n "$account" ]; then
    exit 0
  else
    account=
  fi
  exec 3<&-
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

# The account is only ever a GitHub login handed to gh's own token store as
# data, so it obeys the same shape rule as a GitHub owner and only a github
# record may carry one.
if [ -n "$account" ]; then
  [ "$provider" = github ] || exit 0
  [ "${#account}" -ge 1 ] && [ "${#account}" -le 39 ] || exit 0
  case "$account" in
    *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
  esac
fi

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot redirect this poll at another host or project.
case "$provider" in
  github)
    [ "$host" = github.com ] || exit 0
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
    case "$owner" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0
    if [ -n "$account" ]; then
      if ! token=$(gh auth token -u "$account" 2>/dev/null) || [ -z "$token" ]; then
        printf '%s %s\n' gh-account-token-unavailable "$account"
        exit 0
      fi
      state=$(GH_TOKEN="$token" gh pr view "$url" --json state -q .state 2>/dev/null) || exit 0
    else
      state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || exit 0
    fi
    [ "$state" = MERGED ] && printf '%s\n' merged
    ;;
  gitlab)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A GitLab project sits under at least one group at no fixed depth, and
    # GitLab reserves the "-" segment as its route separator.
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 0
    [ "$url" = "https://$host/$path/-/merge_requests/$number" ] || exit 0
    # glab resolves the instance from the project URL passed to -R, so the host
    # comes from the validated record rather than glab's configured default.
    # It cannot take a merge request URL the way gh does: that form shells out
    # to git for the current repository, and the watcher runs in no repository.
    # The state is read from glab's own field output rather than its JSON,
    # because plain glab has no field selector and firstmate does not require a
    # JSON processor; only an exact "merged" wakes, so a changed format or an
    # unreadable merge request stays silent instead of reporting a merge.
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 0
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    [ "$state" = merged ] && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
