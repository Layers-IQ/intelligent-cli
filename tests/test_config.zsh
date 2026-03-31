#!/usr/bin/env zsh
# ==============================================================================
# zsh-ai-complete: Configuration Module Tests
# File: tests/test_config.zsh
# ==============================================================================
#
# Run standalone:   zsh tests/test_config.zsh
# Run via runner:   zsh tests/test_runner.zsh tests/test_config.zsh
#
# Tests cover TASK-001 acceptance criteria:
#   - All 8+ defaults are correct
#   - Env var ZSH_AI_COMPLETE_* overrides
#   - zstyle ':zai:config' fallback
#   - _zai_config_set runtime overrides
#   - Input validation (type, range, valid sets)
#   - Priority chain: env → override → zstyle → default
# ==============================================================================

# Capture script directory at TOP LEVEL (outside functions).
# Inside functions, $0 is the function name, not the file path.
# ${(%):-%x} gives the sourced/executed filename even inside functions in zsh.
typeset -g _ZAI_TEST_CONFIG_DIR="${${(%):-%x}:a:h}"
typeset -g _ZAI_TEST_CONFIG_PLUGIN="${_ZAI_TEST_CONFIG_DIR}/../plugin/lib/config.zsh"

# ── Bootstrap: load test runner if not already loaded ─────────────────────────
if (( ! ${+functions[assert_equal]} )); then
  source "${_ZAI_TEST_CONFIG_DIR}/test_runner.zsh"
fi

# ── Helper: load config module (reset state each time) ────────────────────────
_test_load_config() {
  # Force reload by unsetting the guard
  unset _ZAI_CONFIG_LOADED
  unset '_ZAI_CONFIG_DEFAULTS'
  unset '_ZAI_CONFIG_OVERRIDES'
  source "${_ZAI_TEST_CONFIG_PLUGIN}"
}

# ── Tests ──────────────────────────────────────────────────────────────────────

print "# [test_config.zsh] Configuration Module Tests"

# ==============================================================================
# 1. Default values
# ==============================================================================

print "# --- 1. Default values ---"

_test_load_config

assert_equal "default ollama_url is http://localhost:11434" \
  "http://localhost:11434" "$(_zai_config_get ollama_url)"

assert_equal "default model is qwen2.5-coder:3b" \
  "qwen2.5-coder:3b" "$(_zai_config_get model)"

assert_equal "default debounce is 150" \
  "150" "$(_zai_config_get debounce)"

assert_equal "default timeout is 4" \
  "4" "$(_zai_config_get timeout)"

assert_equal "default trigger is auto" \
  "auto" "$(_zai_config_get trigger)"

assert_equal "default history_size is 20" \
  "20" "$(_zai_config_get history_size)"

assert_equal "default dir_limit is 50" \
  "50" "$(_zai_config_get dir_limit)"

assert_equal "default min_chars is 3" \
  "3" "$(_zai_config_get min_chars)"

assert_equal "default highlight_style is fg=8" \
  "fg=8" "$(_zai_config_get highlight_style)"

assert_equal "defaults array has 9 entries" \
  "9" "${#_ZAI_CONFIG_DEFAULTS}"

# ==============================================================================
# 2. Environment variable overrides (highest priority)
# ==============================================================================

print "# --- 2. Environment variable overrides ---"

_test_load_config

# Set env var and verify override
ZSH_AI_COMPLETE_DEBOUNCE=200
assert_equal "ZSH_AI_COMPLETE_DEBOUNCE=200 overrides default 150" \
  "200" "$(_zai_config_get debounce)"
unset ZSH_AI_COMPLETE_DEBOUNCE

ZSH_AI_COMPLETE_MODEL="qwen2.5-coder:7b"
assert_equal "ZSH_AI_COMPLETE_MODEL overrides default model" \
  "qwen2.5-coder:7b" "$(_zai_config_get model)"
unset ZSH_AI_COMPLETE_MODEL

ZSH_AI_COMPLETE_TIMEOUT=10
assert_equal "ZSH_AI_COMPLETE_TIMEOUT=10 overrides default 4" \
  "10" "$(_zai_config_get timeout)"
unset ZSH_AI_COMPLETE_TIMEOUT

ZSH_AI_COMPLETE_TRIGGER=manual
assert_equal "ZSH_AI_COMPLETE_TRIGGER=manual overrides default auto" \
  "manual" "$(_zai_config_get trigger)"
unset ZSH_AI_COMPLETE_TRIGGER

ZSH_AI_COMPLETE_OLLAMA_URL="http://127.0.0.1:11434"
assert_equal "ZSH_AI_COMPLETE_OLLAMA_URL overrides default ollama_url" \
  "http://127.0.0.1:11434" "$(_zai_config_get ollama_url)"
unset ZSH_AI_COMPLETE_OLLAMA_URL

ZSH_AI_COMPLETE_HISTORY_SIZE=50
assert_equal "ZSH_AI_COMPLETE_HISTORY_SIZE=50 overrides default 20" \
  "50" "$(_zai_config_get history_size)"
unset ZSH_AI_COMPLETE_HISTORY_SIZE

ZSH_AI_COMPLETE_DIR_LIMIT=100
assert_equal "ZSH_AI_COMPLETE_DIR_LIMIT=100 overrides default 50" \
  "100" "$(_zai_config_get dir_limit)"
unset ZSH_AI_COMPLETE_DIR_LIMIT

ZSH_AI_COMPLETE_MIN_CHARS=5
assert_equal "ZSH_AI_COMPLETE_MIN_CHARS=5 overrides default 3" \
  "5" "$(_zai_config_get min_chars)"
unset ZSH_AI_COMPLETE_MIN_CHARS

# After unsetting, default is restored
assert_equal "after unsetting env var, default debounce 150 is restored" \
  "150" "$(_zai_config_get debounce)"

# ==============================================================================
# 3. zstyle fallback (when env var unset)
# ==============================================================================

print "# --- 3. zstyle fallback ---"

_test_load_config

# Set a zstyle and verify it is used when env var is absent
zstyle ':zai:config' debounce 250
assert_equal "zstyle ':zai:config' debounce 250 is used when env var unset" \
  "250" "$(_zai_config_get debounce)"

zstyle ':zai:config' model "qwen2.5-coder:7b-instruct"
assert_equal "zstyle ':zai:config' model override works" \
  "qwen2.5-coder:7b-instruct" "$(_zai_config_get model)"

zstyle ':zai:config' trigger "manual"
assert_equal "zstyle ':zai:config' trigger manual works" \
  "manual" "$(_zai_config_get trigger)"

# Clean up zstyle settings
zstyle -d ':zai:config' debounce
zstyle -d ':zai:config' model
zstyle -d ':zai:config' trigger

# After removing zstyle, default is restored
assert_equal "after deleting zstyle, default debounce 150 restored" \
  "150" "$(_zai_config_get debounce)"

# ==============================================================================
# 4. Priority: env var takes precedence over zstyle
# ==============================================================================

print "# --- 4. Priority: env var > zstyle > default ---"

_test_load_config

# Set both zstyle and env var — env var wins
zstyle ':zai:config' debounce 250
ZSH_AI_COMPLETE_DEBOUNCE=300
assert_equal "env var (300) takes precedence over zstyle (250)" \
  "300" "$(_zai_config_get debounce)"
unset ZSH_AI_COMPLETE_DEBOUNCE

# After removing env var, zstyle takes effect
assert_equal "after unsetting env var, zstyle 250 takes effect" \
  "250" "$(_zai_config_get debounce)"

zstyle -d ':zai:config' debounce

# After removing both, default takes effect
assert_equal "with no env var or zstyle, default 150 takes effect" \
  "150" "$(_zai_config_get debounce)"

# ==============================================================================
# 5. Runtime overrides via _zai_config_set
# ==============================================================================

print "# --- 5. _zai_config_set runtime overrides ---"

_test_load_config

# Valid set operations
_zai_config_set debounce 300
assert_equal "_zai_config_set debounce 300 works" \
  "300" "$(_zai_config_get debounce)"

_zai_config_set timeout 8
assert_equal "_zai_config_set timeout 8 works" \
  "8" "$(_zai_config_get timeout)"

_zai_config_set trigger manual
assert_equal "_zai_config_set trigger manual works" \
  "manual" "$(_zai_config_get trigger)"

_zai_config_set model "qwen2.5-coder:14b"
assert_equal "_zai_config_set model works" \
  "qwen2.5-coder:14b" "$(_zai_config_get model)"

_zai_config_set history_size 40
assert_equal "_zai_config_set history_size 40 persists" \
  "40" "$(_zai_config_get history_size)"

_zai_config_set dir_limit 100
assert_equal "_zai_config_set dir_limit 100 persists" \
  "100" "$(_zai_config_get dir_limit)"

_zai_config_set min_chars 5
assert_equal "_zai_config_set min_chars 5 persists" \
  "5" "$(_zai_config_get min_chars)"

# Override can be updated
_zai_config_set debounce 400
assert_equal "_zai_config_set debounce can be updated to 400" \
  "400" "$(_zai_config_get debounce)"

# After reset, defaults are restored
_zai_config_reset
assert_equal "after _zai_config_reset, default debounce 150 restored" \
  "150" "$(_zai_config_get debounce)"

# Priority: env var still beats runtime override
_zai_config_set debounce 300
ZSH_AI_COMPLETE_DEBOUNCE=500
assert_equal "env var (500) beats runtime override (300)" \
  "500" "$(_zai_config_get debounce)"
unset ZSH_AI_COMPLETE_DEBOUNCE
_zai_config_reset

# ==============================================================================
# 6. Input validation — integer fields
# ==============================================================================

print "# --- 6. Input validation: integer fields ---"

_test_load_config

# Non-integer debounce
_zai_config_set debounce "abc" 2>/dev/null
assert_false "_zai_config_set debounce 'abc' returns non-zero" $?

_zai_config_set debounce "-1" 2>/dev/null
assert_false "_zai_config_set debounce -1 returns non-zero (non-integer or negative)" $?

_zai_config_set debounce "0" 2>/dev/null
assert_false "_zai_config_set debounce 0 returns non-zero (not positive)" $?

_zai_config_set debounce "1.5" 2>/dev/null
assert_false "_zai_config_set debounce 1.5 returns non-zero (not integer)" $?

# Debounce out of range
_zai_config_set debounce "5" 2>/dev/null
assert_false "_zai_config_set debounce 5 (< 10) returns non-zero (below range)" $?

_zai_config_set debounce "99999" 2>/dev/null
assert_false "_zai_config_set debounce 99999 (> 10000) returns non-zero (above range)" $?

# Valid debounce boundary values
_zai_config_set debounce "10" 2>/dev/null
assert_true "_zai_config_set debounce 10 (min valid) succeeds" $?
_zai_config_reset

_zai_config_set debounce "10000" 2>/dev/null
assert_true "_zai_config_set debounce 10000 (max valid) succeeds" $?
_zai_config_reset

# Timeout validation
_zai_config_set timeout "0" 2>/dev/null
assert_false "_zai_config_set timeout 0 returns non-zero (not positive)" $?

_zai_config_set timeout "-5" 2>/dev/null
assert_false "_zai_config_set timeout -5 returns non-zero" $?

_zai_config_set timeout "abc" 2>/dev/null
assert_false "_zai_config_set timeout 'abc' returns non-zero" $?

_zai_config_set timeout "200" 2>/dev/null
assert_false "_zai_config_set timeout 200 (> 120) returns non-zero (above range)" $?

_zai_config_set timeout "1" 2>/dev/null
assert_true "_zai_config_set timeout 1 (min valid) succeeds" $?
_zai_config_reset

_zai_config_set timeout "120" 2>/dev/null
assert_true "_zai_config_set timeout 120 (max valid) succeeds" $?
_zai_config_reset

# history_size validation
_zai_config_set history_size "0" 2>/dev/null
assert_false "_zai_config_set history_size 0 returns non-zero" $?

_zai_config_set history_size "abc" 2>/dev/null
assert_false "_zai_config_set history_size 'abc' returns non-zero" $?

_zai_config_set history_size "1001" 2>/dev/null
assert_false "_zai_config_set history_size 1001 (> 1000) returns non-zero" $?

_zai_config_set history_size "1" 2>/dev/null
assert_true "_zai_config_set history_size 1 (min valid) succeeds" $?
_zai_config_reset

# dir_limit validation
_zai_config_set dir_limit "0" 2>/dev/null
assert_false "_zai_config_set dir_limit 0 returns non-zero" $?

_zai_config_set dir_limit "-10" 2>/dev/null
assert_false "_zai_config_set dir_limit -10 returns non-zero" $?

_zai_config_set dir_limit "25" 2>/dev/null
assert_true "_zai_config_set dir_limit 25 (valid) succeeds" $?
_zai_config_reset

# min_chars validation
_zai_config_set min_chars "0" 2>/dev/null
assert_false "_zai_config_set min_chars 0 returns non-zero (not positive)" $?

_zai_config_set min_chars "hello" 2>/dev/null
assert_false "_zai_config_set min_chars 'hello' returns non-zero" $?

_zai_config_set min_chars "1" 2>/dev/null
assert_true "_zai_config_set min_chars 1 (min valid) succeeds" $?
_zai_config_reset

# ==============================================================================
# 7. Input validation — trigger mode
# ==============================================================================

print "# --- 7. Input validation: trigger mode ---"

_test_load_config

_zai_config_set trigger "auto" 2>/dev/null
assert_true "_zai_config_set trigger 'auto' succeeds" $?
_zai_config_reset

_zai_config_set trigger "manual" 2>/dev/null
assert_true "_zai_config_set trigger 'manual' succeeds" $?
_zai_config_reset

_zai_config_set trigger "AUTO" 2>/dev/null
assert_false "_zai_config_set trigger 'AUTO' (wrong case) returns non-zero" $?

_zai_config_set trigger "semi" 2>/dev/null
assert_false "_zai_config_set trigger 'semi' returns non-zero (not valid set)" $?

_zai_config_set trigger "" 2>/dev/null
assert_false "_zai_config_set trigger '' (empty) returns non-zero" $?

_zai_config_set trigger "auto,manual" 2>/dev/null
assert_false "_zai_config_set trigger 'auto,manual' returns non-zero" $?

# ==============================================================================
# 8. Input validation — string fields
# ==============================================================================

print "# --- 8. Input validation: string fields ---"

_test_load_config

_zai_config_set model "" 2>/dev/null
assert_false "_zai_config_set model '' (empty) returns non-zero" $?

_zai_config_set ollama_url "" 2>/dev/null
assert_false "_zai_config_set ollama_url '' (empty) returns non-zero" $?

_zai_config_set highlight_style "" 2>/dev/null
assert_false "_zai_config_set highlight_style '' (empty) returns non-zero" $?

_zai_config_set model "qwen2.5-coder:7b" 2>/dev/null
assert_true "_zai_config_set model 'qwen2.5-coder:7b' succeeds" $?
_zai_config_reset

_zai_config_set highlight_style "fg=blue,bold" 2>/dev/null
assert_true "_zai_config_set highlight_style 'fg=blue,bold' succeeds" $?
_zai_config_reset

# ==============================================================================
# 9. Unknown key handling
# ==============================================================================

print "# --- 9. Unknown key handling ---"

_test_load_config

# _zai_config_get on unknown key returns non-zero
_zai_config_get nonexistent_key 2>/dev/null
assert_false "_zai_config_get nonexistent_key returns non-zero" $?

# _zai_config_set on unknown key returns non-zero
_zai_config_set nonexistent_key "value" 2>/dev/null
assert_false "_zai_config_set nonexistent_key returns non-zero" $?

# Missing key argument returns non-zero
_zai_config_get 2>/dev/null
assert_false "_zai_config_get with no argument returns non-zero" $?

_zai_config_set 2>/dev/null
assert_false "_zai_config_set with no argument returns non-zero" $?

# ==============================================================================
# 10. _zai_config_dump produces non-empty output
# ==============================================================================

print "# --- 10. _zai_config_dump ---"

_test_load_config

local dump_output
dump_output="$(_zai_config_dump)"

assert_not_empty "_zai_config_dump produces output" "${dump_output}"
assert_contains "_zai_config_dump output contains 'ollama_url'" "ollama_url" "${dump_output}"
assert_contains "_zai_config_dump output contains 'debounce'" "debounce" "${dump_output}"
assert_contains "_zai_config_dump output contains default value" "150" "${dump_output}"

# ==============================================================================
# 11. Guard: double-sourcing does not reset overrides
# ==============================================================================

print "# --- 11. Double-source guard ---"

_test_load_config
_zai_config_set debounce 777

# Source again — guard should prevent reset
source "${_ZAI_TEST_CONFIG_PLUGIN}"

assert_equal "double-source guard preserves existing override" \
  "777" "$(_zai_config_get debounce)"

_zai_config_reset

# Force reload (unset guard) does reset
unset _ZAI_CONFIG_LOADED
source "${_ZAI_TEST_CONFIG_PLUGIN}"

assert_equal "force reload restores default debounce 150" \
  "150" "$(_zai_config_get debounce)"

# ==============================================================================
# 12. _zai_config_is_positive_integer helper
# ==============================================================================

print "# --- 12. _zai_config_is_positive_integer ---"

_test_load_config

_zai_config_is_positive_integer "1"
assert_true "_zai_config_is_positive_integer '1' returns true" $?

_zai_config_is_positive_integer "100"
assert_true "_zai_config_is_positive_integer '100' returns true" $?

_zai_config_is_positive_integer "0"
assert_false "_zai_config_is_positive_integer '0' returns false" $?

_zai_config_is_positive_integer "-1"
assert_false "_zai_config_is_positive_integer '-1' returns false" $?

_zai_config_is_positive_integer "abc"
assert_false "_zai_config_is_positive_integer 'abc' returns false" $?

_zai_config_is_positive_integer ""
assert_false "_zai_config_is_positive_integer '' returns false" $?

_zai_config_is_positive_integer "1.5"
assert_false "_zai_config_is_positive_integer '1.5' returns false" $?

_zai_config_is_positive_integer "01"
assert_true "_zai_config_is_positive_integer '01' (leading zero) returns true" $?

# ==============================================================================
# Standalone mode: print TAP plan and summary
# ==============================================================================

if [[ "${0}" == "${(%):-%x}" ]] || [[ "${ZSH_ARGZERO:-}" == *"test_config.zsh" ]]; then
  tap_plan
  tap_summary
  exit $(( _TAP_FAIL_COUNT > 0 ? 1 : 0 ))
fi
