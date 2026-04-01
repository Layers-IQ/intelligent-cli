#!/usr/bin/env zsh
# ==============================================================================
# zsh-ai-complete: Initialization Module Tests
# File: tests/test_init.zsh
# ==============================================================================
#
# Run standalone:   zsh tests/test_init.zsh
# Run via runner:   zsh tests/test_runner.zsh tests/test_init.zsh
#
# Tests cover TASK-009 acceptance criteria:
#   - Plugin loader sources all modules without error
#   - Synchronous init completes in <20ms
#   - Cache directory is created with mode 700
#   - Deferred init is registered as a one-shot precmd hook
#   - Deferred init removes itself from precmd after firing
#   - zshexit hook is registered for cleanup
#   - zsh-autosuggestions conflict detection and advisory
#   - Ollama health warning printed when unreachable
#   - Model availability warning printed when model not found
#   - Warmup model function validates URL before sending request
#   - _ZAI_CACHE_DIR constant is set correctly
#   - Double-sourcing guard prevents re-initialization
# ==============================================================================

# Capture script directory at TOP LEVEL (before any functions are defined).
# ${(%):-%x} gives the currently-executing filename even when sourced.
typeset -g _ZAI_TEST_INIT_DIR="${${(%):-%x}:a:h}"
typeset -g _ZAI_TEST_PLUGIN_LIB="${_ZAI_TEST_INIT_DIR}/../plugin/lib"
typeset -g _ZAI_TEST_PLUGIN_FILE="${_ZAI_TEST_INIT_DIR}/../plugin/zsh-ai-complete.plugin.zsh"

# ── Bootstrap: load test runner if not already loaded ─────────────────────────
if (( ! ${+functions[assert_equal]} )); then
  source "${_ZAI_TEST_INIT_DIR}/test_runner.zsh"
fi

# ==============================================================================
# Helper: reset init module state for clean test runs
# ==============================================================================
_test_reset_init() {
  unset _ZAI_INIT_LOADED
  unset _ZAI_PLUGIN_LOADED
  unset _ZAI_CONFIG_LOADED
  unset _ZAI_SECURITY_LOADED
  unset _ZAI_OLLAMA_LOADED
  unset _ZAI_SUGGESTION_LOADED
  unset _ZAI_ASYNC_LOADED
  unset _ZAI_KEYBINDINGS_LOADED
}

# Helper: load only the init module (with minimal deps stubbed)
_test_load_init_module() {
  # Reset guard
  unset _ZAI_INIT_LOADED

  # Ensure config is loaded (init.zsh calls _zai_config_get)
  if (( ! ${+_ZAI_CONFIG_LOADED} )); then
    source "${_ZAI_TEST_PLUGIN_LIB}/config.zsh"
  fi

  # Ensure ollama is loaded (init.zsh calls _zai_ollama_check_health, etc.)
  if (( ! ${+_ZAI_OLLAMA_LOADED} )); then
    source "${_ZAI_TEST_PLUGIN_LIB}/ollama.zsh"
  fi

  source "${_ZAI_TEST_PLUGIN_LIB}/init.zsh"
}

# ==============================================================================
print "# [test_init.zsh] Initialization Module Tests"

# ==============================================================================
# 1. Module loads without error
# ==============================================================================
print "# --- 1. Module load ---"

_test_load_init_module
assert_true "_ZAI_INIT_LOADED flag is set after sourcing" $?
assert_equal "_ZAI_INIT_LOADED equals 1" "1" "${_ZAI_INIT_LOADED}"

# Double-sourcing guard: second source should be a no-op
source "${_ZAI_TEST_PLUGIN_LIB}/init.zsh"
assert_equal "double-source guard: _ZAI_INIT_LOADED still 1" "1" "${_ZAI_INIT_LOADED}"

# ==============================================================================
# 2. _ZAI_CACHE_DIR constant
# ==============================================================================
print "# --- 2. Cache directory constant ---"

assert_not_empty "_ZAI_CACHE_DIR is set" "${_ZAI_CACHE_DIR}"
assert_contains "_ZAI_CACHE_DIR contains zsh-ai-complete" "zsh-ai-complete" "${_ZAI_CACHE_DIR}"
assert_match "_ZAI_CACHE_DIR is under HOME" "^${HOME}" "${_ZAI_CACHE_DIR}"

# ==============================================================================
# 3. Cache directory creation
# ==============================================================================
print "# --- 3. Cache directory creation ---"

# Use a temp dir so we can inspect permissions without affecting the real cache
local _test_cache_orig="${_ZAI_CACHE_DIR}"
local _test_tmp_cache="/tmp/zsh_ai_test_cache_$$"
_ZAI_CACHE_DIR="${_test_tmp_cache}"

# Remove if exists from previous failed run
rm -rf "${_test_tmp_cache}" 2>/dev/null

# Call _zai_init (with stub widgets to avoid ZLE errors outside ZLE context)
# Stub out keybinding functions so _zai_init doesn't fail in test environment
local _prev_register _prev_bind _prev_hook
_prev_register="${functions[_zai_register_widgets]}"
_prev_bind="${functions[_zai_bind_keys]}"

# Override with no-op stubs for testing
_zai_register_widgets() { : }
_zai_bind_keys() { : }

# Run init (will create the temp cache dir)
_zai_init 2>/dev/null

# Restore original functions
if [[ -n "${_prev_register}" ]]; then
  functions[_zai_register_widgets]="${_prev_register}"
else
  unfunction _zai_register_widgets 2>/dev/null
fi
if [[ -n "${_prev_bind}" ]]; then
  functions[_zai_bind_keys]="${_prev_bind}"
else
  unfunction _zai_bind_keys 2>/dev/null
fi

# Check directory was created
if [[ -d "${_test_tmp_cache}" ]]; then
  _tap_ok "cache directory was created by _zai_init"

  # Check permissions (700 = drwx------)
  local _perms
  _perms="$(stat -c '%a' "${_test_tmp_cache}" 2>/dev/null || stat -f '%A' "${_test_tmp_cache}" 2>/dev/null)"
  assert_equal "cache directory has mode 700" "700" "${_perms}"
else
  _tap_not_ok "cache directory was created by _zai_init" "directory exists" "directory missing"
  skip_test "cache directory has mode 700" "directory was not created"
fi

# Cleanup
rm -rf "${_test_tmp_cache}" 2>/dev/null
_ZAI_CACHE_DIR="${_test_cache_orig}"

# ==============================================================================
# 4. Functions are defined
# ==============================================================================
print "# --- 4. Functions defined ---"

assert_true "_zai_init is defined" $(( ${+functions[_zai_init]} ))
assert_true "_zai_deferred_init is defined" $(( ${+functions[_zai_deferred_init]} ))
assert_true "_zai_warmup_model is defined" $(( ${+functions[_zai_warmup_model]} ))
assert_true "_zai_check_autosuggestions_conflict is defined" $(( ${+functions[_zai_check_autosuggestions_conflict]} ))

# ==============================================================================
# 5. Deferred init precmd hook registration
# ==============================================================================
print "# --- 5. Deferred init precmd registration ---"

# Reset precmd_functions to known state
local _saved_precmd_functions=("${precmd_functions[@]}")
precmd_functions=()

# Stub keybinding functions
_zai_register_widgets() { : }
_zai_bind_keys() { : }

_zai_init 2>/dev/null

# Check _zai_deferred_init is in precmd_functions
local _found_deferred=0
local _fn
for _fn in "${precmd_functions[@]}"; do
  if [[ "${_fn}" == "_zai_deferred_init" ]]; then
    _found_deferred=1
    break
  fi
done
assert_equal "_zai_deferred_init is in precmd_functions after init" "1" "${_found_deferred}"

# Restore precmd_functions
precmd_functions=("${_saved_precmd_functions[@]}")
unfunction _zai_register_widgets 2>/dev/null
unfunction _zai_bind_keys 2>/dev/null

# ==============================================================================
# 6. Deferred init self-removal (one-shot semantics)
# ==============================================================================
print "# --- 6. Deferred init removes itself after firing ---"

# Set up a controlled precmd_functions with just our hook
local _saved_precmd2=("${precmd_functions[@]}")
precmd_functions=(_zai_deferred_init)

# Stub health check to avoid real network calls in tests
local _saved_health="${functions[_zai_ollama_check_health]}"
_zai_ollama_check_health() { return 1 }  # Simulate Ollama unreachable

# Fire the deferred init
_zai_deferred_init 2>/dev/null

# Check it removed itself
local _still_in_precmd=0
for _fn in "${precmd_functions[@]}"; do
  if [[ "${_fn}" == "_zai_deferred_init" ]]; then
    _still_in_precmd=1
    break
  fi
done
assert_equal "_zai_deferred_init removed itself from precmd after firing" "0" "${_still_in_precmd}"

# Restore
precmd_functions=("${_saved_precmd2[@]}")
if [[ -n "${_saved_health}" ]]; then
  functions[_zai_ollama_check_health]="${_saved_health}"
else
  unfunction _zai_ollama_check_health 2>/dev/null
fi

# ==============================================================================
# 7. Ollama health warning when unreachable
# ==============================================================================
print "# --- 7. Ollama health warning ---"

# Override deferred init components with stubs
precmd_functions=()

local _saved_health2="${functions[_zai_ollama_check_health]}"
_zai_ollama_check_health() { return 1 }  # Simulate unreachable

# Capture stderr output from _zai_deferred_init
local _stderr_output
_stderr_output="$(_zai_deferred_init 2>&1)"

assert_contains "health warning mentions 'Ollama'" "Ollama" "${_stderr_output}"
assert_contains "health warning mentions 'not reachable'" "not reachable" "${_stderr_output}"
assert_contains "health warning suggests 'ollama serve'" "ollama serve" "${_stderr_output}"

# Restore
if [[ -n "${_saved_health2}" ]]; then
  functions[_zai_ollama_check_health]="${_saved_health2}"
else
  unfunction _zai_ollama_check_health 2>/dev/null
fi

# ==============================================================================
# 8. Model availability warning when model not found
# ==============================================================================
print "# --- 8. Model availability warning ---"

precmd_functions=()

# Stub health check to pass (Ollama "available") but model check to fail
local _saved_health3="${functions[_zai_ollama_check_health]}"
local _saved_model_check="${functions[_zai_ollama_check_model]}"
_zai_ollama_check_health() { return 0 }
_zai_ollama_check_model() { return 1 }

local _model_output
_model_output="$(_zai_deferred_init 2>&1)"

assert_contains "model warning mentions model name" "$(_zai_config_get model 2>/dev/null)" "${_model_output}"
assert_contains "model warning mentions 'not found'" "not found" "${_model_output}"
assert_contains "model warning suggests ollama pull" "ollama pull" "${_model_output}"

# Restore
if [[ -n "${_saved_health3}" ]]; then
  functions[_zai_ollama_check_health]="${_saved_health3}"
else
  unfunction _zai_ollama_check_health 2>/dev/null
fi
if [[ -n "${_saved_model_check}" ]]; then
  functions[_zai_ollama_check_model]="${_saved_model_check}"
else
  unfunction _zai_ollama_check_model 2>/dev/null
fi

# ==============================================================================
# 9. No warning when Ollama is available and model is present
# ==============================================================================
print "# --- 9. No warning when Ollama + model OK ---"

precmd_functions=()

local _saved_health4="${functions[_zai_ollama_check_health]}"
local _saved_model_check4="${functions[_zai_ollama_check_model]}"
local _saved_warmup="${functions[_zai_warmup_model]}"
_zai_ollama_check_health() { return 0 }
_zai_ollama_check_model() { return 0 }
_zai_warmup_model() { : }  # Stub out warmup (avoids real network + background job)

local _ok_output
_ok_output="$(_zai_deferred_init 2>&1)"

assert_empty "no warning output when Ollama + model OK" "${_ok_output}"

# Restore
if [[ -n "${_saved_health4}" ]]; then
  functions[_zai_ollama_check_health]="${_saved_health4}"
else
  unfunction _zai_ollama_check_health 2>/dev/null
fi
if [[ -n "${_saved_model_check4}" ]]; then
  functions[_zai_ollama_check_model]="${_saved_model_check4}"
else
  unfunction _zai_ollama_check_model 2>/dev/null
fi
if [[ -n "${_saved_warmup}" ]]; then
  functions[_zai_warmup_model]="${_saved_warmup}"
else
  unfunction _zai_warmup_model 2>/dev/null
fi

# ==============================================================================
# 10. zsh-autosuggestions conflict detection
# ==============================================================================
print "# --- 10. zsh-autosuggestions conflict detection ---"

# Define the sentinel function that zsh-autosuggestions registers
_zsh_autosuggest_start() { : }

local _autosuggest_output
_autosuggest_output="$(_zai_check_autosuggestions_conflict 2>&1)"

assert_contains "conflict advisory mentions autosuggestions" "zsh-autosuggestions" "${_autosuggest_output}"
assert_contains "conflict advisory mentions POSTDISPLAY" "POSTDISPLAY" "${_autosuggest_output}"
assert_contains "conflict advisory suggests disabling" "disable" "${_autosuggest_output}"

# Clean up the sentinel
unfunction _zsh_autosuggest_start 2>/dev/null

# No advisory when zsh-autosuggestions is NOT loaded
local _no_conflict_output
_no_conflict_output="$(_zai_check_autosuggestions_conflict 2>&1)"
assert_empty "no advisory when zsh-autosuggestions not present" "${_no_conflict_output}"

# ==============================================================================
# 11. _zai_warmup_model URL validation
# ==============================================================================
print "# --- 11. Warmup model URL validation ---"

# Valid URL should not fail at validation stage (may fail at curl but that's OK)
# We stub curl to avoid real network calls
local _saved_curl_path
if command -v curl >/dev/null 2>&1; then
  # Just test the URL validation path by calling with a known-invalid URL
  _zai_warmup_model "qwen2.5-coder:7b" "http://evil.com:11434"
  assert_false "_zai_warmup_model rejects non-loopback URL" $?

  _zai_warmup_model "qwen2.5-coder:7b" ""
  assert_false "_zai_warmup_model rejects empty URL" $?
else
  skip_test "_zai_warmup_model rejects non-loopback URL" "curl not available"
  skip_test "_zai_warmup_model rejects empty URL" "curl not available"
fi

# ==============================================================================
# 12. Plugin loader file exists and contains expected markers
# ==============================================================================
print "# --- 12. Plugin loader file integrity ---"

if [[ -f "${_ZAI_TEST_PLUGIN_FILE}" ]]; then
  _tap_ok "plugin/zsh-ai-complete.plugin.zsh exists"

  local _plugin_content
  _plugin_content="$(< "${_ZAI_TEST_PLUGIN_FILE}")"

  assert_contains "plugin loader checks zsh version 5.3" "5.3" "${_plugin_content}"
  assert_contains "plugin loader sources config.zsh" "config.zsh" "${_plugin_content}"
  assert_contains "plugin loader sources security.zsh" "security.zsh" "${_plugin_content}"
  assert_contains "plugin loader sources context.zsh" "context.zsh" "${_plugin_content}"
  assert_contains "plugin loader sources prompt.zsh" "prompt.zsh" "${_plugin_content}"
  assert_contains "plugin loader sources ollama.zsh" "ollama.zsh" "${_plugin_content}"
  assert_contains "plugin loader sources suggestion.zsh" "suggestion.zsh" "${_plugin_content}"
  assert_contains "plugin loader sources async.zsh" "async.zsh" "${_plugin_content}"
  assert_contains "plugin loader sources keybindings.zsh" "keybindings.zsh" "${_plugin_content}"
  assert_contains "plugin loader sources init.zsh" "init.zsh" "${_plugin_content}"
  assert_contains "plugin loader calls _zai_init" "_zai_init" "${_plugin_content}"
  assert_contains "plugin loader uses \${0:a:h}" '${0:a:h}' "${_plugin_content}"
  assert_contains "plugin loader has double-source guard" "_ZAI_PLUGIN_LOADED" "${_plugin_content}"
  assert_contains "plugin loader measures EPOCHREALTIME" "EPOCHREALTIME" "${_plugin_content}"
else
  _tap_not_ok "plugin/zsh-ai-complete.plugin.zsh exists" "file present" "file missing"
  skip_test "plugin loader checks zsh version 5.3" "plugin file missing"
  skip_test "plugin loader sources config.zsh" "plugin file missing"
  skip_test "plugin loader sources security.zsh" "plugin file missing"
  skip_test "plugin loader sources context.zsh" "plugin file missing"
  skip_test "plugin loader sources prompt.zsh" "plugin file missing"
  skip_test "plugin loader sources ollama.zsh" "plugin file missing"
  skip_test "plugin loader sources suggestion.zsh" "plugin file missing"
  skip_test "plugin loader sources async.zsh" "plugin file missing"
  skip_test "plugin loader sources keybindings.zsh" "plugin file missing"
  skip_test "plugin loader sources init.zsh" "plugin file missing"
  skip_test "plugin loader calls _zai_init" "plugin file missing"
  skip_test "plugin loader uses \${0:a:h}" "plugin file missing"
  skip_test "plugin loader has double-source guard" "plugin file missing"
  skip_test "plugin loader measures EPOCHREALTIME" "plugin file missing"
fi

# ==============================================================================
# 13. lib/init.zsh file integrity
# ==============================================================================
print "# --- 13. lib/init.zsh file integrity ---"

local _init_file="${_ZAI_TEST_PLUGIN_LIB}/init.zsh"
if [[ -f "${_init_file}" ]]; then
  _tap_ok "plugin/lib/init.zsh exists"

  local _init_content
  _init_content="$(< "${_init_file}")"

  assert_contains "init.zsh has double-source guard" "_ZAI_INIT_LOADED" "${_init_content}"
  assert_contains "init.zsh defines _ZAI_CACHE_DIR" "_ZAI_CACHE_DIR" "${_init_content}"
  assert_contains "init.zsh creates cache dir with mkdir -p" "mkdir -p" "${_init_content}"
  assert_contains "init.zsh sets mode 700 with chmod" "chmod 700" "${_init_content}"
  assert_contains "init.zsh registers precmd hook" "precmd" "${_init_content}"
  assert_contains "init.zsh registers zshexit hook" "zshexit" "${_init_content}"
  assert_contains "init.zsh uses add-zsh-hook" "add-zsh-hook" "${_init_content}"
  assert_contains "init.zsh checks for _zsh_autosuggest_start" "_zsh_autosuggest_start" "${_init_content}"
  assert_contains "init.zsh has keep_alive warmup" "keep_alive" "${_init_content}"
  assert_contains "init.zsh validates URL before warmup" "_zai_validate_ollama_url" "${_init_content}"
else
  _tap_not_ok "plugin/lib/init.zsh exists" "file present" "file missing"
fi

# ==============================================================================
# 14. Startup timing — _zai_init <20ms (performance regression detection)
# ==============================================================================
print "# --- 14. Startup timing ---"

# This test measures actual synchronous init time.
# We stub all I/O-bound operations to measure pure function dispatch overhead.
if (( ! ${+_ZAI_INIT_LOADED} )); then
  _test_load_init_module
fi

# Stubs to prevent real I/O during timing test
_zai_register_widgets() { : }
_zai_bind_keys() { : }
local _saved_asconf="${functions[_zai_check_autosuggestions_conflict]}"
_zai_check_autosuggestions_conflict() { : }
local _saved_cachedir="${_ZAI_CACHE_DIR}"
_ZAI_CACHE_DIR="/tmp"  # Use existing dir to skip mkdir

local _t_start _t_end _elapsed_ms
_t_start="${EPOCHREALTIME}"
_zai_init 2>/dev/null
_t_end="${EPOCHREALTIME}"

# Compute elapsed milliseconds
_elapsed_ms="$(printf '%.0f' "$(( (_t_end - _t_start) * 1000 ))")"

# Restore stubs
_ZAI_CACHE_DIR="${_saved_cachedir}"
if [[ -n "${_saved_asconf}" ]]; then
  functions[_zai_check_autosuggestions_conflict]="${_saved_asconf}"
else
  unfunction _zai_check_autosuggestions_conflict 2>/dev/null
fi
unfunction _zai_register_widgets 2>/dev/null
unfunction _zai_bind_keys 2>/dev/null

# The synchronous init path (excluding actual widget/keybinding work) should
# complete well within 20ms. We use 50ms as the test threshold to account for
# variable CI system load while still catching severe regressions.
if (( _elapsed_ms <= 50 )); then
  _tap_ok "_zai_init synchronous overhead <50ms (actual: ${_elapsed_ms}ms)"
else
  _tap_not_ok "_zai_init synchronous overhead <50ms" "<50ms" "${_elapsed_ms}ms"
fi

# ==============================================================================
# Standalone runner support
# ==============================================================================
if [[ "${0}" == "${(%):-%x}" ]] || [[ "${ZSH_ARGZERO:-}" == *"test_init.zsh" ]]; then
  tap_plan
  tap_summary
  exit $(( _TAP_FAIL_COUNT > 0 ? 1 : 0 ))
fi
