#!/usr/bin/env zsh
# ==============================================================================
# zsh-ai-complete: SuggestionManager Tests
# File: tests/test_suggestion.zsh
# ==============================================================================
#
# Run standalone:   zsh tests/test_suggestion.zsh
# Run via runner:   zsh tests/test_runner.zsh tests/test_suggestion.zsh
#
# Tests cover TASK-006 acceptance criteria:
#   AC1  POSTDISPLAY is set with ghost text after cursor
#   AC2  Ghost text styled as dimmed/grey via region_highlight
#   AC3  History prefix matching returns correct completion suffix
#   AC4  Accept appends suggestion text to BUFFER at CURSOR position
#   AC5  Accept updates CURSOR to point after inserted text
#   AC6  Accept clears POSTDISPLAY after insertion
#   AC7  Accept does NOT call accept-line (suggestions are editable only)
#   AC8  Dismiss clears POSTDISPLAY without inserting text
#   AC9  Update replaces ghost text only if BUFFER still matches prefix
#   AC10 Suggestions always appear as editable text, never auto-executed
#
# ==============================================================================

# Capture script directory at TOP LEVEL (outside functions).
typeset -g _ZAI_TEST_SUGG_DIR="${${(%):-%x}:a:h}"
typeset -g _ZAI_TEST_SUGG_PLUGIN="${_ZAI_TEST_SUGG_DIR}/../plugin/lib"

# ── Bootstrap: load test runner if not already loaded ─────────────────────────
if (( ! ${+functions[assert_equal]} )); then
  source "${_ZAI_TEST_SUGG_DIR}/test_runner.zsh"
fi

# ==============================================================================
# ZLE variable simulation
# ==============================================================================
# These variables are provided by ZLE in real usage. We declare them as globals
# so all suggestion functions can read/write them in the test environment.

typeset -g  BUFFER=""
typeset -gi CURSOR=0
typeset -g  POSTDISPLAY=""
typeset -ga region_highlight

# ==============================================================================
# ZLE command mock
# ==============================================================================
# `zle` is active only inside ZLE widgets. In tests we mock it as a no-op so
# _zai_suggestion_show / _zai_suggestion_clear / _zai_suggestion_accept won't
# fail with "zle not active".

function zle() {
  # No-op: ZLE commands (zle -R, zle -F, etc.) are silent in test context
  return 0
}

# ==============================================================================
# fc builtin mock
# ==============================================================================
# `fc -l -1000` is used by _zai_suggestion_get_from_history.
# We override the fc builtin with a predictable test history.
# Each line simulates fc -l output: "  NUM  command"

_zai_test_fc_mock_install() {
  function fc() {
    # Simulate fc -l output with 10 test history entries (oldest first).
    # Entries are intentionally varied to test prefix matching.
    print "    1  ls -la"
    print "    2  git status"
    print "    3  git add ."
    print "    4  git commit -m 'initial commit'"
    print "    5  git log --oneline"
    print "    6  git stash"
    print "    7  git checkout main"
    print "    8  git status --short"
    print "    9  grep -r 'pattern' ."
    print "   10  git diff HEAD"
  }
}

_zai_test_fc_mock_remove() {
  unfunction fc 2>/dev/null || true
}

# ==============================================================================
# Helper: load/reload suggestion module
# ==============================================================================

_test_load_suggestion() {
  # Clear module guard to allow reload
  unset _ZAI_SUGGESTION_LOADED

  # Also clear config guard so config reloads cleanly
  unset _ZAI_CONFIG_LOADED
  unset '_ZAI_CONFIG_DEFAULTS'
  unset '_ZAI_CONFIG_OVERRIDES'

  # Source config then suggestion
  source "${_ZAI_TEST_SUGG_PLUGIN}/config.zsh"
  source "${_ZAI_TEST_SUGG_PLUGIN}/suggestion.zsh"

  # Reset ZLE simulation state
  BUFFER=""
  CURSOR=0
  POSTDISPLAY=""
  region_highlight=()
  _ZAI_SUGGESTION_HIGHLIGHT=""
  _ZAI_SUGGESTION_PREFIX=""
}

# ==============================================================================
# Print header
# ==============================================================================

print "# [test_suggestion.zsh] SuggestionManager Tests"

# ==============================================================================
# 1. _zai_suggestion_show — POSTDISPLAY is set with ghost text
# ==============================================================================

print "# --- 1. _zai_suggestion_show: POSTDISPLAY ---"

_test_load_suggestion

BUFFER="git st"
CURSOR=6

_zai_suggestion_show "atus --short"

# AC1: POSTDISPLAY is set with ghost text showing suggestion after cursor
assert_equal "show: POSTDISPLAY is set to suggestion text" \
  "atus --short" "${POSTDISPLAY}"

# Verify BUFFER is unchanged
assert_equal "show: BUFFER is not modified" \
  "git st" "${BUFFER}"

# Verify CURSOR is unchanged
assert_equal "show: CURSOR is not modified" \
  "6" "${CURSOR}"

# ==============================================================================
# 2. _zai_suggestion_show — region_highlight entry added
# ==============================================================================

print "# --- 2. _zai_suggestion_show: region_highlight ---"

_test_load_suggestion

BUFFER="git st"
CURSOR=6
_zai_suggestion_show "atus"

# AC2: Ghost text displays with dimmed/grey styling via region_highlight
assert_not_empty "show: region_highlight array is non-empty after show" \
  "${region_highlight[*]}"

# The added entry must contain "P0" (POSTDISPLAY-relative, starting at 0)
assert_contains "show: region_highlight entry contains P0 prefix" \
  "P0" "${region_highlight[1]}"

# The added entry must contain the POSTDISPLAY length as end position
local expected_len=${#POSTDISPLAY}
assert_contains "show: region_highlight entry contains POSTDISPLAY length" \
  "${expected_len}" "${region_highlight[1]}"

# The added entry must contain the configured highlight style (default: fg=8)
assert_contains "show: region_highlight entry contains highlight style fg=8" \
  "fg=8" "${region_highlight[1]}"

# _ZAI_SUGGESTION_HIGHLIGHT must be set (tracks our entry for cleanup)
assert_not_empty "show: _ZAI_SUGGESTION_HIGHLIGHT is set" \
  "${_ZAI_SUGGESTION_HIGHLIGHT}"

# ==============================================================================
# 3. _zai_suggestion_show — custom highlight style from config
# ==============================================================================

print "# --- 3. _zai_suggestion_show: custom highlight style ---"

_test_load_suggestion
_zai_config_set highlight_style "fg=244,italic"

BUFFER="ls"
CURSOR=2
_zai_suggestion_show " -la"

assert_contains "show: custom style fg=244,italic used in region_highlight" \
  "fg=244,italic" "${region_highlight[1]}"

_zai_config_reset

# ==============================================================================
# 4. _zai_suggestion_show — stores BUFFER as prefix
# ==============================================================================

print "# --- 4. _zai_suggestion_show: stores prefix for stale-check ---"

_test_load_suggestion

BUFFER="docker run"
CURSOR=10
_zai_suggestion_show " --rm -it ubuntu"

assert_equal "show: _ZAI_SUGGESTION_PREFIX stores current BUFFER" \
  "docker run" "${_ZAI_SUGGESTION_PREFIX}"

# ==============================================================================
# 5. _zai_suggestion_show — empty text is no-op
# ==============================================================================

print "# --- 5. _zai_suggestion_show: empty text is no-op ---"

_test_load_suggestion

BUFFER="ls"
POSTDISPLAY="previous"

_zai_suggestion_show ""

assert_equal "show: empty text leaves POSTDISPLAY unchanged" \
  "previous" "${POSTDISPLAY}"

# ==============================================================================
# 6. _zai_suggestion_show — replaces previous suggestion
# ==============================================================================

print "# --- 6. _zai_suggestion_show: replaces previous suggestion ---"

_test_load_suggestion

BUFFER="git"
CURSOR=3
_zai_suggestion_show " status"

local first_highlight="${region_highlight[1]}"
local highlight_count=${#region_highlight}

# Show a new suggestion (different text)
_zai_suggestion_show " commit -m"

# POSTDISPLAY should be updated
assert_equal "show: POSTDISPLAY updated with new suggestion" \
  " commit -m" "${POSTDISPLAY}"

# region_highlight should still have only one suggestion entry (old one replaced)
assert_equal "show: region_highlight count remains 1 after replace" \
  "1" "${#region_highlight}"

# The old entry should be gone
assert_not_equal "show: old region_highlight entry was replaced" \
  "${first_highlight}" "${region_highlight[1]}"

# ==============================================================================
# 7. _zai_suggestion_clear — clears POSTDISPLAY
# ==============================================================================

print "# --- 7. _zai_suggestion_clear ---"

_test_load_suggestion

BUFFER="git st"
CURSOR=6
_zai_suggestion_show "atus"

# Verify suggestion is showing
assert_equal "clear pre: POSTDISPLAY has suggestion" \
  "atus" "${POSTDISPLAY}"

_zai_suggestion_clear

# AC8: Dismiss clears POSTDISPLAY without inserting text
assert_empty "clear: POSTDISPLAY is empty after clear" "${POSTDISPLAY}"

# region_highlight entry removed
assert_empty "clear: region_highlight is empty after clear" \
  "${region_highlight[*]}"

# Internal state cleared
assert_empty "clear: _ZAI_SUGGESTION_HIGHLIGHT is empty after clear" \
  "${_ZAI_SUGGESTION_HIGHLIGHT}"

assert_empty "clear: _ZAI_SUGGESTION_PREFIX is empty after clear" \
  "${_ZAI_SUGGESTION_PREFIX}"

# AC8: BUFFER is unchanged after dismiss
assert_equal "clear: BUFFER is not modified by clear" \
  "git st" "${BUFFER}"

# ==============================================================================
# 8. _zai_suggestion_accept — basic insert at end of BUFFER
# ==============================================================================

print "# --- 8. _zai_suggestion_accept: insert at end of BUFFER ---"

_test_load_suggestion

BUFFER="git st"
CURSOR=6
POSTDISPLAY="atus --short"
region_highlight=("P0 11 fg=8")
_ZAI_SUGGESTION_HIGHLIGHT="P0 11 fg=8"
_ZAI_SUGGESTION_PREFIX="git st"

_zai_suggestion_accept

# AC4: Accept appends suggestion text to BUFFER at CURSOR position
assert_equal "accept: BUFFER contains prefix + suggestion" \
  "git status --short" "${BUFFER}"

# AC5: Accept updates CURSOR to point after inserted text
assert_equal "accept: CURSOR advances past inserted text" \
  "18" "${CURSOR}"

# AC6: Accept clears POSTDISPLAY after insertion
assert_empty "accept: POSTDISPLAY is cleared after accept" "${POSTDISPLAY}"

# region_highlight cleared
assert_empty "accept: region_highlight is cleared after accept" \
  "${region_highlight[*]}"

# AC7 / AC10: BUFFER now holds the full text — user must press Enter separately.
# We verify accept-line was NOT called by checking no side effects happened.
# (If accept-line were called, the test itself would terminate/exit prematurely.)
assert_equal "accept: full command is in BUFFER (user must press Enter)" \
  "git status --short" "${BUFFER}"

# ==============================================================================
# 9. _zai_suggestion_accept — insert mid-cursor (cursor not at end)
# ==============================================================================

print "# --- 9. _zai_suggestion_accept: insert mid-cursor ---"

_test_load_suggestion

# Simulate: BUFFER="git  status" (two spaces), CURSOR=4 (after "git ")
# Suggestion is the missing space + "s" to fix the typo
BUFFER="git  status"
CURSOR=4
POSTDISPLAY="--short"
region_highlight=("P0 7 fg=8")
_ZAI_SUGGESTION_HIGHLIGHT="P0 7 fg=8"
_ZAI_SUGGESTION_PREFIX="git "

_zai_suggestion_accept

# Text before cursor: "git " (4 chars)
# Suggestion: "--short" (7 chars)
# Text after cursor: " status" (7 chars)
# Result: "git --short status"
assert_equal "accept mid-cursor: suggestion inserted at cursor" \
  "git --short status" "${BUFFER}"

# CURSOR was 4, suggestion is 7 chars → CURSOR = 4 + 7 = 11
assert_equal "accept mid-cursor: CURSOR advanced by suggestion length" \
  "11" "${CURSOR}"

assert_empty "accept mid-cursor: POSTDISPLAY cleared" "${POSTDISPLAY}"

# ==============================================================================
# 10. _zai_suggestion_accept — cursor at position 0
# ==============================================================================

print "# --- 10. _zai_suggestion_accept: cursor at position 0 ---"

_test_load_suggestion

BUFFER=""
CURSOR=0
POSTDISPLAY="ls -la"
region_highlight=("P0 6 fg=8")
_ZAI_SUGGESTION_HIGHLIGHT="P0 6 fg=8"
_ZAI_SUGGESTION_PREFIX=""

_zai_suggestion_accept

assert_equal "accept at 0: BUFFER becomes suggestion text" \
  "ls -la" "${BUFFER}"

assert_equal "accept at 0: CURSOR is 6 (length of suggestion)" \
  "6" "${CURSOR}"

assert_empty "accept at 0: POSTDISPLAY cleared" "${POSTDISPLAY}"

# ==============================================================================
# 11. _zai_suggestion_accept — empty POSTDISPLAY is no-op
# ==============================================================================

print "# --- 11. _zai_suggestion_accept: empty POSTDISPLAY is no-op ---"

_test_load_suggestion

BUFFER="git status"
CURSOR=10
POSTDISPLAY=""

_zai_suggestion_accept

# BUFFER unchanged
assert_equal "accept empty: BUFFER unchanged when POSTDISPLAY is empty" \
  "git status" "${BUFFER}"

# CURSOR unchanged
assert_equal "accept empty: CURSOR unchanged when POSTDISPLAY is empty" \
  "10" "${CURSOR}"

# ==============================================================================
# 12. _zai_suggestion_get_from_history — basic prefix match (newest wins)
# ==============================================================================

print "# --- 12. _zai_suggestion_get_from_history: basic match ---"

_test_load_suggestion
_zai_test_fc_mock_install

# "git st" matches "git status" (entry 2) and "git stash" (entry 6) and
# "git status --short" (entry 8). Entry 8 is the newest, so it wins.
local hist_result
hist_result=$(_zai_suggestion_get_from_history "git st")

# AC3: History prefix matching returns correct completion suffix from fc -l
# Entry 10 is "git diff HEAD", entry 9 is "grep ...", entry 8 is "git status --short"
# Most recent "git st*" is "git status --short" (entry 8)
assert_equal "history: 'git st' matches 'git status --short' (newest win)" \
  "atus --short" "${hist_result}"

_zai_test_fc_mock_remove

# ==============================================================================
# 13. _zai_suggestion_get_from_history — returns only suffix
# ==============================================================================

print "# --- 13. _zai_suggestion_get_from_history: returns only suffix ---"

_test_load_suggestion
_zai_test_fc_mock_install

# "git d" matches "git diff HEAD" (entry 10, most recent)
local diff_result
diff_result=$(_zai_suggestion_get_from_history "git d")

assert_equal "history: 'git d' returns 'iff HEAD' (suffix only)" \
  "iff HEAD" "${diff_result}"

_zai_test_fc_mock_remove

# ==============================================================================
# 14. _zai_suggestion_get_from_history — no match returns non-zero
# ==============================================================================

print "# --- 14. _zai_suggestion_get_from_history: no match ---"

_test_load_suggestion
_zai_test_fc_mock_install

_zai_suggestion_get_from_history "zzz_no_such_command" 2>/dev/null
assert_false "history: unmatched prefix returns non-zero" $?

local no_match_output
no_match_output=$(_zai_suggestion_get_from_history "zzz_no_such_command" 2>/dev/null)
assert_empty "history: unmatched prefix prints nothing" "${no_match_output}"

_zai_test_fc_mock_remove

# ==============================================================================
# 15. _zai_suggestion_get_from_history — exact match (no suffix) is skipped
# ==============================================================================

print "# --- 15. _zai_suggestion_get_from_history: exact match skipped ---"

_test_load_suggestion
_zai_test_fc_mock_install

# "ls -la" is in history exactly — but there is no suffix to offer
_zai_suggestion_get_from_history "ls -la" 2>/dev/null
assert_false "history: exact match (no suffix) returns non-zero" $?

_zai_test_fc_mock_remove

# ==============================================================================
# 16. _zai_suggestion_get_from_history — empty prefix returns non-zero
# ==============================================================================

print "# --- 16. _zai_suggestion_get_from_history: empty prefix ---"

_test_load_suggestion
_zai_test_fc_mock_install

_zai_suggestion_get_from_history "" 2>/dev/null
assert_false "history: empty prefix returns non-zero" $?

_zai_test_fc_mock_remove

# ==============================================================================
# 17. _zai_suggestion_get_from_history — fc output format robustness
# ==============================================================================

print "# --- 17. _zai_suggestion_get_from_history: fc format robustness ---"

_test_load_suggestion

# Install a mock fc that uses varying-width numbers (tests whitespace stripping)
function fc() {
  print "    1  echo hello"
  print "   12  echo world"
  print "  100  echo done"
  print " 1000  echo 'quoted args'"
}

local echo_result
echo_result=$(_zai_suggestion_get_from_history "echo ")

# Most recent entry with "echo " prefix is entry 1000: echo 'quoted args'
assert_equal "history: varying-width fc numbers handled correctly" \
  "'quoted args'" "${echo_result}"

_zai_test_fc_mock_remove

# ==============================================================================
# 18. _zai_suggestion_update — updates when BUFFER matches prefix
# ==============================================================================

print "# --- 18. _zai_suggestion_update: updates when prefix matches ---"

_test_load_suggestion

# Simulate: history suggestion was shown, BUFFER is still the same
BUFFER="git st"
CURSOR=6
_ZAI_SUGGESTION_PREFIX="git st"  # Set as if _zai_suggestion_show was called
POSTDISPLAY="ash"                 # Current history-based suggestion
region_highlight=("P0 3 fg=8")
_ZAI_SUGGESTION_HIGHLIGHT="P0 3 fg=8"

# Async AI result arrives: same BUFFER prefix → update should fire
_zai_suggestion_update "atus --short"

# AC9: Update replaces ghost text only if BUFFER still matches prefix
assert_equal "update: POSTDISPLAY replaced with AI suggestion" \
  "atus --short" "${POSTDISPLAY}"

assert_not_empty "update: region_highlight set for new suggestion" \
  "${region_highlight[*]}"

# ==============================================================================
# 19. _zai_suggestion_update — rejected when BUFFER has changed
# ==============================================================================

print "# --- 19. _zai_suggestion_update: rejected when BUFFER changed ---"

_test_load_suggestion

# Simulate: async result arrives but BUFFER has since been modified
BUFFER="git status"       # User typed more characters
CURSOR=10
_ZAI_SUGGESTION_PREFIX="git st"  # Old prefix when request was fired
POSTDISPLAY=""
region_highlight=()

# AI result for old "git st" prefix — should be discarded
_zai_suggestion_update "ash"

# AC9: POSTDISPLAY should NOT be updated because BUFFER != prefix
assert_empty "update: POSTDISPLAY NOT set when BUFFER has changed (stale)" \
  "${POSTDISPLAY}"

assert_empty "update: region_highlight NOT set for stale result" \
  "${region_highlight[*]}"

# ==============================================================================
# 20. _zai_suggestion_update — shows suggestion when no prior prefix stored
# ==============================================================================

print "# --- 20. _zai_suggestion_update: shows when no prior prefix ---"

_test_load_suggestion

# No prior suggestion was shown; _ZAI_SUGGESTION_PREFIX is empty
BUFFER="docker run"
CURSOR=10
_ZAI_SUGGESTION_PREFIX=""   # No prior show call
POSTDISPLAY=""
region_highlight=()

# First AI result should still be shown
_zai_suggestion_update " --rm -it ubuntu"

assert_equal "update: shows suggestion when no stored prefix" \
  " --rm -it ubuntu" "${POSTDISPLAY}"

# ==============================================================================
# 21. _zai_suggestion_update — empty text is no-op
# ==============================================================================

print "# --- 21. _zai_suggestion_update: empty text is no-op ---"

_test_load_suggestion

BUFFER="git"
CURSOR=3
_ZAI_SUGGESTION_PREFIX="git"
POSTDISPLAY="existing"
region_highlight=("P0 8 fg=8")
_ZAI_SUGGESTION_HIGHLIGHT="P0 8 fg=8"

_zai_suggestion_update ""

# POSTDISPLAY should remain unchanged
assert_equal "update: empty text leaves POSTDISPLAY unchanged" \
  "existing" "${POSTDISPLAY}"

# ==============================================================================
# 22. Double-source guard — reload does not reset state
# ==============================================================================

print "# --- 22. Double-source guard ---"

_test_load_suggestion

BUFFER="npm run"
CURSOR=7
_zai_suggestion_show " build"

local saved_postdisplay="${POSTDISPLAY}"
local saved_prefix="${_ZAI_SUGGESTION_PREFIX}"

# Source suggestion.zsh again — guard should prevent state reset
source "${_ZAI_TEST_SUGG_PLUGIN}/suggestion.zsh"

assert_equal "double-source: POSTDISPLAY preserved across re-source" \
  "${saved_postdisplay}" "${POSTDISPLAY}"

assert_equal "double-source: _ZAI_SUGGESTION_PREFIX preserved across re-source" \
  "${saved_prefix}" "${_ZAI_SUGGESTION_PREFIX}"

# ==============================================================================
# 23. _zai_suggestion_clear does not affect other region_highlight entries
# ==============================================================================

print "# --- 23. clear: does not remove other plugins' region_highlight entries ---"

_test_load_suggestion

# Simulate another plugin (e.g. zsh-syntax-highlighting) having its own entry
region_highlight=("0 3 fg=red")  # pre-existing entry from another plugin

BUFFER="git"
CURSOR=3
_zai_suggestion_show " status"

# region_highlight now has: the syntax-highlighting entry + our suggestion entry
assert_equal "clear pre: two region_highlight entries exist" \
  "2" "${#region_highlight}"

_zai_suggestion_clear

# After clear, only the external entry should remain
assert_equal "clear: only external region_highlight entry preserved" \
  "1" "${#region_highlight}"

assert_contains "clear: external entry '0 3 fg=red' is preserved" \
  "0 3 fg=red" "${region_highlight[1]}"

# ==============================================================================
# 24. Safety contract: accept does not execute the command
# ==============================================================================

print "# --- 24. Safety contract: accept inserts editable text only ---"

_test_load_suggestion

# Set up a dangerous command in POSTDISPLAY
BUFFER="rm -rf"
CURSOR=6
POSTDISPLAY=" /tmp/test"
region_highlight=("P0 10 fg=8")
_ZAI_SUGGESTION_HIGHLIGHT="P0 10 fg=8"
_ZAI_SUGGESTION_PREFIX="rm -rf"

# Track whether accept-line is called by mocking zle with a side-effect monitor
typeset -g _ZAI_TEST_ACCEPT_LINE_CALLED=0
function zle() {
  if [[ "${1}" == ".accept-line" ]] || [[ "${1}" == "accept-line" ]]; then
    _ZAI_TEST_ACCEPT_LINE_CALLED=1
  fi
  return 0
}

_zai_suggestion_accept

# AC7 / AC10: accept-line must NOT be called
assert_equal "safety: accept-line is NOT called during suggestion accept" \
  "0" "${_ZAI_TEST_ACCEPT_LINE_CALLED}"

# BUFFER holds the full command but command was NOT executed
assert_equal "safety: full command is in editable BUFFER" \
  "rm -rf /tmp/test" "${BUFFER}"

# Restore zle mock
function zle() { return 0 }

# ==============================================================================
# 25. _zai_suggestion_reset — test helper clears all state
# ==============================================================================

print "# --- 25. _zai_suggestion_reset ---"

_test_load_suggestion

BUFFER="test"
CURSOR=4
_zai_suggestion_show " value"

assert_not_empty "_zai_suggestion_reset pre: POSTDISPLAY is set" "${POSTDISPLAY}"

_zai_suggestion_reset

assert_empty "_zai_suggestion_reset: POSTDISPLAY cleared" "${POSTDISPLAY}"
assert_empty "_zai_suggestion_reset: _ZAI_SUGGESTION_HIGHLIGHT cleared" \
  "${_ZAI_SUGGESTION_HIGHLIGHT}"
assert_empty "_zai_suggestion_reset: _ZAI_SUGGESTION_PREFIX cleared" \
  "${_ZAI_SUGGESTION_PREFIX}"
assert_empty "_zai_suggestion_reset: region_highlight cleared" \
  "${region_highlight[*]}"

# ==============================================================================
# 26. _zai_suggestion_get_from_history — single-character prefix
# ==============================================================================

print "# --- 26. _zai_suggestion_get_from_history: single-char prefix ---"

_test_load_suggestion

function fc() {
  print "    1  ls"
  print "    2  less /etc/hosts"
  print "    3  ln -s foo bar"
}

local l_result
l_result=$(_zai_suggestion_get_from_history "l")

# Most recent entry starting with "l" is "ln -s foo bar" (entry 3)
assert_equal "history: single-char 'l' matches newest 'ln -s foo bar'" \
  "n -s foo bar" "${l_result}"

_zai_test_fc_mock_remove

# ==============================================================================
# 27. Multiple show+clear cycles — region_highlight stays clean
# ==============================================================================

print "# --- 27. Multiple show/clear cycles keep region_highlight clean ---"

_test_load_suggestion

BUFFER="git"
CURSOR=3

local cycle
for cycle in 1 2 3 4 5; do
  _zai_suggestion_show " status"
  _zai_suggestion_clear
done

assert_empty "cycles: region_highlight is empty after 5 show+clear cycles" \
  "${region_highlight[*]}"

assert_empty "cycles: POSTDISPLAY is empty after 5 show+clear cycles" \
  "${POSTDISPLAY}"

# ==============================================================================
# 28. _zai_suggestion_accept — internal state fully cleared
# ==============================================================================

print "# --- 28. accept: all internal state cleared after accept ---"

_test_load_suggestion

BUFFER="ls"
CURSOR=2
POSTDISPLAY=" -la"
region_highlight=("P0 4 fg=8")
_ZAI_SUGGESTION_HIGHLIGHT="P0 4 fg=8"
_ZAI_SUGGESTION_PREFIX="ls"

_zai_suggestion_accept

assert_empty "accept: _ZAI_SUGGESTION_HIGHLIGHT cleared" \
  "${_ZAI_SUGGESTION_HIGHLIGHT}"

assert_empty "accept: _ZAI_SUGGESTION_PREFIX cleared" \
  "${_ZAI_SUGGESTION_PREFIX}"

assert_empty "accept: POSTDISPLAY cleared" "${POSTDISPLAY}"

assert_empty "accept: region_highlight cleared" "${region_highlight[*]}"

# ==============================================================================
# Standalone mode: print TAP plan and summary
# ==============================================================================

if [[ "${0}" == "${(%):-%x}" ]] || [[ "${ZSH_ARGZERO:-}" == *"test_suggestion.zsh" ]]; then
  tap_plan
  tap_summary
  exit $(( _TAP_FAIL_COUNT > 0 ? 1 : 0 ))
fi
