#!/usr/bin/env zsh
# ==============================================================================
# zsh-ai-complete: KeybindingManager Tests
# File: tests/test_keybindings.zsh
# ==============================================================================
#
# Run standalone:  zsh tests/test_keybindings.zsh
# Run via runner:  zsh tests/test_runner.zsh tests/test_keybindings.zsh
#
# Tests cover TASK-008 acceptance criteria:
#   AC1  Tab key completes normally (inserts tab) when no suggestion shown
#   AC2  Right Arrow key moves cursor forward when no suggestion shown
#   AC3  Right Arrow accepts suggestion when POSTDISPLAY non-empty
#   AC4  Tab accepts suggestion when POSTDISPLAY non-empty
#   AC5  Escape key dismisses suggestion without breaking arrow key escape sequences
#   AC6  KEYTIMEOUT=10 enables 100ms Escape disambiguation without sluggishness
#   AC7  Ctrl+Space manually triggers completion, bypassing debounce in manual mode
#   AC8  Self-insert shows instant history match before async request fires
#   AC9  Backward-delete clears suggestion and restarts debounce timer
#   AC10 Accept-line calls full cleanup before executing command
#   AC11 Keybinding conflicts with existing oh-my-zsh/zsh-autosuggestions minimized
#
# ==============================================================================

# Capture script directory at TOP LEVEL (outside functions).
typeset -g _ZAI_TEST_KB_DIR="${${(%):-%x}:a:h}"
typeset -g _ZAI_TEST_KB_PLUGIN="${_ZAI_TEST_KB_DIR}/../plugin/lib"

# ── Bootstrap: load test runner if not already loaded ─────────────────────────
if (( ! ${+functions[assert_equal]} )); then
  source "${_ZAI_TEST_KB_DIR}/test_runner.zsh"
fi

# ==============================================================================
# ZLE variable simulation
# ==============================================================================
# These variables are set by ZLE during widget execution. We declare them as
# globals so widget functions can read and write them in the test environment.

typeset -g  BUFFER=""
typeset -gi CURSOR=0
typeset -g  POSTDISPLAY=""
typeset -ga region_highlight=()
typeset -g  KEYS=""        # Key sequence that triggered the current widget
typeset -g  WIDGET=""      # Name of the widget being executed
typeset -gi KEYTIMEOUT=1   # Set to a default; _zai_bind_keys will set to 10

# ==============================================================================
# Call tracking infrastructure
# ==============================================================================
# Track which ZLE commands and mock functions are called by each widget.
# Each tracking variable is reset before each test.

typeset -ga _ZAI_TEST_ZLE_CALLS=()       # Record all `zle <arg>` invocations
typeset -ga _ZAI_TEST_DEBOUNCE_CALLS=()  # Track _zai_debounce_start calls
typeset -ga _ZAI_TEST_DEBOUNCE_CANCEL=() # Track _zai_debounce_cancel calls
typeset -ga _ZAI_TEST_ASYNC_CALLS=()     # Track _zai_async_request calls
typeset -ga _ZAI_TEST_ASYNC_CANCEL=()    # Track _zai_async_cancel calls
typeset -ga _ZAI_TEST_CLEANUP_CALLS=()   # Track _zai_full_cleanup calls

# ==============================================================================
# ZLE command mock
# ==============================================================================
# `zle` is only active inside ZLE context. We mock it as a tracking function.
# The mock records each call and simulates the side effects of key operations
# that affect BUFFER and CURSOR.

function zle() {
  local cmd="${1}"
  _ZAI_TEST_ZLE_CALLS+=("${cmd}")

  case "${cmd}" in
    .self-insert)
      # Simulate inserting the character recorded in $KEYS at cursor position.
      # For tests, we treat KEYS as the character being typed.
      if [[ -n "${KEYS}" ]] && [[ "${#KEYS}" -eq 1 ]]; then
        BUFFER="${BUFFER[1,CURSOR]}${KEYS}${BUFFER[$((CURSOR + 1)),-1]}"
        (( CURSOR++ ))
      fi
      ;;
    .backward-delete-char)
      # Simulate deleting the character before the cursor.
      if (( CURSOR > 0 )); then
        BUFFER="${BUFFER[1,$((CURSOR - 1))]}${BUFFER[$((CURSOR + 1)),-1]}"
        (( CURSOR-- ))
      fi
      ;;
    .accept-line)
      # Simulate executing the command — no-op in tests.
      ;;
    forward-char)
      # Simulate moving cursor one character forward.
      (( CURSOR < ${#BUFFER} )) && (( CURSOR++ ))
      ;;
    expand-or-complete)
      # Simulate tab completion — no-op in tests; we just track the call.
      ;;
    -R)
      # Redraw request — no-op in tests.
      ;;
    -N)
      # Widget registration — no-op (handled by real zle during plugin load).
      ;;
    *)
      # Unknown command — record it for assertion.
      ;;
  esac
  return 0
}

# ==============================================================================
# fc builtin mock for history matching
# ==============================================================================

_zai_test_fc_mock_install() {
  function fc() {
    print "    1  ls -la"
    print "    2  git status"
    print "    3  git add ."
    print "    4  git commit -m 'init'"
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
# Mock async engine functions
# ==============================================================================
# These are defined in async.zsh (TASK-007). We mock them here so keybindings
# can be tested independently.

function _zai_debounce_start() {
  _ZAI_TEST_DEBOUNCE_CALLS+=("debounce_start:${BUFFER}")
}

function _zai_debounce_cancel() {
  _ZAI_TEST_DEBOUNCE_CANCEL+=("debounce_cancel")
}

function _zai_async_request() {
  _ZAI_TEST_ASYNC_CALLS+=("async_request:${1}")
}

function _zai_async_cancel() {
  _ZAI_TEST_ASYNC_CANCEL+=("async_cancel")
}

function _zai_full_cleanup() {
  _ZAI_TEST_CLEANUP_CALLS+=("full_cleanup")
  # Also clear POSTDISPLAY as the real implementation does
  POSTDISPLAY=""
}

# ==============================================================================
# Test state reset helper
# ==============================================================================

_zai_test_kb_reset() {
  BUFFER=""
  CURSOR=0
  POSTDISPLAY=""
  KEYS=""
  WIDGET=""
  region_highlight=()
  _ZAI_SUGGESTION_HIGHLIGHT=""
  _ZAI_SUGGESTION_PREFIX=""
  _ZAI_TEST_ZLE_CALLS=()
  _ZAI_TEST_DEBOUNCE_CALLS=()
  _ZAI_TEST_DEBOUNCE_CANCEL=()
  _ZAI_TEST_ASYNC_CALLS=()
  _ZAI_TEST_ASYNC_CANCEL=()
  _ZAI_TEST_CLEANUP_CALLS=()
}

# ==============================================================================
# Bootstrap: load modules under test
# ==============================================================================

_test_load_keybindings() {
  # Clear module guards to allow reload
  unset _ZAI_KEYBINDINGS_LOADED
  unset _ZAI_SUGGESTION_LOADED
  unset _ZAI_CONFIG_LOADED
  unset '_ZAI_CONFIG_DEFAULTS'
  unset '_ZAI_CONFIG_OVERRIDES'

  # Source dependencies + module under test
  source "${_ZAI_TEST_KB_PLUGIN}/config.zsh"
  source "${_ZAI_TEST_KB_PLUGIN}/suggestion.zsh"
  source "${_ZAI_TEST_KB_PLUGIN}/keybindings.zsh"

  # Reset all state
  _zai_test_kb_reset
}

# ==============================================================================
# Print header
# ==============================================================================

print "# [test_keybindings.zsh] KeybindingManager Tests"

# ==============================================================================
# 1. _zai_widget_self_insert — basic character insertion
# ==============================================================================

print "# --- 1. _zai_widget_self_insert: basic character insertion ---"

_test_load_keybindings
_zai_test_fc_mock_install

BUFFER="git "
CURSOR=4
KEYS="s"

_zai_widget_self_insert

# The mock zle .self-insert inserted 's' at position 4
assert_equal "self-insert: character added to BUFFER" \
  "git s" "${BUFFER}"

assert_equal "self-insert: CURSOR advanced past inserted char" \
  "5" "${CURSOR}"

_zai_test_fc_mock_remove

# ==============================================================================
# 2. _zai_widget_self_insert — shows instant history match (AC8)
# ==============================================================================

print "# --- 2. _zai_widget_self_insert: shows instant history match (AC8) ---"

_test_load_keybindings
_zai_test_fc_mock_install

# Manually set BUFFER as if user already typed "git s" (after self-insert fires)
# We set BUFFER + CURSOR before calling so the history lookup works
BUFFER="git "
CURSOR=4
KEYS="s"

_zai_widget_self_insert
# After self-insert, BUFFER="git s", CURSOR=5

# AC8: POSTDISPLAY should show the history match suffix for "git s"
# From mock history: "git status --short" (entry 8) is most recent "git s*"
assert_equal "self-insert: POSTDISPLAY shows history match 'tatus --short'" \
  "tatus --short" "${POSTDISPLAY}"

_zai_test_fc_mock_remove

# ==============================================================================
# 3. _zai_widget_self_insert — no history match leaves POSTDISPLAY empty
# ==============================================================================

print "# --- 3. _zai_widget_self_insert: no history match → no POSTDISPLAY ---"

_test_load_keybindings
_zai_test_fc_mock_install

BUFFER="zzz_no_match_x"
CURSOR=14
KEYS="y"

_zai_widget_self_insert

assert_empty "self-insert: POSTDISPLAY empty when no history match" "${POSTDISPLAY}"

_zai_test_fc_mock_remove

# ==============================================================================
# 4. _zai_widget_self_insert — triggers debounce in auto mode (AC8)
# ==============================================================================

print "# --- 4. _zai_widget_self_insert: triggers debounce in auto mode ---"

_test_load_keybindings
_zai_config_set trigger "auto"  # ensure auto mode
_zai_test_fc_mock_remove

BUFFER="git "
CURSOR=4
KEYS="s"

_zai_widget_self_insert

assert_not_empty "self-insert: debounce_start called in auto mode" \
  "${_ZAI_TEST_DEBOUNCE_CALLS[*]}"

assert_contains "self-insert: debounce_start called with updated BUFFER" \
  "debounce_start:" "${_ZAI_TEST_DEBOUNCE_CALLS[1]}"

# ==============================================================================
# 5. _zai_widget_self_insert — skips debounce in manual mode (AC7)
# ==============================================================================

print "# --- 5. _zai_widget_self_insert: skips debounce in manual mode (AC7) ---"

_test_load_keybindings
_zai_config_set trigger "manual"  # manual mode

BUFFER="git "
CURSOR=4
KEYS="s"

_zai_widget_self_insert

assert_empty "self-insert: debounce NOT called in manual mode" \
  "${_ZAI_TEST_DEBOUNCE_CALLS[*]}"

_zai_config_reset

# ==============================================================================
# 6. _zai_widget_self_insert — clears stale POSTDISPLAY before new match
# ==============================================================================

print "# --- 6. _zai_widget_self_insert: clears stale POSTDISPLAY ---"

_test_load_keybindings

# Simulate an existing suggestion showing from a previous keystroke
POSTDISPLAY="old suggestion"
region_highlight=("P0 14 fg=8")
_ZAI_SUGGESTION_HIGHLIGHT="P0 14 fg=8"
_ZAI_SUGGESTION_PREFIX="git"

# Install a fc mock that returns no results — ensures POSTDISPLAY stays empty
# after the stale suggestion is cleared (deterministic regardless of real history).
function fc() { return 0 }

BUFFER="git"
CURSOR=3
KEYS="x"

_zai_widget_self_insert

# POSTDISPLAY should be cleared (old stale suggestion gone, no new match)
assert_empty "self-insert: stale POSTDISPLAY cleared before new match" \
  "${POSTDISPLAY}"

assert_not_equal "self-insert: stale suggestion 'old suggestion' was replaced" \
  "old suggestion" "${POSTDISPLAY}"

_zai_test_fc_mock_remove

# ==============================================================================
# 7. _zai_widget_backward_delete — basic deletion (AC9)
# ==============================================================================

print "# --- 7. _zai_widget_backward_delete: basic deletion (AC9) ---"

_test_load_keybindings

BUFFER="git st"
CURSOR=6
POSTDISPLAY="atus --short"
region_highlight=("P0 12 fg=8")
_ZAI_SUGGESTION_HIGHLIGHT="P0 12 fg=8"
_ZAI_SUGGESTION_PREFIX="git st"

_zai_widget_backward_delete

# AC9: backward-delete-char should have been called (mock simulates it)
assert_equal "backward-delete: BUFFER has last char removed" \
  "git s" "${BUFFER}"

assert_equal "backward-delete: CURSOR decremented" \
  "5" "${CURSOR}"

# ==============================================================================
# 8. _zai_widget_backward_delete — clears suggestion (AC9)
# ==============================================================================

print "# --- 8. _zai_widget_backward_delete: clears suggestion (AC9) ---"

_test_load_keybindings

BUFFER="git st"
CURSOR=6
POSTDISPLAY="atus --short"
region_highlight=("P0 12 fg=8")
_ZAI_SUGGESTION_HIGHLIGHT="P0 12 fg=8"
_ZAI_SUGGESTION_PREFIX="git st"

_zai_widget_backward_delete

# AC9: Suggestion must be cleared after delete
assert_empty "backward-delete: POSTDISPLAY cleared after delete" "${POSTDISPLAY}"

assert_empty "backward-delete: region_highlight cleared after delete" \
  "${region_highlight[*]}"

# ==============================================================================
# 9. _zai_widget_backward_delete — restarts debounce when buffer >= min_chars (AC9)
# ==============================================================================

print "# --- 9. _zai_widget_backward_delete: restarts debounce when buffer >= min_chars ---"

_test_load_keybindings
_zai_config_set trigger "auto"
_zai_config_set min_chars "3"

BUFFER="git stat"  # 8 chars; after delete will be "git sta" (7 chars) >= 3
CURSOR=8

_zai_widget_backward_delete

assert_not_empty "backward-delete: debounce restarted when buffer still >= min_chars" \
  "${_ZAI_TEST_DEBOUNCE_CALLS[*]}"

_zai_config_reset

# ==============================================================================
# 10. _zai_widget_backward_delete — cancels debounce when buffer < min_chars
# ==============================================================================

print "# --- 10. _zai_widget_backward_delete: cancels debounce when buffer < min_chars ---"

_test_load_keybindings
_zai_config_set trigger "auto"
_zai_config_set min_chars "3"

BUFFER="ab"  # 2 chars; after delete will be "a" (1 char) < 3
CURSOR=2

_zai_widget_backward_delete

assert_not_empty "backward-delete: debounce cancelled when buffer < min_chars" \
  "${_ZAI_TEST_DEBOUNCE_CANCEL[*]}"

assert_empty "backward-delete: debounce NOT started when buffer < min_chars" \
  "${_ZAI_TEST_DEBOUNCE_CALLS[*]}"

_zai_config_reset

# ==============================================================================
# 11. _zai_widget_backward_delete — no debounce in manual mode
# ==============================================================================

print "# --- 11. _zai_widget_backward_delete: no debounce in manual mode ---"

_test_load_keybindings
_zai_config_set trigger "manual"

BUFFER="git status"
CURSOR=10

_zai_widget_backward_delete

assert_empty "backward-delete: no debounce in manual mode" \
  "${_ZAI_TEST_DEBOUNCE_CALLS[*]}"

assert_empty "backward-delete: no debounce cancel in manual mode" \
  "${_ZAI_TEST_DEBOUNCE_CANCEL[*]}"

_zai_config_reset

# ==============================================================================
# 12. _zai_widget_accept_suggestion — accepts ghost text (AC3, AC4)
# ==============================================================================

print "# --- 12. _zai_widget_accept_suggestion: accepts ghost text (AC3, AC4) ---"

_test_load_keybindings

BUFFER="git st"
CURSOR=6
POSTDISPLAY="atus --short"
region_highlight=("P0 12 fg=8")
_ZAI_SUGGESTION_HIGHLIGHT="P0 12 fg=8"
_ZAI_SUGGESTION_PREFIX="git st"

KEYS=$'\e[C'  # Right Arrow

_zai_widget_accept_suggestion

# AC3: Right Arrow accepts suggestion when POSTDISPLAY non-empty
# AC4: Tab accepts suggestion when POSTDISPLAY non-empty
assert_equal "accept-suggestion: BUFFER contains prefix + ghost text" \
  "git status --short" "${BUFFER}"

assert_equal "accept-suggestion: CURSOR advanced past inserted text" \
  "18" "${CURSOR}"

assert_empty "accept-suggestion: POSTDISPLAY cleared after accept" "${POSTDISPLAY}"

# ==============================================================================
# 13. _zai_widget_accept_suggestion — Right Arrow falls through when no suggestion (AC2)
# ==============================================================================

print "# --- 13. _zai_widget_accept_suggestion: Right Arrow fallthrough to forward-char (AC2) ---"

_test_load_keybindings

BUFFER="git status"
CURSOR=3
POSTDISPLAY=""
KEYS=$'\e[C'  # Right Arrow

_zai_widget_accept_suggestion

# AC2: Right Arrow moves cursor forward when no suggestion shown
assert_contains "accept-suggestion: forward-char called when no suggestion (VT arrow)" \
  "forward-char" "${_ZAI_TEST_ZLE_CALLS[*]}"

assert_equal "accept-suggestion: CURSOR moved forward (no suggestion)" \
  "4" "${CURSOR}"

# ==============================================================================
# 14. _zai_widget_accept_suggestion — Right Arrow app mode falls through (AC2)
# ==============================================================================

print "# --- 14. _zai_widget_accept_suggestion: Right Arrow eOC fallthrough (AC2) ---"

_test_load_keybindings

BUFFER="docker run"
CURSOR=3
POSTDISPLAY=""
KEYS=$'\eOC'  # Right Arrow application mode

_zai_widget_accept_suggestion

assert_contains "accept-suggestion: forward-char called when no suggestion (app mode arrow)" \
  "forward-char" "${_ZAI_TEST_ZLE_CALLS[*]}"

# ==============================================================================
# 15. _zai_widget_accept_suggestion — Tab falls through to expand-or-complete (AC1)
# ==============================================================================

print "# --- 15. _zai_widget_accept_suggestion: Tab fallthrough to expand-or-complete (AC1) ---"

_test_load_keybindings

BUFFER="git "
CURSOR=4
POSTDISPLAY=""
KEYS=$'\t'  # Tab

_zai_widget_accept_suggestion

# AC1: Tab key completes normally when no suggestion shown
assert_contains "accept-suggestion: expand-or-complete called when no suggestion (Tab)" \
  "expand-or-complete" "${_ZAI_TEST_ZLE_CALLS[*]}"

# BUFFER should be unchanged (expand-or-complete mock is a no-op)
assert_equal "accept-suggestion: BUFFER unchanged on Tab with no suggestion" \
  "git " "${BUFFER}"

# ==============================================================================
# 16. _zai_widget_accept_suggestion — Tab accepts suggestion when shown (AC4)
# ==============================================================================

print "# --- 16. _zai_widget_accept_suggestion: Tab accepts suggestion (AC4) ---"

_test_load_keybindings

BUFFER="git s"
CURSOR=5
POSTDISPLAY="tatus"
region_highlight=("P0 5 fg=8")
_ZAI_SUGGESTION_HIGHLIGHT="P0 5 fg=8"
_ZAI_SUGGESTION_PREFIX="git s"
KEYS=$'\t'  # Tab

_zai_widget_accept_suggestion

# AC4: Tab accepts suggestion when POSTDISPLAY non-empty
assert_equal "accept-suggestion: Tab accepts ghost text into BUFFER" \
  "git status" "${BUFFER}"

assert_empty "accept-suggestion: POSTDISPLAY cleared after Tab accept" "${POSTDISPLAY}"

# expand-or-complete should NOT have been called (suggestion was accepted)
local expand_called=0
local c
for c in "${_ZAI_TEST_ZLE_CALLS[@]}"; do
  [[ "${c}" == "expand-or-complete" ]] && expand_called=1
done
assert_equal "accept-suggestion: expand-or-complete NOT called when suggestion accepted via Tab" \
  "0" "${expand_called}"

# ==============================================================================
# 17. _zai_widget_dismiss — clears ghost text (AC5)
# ==============================================================================

print "# --- 17. _zai_widget_dismiss: clears ghost text (AC5) ---"

_test_load_keybindings

BUFFER="git st"
CURSOR=6
POSTDISPLAY="atus"
region_highlight=("P0 4 fg=8")
_ZAI_SUGGESTION_HIGHLIGHT="P0 4 fg=8"
_ZAI_SUGGESTION_PREFIX="git st"

_zai_widget_dismiss

# AC5: Escape key dismisses suggestion
assert_empty "dismiss: POSTDISPLAY cleared after dismiss" "${POSTDISPLAY}"

assert_empty "dismiss: region_highlight cleared after dismiss" \
  "${region_highlight[*]}"

# BUFFER must be unchanged — dismiss only clears ghost text, not real input
assert_equal "dismiss: BUFFER unchanged after dismiss" \
  "git st" "${BUFFER}"

# ==============================================================================
# 18. _zai_widget_dismiss — cancels in-flight requests and debounce (AC5)
# ==============================================================================

print "# --- 18. _zai_widget_dismiss: cancels in-flight requests and debounce ---"

_test_load_keybindings

BUFFER="git st"
CURSOR=6
POSTDISPLAY="atus"

_zai_widget_dismiss

assert_not_empty "dismiss: debounce_cancel called" \
  "${_ZAI_TEST_DEBOUNCE_CANCEL[*]}"

assert_not_empty "dismiss: async_cancel called" \
  "${_ZAI_TEST_ASYNC_CANCEL[*]}"

# ==============================================================================
# 19. _zai_widget_dismiss — works when no suggestion is showing
# ==============================================================================

print "# --- 19. _zai_widget_dismiss: works when POSTDISPLAY is empty ---"

_test_load_keybindings

BUFFER="git status"
CURSOR=10
POSTDISPLAY=""

# Should not error when called with no active suggestion
_zai_widget_dismiss
local dismiss_exit=$?

assert_true "dismiss: no error when called with empty POSTDISPLAY" ${dismiss_exit}

# ==============================================================================
# 20. _zai_widget_manual_trigger — fires async request immediately (AC7)
# ==============================================================================

print "# --- 20. _zai_widget_manual_trigger: fires async request (AC7) ---"

_test_load_keybindings
_zai_config_set min_chars "3"

BUFFER="git status"
CURSOR=10

_zai_widget_manual_trigger

# AC7: Ctrl+Space manually triggers completion
assert_not_empty "manual-trigger: _zai_async_request called" \
  "${_ZAI_TEST_ASYNC_CALLS[*]}"

assert_equal "manual-trigger: _zai_async_request called with BUFFER" \
  "async_request:git status" "${_ZAI_TEST_ASYNC_CALLS[1]}"

_zai_config_reset

# ==============================================================================
# 21. _zai_widget_manual_trigger — cancels pending debounce before firing (AC7)
# ==============================================================================

print "# --- 21. _zai_widget_manual_trigger: cancels debounce before firing ---"

_test_load_keybindings
_zai_config_set min_chars "3"

BUFFER="git log"
CURSOR=7

_zai_widget_manual_trigger

# Should cancel debounce (bypass it) before firing immediately
assert_not_empty "manual-trigger: debounce_cancel called before async_request" \
  "${_ZAI_TEST_DEBOUNCE_CANCEL[*]}"

_zai_config_reset

# ==============================================================================
# 22. _zai_widget_manual_trigger — does NOT fire when buffer < min_chars
# ==============================================================================

print "# --- 22. _zai_widget_manual_trigger: does NOT fire when buffer < min_chars ---"

_test_load_keybindings
_zai_config_set min_chars "3"

BUFFER="gi"   # 2 chars — below min_chars=3
CURSOR=2

_zai_widget_manual_trigger

assert_empty "manual-trigger: no async_request when buffer < min_chars" \
  "${_ZAI_TEST_ASYNC_CALLS[*]}"

_zai_config_reset

# ==============================================================================
# 23. _zai_widget_manual_trigger — fires in manual trigger mode (AC7)
# ==============================================================================

print "# --- 23. _zai_widget_manual_trigger: fires in manual mode (AC7) ---"

_test_load_keybindings
_zai_config_set trigger "manual"  # explicit manual mode
_zai_config_set min_chars "3"

BUFFER="docker run --rm"
CURSOR=15

_zai_widget_manual_trigger

# AC7: Ctrl+Space manually triggers completion, bypassing debounce in manual mode
assert_not_empty "manual-trigger: async_request fired in manual mode" \
  "${_ZAI_TEST_ASYNC_CALLS[*]}"

assert_equal "manual-trigger: correct BUFFER passed to async_request" \
  "async_request:docker run --rm" "${_ZAI_TEST_ASYNC_CALLS[1]}"

_zai_config_reset

# ==============================================================================
# 24. _zai_widget_accept_line — calls full cleanup (AC10)
# ==============================================================================

print "# --- 24. _zai_widget_accept_line: calls full cleanup (AC10) ---"

_test_load_keybindings

BUFFER="git status"
CURSOR=10
POSTDISPLAY=" --short"

_zai_widget_accept_line

# AC10: Accept-line calls full cleanup before executing command
assert_not_empty "accept-line: _zai_full_cleanup called" \
  "${_ZAI_TEST_CLEANUP_CALLS[*]}"

# ==============================================================================
# 25. _zai_widget_accept_line — calls .accept-line after cleanup (AC10)
# ==============================================================================

print "# --- 25. _zai_widget_accept_line: calls .accept-line after cleanup ---"

_test_load_keybindings

BUFFER="ls -la"
CURSOR=6
POSTDISPLAY=""

_zai_widget_accept_line

# .accept-line must be called (original built-in)
assert_contains "accept-line: zle .accept-line called" \
  ".accept-line" "${_ZAI_TEST_ZLE_CALLS[*]}"

# ==============================================================================
# 26. _zai_widget_accept_line — cleanup happens BEFORE accept-line
# ==============================================================================

print "# --- 26. _zai_widget_accept_line: cleanup order is cleanup → accept-line ---"

_test_load_keybindings

# We verify order by checking that cleanup is recorded before .accept-line
# in the combined call log.
typeset -g _ZAI_TEST_CALL_ORDER=()

function _zai_full_cleanup() {
  _ZAI_TEST_CALL_ORDER+=("cleanup")
}

# Override zle to track .accept-line specifically
function zle() {
  if [[ "${1}" == ".accept-line" ]]; then
    _ZAI_TEST_CALL_ORDER+=("accept-line")
  fi
  return 0
}

BUFFER="echo hello"
CURSOR=10

_zai_widget_accept_line

assert_equal "accept-line: cleanup called first (index 1)" \
  "cleanup" "${_ZAI_TEST_CALL_ORDER[1]}"

assert_equal "accept-line: .accept-line called second (index 2)" \
  "accept-line" "${_ZAI_TEST_CALL_ORDER[2]}"

# Restore zle mock
function zle() {
  local cmd="${1}"
  _ZAI_TEST_ZLE_CALLS+=("${cmd}")
  return 0
}

# ==============================================================================
# 27. _zai_register_widgets — registers all expected widgets
# ==============================================================================

print "# --- 27. _zai_register_widgets: all widgets defined as functions ---"

_test_load_keybindings

# Verify all widget functions exist after module load
assert_true "register: _zai_widget_self_insert is defined" \
  $(( ${+functions[_zai_widget_self_insert]} ))

assert_true "register: _zai_widget_backward_delete is defined" \
  $(( ${+functions[_zai_widget_backward_delete]} ))

assert_true "register: _zai_widget_accept_suggestion is defined" \
  $(( ${+functions[_zai_widget_accept_suggestion]} ))

assert_true "register: _zai_widget_dismiss is defined" \
  $(( ${+functions[_zai_widget_dismiss]} ))

assert_true "register: _zai_widget_manual_trigger is defined" \
  $(( ${+functions[_zai_widget_manual_trigger]} ))

assert_true "register: _zai_widget_accept_line is defined" \
  $(( ${+functions[_zai_widget_accept_line]} ))

# ==============================================================================
# 28. _zai_bind_keys — sets KEYTIMEOUT=10 (AC6)
# ==============================================================================

print "# --- 28. _zai_bind_keys: KEYTIMEOUT set to 10 (AC6) ---"

_test_load_keybindings

# Reset KEYTIMEOUT to confirm _zai_bind_keys changes it
KEYTIMEOUT=1

_zai_bind_keys 2>/dev/null  # suppress bindkey output in test env

# AC6: KEYTIMEOUT=10 enables 100ms Escape disambiguation
assert_equal "bind-keys: KEYTIMEOUT set to 10 for 100ms escape disambiguation" \
  "10" "${KEYTIMEOUT}"

# ==============================================================================
# 29. accept-suggestion — unknown key falls through to forward-char
# ==============================================================================

print "# --- 29. _zai_widget_accept_suggestion: unknown key falls through to forward-char ---"

_test_load_keybindings

BUFFER="hello world"
CURSOR=0
POSTDISPLAY=""
KEYS=$'\eX'  # Some unknown escape sequence

_zai_widget_accept_suggestion

assert_contains "accept-suggestion: forward-char called for unknown key fallthrough" \
  "forward-char" "${_ZAI_TEST_ZLE_CALLS[*]}"

# ==============================================================================
# 30. Double-source guard — reload does not reset widget state
# ==============================================================================

print "# --- 30. Double-source guard: reload is a no-op ---"

_test_load_keybindings

# Set some state to verify it survives re-source
POSTDISPLAY="test suggestion"
local saved_postdisplay="${POSTDISPLAY}"

# Source keybindings.zsh again — guard should prevent any state reset
source "${_ZAI_TEST_KB_PLUGIN}/keybindings.zsh"

assert_equal "double-source: POSTDISPLAY preserved across re-source" \
  "${saved_postdisplay}" "${POSTDISPLAY}"

assert_true "double-source: _ZAI_KEYBINDINGS_LOADED flag prevents re-init" \
  $(( ${+_ZAI_KEYBINDINGS_LOADED} ))

# ==============================================================================
# 31. _zai_widget_accept_suggestion — safety: accept does NOT call accept-line
# ==============================================================================

print "# --- 31. accept-suggestion: does NOT call accept-line (safety) ---"

_test_load_keybindings

BUFFER="rm -rf"
CURSOR=6
POSTDISPLAY=" /tmp/test"
region_highlight=("P0 10 fg=8")
_ZAI_SUGGESTION_HIGHLIGHT="P0 10 fg=8"
_ZAI_SUGGESTION_PREFIX="rm -rf"

# Track accept-line calls specifically
typeset -g _ZAI_TEST_ACCEPT_LINE_CALLED=0
function zle() {
  local cmd="${1}"
  _ZAI_TEST_ZLE_CALLS+=("${cmd}")
  if [[ "${cmd}" == ".accept-line" ]] || [[ "${cmd}" == "accept-line" ]]; then
    _ZAI_TEST_ACCEPT_LINE_CALLED=1
  fi
  return 0
}

KEYS=$'\e[C'
_zai_widget_accept_suggestion

assert_equal "accept-suggestion: .accept-line NOT called — suggestion is editable text" \
  "0" "${_ZAI_TEST_ACCEPT_LINE_CALLED}"

assert_equal "accept-suggestion: full command in BUFFER (user must press Enter)" \
  "rm -rf /tmp/test" "${BUFFER}"

# Restore zle mock
function zle() {
  local cmd="${1}"
  _ZAI_TEST_ZLE_CALLS+=("${cmd}")
  case "${cmd}" in
    .self-insert)
      if [[ -n "${KEYS}" ]] && [[ "${#KEYS}" -eq 1 ]]; then
        BUFFER="${BUFFER[1,CURSOR]}${KEYS}${BUFFER[$((CURSOR + 1)),-1]}"
        (( CURSOR++ ))
      fi
      ;;
    .backward-delete-char)
      if (( CURSOR > 0 )); then
        BUFFER="${BUFFER[1,$((CURSOR - 1))]}${BUFFER[$((CURSOR + 1)),-1]}"
        (( CURSOR-- ))
      fi
      ;;
    forward-char)
      (( CURSOR < ${#BUFFER} )) && (( CURSOR++ ))
      ;;
  esac
  return 0
}

# ==============================================================================
# 32. _zai_widget_self_insert — triggers history match then async (correct ordering)
# ==============================================================================

print "# --- 32. _zai_widget_self_insert: history match shown before async request ---"

_test_load_keybindings
_zai_config_set trigger "auto"

typeset -g _ZAI_TEST_SHOW_CALLED=0
typeset -g _ZAI_TEST_SHOW_TEXT=""
typeset -g _ZAI_TEST_DEBOUNCE_ORDER=()

# Override _zai_suggestion_show to track when it's called
function _zai_suggestion_show() {
  _ZAI_TEST_SHOW_CALLED=1
  _ZAI_TEST_SHOW_TEXT="${1}"
  _ZAI_TEST_DEBOUNCE_ORDER+=("show:${1}")
}

# Override _zai_debounce_start to track relative to show
function _zai_debounce_start() {
  _ZAI_TEST_DEBOUNCE_CALLS+=("debounce_start")
  _ZAI_TEST_DEBOUNCE_ORDER+=("debounce")
}

function fc() {
  print "    1  git status --short"
}

BUFFER="git s"
CURSOR=5
KEYS="t"  # Will result in BUFFER="git st" after self-insert

_zai_widget_self_insert

# Show should come before debounce (instant history match before async)
assert_equal "self-insert: history show fires before debounce (index 1)" \
  "show:tatus --short" "${_ZAI_TEST_DEBOUNCE_ORDER[1]}"

assert_equal "self-insert: debounce fires after history show (index 2)" \
  "debounce" "${_ZAI_TEST_DEBOUNCE_ORDER[2]}"

_zai_test_fc_mock_remove
_zai_config_reset

# Restore the original suggestion show function
unset _ZAI_TEST_SHOW_CALLED _ZAI_TEST_SHOW_TEXT _ZAI_TEST_DEBOUNCE_ORDER
_test_load_keybindings  # Reload to restore real _zai_suggestion_show

# ==============================================================================
# Standalone mode: print TAP plan and summary
# ==============================================================================

if [[ "${0}" == "${(%):-%x}" ]] || [[ "${ZSH_ARGZERO:-}" == *"test_keybindings.zsh" ]]; then
  tap_plan
  tap_summary
  exit $(( _TAP_FAIL_COUNT > 0 ? 1 : 0 ))
fi
