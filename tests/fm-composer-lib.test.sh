#!/usr/bin/env bash
# tests/fm-composer-lib.test.sh - the shared composer-content classifier
# (bin/fm-composer-lib.sh), the ONE fleet-wide owner every backend adapter
# delegates its empty|pending|unknown verdict to.
#
# The load-bearing contract, task fm-composer-shellglyph-safety:
#   1. A BARE shell prompt glyph (`>`/`$`/`%`/`#`) on an unstructured row is a
#      dead shell, NOT an empty agent composer - it must read `unknown`
#      (unsafe-for-injection), never `empty`. This is the safety fix.
#   2. The SAME shell glyph INSIDE a bordered composer box is the harness's own
#      prompt and still reads `empty` (existing behavior preserved).
#   3. The AGENT prompt glyphs `❯` (claude) and `›` (codex) inside a bordered
#      composer box are unconditional proof, same as point 2.
#   4. Real unsubmitted text reads `pending`; a known idle placeholder reads
#      `empty`.
#
# Extended contract, task fm-composer-glyph-w3: on this fleet `❯`/`›` are ALSO
# the zsh/starship shell prompt and a dialog menu's highlighted-row marker, so
# a BARE (unbordered) agent glyph is no longer unconditional proof either:
#   5. A bare `❯`/`›` row with no [glyph_corroborated] evidence reads
#      `unknown` - it is indistinguishable from a dead shell's own prompt.
#   6. The SAME bare row reads `empty` only when the caller passes
#      [glyph_corroborated]=1 (Herdr's native agent registry, or tmux's
#      foreground-process evidence) - only that positive proof authorizes
#      injection.
#   7. A dialog's highlighted row (e.g. `❯ 1. Red`) carries real content after
#      the glyph and reads `pending` regardless of corroboration - it is never
#      mistaken for an empty composer by this classifier.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

# classify <bordered> <content> [idle_re] -> echoes the verdict.
classify() { fm_composer_classify_content "$@"; }

# --- Safety fix: bare shell prompt is NOT an empty agent composer -----------

test_bare_shell_glyphs_are_unknown() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "$g")
    [ "$out" = unknown ] \
      || fail "bare shell glyph '$g' must read unknown (dead shell, unsafe), got '$out'"
  done
  pass "fm_composer_classify_content: a bare shell prompt glyph (>/\$/%/#) reads unknown, never empty"
}

test_stripped_unbordered_content_uses_plain_content() {
  local plain out
  for plain in '$' 'user@host $'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = unknown ] \
      || fail "stripped unbordered content '$plain' must retain its unknown safety verdict, got '$out'"
  done
  # An agent glyph surviving only in plain_content (ghost-stripped away from
  # content) is the SAME bare-glyph case as content itself being the glyph:
  # unknown without corroboration, empty with it (task fm-composer-glyph-w3).
  for plain in '❯' '›'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = unknown ] \
      || fail "a stripped agent glyph '$plain' with no corroboration must read unknown, got '$out'"
    out=$(classify 0 '' '' sensitive "$plain" 1)
    [ "$out" = empty ] \
      || fail "a stripped agent glyph '$plain' with corroboration must read empty, got '$out'"
  done
  pass "fm_composer_classify_content: stripped unbordered content is unknown except a corroborated agent glyph"
}

test_bare_shell_prompt_with_command_is_not_empty() {
  local out
  # A dead shell showing a typed command must not read empty either.
  out=$(classify 0 '$ ls -la')
  [ "$out" != empty ] || fail "a bare shell prompt with a command must not read empty, got '$out'"
  pass "fm_composer_classify_content: a bare shell prompt carrying a command is not empty"
}

# --- Preserved: shell glyph inside a composer box is the harness prompt ------

test_bordered_shell_glyph_is_empty() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 1 "$g")
    [ "$out" = empty ] \
      || fail "a shell glyph '$g' inside a bordered composer box must read empty, got '$out'"
  done
  pass "fm_composer_classify_content: a bare prompt glyph inside a bordered composer box reads empty (claude's own idle composer)"
}

# --- Bordered agent glyphs are unconditional proof ---------------------------

test_bordered_agent_glyphs_are_empty() {
  local out
  out=$(classify 1 '❯'); [ "$out" = empty ] || fail "bordered claude '❯' should read empty, got '$out'"
  out=$(classify 1 '›'); [ "$out" = empty ] || fail "bordered codex '›' should read empty, got '$out'"
  pass "fm_composer_classify_content: agent prompt glyphs (❯ claude, › codex) read empty inside a bordered composer box"
}

# --- Bare agent glyphs require corroboration (task fm-composer-glyph-w3) ----
# The root-cause fix: on this fleet ❯ is ALSO the zsh/starship shell prompt
# (F1/F3 in data/fm-herdr-friction-s1/report.md), so a bare glyph alone can no
# longer prove an empty agent composer.

test_bare_agent_glyph_shell_prompt_row_is_unknown_without_corroboration() {
  local out
  # This is literally what a dead-shell husk pane's prompt renders as
  # (report.md finding F1, probe 4): indistinguishable from a live agent's
  # own idle composer without independent proof of agent ownership.
  out=$(classify 0 '❯'); [ "$out" = unknown ] \
    || fail "a bare claude glyph '❯' with no corroboration must read unknown (shell-prompt collision), got '$out'"
  out=$(classify 0 '›'); [ "$out" = unknown ] \
    || fail "a bare codex glyph '›' with no corroboration must read unknown (shell-prompt collision), got '$out'"
  pass "fm_composer_classify_content: a bare agent glyph with no corroboration reads unknown, not empty"
}

test_bare_agent_glyph_genuine_idle_composer_is_empty_when_corroborated() {
  local out
  # A real idle agent composer must still classify empty once the caller
  # supplies positive ownership evidence, so ordinary steering to a healthy
  # worker is unchanged.
  out=$(classify 0 '❯' '' sensitive '' 1); [ "$out" = empty ] \
    || fail "a corroborated bare claude glyph '❯' should read empty, got '$out'"
  out=$(classify 0 '›' '' sensitive '' 1); [ "$out" = empty ] \
    || fail "a corroborated bare codex glyph '›' should read empty, got '$out'"
  pass "fm_composer_classify_content: a bare agent glyph with corroboration still reads empty"
}

test_dialog_menu_highlighted_row_is_pending_not_empty() {
  local out
  # report.md finding F2, probe 6: Claude's AskUserQuestion highlighted row
  # renders as "❯ 1. Red" - the same leading glyph, but real content follows
  # it, so it must never be mistaken for an empty composer, corroborated or not.
  out=$(classify 0 '❯ 1. Red'); [ "$out" = pending ] \
    || fail "an uncorroborated dialog menu row must read pending, got '$out'"
  out=$(classify 0 '❯ 1. Red' '' sensitive '' 1); [ "$out" = pending ] \
    || fail "a corroborated dialog menu row must still read pending, got '$out'"
  pass "fm_composer_classify_content: a dialog menu's highlighted row is pending, never empty"
}

# --- Empty content and idle placeholder -------------------------------------

test_empty_content_is_empty() {
  local out
  out=$(classify 0 ''); [ "$out" = empty ] || fail "empty bare content should read empty, got '$out'"
  out=$(classify 1 ''); [ "$out" = empty ] || fail "empty bordered content should read empty, got '$out'"
  pass "fm_composer_classify_content: an empty composer reads empty"
}

test_idle_placeholder_is_empty() {
  local idle='^Type a message\.\.\.$' out
  # Placeholder with no prompt glyph (grok's bordered empty composer).
  out=$(classify 1 'Type a message...' "$idle")
  [ "$out" = empty ] || fail "the grok idle placeholder should read empty, got '$out'"
  # Placeholder after an agent glyph (post-strip match).
  out=$(classify 0 '❯ Type a message...' "$idle")
  [ "$out" = empty ] || fail "the idle placeholder after a glyph should read empty, got '$out'"
  # Without the idle regex it is just text -> pending.
  out=$(classify 1 'Type a message...')
  [ "$out" = pending ] || fail "without an idle regex the placeholder text is pending, got '$out'"
  pass "fm_composer_classify_content: a known idle placeholder reads empty, before and after glyph stripping"
}

test_idle_placeholder_case_mode_is_explicit() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 1 'type a message...' "$idle")
  [ "$out" = pending ] || fail "a case-variant idle placeholder should remain pending by default, got '$out'"
  out=$(classify 1 'type a message...' "$idle" insensitive)
  [ "$out" = empty ] || fail "an explicitly insensitive idle placeholder should read empty, got '$out'"
  pass "fm_composer_classify_content: idle matching preserves the caller's case mode"
}

# --- Real text is pending ---------------------------------------------------

test_real_text_is_pending() {
  local out
  out=$(classify 0 '❯ fix findings 1 and 3'); [ "$out" = pending ] || fail "bare '❯ <text>' should be pending, got '$out'"
  out=$(classify 1 '> deploy staging now'); [ "$out" = pending ] || fail "bordered '> <text>' should be pending, got '$out'"
  # A slash-command popup argument-hint placeholder is still unsubmitted text.
  out=$(classify 1 '/compact compaction instructions'); [ "$out" = pending ] || fail "a popup placeholder fill should be pending, got '$out'"
  pass "fm_composer_classify_content: real unsubmitted text reads pending (including a popup argument-hint fill)"
}

test_bare_shell_glyphs_are_unknown
test_stripped_unbordered_content_uses_plain_content
test_bare_shell_prompt_with_command_is_not_empty
test_bordered_shell_glyph_is_empty
test_bordered_agent_glyphs_are_empty
test_bare_agent_glyph_shell_prompt_row_is_unknown_without_corroboration
test_bare_agent_glyph_genuine_idle_composer_is_empty_when_corroborated
test_dialog_menu_highlighted_row_is_pending_not_empty
test_empty_content_is_empty
test_idle_placeholder_is_empty
test_idle_placeholder_case_mode_is_explicit
test_real_text_is_pending
