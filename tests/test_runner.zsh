#!/usr/bin/env zsh
# ==============================================================================
# zsh-ai-complete: TAP-compatible Test Runner
# File: tests/test_runner.zsh
# ==============================================================================
#
# Usage:
#   zsh tests/test_runner.zsh                  # run all test files
#   zsh tests/test_runner.zsh tests/test_config.zsh  # run specific file
#
# Output format: TAP (Test Anything Protocol) compatible
#   TAP version 13
#   1..N
#   ok 1 - description
#   not ok 2 - description
#     # expected: foo
#     # got: bar
#
# ==============================================================================

# ── Internal state ─────────────────────────────────────────────────────────────
typeset -gi _TAP_TEST_COUNT=0
typeset -gi _TAP_PASS_COUNT=0
typeset -gi _TAP_FAIL_COUNT=0
typeset -gi _TAP_SKIP_COUNT=0
typeset -ga _TAP_FAILURES=()

# ── TAP output helpers ─────────────────────────────────────────────────────────

tap_plan() {
  # Called at end of all tests to output the plan line (TAP requires it)
  print "1..${_TAP_TEST_COUNT}"
}

_tap_ok() {
  local desc="${1}"
  (( _TAP_TEST_COUNT++ ))
  (( _TAP_PASS_COUNT++ ))
  print "ok ${_TAP_TEST_COUNT} - ${desc}"
}

_tap_not_ok() {
  local desc="${1}"
  local expected="${2:-}"
  local got="${3:-}"
  (( _TAP_TEST_COUNT++ ))
  (( _TAP_FAIL_COUNT++ ))
  print "not ok ${_TAP_TEST_COUNT} - ${desc}"
  if [[ -n "${expected}" ]]; then
    print "  # expected: ${expected}"
  fi
  if [[ -n "${got}" ]]; then
    print "  # got:      ${got}"
  fi
  _TAP_FAILURES+=("${_TAP_TEST_COUNT}: ${desc}")
}

_tap_skip() {
  local desc="${1}"
  local reason="${2:-}"
  (( _TAP_TEST_COUNT++ ))
  (( _TAP_SKIP_COUNT++ ))
  print "ok ${_TAP_TEST_COUNT} - ${desc} # SKIP ${reason}"
}

# ── Assert functions ───────────────────────────────────────────────────────────

# assert_equal <description> <expected> <actual>
assert_equal() {
  local desc="${1}"
  local expected="${2}"
  local actual="${3}"
  if [[ "${expected}" == "${actual}" ]]; then
    _tap_ok "${desc}"
  else
    _tap_not_ok "${desc}" "${expected}" "${actual}"
  fi
}

# assert_not_equal <description> <expected> <actual>
assert_not_equal() {
  local desc="${1}"
  local not_expected="${2}"
  local actual="${3}"
  if [[ "${not_expected}" != "${actual}" ]]; then
    _tap_ok "${desc}"
  else
    _tap_not_ok "${desc}" "not '${not_expected}'" "'${actual}'"
  fi
}

# assert_match <description> <pattern> <string>
# Uses zsh glob/regex matching
assert_match() {
  local desc="${1}"
  local pattern="${2}"
  local string="${3}"
  if [[ "${string}" =~ ${pattern} ]]; then
    _tap_ok "${desc}"
  else
    _tap_not_ok "${desc}" "match /${pattern}/" "${string}"
  fi
}

# assert_true <description> <exit_code>
assert_true() {
  local desc="${1}"
  local code="${2}"
  if (( code == 0 )); then
    _tap_ok "${desc}"
  else
    _tap_not_ok "${desc}" "exit code 0" "exit code ${code}"
  fi
}

# assert_false <description> <exit_code>
assert_false() {
  local desc="${1}"
  local code="${2}"
  if (( code != 0 )); then
    _tap_ok "${desc}"
  else
    _tap_not_ok "${desc}" "exit code non-zero" "exit code ${code}"
  fi
}

# assert_empty <description> <value>
assert_empty() {
  local desc="${1}"
  local val="${2}"
  if [[ -z "${val}" ]]; then
    _tap_ok "${desc}"
  else
    _tap_not_ok "${desc}" "(empty)" "'${val}'"
  fi
}

# assert_not_empty <description> <value>
assert_not_empty() {
  local desc="${1}"
  local val="${2}"
  if [[ -n "${val}" ]]; then
    _tap_ok "${desc}"
  else
    _tap_not_ok "${desc}" "(non-empty)" "(empty)"
  fi
}

# assert_contains <description> <substring> <string>
assert_contains() {
  local desc="${1}"
  local substring="${2}"
  local string="${3}"
  if [[ "${string}" == *"${substring}"* ]]; then
    _tap_ok "${desc}"
  else
    _tap_not_ok "${desc}" "contains '${substring}'" "${string}"
  fi
}

# skip_test <description> <reason>
skip_test() {
  _tap_skip "${1}" "${2:-}"
}

# ── Test summary ───────────────────────────────────────────────────────────────

tap_summary() {
  print ""
  print "# Tests:  ${_TAP_TEST_COUNT}"
  print "# Passed: ${_TAP_PASS_COUNT}"
  print "# Failed: ${_TAP_FAIL_COUNT}"
  print "# Skipped: ${_TAP_SKIP_COUNT}"

  if (( _TAP_FAIL_COUNT > 0 )); then
    print ""
    print "# FAILED TESTS:"
    local f
    for f in "${_TAP_FAILURES[@]}"; do
      print "#   ${f}"
    done
  fi
}

# ── Main: run test files ───────────────────────────────────────────────────────

_tap_run_files() {
  local test_files=("$@")
  local f

  print "TAP version 13"

  for f in "${test_files[@]}"; do
    if [[ ! -f "${f}" ]]; then
      print "# WARNING: test file not found: ${f}"
      continue
    fi
    print "# --- ${f} ---"
    # Source each test file in a subshell-like context to isolate state
    # We use source (.) to keep the TAP counters in scope
    source "${f}"
  done

  tap_plan
  tap_summary
}

# ── Entry point ────────────────────────────────────────────────────────────────

if [[ "${0}" == "${(%):-%x}" ]] || [[ "${ZSH_ARGZERO:-}" == *"test_runner.zsh" ]]; then
  # Running directly as: zsh tests/test_runner.zsh [files...]
  local _runner_dir="${0:a:h}"

  if (( $# > 0 )); then
    _tap_run_files "$@"
  else
    # Auto-discover test files in same directory
    local _test_files=("${_runner_dir}"/test_*.zsh)
    # Exclude self
    _test_files=("${(@)_test_files:#*test_runner.zsh}")
    _tap_run_files "${_test_files[@]}"
  fi

  # Exit with failure count (non-zero = failures exist)
  exit $(( _TAP_FAIL_COUNT > 0 ? 1 : 0 ))
fi
