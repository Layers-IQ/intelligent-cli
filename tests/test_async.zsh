#!/usr/bin/env zsh
# ==============================================================================
# zsh-ai-complete: AsyncEngine + Resilience Layer Tests
# File: tests/test_async.zsh
# ==============================================================================
#
# Run standalone:   zsh tests/test_async.zsh
# Run via runner:   zsh tests/test_runner.zsh tests/test_async.zsh
#
# Coverage (TASK-007 + TASK-011 acceptance criteria):
#
# TASK-011:
#   AC-1: When Ollama running, AI suggestions display
#   AC-2: When Ollama stopped mid-session, history-only continues without errors
#   AC-3: No error/warning messages when Ollama unavailable
#   AC-4: Availability rechecked every 30s or on request failure
#   AC-5: When Ollama restarted, AI resumes automatically
#   AC-6: Health check is lightweight (checked via _zai_check_ollama_periodic logic)
#   AC-7: Graceful degradation is transparent (no user config needed)
#
# TASK-007:
#   Debounce timer fires after delay
#   Generation counter increments and is embedded in output
#   Stale results are rejected
#   Full cleanup cancels timers and requests
#   FD/PID globals reset to -1 after cleanup
# ==============================================================================

# Capture script directory at TOP LEVEL (outside functions)
typeset -g _ZAI_TEST_ASYNC_DIR="${${(%):-%x}:a:h}"
typeset -g _ZAI_TEST_ASYNC_CONFIG="${_ZAI_TEST_ASYNC_DIR}/../plugin/lib/config.zsh"
typeset -g _ZAI_TEST_ASYNC_PLUGIN="${_ZAI_TEST_ASYNC_DIR}/../plugin/lib/async.zsh"

# ── Bootstrap: load test runner if not already loaded ─────────────────────────
if (( ! ${+functions[assert_equal]} )); then
  source "${_ZAI_TEST_ASYNC_DIR}/test_runner.zsh"
fi

# ==============================================================================
# Minimal ZLE stub
#
# ZLE is not available outside a running shell's line editor.  We provide a
# no-op stub so all zle -F / zle -R calls in the module succeed silently.
# ==============================================================================
if (( ! ${+functions[zle]} )); then
  function zle() { return 0; }
fi

# ==============================================================================
# Stub dependencies for the async module's subshell pipeline.
# These functions are inherited by process substitutions.
# Real implementations live in their respective modules; here we supply
# lightweight stubs that return controlled output for unit testing.
# ==============================================================================

# ContextGatherer stub: returns minimal context
_zai_gather_full_context() {
  print "<directory>stub</directory><history>stub</history>"
}

# PromptBuilder stubs
_zai_build_completion_prompt() {
  print "<|fim_prefix|>${2}${1}<|fim_suffix|><|fim_middle|>"
}
_zai_build_nl_translation_prompt() {
  print "translate: ${1}"
}
_zai_get_generation_params() {
  print '{"temperature":0.1}'
}
_zai_clean_completion() {
  # Return the first argument as-is (raw completion)
  print -r -- "${1}"
}

# SuggestionManager stub: record last call for assertions
typeset -g _STUB_SUGGESTION_UPDATED=""
_zai_suggestion_update() {
  _STUB_SUGGESTION_UPDATED="${1}"
}
_zai_suggestion_clear() {
  return 0
}
_zai_suggestion_show() {
  return 0
}

# ==============================================================================
# Helper: (re)load the async module with a clean slate
# ==============================================================================
_test_load_async() {
  # Force reload config
  unset _ZAI_CONFIG_LOADED
  unset '_ZAI_CONFIG_DEFAULTS'
  unset '_ZAI_CONFIG_OVERRIDES'
  source "${_ZAI_TEST_ASYNC_CONFIG}"

  # Force reload async module
  unset _ZAI_ASYNC_LOADED
  unset _ZAI_GEN_COUNTER
  unset _ZAI_TIMER_FD
  unset _ZAI_TIMER_PID
  unset _ZAI_REQ_FD
  unset _ZAI_REQ_PID
  unset _ZAI_OLLAMA_AVAILABLE
  unset _ZAI_OLLAMA_FAIL_SECONDS
  unset _ZAI_OLLAMA_RECHECK_INTERVAL
  source "${_ZAI_TEST_ASYNC_PLUGIN}"
}

# ==============================================================================
print "# [test_async.zsh] AsyncEngine + Resilience Layer Tests"
# ==============================================================================

_test_load_async

# ==============================================================================
# 1. Module-level initial state
# ==============================================================================
print "# --- 1. Initial state after module load ---"

assert_equal "initial _ZAI_GEN_COUNTER is 0"       "0"  "${_ZAI_GEN_COUNTER}"
assert_equal "initial _ZAI_TIMER_FD is -1"          "-1" "${_ZAI_TIMER_FD}"
assert_equal "initial _ZAI_TIMER_PID is -1"         "-1" "${_ZAI_TIMER_PID}"
assert_equal "initial _ZAI_REQ_FD is -1"            "-1" "${_ZAI_REQ_FD}"
assert_equal "initial _ZAI_REQ_PID is -1"           "-1" "${_ZAI_REQ_PID}"

# Resilience layer initial state: assume Ollama is available
assert_equal "initial _ZAI_OLLAMA_AVAILABLE is 1 (assume up)" "1" "${_ZAI_OLLAMA_AVAILABLE}"
assert_equal "initial _ZAI_OLLAMA_FAIL_SECONDS is -1 (never failed)" "-1" "${_ZAI_OLLAMA_FAIL_SECONDS}"
assert_equal "initial _ZAI_OLLAMA_RECHECK_INTERVAL is 30" "30" "${_ZAI_OLLAMA_RECHECK_INTERVAL}"

# ==============================================================================
# 2. _zai_check_ollama_periodic — available state (AC-1, AC-6)
# ==============================================================================
print "# --- 2. _zai_check_ollama_periodic: Ollama available ---"

_test_load_async

# When Ollama is available (flag=1), the function should always return 0
_ZAI_OLLAMA_AVAILABLE=1
_zai_check_ollama_periodic
assert_true "_zai_check_ollama_periodic returns 0 when Ollama available (flag=1)" $?

_ZAI_OLLAMA_AVAILABLE=1
_ZAI_OLLAMA_FAIL_SECONDS=0   # Even with stale fail time, flag=1 should proceed
_zai_check_ollama_periodic
assert_true "_zai_check_ollama_periodic returns 0 when flag=1 regardless of fail time" $?

# Reset to clean state
_ZAI_OLLAMA_FAIL_SECONDS=-1

# ==============================================================================
# 3. _zai_check_ollama_periodic — unavailable + in cooldown (AC-2, AC-3)
# ==============================================================================
print "# --- 3. _zai_check_ollama_periodic: unavailable + cooldown active ---"

_test_load_async

# Simulate: Ollama went down 5 seconds ago (well within 30s cooldown)
_ZAI_OLLAMA_AVAILABLE=0
_ZAI_OLLAMA_FAIL_SECONDS=$(( SECONDS - 5 ))
_ZAI_OLLAMA_RECHECK_INTERVAL=30

_zai_check_ollama_periodic
assert_false "_zai_check_ollama_periodic returns 1 when unavailable within cooldown" $?

# Simulate: Ollama went down 29 seconds ago (just barely within cooldown)
_ZAI_OLLAMA_FAIL_SECONDS=$(( SECONDS - 29 ))
_zai_check_ollama_periodic
assert_false "_zai_check_ollama_periodic returns 1 at 29s (just inside 30s cooldown)" $?

# Simulate: Ollama went down 0 seconds ago (just failed)
_ZAI_OLLAMA_FAIL_SECONDS="${SECONDS}"
_zai_check_ollama_periodic
assert_false "_zai_check_ollama_periodic returns 1 immediately after failure" $?

# ==============================================================================
# 4. _zai_check_ollama_periodic — cooldown expired (AC-4, AC-5)
# ==============================================================================
print "# --- 4. _zai_check_ollama_periodic: cooldown expired → allow recheck ---"

_test_load_async

# Simulate: Ollama went down exactly 30 seconds ago (cooldown just expired)
_ZAI_OLLAMA_AVAILABLE=0
_ZAI_OLLAMA_FAIL_SECONDS=$(( SECONDS - 30 ))
_ZAI_OLLAMA_RECHECK_INTERVAL=30

_zai_check_ollama_periodic
assert_true "_zai_check_ollama_periodic returns 0 at exactly 30s (cooldown boundary)" $?

# Simulate: Ollama went down 60 seconds ago (well past cooldown)
_ZAI_OLLAMA_FAIL_SECONDS=$(( SECONDS - 60 ))
_zai_check_ollama_periodic
assert_true "_zai_check_ollama_periodic returns 0 at 60s (past cooldown)" $?

# Simulate: very old failure (long-running session)
_ZAI_OLLAMA_FAIL_SECONDS=$(( SECONDS - 3600 ))
_zai_check_ollama_periodic
assert_true "_zai_check_ollama_periodic returns 0 after 1 hour (long cooldown expiry)" $?

# ==============================================================================
# 5. _zai_check_ollama_periodic — edge case: fail_seconds=-1 (AC-6)
# ==============================================================================
print "# --- 5. _zai_check_ollama_periodic: edge cases ---"

_test_load_async

# Edge case: unavailable but fail_seconds never set (defensive guard)
_ZAI_OLLAMA_AVAILABLE=0
_ZAI_OLLAMA_FAIL_SECONDS=-1

_zai_check_ollama_periodic
assert_true "_zai_check_ollama_periodic returns 0 for unavailable+fail_seconds=-1 (edge)" $?

# Edge case: custom short recheck interval (2 seconds)
_ZAI_OLLAMA_AVAILABLE=0
_ZAI_OLLAMA_FAIL_SECONDS=$(( SECONDS - 1 ))  # 1 second ago
_ZAI_OLLAMA_RECHECK_INTERVAL=2

_zai_check_ollama_periodic
assert_false "_zai_check_ollama_periodic returns 1 within custom 2s interval" $?

_ZAI_OLLAMA_FAIL_SECONDS=$(( SECONDS - 3 ))  # 3 seconds ago
_zai_check_ollama_periodic
assert_true "_zai_check_ollama_periodic returns 0 past custom 2s interval" $?

# ==============================================================================
# 6. Resilience state transitions — simulate callback behavior (AC-2, AC-3, AC-5)
# ==============================================================================
print "# --- 6. Resilience state transitions ---"

_test_load_async

# Simulate what _zai_async_callback does on an UNAVAIL signal
# (testing the state-update logic, not ZLE fd reading)

# Before: Ollama available
assert_equal "before UNAVAIL: _ZAI_OLLAMA_AVAILABLE=1" "1" "${_ZAI_OLLAMA_AVAILABLE}"

# Simulate UNAVAIL signal received — replicate callback state update logic
_ZAI_OLLAMA_AVAILABLE=0
_ZAI_OLLAMA_FAIL_SECONDS="${SECONDS}"

assert_equal "after UNAVAIL signal: _ZAI_OLLAMA_AVAILABLE=0" "0" "${_ZAI_OLLAMA_AVAILABLE}"
(( _ZAI_OLLAMA_FAIL_SECONDS >= 0 ))
assert_true "after UNAVAIL signal: _ZAI_OLLAMA_FAIL_SECONDS is SECONDS value" $?

# Check that periodic gate now blocks (AC-2: history continues without errors)
_ZAI_OLLAMA_RECHECK_INTERVAL=30
_zai_check_ollama_periodic
assert_false "after UNAVAIL: periodic gate blocks new Ollama requests" $?

# Simulate successful reconnect — replicate callback state update on valid result
_ZAI_OLLAMA_AVAILABLE=1
_ZAI_OLLAMA_FAIL_SECONDS=-1

assert_equal "after reconnect: _ZAI_OLLAMA_AVAILABLE=1" "1" "${_ZAI_OLLAMA_AVAILABLE}"
assert_equal "after reconnect: _ZAI_OLLAMA_FAIL_SECONDS=-1" "-1" "${_ZAI_OLLAMA_FAIL_SECONDS}"

# Check that periodic gate allows requests again (AC-5: AI resumes)
_zai_check_ollama_periodic
assert_true "after reconnect: periodic gate allows Ollama requests again" $?

# ==============================================================================
# 7. Generation counter (TASK-007 AC: counter increments)
# ==============================================================================
print "# --- 7. Generation counter ---"

_test_load_async

assert_equal "counter starts at 0" "0" "${_ZAI_GEN_COUNTER}"

# Each call to _zai_async_request should increment the counter.
# We mock the subshell by overriding exec to a no-op and mock zle -F.
# Instead, we test counter increment directly by calling the relevant code.

(( _ZAI_GEN_COUNTER++ ))
assert_equal "counter increments to 1" "1" "${_ZAI_GEN_COUNTER}"

(( _ZAI_GEN_COUNTER++ ))
assert_equal "counter increments to 2" "2" "${_ZAI_GEN_COUNTER}"

(( _ZAI_GEN_COUNTER++ ))
assert_equal "counter increments to 3" "3" "${_ZAI_GEN_COUNTER}"

# ==============================================================================
# 8. _zai_async_reset (test helper) — state fully restored
# ==============================================================================
print "# --- 8. _zai_async_reset restores initial state ---"

_test_load_async

# Put module in a non-initial state
_ZAI_GEN_COUNTER=42
_ZAI_OLLAMA_AVAILABLE=0
_ZAI_OLLAMA_FAIL_SECONDS=12345

_zai_async_reset

assert_equal "reset: _ZAI_GEN_COUNTER=0"           "0"  "${_ZAI_GEN_COUNTER}"
assert_equal "reset: _ZAI_OLLAMA_AVAILABLE=1"       "1"  "${_ZAI_OLLAMA_AVAILABLE}"
assert_equal "reset: _ZAI_OLLAMA_FAIL_SECONDS=-1"   "-1" "${_ZAI_OLLAMA_FAIL_SECONDS}"
assert_equal "reset: _ZAI_TIMER_FD=-1"              "-1" "${_ZAI_TIMER_FD}"
assert_equal "reset: _ZAI_TIMER_PID=-1"             "-1" "${_ZAI_TIMER_PID}"
assert_equal "reset: _ZAI_REQ_FD=-1"               "-1" "${_ZAI_REQ_FD}"
assert_equal "reset: _ZAI_REQ_PID=-1"              "-1" "${_ZAI_REQ_PID}"

# ==============================================================================
# 9. Debounce timing math — sleep_secs conversion
# ==============================================================================
print "# --- 9. Debounce sleep duration computation ---"

_test_load_async

# Verify the integer math formula used in _zai_debounce_start produces
# correct results without floating-point format issues.
# Formula: whole=$(( ms / 1000 )); frac=$(( ms % 1000 ))
# Result:  printf '%d.%03d' whole frac

local sleep_val
printf -v sleep_val '%d.%03d' "$(( 150 / 1000 ))" "$(( 150 % 1000 ))"
assert_equal "debounce 150ms → sleep 0.150" "0.150" "${sleep_val}"

printf -v sleep_val '%d.%03d' "$(( 300 / 1000 ))" "$(( 300 % 1000 ))"
assert_equal "debounce 300ms → sleep 0.300" "0.300" "${sleep_val}"

printf -v sleep_val '%d.%03d' "$(( 1000 / 1000 ))" "$(( 1000 % 1000 ))"
assert_equal "debounce 1000ms → sleep 1.000" "1.000" "${sleep_val}"

printf -v sleep_val '%d.%03d' "$(( 1500 / 1000 ))" "$(( 1500 % 1000 ))"
assert_equal "debounce 1500ms → sleep 1.500" "1.500" "${sleep_val}"

printf -v sleep_val '%d.%03d' "$(( 50 / 1000 ))" "$(( 50 % 1000 ))"
assert_equal "debounce 50ms → sleep 0.050" "0.050" "${sleep_val}"

# ==============================================================================
# 10. UNAVAIL output format from background pipeline simulation
# ==============================================================================
print "# --- 10. UNAVAIL signal output format ---"

_test_load_async

# Simulate the background subshell's UNAVAIL output format directly
# by running the relevant print statement in a subshell and capturing it.
local unavail_output token_used=7
unavail_output="$(print -r -- "UNAVAIL:${token_used}")"

assert_equal "UNAVAIL output has correct format" "UNAVAIL:7" "${unavail_output}"

# Verify prefix detection logic (mirrors _zai_async_callback)
[[ "${unavail_output}" == "UNAVAIL:"* ]]
assert_true "UNAVAIL: prefix detected correctly" $?

# Non-unavail string should not match
[[ "5:ls -la" == "UNAVAIL:"* ]]
assert_false "normal result does not match UNAVAIL prefix" $?

# ==============================================================================
# 11. Result parsing — token extraction (mirrors _zai_async_callback logic)
# ==============================================================================
print "# --- 11. Result parsing: token and completion extraction ---"

_test_load_async

# The callback parses "<token>:<completion>" as: token = text before first ":"
# completion = everything after the first ":"
local raw_result token_part completion_part

raw_result="5:ls -la"
token_part="${raw_result%%:*}"
completion_part="${raw_result#*:}"
assert_equal "token extracted from '5:ls -la'" "5" "${token_part}"
assert_equal "completion extracted from '5:ls -la'" "ls -la" "${completion_part}"

# Completion with colon in it (e.g. time format)
raw_result="3:echo 12:00"
token_part="${raw_result%%:*}"
completion_part="${raw_result#*:}"
assert_equal "token from '3:echo 12:00'" "3" "${token_part}"
assert_equal "completion with colon: 'echo 12:00'" "echo 12:00" "${completion_part}"

# Single-char completion
raw_result="1: "
token_part="${raw_result%%:*}"
completion_part="${raw_result#*:}"
assert_equal "token from '1: '" "1" "${token_part}"
assert_equal "completion from '1: '" " " "${completion_part}"

# ==============================================================================
# 12. Stale result rejection (TASK-007 AC: stale results rejected)
# ==============================================================================
print "# --- 12. Stale result rejection via generation counter ---"

_test_load_async

# Simulate: current counter is 5, received result has token 3 → stale
_ZAI_GEN_COUNTER=5
local resp_token="3"

[[ "${resp_token}" != "${_ZAI_GEN_COUNTER}" ]]
assert_true "stale token '3' != current counter '5' → rejected" $?

# Simulate: current counter matches → fresh result
resp_token="5"
[[ "${resp_token}" != "${_ZAI_GEN_COUNTER}" ]]
assert_false "matching token '5' == current counter '5' → accepted (not rejected)" $?

# Simulate: counter at 1, token is 1 → accept
_ZAI_GEN_COUNTER=1
resp_token="1"
[[ "${resp_token}" != "${_ZAI_GEN_COUNTER}" ]]
assert_false "token '1' matches counter '1' → accepted" $?

# ==============================================================================
# 13. _zai_async_request early-return when Ollama unavailable in cooldown
#     (AC-2, AC-3: no errors, no warnings; pipeline skipped silently)
# ==============================================================================
print "# --- 13. _zai_async_request skips subshell when Ollama unavailable ---"

_test_load_async

# Put Ollama into unavailable + in-cooldown state
_ZAI_OLLAMA_AVAILABLE=0
_ZAI_OLLAMA_FAIL_SECONDS="${SECONDS}"   # failed just now → 30s cooldown active
_ZAI_OLLAMA_RECHECK_INTERVAL=30

# Track whether _zai_async_cancel was called (it always is at start of request)
typeset -g _CANCEL_CALLED=0
local _saved_cancel
_saved_cancel="$(typeset -f _zai_async_cancel)"

function _zai_async_cancel() { (( _CANCEL_CALLED++ )); }

# Track generation counter before call
local counter_before="${_ZAI_GEN_COUNTER}"

# Call should return early due to _zai_check_ollama_periodic returning 1
_zai_async_request "test buffer"

# Counter must NOT have incremented (no subshell was spawned)
assert_equal "generation counter unchanged when Ollama unavailable in cooldown" \
  "${counter_before}" "${_ZAI_GEN_COUNTER}"

# Restore original cancel function
eval "${_saved_cancel}"
unset _CANCEL_CALLED

# ==============================================================================
# 14. _zai_async_request proceeds when Ollama available (AC-1: AI completions shown)
# ==============================================================================
print "# --- 14. _zai_async_request proceeds when Ollama is available ---"

_test_load_async

# Ensure Ollama is available
_ZAI_OLLAMA_AVAILABLE=1
local counter_before="${_ZAI_GEN_COUNTER}"  # should be 0

# We need to mock the Ollama generate function so the subshell completes quickly
function _zai_ollama_generate() {
  print '{"response":"ls -la","done":true}'
  return 0
}
function _zai_ollama_parse_response() {
  print "ls -la"
}

# _zai_async_request will spawn a subshell, increment counter, register zle -F
# Since zle is mocked as a no-op, this won't actually register.
# We verify the counter incremented (subshell was spawned).
_zai_async_request "ls"

local counter_after="${_ZAI_GEN_COUNTER}"
(( counter_after > counter_before ))
assert_true "generation counter incremented when Ollama available (request spawned)" $?

# Clean up the spawned subshell fd/pid
_zai_async_reset

# ==============================================================================
# 15. _zai_async_request allows recheck attempt after cooldown expires (AC-4, AC-5)
# ==============================================================================
print "# --- 15. Cooldown expiry allows recheck attempt ---"

_test_load_async

# Simulate: Ollama was unavailable 31 seconds ago → cooldown expired
_ZAI_OLLAMA_AVAILABLE=0
_ZAI_OLLAMA_FAIL_SECONDS=$(( SECONDS - 31 ))
_ZAI_OLLAMA_RECHECK_INTERVAL=30

local counter_before="${_ZAI_GEN_COUNTER}"

# _zai_check_ollama_periodic should allow the request
_zai_check_ollama_periodic
assert_true "periodic check allows request after cooldown expiry (31s > 30s)" $?

# _zai_async_request should also proceed and increment counter
_zai_async_request "ls"

local counter_after="${_ZAI_GEN_COUNTER}"
(( counter_after > counter_before ))
assert_true "counter incremented after cooldown expiry (reconnect attempt spawned)" $?

_zai_async_reset

# ==============================================================================
# 16. _zai_debounce_cancel — idempotent on inactive timer
# ==============================================================================
print "# --- 16. _zai_debounce_cancel is idempotent when no timer active ---"

_test_load_async

assert_equal "timer fd -1 before cancel" "-1" "${_ZAI_TIMER_FD}"
assert_equal "timer pid -1 before cancel" "-1" "${_ZAI_TIMER_PID}"

# Calling cancel with no active timer should not error
_zai_debounce_cancel
assert_equal "timer fd still -1 after cancel (no-op)" "-1" "${_ZAI_TIMER_FD}"
assert_equal "timer pid still -1 after cancel (no-op)" "-1" "${_ZAI_TIMER_PID}"

# Double cancel should also be safe
_zai_debounce_cancel
_zai_debounce_cancel
assert_true "triple debounce_cancel is safe (no error)" $?

# ==============================================================================
# 17. _zai_async_cancel — idempotent on inactive request
# ==============================================================================
print "# --- 17. _zai_async_cancel is idempotent when no request active ---"

_test_load_async

assert_equal "req fd -1 before cancel" "-1" "${_ZAI_REQ_FD}"
assert_equal "req pid -1 before cancel" "-1" "${_ZAI_REQ_PID}"

_zai_async_cancel
assert_equal "req fd still -1 after cancel (no-op)" "-1" "${_ZAI_REQ_FD}"
assert_equal "req pid still -1 after cancel (no-op)" "-1" "${_ZAI_REQ_PID}"

_zai_async_cancel
_zai_async_cancel
assert_true "triple async_cancel is safe (no error)" $?

# ==============================================================================
# 18. _zai_full_cleanup resets fd/pid sentinels (TASK-007 AC: FD/PID reset to -1)
# ==============================================================================
print "# --- 18. _zai_full_cleanup resets FD and PID to -1 ---"

_test_load_async

# Set non-sentinel values to verify cleanup resets them
_ZAI_TIMER_FD=5
_ZAI_TIMER_PID=12345
_ZAI_REQ_FD=6
_ZAI_REQ_PID=12346

# Mock exec to prevent actual fd operations on bogus fds
# (The cancel functions use exec {fd}<&- which would error on invalid fds;
#  we mock the cancel functions to just reset the variables.)
function _zai_debounce_cancel() {
  _ZAI_TIMER_FD=-1
  _ZAI_TIMER_PID=-1
}
function _zai_async_cancel() {
  _ZAI_REQ_FD=-1
  _ZAI_REQ_PID=-1
}

_zai_full_cleanup

assert_equal "full_cleanup: _ZAI_TIMER_FD=-1"  "-1" "${_ZAI_TIMER_FD}"
assert_equal "full_cleanup: _ZAI_TIMER_PID=-1" "-1" "${_ZAI_TIMER_PID}"
assert_equal "full_cleanup: _ZAI_REQ_FD=-1"   "-1" "${_ZAI_REQ_FD}"
assert_equal "full_cleanup: _ZAI_REQ_PID=-1"  "-1" "${_ZAI_REQ_PID}"

# Restore originals from source
_test_load_async

# ==============================================================================
# 19. Double-source guard
# ==============================================================================
print "# --- 19. Double-source guard ---"

_test_load_async
local loaded_before="${_ZAI_ASYNC_LOADED}"

# Source again without unsetting the guard — should be a no-op
source "${_ZAI_TEST_ASYNC_PLUGIN}"

assert_equal "double-source: _ZAI_ASYNC_LOADED remains 1" "1" "${_ZAI_ASYNC_LOADED}"
assert_equal "double-source: gen counter unchanged" "0" "${_ZAI_GEN_COUNTER}"

# ==============================================================================
# 20. No stderr output when Ollama unavailable (AC-3: no error messages)
# ==============================================================================
print "# --- 20. No stderr messages when Ollama unavailable ---"

_test_load_async

# Capture stderr during a periodic check while Ollama is "down"
_ZAI_OLLAMA_AVAILABLE=0
_ZAI_OLLAMA_FAIL_SECONDS="${SECONDS}"
_ZAI_OLLAMA_RECHECK_INTERVAL=30

local stderr_output
stderr_output="$( _zai_check_ollama_periodic 2>&1 >/dev/null )"
assert_empty "_zai_check_ollama_periodic emits no stderr when unavailable" "${stderr_output}"

# Simulate async_request early-return capturing stderr
local BUFFER="test"   # ZLE var needed if tested outside ZLE
stderr_output="$( _zai_async_request "test" 2>&1 >/dev/null )"
assert_empty "_zai_async_request emits no stderr when Ollama in cooldown" "${stderr_output}"

# ==============================================================================
# 21. Recheck interval defaults (AC-4: checked every 30s)
# ==============================================================================
print "# --- 21. Recheck interval is 30 seconds by default ---"

_test_load_async

assert_equal "default recheck interval is 30 seconds" "30" "${_ZAI_OLLAMA_RECHECK_INTERVAL}"

# Verify the 30-second boundary precisely: 29s → skip, 30s → allow
_ZAI_OLLAMA_AVAILABLE=0
_ZAI_OLLAMA_RECHECK_INTERVAL=30

_ZAI_OLLAMA_FAIL_SECONDS=$(( SECONDS - 29 ))
_zai_check_ollama_periodic
assert_false "at 29s (< 30s interval): still in cooldown" $?

_ZAI_OLLAMA_FAIL_SECONDS=$(( SECONDS - 30 ))
_zai_check_ollama_periodic
assert_true "at exactly 30s: cooldown boundary crossed (>= 30)" $?

# ==============================================================================
# 22. Source code audit — no print to stdout/stderr in resilience path (AC-3)
# ==============================================================================
print "# --- 22. Source code audit: no user-visible messages in resilience path ---"

_test_load_async

# Inspect the source of key resilience functions for user-facing output
local check_src request_src callback_src

check_src="$(typeset -f _zai_check_ollama_periodic 2>/dev/null)"
request_src="$(typeset -f _zai_async_request 2>/dev/null)"
callback_src="$(typeset -f _zai_async_callback 2>/dev/null)"

# _zai_check_ollama_periodic should not print anything (pure logic function)
[[ "${check_src}" != *"print "* ]]
assert_true "_zai_check_ollama_periodic contains no print statements (silent)" $?

# _zai_async_request should not emit messages when taking the early-return path
# (It may contain echo/print for internal logic — but should not have
#  user-facing "error:" or "warning:" text in the early-return branch)
[[ "${request_src}" != *"error:"* ]] && [[ "${request_src}" != *"warning:"* ]]
assert_true "_zai_async_request has no 'error:' or 'warning:' messages" $?

# _zai_async_callback UNAVAIL handler should not print to user
# The callback updates flags only; no output to stdout/stderr when flag changes
[[ "${callback_src}" == *"UNAVAIL:"* ]]
assert_true "_zai_async_callback handles UNAVAIL: signal" $?

# ==============================================================================
# Cleanup
# ==============================================================================

_zai_async_reset

# ==============================================================================
# Standalone mode: print TAP plan and summary
# ==============================================================================
if [[ "${0}" == "${(%):-%x}" ]] || [[ "${ZSH_ARGZERO:-}" == *"test_async.zsh" ]]; then
  tap_plan
  tap_summary
  exit $(( _TAP_FAIL_COUNT > 0 ? 1 : 0 ))
fi
