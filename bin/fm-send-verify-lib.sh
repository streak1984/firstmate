#!/usr/bin/env bash
# bin/fm-send-verify-lib.sh - the post-send classification owner behind
# fm-send.sh --verify: landed | queued | dropped | unknown, decided from the
# composer state, the pane's busy state, and a plain pane capture.
#
# Reuses the fleet's existing owners instead of inventing a second opinion:
# the shared composer classifier (bin/fm-composer-lib.sh, dispatched through
# fm_backend_composer_state in bin/fm-backend.sh), the tmux busy-footer
# matcher (fm_pane_is_busy, bin/fm-tmux-lib.sh), herdr's native agent-state
# busy (fm_backend_herdr_busy_state), and herdr's queue-entry evidence
# (fm_backend_herdr_submit_queue_evidence). The full verdict contract - the
# three outcomes, the exit-code rule, the no-auto-resend rule, and the
# transcript matching method - is stated once in bin/fm-send.sh's header;
# this file only implements it.
#
# Sourcing: bin/fm-send.sh sources this after bin/fm-backend.sh. This file
# sources bin/fm-composer-lib.sh itself (a cheap idempotent redefinition per
# that file's header) so its ANSI strip is available even standalone, which
# keeps the tmux- and herdr-only tests able to source just this file.
# All functions are `set -u` and `set -e` safe.
#
# Test seam: the classifier dispatches through fm_backend_composer_state,
# fm_backend_capture, fm_backend_source, fm_pane_is_busy (tmux arms),
# fm_backend_busy_state and fm_backend_herdr_submit_queue_evidence (herdr
# arms), so a test can stub any of them by redefining the function, exactly
# like the away-mode tests stub fm_pane_is_busy.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-composer-lib.sh
. "$SCRIPT_DIR/fm-composer-lib.sh"

# fm_send_verify_normalize: read one text on stdin, print its normalized form
# on stdout: ANSI escapes stripped (fm_composer_strip_ansi), the composer box
# border glyphs (│ ┃ ║) deleted, the invisible U+2063 operational-marker
# carrier (bin/fm-operational-input.sh) deleted, and every whitespace run -
# including the newlines a wrapped message spans - collapsed into a single
# ASCII space, then trimmed. LC_ALL=C keeps the byte walk deterministic under
# any caller locale; the border glyphs are deleted as full UTF-8 sequences, so
# a multibyte character that merely shares a byte with a border glyph is never
# mangled. U+2063 is deleted (not spaced) because it is zero-width: a marked
# secondmate message carries it invisibly, no pane ever renders it, and
# leaving it in the message side would make every marked echo unmatchable.
# Both the message and the capture pass through this same normalization, so
# the two sides stay comparable.
FM_SEND_VERIFY_U2063=$(printf '\xe2\x81\xa3')
fm_send_verify_normalize() {
  LC_ALL=C fm_composer_strip_ansi \
    | LC_ALL=C sed 's/│/ /g; s/┃/ /g; s/║/ /g' \
    | LC_ALL=C sed "s/$FM_SEND_VERIFY_U2063//g" \
    | LC_ALL=C tr -s '[:space:]' ' ' \
    | LC_ALL=C sed -e 's/^ //' -e 's/ $//'
}

# fm_send_verify_transcript_has: 0 when the normalized <message> appears as a
# substring of the normalized <transcript>, 1 otherwise. Two passes: the
# whitespace-collapsed form (defeats wrapping at word boundaries), then, when
# that misses, the fully whitespace-free form (defeats a hard terminal wrap in
# the middle of a long token, for example a URL split across lines). An empty
# message never matches.
fm_send_verify_transcript_has() {  # <message> <transcript>
  local message=$1 transcript=$2 msg cap msg_nw cap_nw
  msg=$(printf '%s' "$message" | fm_send_verify_normalize)
  cap=$(printf '%s' "$transcript" | fm_send_verify_normalize)
  [ -n "$msg" ] || return 1
  case "$cap" in
    *"$msg"*) return 0 ;;
  esac
  msg_nw=${msg// /}
  cap_nw=${cap// /}
  [ -n "$msg_nw" ] || return 1
  case "$cap_nw" in
    *"$msg_nw"*) return 0 ;;
  esac
  return 1
}

# fm_send_verify_capable: 0 when <backend> has the composer-state plus
# busy-state chain --verify needs; otherwise echoes the honest reason and
# returns 1. tmux and herdr own the chain today (fm_tmux_composer_state plus
# fm_pane_is_busy; fm_backend_herdr_composer_state plus fm_backend_herdr_busy_state).
# zellij has no composer-state owner at all; orca and cmux have a composer
# owner but no busy-state source, so they cannot separate queued from dropped;
# any other backend is unknown.
fm_send_verify_capable() {  # <backend>
  case "$1" in
    tmux|herdr) return 0 ;;
    zellij) printf 'backend %s has no composer-state owner' "$1" ;;
    orca|cmux) printf 'backend %s has no busy-state source to separate queued from dropped' "$1" ;;
    *) printf 'backend %s has no composer-state owner' "$1" ;;
  esac
  return 1
}

# fm_send_verify_classify: the --verify decision procedure. Echoes
# "<verdict> <one short detail>" on stdout:
#   landed  - composer no longer holds the message and the message matched in
#             the pane capture (normalized match, see
#             fm_send_verify_transcript_has); or the submit core positively
#             confirmed submission ([submit-verdict] empty) and the fresh
#             reads corroborate it: a clear composer on a busy pane, or a
#             busy herdr pane whose composer is unreadable exactly because
#             the agent is working (a working Pi refuses its separated
#             composer shape by design) with a clean absent queue-entry read.
#             Real panes rarely echo the message in matchable form (Pi does
#             not echo steers at all; long messages collapse), so the echo is
#             corroboration, never a requirement, once submission was
#             positively confirmed.
#   queued  - tmux: proven-pending composer on a busy pane (the opencode
#             text-stays-visible busy-queue shape the submit core converts);
#             herdr: the same pending-on-busy shape, a busy pane showing the
#             native pi "Steering:" queue-entry evidence, or a busy pane
#             whose submit core already proved the queue entry
#             ([submit-verdict] queued) even when that entry has since
#             scrolled out of the evidence window.
#   dropped - proven-pending composer on an idle pane (text stuck), or an
#             empty composer on an idle pane with the message nowhere in the
#             capture (text vanished) and no positive submit confirmation.
#             tmux pending-unproven on an idle pane also drops (the text IS
#             in the composer).
#   unknown - unreadable composer, ambiguous composer text on a busy pane, a
#             busy pane without queue evidence or submit confirmation, an
#             unreadable busy state, a confirmed submit whose message is no
#             longer visible on an idle pane (a fast turn that already
#             ended), or a backend without the capability chain (see
#             fm_send_verify_capable). Reported honestly, never guessed: an
#             unreadable composer can neither confirm landed nor prove
#             dropped, and a busy pane can still be mid-turn.
# Requires bin/fm-backend.sh sourced for the dispatch functions; the tmux
# arms also need fm_pane_is_busy from bin/fm-tmux-lib.sh, which the tmux
# adapter loads through fm_backend_source. <harness> scopes the tmux
# busy-footer signatures; [expected-label] flows into the capture call.
# [submit-verdict] is the send path's own proof-carrying verdict (empty for a
# positively confirmed submission, queued for the herdr busy-queue
# acceptance, anything else or absent for no confirmation evidence); an
# absent submit-verdict preserves the strictly read-only classification.
fm_send_verify_classify() {  # <backend> <target> <harness> <message> [expected-label] [submit-verdict]
  local backend=$1 target=$2 harness=$3 message=$4 label=${5:-} submit=${6:-}
  local reason composer busy transcript evidence
  reason=$(fm_send_verify_capable "$backend") || { printf 'unknown %s' "$reason"; return 0; }
  fm_backend_source "$backend" \
    || { printf 'unknown backend %s adapter could not be loaded' "$backend"; return 0; }
  composer=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null || printf 'unknown')
  case "$backend" in
    tmux)
      if fm_pane_is_busy "$target" "$harness"; then
        busy=busy
      else
        busy=idle
      fi
      ;;
    herdr)
      busy=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null || printf 'unknown')
      ;;
  esac
  transcript=$(fm_backend_capture "$backend" "$target" 200 "$label" 2>/dev/null || true)
  case "$composer" in
    empty)
      if fm_send_verify_transcript_has "$message" "$transcript"; then
        printf 'landed composer cleared and message echoed in the pane capture'
      elif [ "$busy" = busy ]; then
        if [ "$submit" = empty ]; then
          printf 'landed submit confirmed and the composer is clear on the busy pane'
        else
          printf 'unknown composer empty but message not echoed while the pane is busy'
        fi
      elif [ "$busy" = idle ]; then
        if [ "$submit" = empty ]; then
          printf 'unknown submit confirmed but the message is no longer visible on the idle pane'
        else
          printf 'dropped message found nowhere on an idle pane'
        fi
      else
        printf 'unknown cannot read the pane busy state'
      fi
      ;;
    pending)
      if [ "$busy" = busy ]; then
        printf 'queued busy pane accepted the message for delivery at turn end'
      elif [ "$busy" = idle ]; then
        printf 'dropped composer still holds the message on an idle pane'
      else
        printf 'unknown cannot read the pane busy state'
      fi
      ;;
    pending-unproven)
      if [ "$busy" = busy ]; then
        printf 'unknown ambiguous composer text on a busy pane'
      elif [ "$busy" = idle ]; then
        printf 'dropped composer holds the message text on an idle pane'
      else
        printf 'unknown cannot read the pane busy state'
      fi
      ;;
    unknown)
      if [ "$backend" = herdr ] && [ "$busy" = busy ]; then
        evidence=$(fm_backend_herdr_submit_queue_evidence "$target" 2>/dev/null || printf 'unknown')
        if [ "$evidence" = queued ]; then
          printf 'queued busy pane shows an accepted queue entry'
        elif [ "$submit" = empty ] && [ "$evidence" = absent ]; then
          printf 'landed submit confirmed on the busy pane; composer unreadable while the agent works'
        elif [ "$submit" = queued ]; then
          printf 'queued submit core observed the accepted queue entry'
        else
          printf 'unknown busy pane without queue evidence'
        fi
      else
        printf 'unknown composer state unreadable'
      fi
      ;;
  esac
}
