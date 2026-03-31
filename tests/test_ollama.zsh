#!/usr/bin/env zsh
# ==============================================================================
# zsh-ai-complete: OllamaClient Module Tests
# File: tests/test_ollama.zsh
# ==============================================================================
#
# Run standalone:   zsh tests/test_ollama.zsh
# Run via runner:   zsh tests/test_runner.zsh tests/test_ollama.zsh
#
# Tests cover TASK-005 acceptance criteria:
#   AC-1: URL rejects http://localhost@evil.com (@ credential embedding)
#   AC-2: URL rejects http://localhost.evil.com (subdomain trick)
#   AC-3: URL rejects http://[::ffff:7f00:1]:11434 (IPv4-mapped IPv6)
#   AC-4: URL accepts localhost:11434, 127.0.0.1:11434, [::1]:11434
#   AC-5: curl POST uses stdin piping (-d @-)
#   AC-6: Loopback interface: lo0 (macOS) vs lo (Linux)
#   AC-7: JSON parsing handles escaped chars (\n, \t, \\, \")
#   AC-8: Health check returns 0 when Ollama running
#   AC-9: Health check returns non-zero when Ollama not running
#   AC-10: Model check returns 0 when model present
#   AC-11: Model check returns non-zero when model absent
# ==============================================================================

# Capture script directory at TOP LEVEL (outside functions)
typeset -g _ZAI_TEST_OLLAMA_DIR="${${(%):-%x}:a:h}"
typeset -g _ZAI_TEST_OLLAMA_CONFIG="${_ZAI_TEST_OLLAMA_DIR}/../plugin/lib/config.zsh"
typeset -g _ZAI_TEST_OLLAMA_PLUGIN="${_ZAI_TEST_OLLAMA_DIR}/../plugin/lib/ollama.zsh"

# ── Bootstrap: load test runner if not already loaded ─────────────────────────
if (( ! ${+functions[assert_equal]} )); then
  source "${_ZAI_TEST_OLLAMA_DIR}/test_runner.zsh"
fi

# ── Helper: (re)load config and ollama modules ────────────────────────────────
_test_load_ollama() {
  # Force reload config
  unset _ZAI_CONFIG_LOADED
  unset '_ZAI_CONFIG_DEFAULTS'
  unset '_ZAI_CONFIG_OVERRIDES'
  source "${_ZAI_TEST_OLLAMA_CONFIG}"

  # Force reload ollama
  unset _ZAI_OLLAMA_LOADED
  unset _ZAI_LOOPBACK_IFACE
  source "${_ZAI_TEST_OLLAMA_PLUGIN}"
}

# ── Curl mock infrastructure ──────────────────────────────────────────────────
# Mocks use temp files to communicate results back from subshells ($() creates
# a forked sub-process; writes to shell vars inside it don't propagate back).
#
# File-based approach:
#   - Each curl arg is written one per line to _MOCK_CURL_ARGS_FILE
#   - Stdin (when @- present) is written to _MOCK_CURL_STDIN_FILE
#   - Response text and exit code are inherited via read-only var inheritance

typeset -g _MOCK_CURL_RESPONSE=""
typeset -g _MOCK_CURL_EXIT=0
typeset -g _MOCK_CURL_ARGS_FILE="${TMPDIR:-/tmp}/_zai_mock_args.$$"
typeset -g _MOCK_CURL_STDIN_FILE="${TMPDIR:-/tmp}/_zai_mock_stdin.$$"

_mock_curl_setup() {
  local response="${1:-}"
  local exit_code="${2:-0}"
  _MOCK_CURL_RESPONSE="${response}"
  _MOCK_CURL_EXIT="${exit_code}"
  # Clear temp files
  : > "${_MOCK_CURL_ARGS_FILE}"
  : > "${_MOCK_CURL_STDIN_FILE}"

  # Define mock curl function — inherits _MOCK_CURL_RESPONSE and _MOCK_CURL_EXIT
  # via forked subshell variable inheritance. Writes args/stdin to temp files.
  function curl() {
    local i
    for i in "$@"; do
      print -r -- "${i}" >> "${_MOCK_CURL_ARGS_FILE}"
    done
    for i in "$@"; do
      if [[ "${i}" == "@-" ]]; then
        cat > "${_MOCK_CURL_STDIN_FILE}"
        break
      fi
    done
    print -r -- "${_MOCK_CURL_RESPONSE}"
    return ${_MOCK_CURL_EXIT}
  }
}

_mock_curl_teardown() {
  unfunction curl 2>/dev/null || true
  rm -f "${_MOCK_CURL_ARGS_FILE}" "${_MOCK_CURL_STDIN_FILE}" 2>/dev/null
  _MOCK_CURL_RESPONSE=""
  _MOCK_CURL_EXIT=0
}

# Returns 0 if needle appears as an exact line in the args file
_mock_curl_args_contain() {
  local needle="${1}"
  if [[ ! -f "${_MOCK_CURL_ARGS_FILE}" ]]; then return 1; fi
  local line
  while IFS= read -r line; do
    [[ "${line}" == "${needle}" ]] && return 0
  done < "${_MOCK_CURL_ARGS_FILE}"
  return 1
}

# Returns 0 if needle appears anywhere in the stdin capture file
_mock_curl_stdin_contains() {
  local needle="${1}"
  if [[ ! -f "${_MOCK_CURL_STDIN_FILE}" ]]; then return 1; fi
  [[ "$(cat "${_MOCK_CURL_STDIN_FILE}")" == *"${needle}"* ]]
}

# Returns 0 if needle appears anywhere in the args file (substring match)
_mock_curl_args_contains_substr() {
  local needle="${1}"
  if [[ ! -f "${_MOCK_CURL_ARGS_FILE}" ]]; then return 1; fi
  [[ "$(cat "${_MOCK_CURL_ARGS_FILE}")" == *"${needle}"* ]]
}

# ==============================================================================
print "# [test_ollama.zsh] OllamaClient Module Tests"
# ==============================================================================

_test_load_ollama

# ==============================================================================
# 1. URL validation — @ credential embedding (AC-1)
# ==============================================================================
print "# --- 1. URL validation: @ credential embedding (AC-1) ---"

# The @ trick: per RFC 3986 §3.2.1, userinfo appears before @ in the authority.
# http://localhost@evil.com → host is evil.com; "localhost" is the userinfo.
_zai_validate_ollama_url "http://localhost@evil.com"
assert_false "rejects http://localhost@evil.com (@ embedding, evil.com is actual host)" $?

_zai_validate_ollama_url "http://user:pass@localhost:11434"
assert_false "rejects http://user:pass@localhost:11434 (credentials in URL)" $?

_zai_validate_ollama_url "http://127.0.0.1@evil.com"
assert_false "rejects http://127.0.0.1@evil.com (@ with IPv4 userinfo)" $?

_zai_validate_ollama_url "http://admin@localhost:11434"
assert_false "rejects http://admin@localhost:11434 (user@ prefix)" $?

# ==============================================================================
# 2. URL validation — subdomain tricks (AC-2)
# ==============================================================================
print "# --- 2. URL validation: subdomain tricks (AC-2) ---"

_zai_validate_ollama_url "http://localhost.evil.com"
assert_false "rejects http://localhost.evil.com (localhost as subdomain)" $?

_zai_validate_ollama_url "http://localhost.evil.com:11434"
assert_false "rejects http://localhost.evil.com:11434 (subdomain with port)" $?

_zai_validate_ollama_url "http://127.0.0.1.evil.com"
assert_false "rejects http://127.0.0.1.evil.com (IPv4 as subdomain)" $?

_zai_validate_ollama_url "http://evil.localhost:11434"
assert_false "rejects http://evil.localhost:11434 (subdomain of localhost)" $?

_zai_validate_ollama_url "http://notlocalhost:11434"
assert_false "rejects http://notlocalhost:11434 (hostname not in allowlist)" $?

# ==============================================================================
# 3. URL validation — IPv4-mapped IPv6 (AC-3)
# ==============================================================================
print "# --- 3. URL validation: IPv4-mapped IPv6 (AC-3) ---"

_zai_validate_ollama_url "http://[::ffff:7f00:1]:11434"
assert_false "rejects http://[::ffff:7f00:1]:11434 (IPv4-mapped IPv6)" $?

_zai_validate_ollama_url "http://[::ffff:127.0.0.1]:11434"
assert_false "rejects http://[::ffff:127.0.0.1]:11434 (IPv4-mapped IPv6 dotted)" $?

_zai_validate_ollama_url "http://[2001:db8::1]:11434"
assert_false "rejects http://[2001:db8::1]:11434 (non-loopback IPv6)" $?

_zai_validate_ollama_url "http://[::2]:11434"
assert_false "rejects http://[::2]:11434 (similar to ::1 but different)" $?

# ==============================================================================
# 4. URL validation — valid loopback URLs (AC-4)
# ==============================================================================
print "# --- 4. URL validation: valid loopback URLs (AC-4) ---"

_zai_validate_ollama_url "http://localhost:11434"
assert_true "accepts http://localhost:11434" $?

_zai_validate_ollama_url "http://127.0.0.1:11434"
assert_true "accepts http://127.0.0.1:11434" $?

_zai_validate_ollama_url "http://[::1]:11434"
assert_true "accepts http://[::1]:11434" $?

_zai_validate_ollama_url "http://localhost"
assert_true "accepts http://localhost (no port)" $?

_zai_validate_ollama_url "http://127.0.0.1"
assert_true "accepts http://127.0.0.1 (no port)" $?

_zai_validate_ollama_url "http://[::1]"
assert_true "accepts http://[::1] (no port)" $?

_zai_validate_ollama_url "http://localhost:11434/api/generate"
assert_true "accepts http://localhost:11434/api/generate (with path)" $?

_zai_validate_ollama_url "https://localhost:11434"
assert_true "accepts https://localhost:11434 (https scheme)" $?

# ==============================================================================
# 5. URL validation — edge cases and rejection of non-loopback
# ==============================================================================
print "# --- 5. URL validation: edge cases ---"

_zai_validate_ollama_url ""
assert_false "rejects empty URL" $?

_zai_validate_ollama_url "ftp://localhost:11434"
assert_false "rejects ftp:// scheme (unrecognised)" $?

_zai_validate_ollama_url "localhost:11434"
assert_false "rejects URL without http:// or https:// scheme" $?

_zai_validate_ollama_url "//localhost:11434"
assert_false "rejects protocol-relative URL (no scheme)" $?

# ==============================================================================
# 6. Loopback interface detection (AC-6)
# ==============================================================================
print "# --- 6. Loopback interface detection (AC-6) ---"

assert_not_empty "_ZAI_LOOPBACK_IFACE is set at module load time" "${_ZAI_LOOPBACK_IFACE}"

local current_os
current_os="$(uname -s 2>/dev/null)"
if [[ "${current_os}" == "Darwin" ]]; then
  assert_equal "_ZAI_LOOPBACK_IFACE is 'lo0' on macOS" "lo0" "${_ZAI_LOOPBACK_IFACE}"
else
  assert_equal "_ZAI_LOOPBACK_IFACE is 'lo' on Linux" "lo" "${_ZAI_LOOPBACK_IFACE}"
fi

# Simulate macOS platform detection by overriding uname
function uname() { print "Darwin"; }
unset _ZAI_OLLAMA_LOADED; unset _ZAI_LOOPBACK_IFACE
source "${_ZAI_TEST_OLLAMA_PLUGIN}"
assert_equal "simulated macOS uname → _ZAI_LOOPBACK_IFACE='lo0'" "lo0" "${_ZAI_LOOPBACK_IFACE}"
unfunction uname

# Simulate Linux platform detection
function uname() { print "Linux"; }
unset _ZAI_OLLAMA_LOADED; unset _ZAI_LOOPBACK_IFACE
source "${_ZAI_TEST_OLLAMA_PLUGIN}"
assert_equal "simulated Linux uname → _ZAI_LOOPBACK_IFACE='lo'" "lo" "${_ZAI_LOOPBACK_IFACE}"
unfunction uname

# Simulate unknown platform — defaults to Linux (lo)
function uname() { print "FreeBSD"; }
unset _ZAI_OLLAMA_LOADED; unset _ZAI_LOOPBACK_IFACE
source "${_ZAI_TEST_OLLAMA_PLUGIN}"
assert_equal "simulated FreeBSD uname → falls back to 'lo'" "lo" "${_ZAI_LOOPBACK_IFACE}"
unfunction uname

# Restore actual platform
unset _ZAI_OLLAMA_LOADED; unset _ZAI_LOOPBACK_IFACE
source "${_ZAI_TEST_OLLAMA_PLUGIN}"

# ==============================================================================
# 7. Source code inspection — stdin piping and --interface flag (AC-5, AC-6)
# ==============================================================================
print "# --- 7. Source code inspection: curl flags (AC-5, AC-6) ---"

_test_load_ollama

# AC-5: Verify _zai_ollama_generate uses -d @- (stdin piping, not -d <string>)
local generate_src
generate_src="$(typeset -f _zai_ollama_generate 2>/dev/null)"

assert_contains "_zai_ollama_generate source uses '-d @-' for stdin piping (AC-5)" \
  "-d @-" "${generate_src}"

assert_contains "_zai_ollama_generate source uses '--interface' flag for loopback" \
  "--interface" "${generate_src}"

assert_contains "_zai_ollama_generate source uses '--max-time' for timeout" \
  "--max-time" "${generate_src}"

assert_contains "_zai_ollama_generate source uses '--silent' flag" \
  "--silent" "${generate_src}"

assert_contains "_zai_ollama_generate source uses '-X POST'" \
  "-X POST" "${generate_src}"

# Also verify health check and model check use --interface
local health_src model_src
health_src="$(typeset -f _zai_ollama_check_health 2>/dev/null)"
model_src="$(typeset -f _zai_ollama_check_model 2>/dev/null)"

assert_contains "_zai_ollama_check_health uses --interface flag" \
  "--interface" "${health_src}"

assert_contains "_zai_ollama_check_model uses --interface flag" \
  "--interface" "${model_src}"

# ==============================================================================
# 8. _zai_json_escape_string helper
# ==============================================================================
print "# --- 8. _zai_json_escape_string helper ---"

_test_load_ollama

local escaped

escaped="$(_zai_json_escape_string 'hello world')"
assert_equal "no-op for plain string" "hello world" "${escaped}"

# Double quote: " → \"
escaped="$(_zai_json_escape_string 'say "hi"')"
assert_equal 'escapes double quotes: " → \"' 'say \"hi\"' "${escaped}"

# Backslash: \ → \\  (input has one backslash, output should have two)
escaped="$(_zai_json_escape_string $'path\\here')"
assert_equal 'escapes backslash: \ → \\' 'path\\here' "${escaped}"

# Newline: LF → \n  (input has actual newline, output should have literal \n)
escaped="$(_zai_json_escape_string $'line1\nline2')"
assert_equal 'escapes newline: LF → \n' $'line1\\nline2' "${escaped}"

# Tab: TAB → \t
escaped="$(_zai_json_escape_string $'col1\tcol2')"
assert_equal 'escapes tab: TAB → \t' $'col1\\tcol2' "${escaped}"

# Critical ordering: backslash must be escaped before quotes to avoid double-escaping.
# Input:  say \"hi\"      (one backslash + one double-quote on each side of hi)
# Step 1 (escape \):  say \\"hi\\"   (each \ → \\, quotes still bare)
# Step 2 (escape "):  say \\\"hi\\\" (each " → \", backslashes already doubled)
# Output: say \\\"hi\\\"  — three chars before/after hi: \\  \"
# Wrong (if quotes escaped first):  say \\\"hi\\\"  would still be correct here
# but for input \" → if " was escaped first, \ before it would then be double-escaped
escaped="$(_zai_json_escape_string 'say \"hi\"')"
# Expected: say \\\"hi\\\"  (backslash-backslash-backslash-quote wrapping hi)
# In single-quoted shell:  '\\\"' = \\ (2 backslashes) + \" (1 backslash + 1 quote)
assert_equal 'backslash-quote input: correct ordering (no double-escaping)' 'say \\\"hi\\\"' "${escaped}"

# ==============================================================================
# 9. JSON response parsing — basic extraction (AC-7)
# ==============================================================================
print "# --- 9. JSON response parsing: basic cases (AC-7) ---"

_test_load_ollama

local parsed

# Simple response field
parsed="$(_zai_ollama_parse_response '{"model":"qwen2.5-coder:3b","response":"ls -la","done":true}')"
assert_equal "parses simple response field" "ls -la" "${parsed}"

# Response among multiple fields
parsed="$(_zai_ollama_parse_response '{"model":"m","created_at":"t","response":"git status","done":true,"done_reason":"stop"}')"
assert_equal "parses response field among other fields" "git status" "${parsed}"

# Empty response value
parsed="$(_zai_ollama_parse_response '{"response":"","done":true}')"
assert_equal "parses empty response field as empty string" "" "${parsed}"

# Missing response field (no crash)
local rc
_zai_ollama_parse_response '{"model":"x","done":true}' >/dev/null 2>&1
rc=$?
assert_true "handles missing response field gracefully (no crash)" ${rc}

# Empty input
_zai_ollama_parse_response "" >/dev/null 2>&1
assert_false "returns non-zero for empty input" $?

# ==============================================================================
# 10. JSON response parsing — escaped characters (AC-7)
# ==============================================================================
print "# --- 10. JSON response parsing: escaped characters (AC-7) ---"

_test_load_ollama

# \n in JSON → actual newline
# Input JSON has literal backslash-n (JSON escape for newline)
parsed="$(_zai_ollama_parse_response '{"response":"line1\nline2","done":true}')"
# Expected: line1 + actual newline + line2
local expected_newline
printf -v expected_newline 'line1\nline2'
assert_equal "parses JSON \\n as actual newline character" "${expected_newline}" "${parsed}"

# \t in JSON → actual tab
parsed="$(_zai_ollama_parse_response '{"response":"col1\tcol2","done":true}')"
local expected_tab
printf -v expected_tab 'col1\tcol2'
assert_equal "parses JSON \\t as actual tab character" "${expected_tab}" "${parsed}"

# \\ in JSON → single backslash
# Input: path\\here (two backslashes = one backslash in decoded output)
parsed="$(_zai_ollama_parse_response '{"response":"path\\here","done":true}')"
# Expected: path\here with exactly one backslash (single-quoted = literal backslash)
assert_equal 'parses JSON \\\\ as single backslash' 'path\here' "${parsed}"

# \" in JSON → literal double quote
# Input has backslash+doublequote inside the value (JSON escape for double-quote)
parsed="$(_zai_ollama_parse_response '{"response":"say \"hi\"","done":true}')"
assert_equal 'parses JSON \" as literal double-quote' 'say "hi"' "${parsed}"

# \/ in JSON → forward slash (valid JSON escape)
parsed="$(_zai_ollama_parse_response '{"response":"path\/to\/file","done":true}')"
assert_equal "parses JSON \\/ as forward slash" "path/to/file" "${parsed}"

# Combination: \" and \n together
# JSON: {"response":"echo \"hello\nworld\"","done":true}
# Input (single-quoted, literal): backslash+doublequote around hello\nworld
parsed="$(_zai_ollama_parse_response '{"response":"echo \"hello\nworld\"","done":true}')"
local expected_combo
printf -v expected_combo 'echo "hello\nworld"'
assert_equal 'parses combination of \" and \\n escapes' "${expected_combo}" "${parsed}"

# Response with trailing JSON context fields
parsed="$(_zai_ollama_parse_response '{"model":"m","response":"docker ps -a","done":true,"context":[1,2,3]}')"
assert_equal "parses response with subsequent context fields" "docker ps -a" "${parsed}"

# ==============================================================================
# 11. _zai_ollama_generate — runtime behavior with mock curl
# ==============================================================================
print "# --- 11. _zai_ollama_generate runtime behavior ---"

_test_load_ollama

# Test: generate returns parsed completion text
_mock_curl_setup '{"model":"qwen2.5-coder:3b","response":"docker ps -a","done":true}' 0

local completion
completion="$(_zai_ollama_generate "list running containers" '{"temperature":0.1}')"
assert_equal "_zai_ollama_generate returns parsed completion text" "docker ps -a" "${completion}"

_mock_curl_teardown

# Test: curl failure propagates as non-zero exit
_mock_curl_setup "" 7  # curl exit 7 = could not connect

_zai_ollama_generate "test" '{}' >/dev/null 2>&1
assert_false "_zai_ollama_generate returns non-zero on curl failure (exit 7)" $?

_mock_curl_teardown

# Test: curl -d @- is actually used at runtime (stdin piping)
_mock_curl_setup '{"response":"ls","done":true}' 0

_zai_ollama_generate "complete: ls" '{"temperature":0.1}' >/dev/null 2>&1

# Check @- arg was passed (from temp file)
_mock_curl_args_contain "@-"
assert_true "curl called with @- argument at runtime (stdin piping, AC-5)" $?

# Check prompt appears in stdin, NOT in args
_mock_curl_stdin_contains "complete: ls"
assert_true "prompt text appears in curl stdin body" $?

# Verify prompt does NOT appear as a direct curl argument
_mock_curl_args_contains_substr "complete: ls"
assert_false "prompt text does NOT appear in curl command-line args" $?

_mock_curl_teardown

# Test: --interface flag is used at runtime
_mock_curl_setup '{"response":"ls","done":true}' 0

_zai_ollama_generate "test" '{}' >/dev/null 2>&1

_mock_curl_args_contain "--interface"
assert_true "curl called with --interface flag at runtime (AC-6)" $?

_mock_curl_args_contain "${_ZAI_LOOPBACK_IFACE}"
assert_true "curl --interface uses correct loopback adapter at runtime" $?

_mock_curl_teardown

# ==============================================================================
# 12. _zai_ollama_generate — URL validation rejects bad URLs
# ==============================================================================
print "# --- 12. _zai_ollama_generate URL validation integration ---"

_test_load_ollama
_mock_curl_setup '{"response":"ls","done":true}' 0

# Set a URL with @ — should be rejected before curl is called
ZSH_AI_COMPLETE_OLLAMA_URL="http://localhost@evil.com:11434"
: > "${_MOCK_CURL_ARGS_FILE}"  # Clear args file
_zai_ollama_generate "test" '{}' >/dev/null 2>&1
assert_false "_zai_ollama_generate rejects URL with @ (non-zero return)" $?

local args_file_size
args_file_size=$(wc -c < "${_MOCK_CURL_ARGS_FILE}" 2>/dev/null || print 0)
assert_equal "_zai_ollama_generate with bad URL: curl NOT called" "0" "${args_file_size// /}"

unset ZSH_AI_COMPLETE_OLLAMA_URL
_mock_curl_teardown

# ==============================================================================
# 13. _zai_ollama_check_health (AC-8, AC-9)
# ==============================================================================
print "# --- 13. _zai_ollama_check_health (AC-8, AC-9) ---"

_test_load_ollama

# AC-8: returns 0 when Ollama reachable (mock curl returning 0)
_mock_curl_setup "Ollama is running" 0

_zai_ollama_check_health
assert_true "health check returns 0 when Ollama reachable (mock, AC-8)" $?

_mock_curl_teardown

# AC-9: returns non-zero when Ollama not running (mock curl exit 7 = connection refused)
_mock_curl_setup "" 7

_zai_ollama_check_health
assert_false "health check returns non-zero when Ollama unreachable (mock exit 7, AC-9)" $?

_mock_curl_teardown

# AC-9: returns non-zero when Ollama times out (mock curl exit 28 = timeout)
_mock_curl_setup "" 28

_zai_ollama_check_health
assert_false "health check returns non-zero on timeout (mock exit 28, AC-9)" $?

_mock_curl_teardown

# AC-9: returns non-zero when URL is invalid (@ in URL)
ZSH_AI_COMPLETE_OLLAMA_URL="http://localhost@evil.com"
_zai_ollama_check_health
assert_false "health check returns non-zero for invalid URL with @" $?
unset ZSH_AI_COMPLETE_OLLAMA_URL

# Health check targets root URL (not /api/generate or other paths)
_mock_curl_setup "Ollama is running" 0

_zai_ollama_check_health >/dev/null 2>&1

local health_url_arg
health_url_arg="$(cat "${_MOCK_CURL_ARGS_FILE}" 2>/dev/null | tail -1)"
assert_false "health check targets root URL (not /api/generate)" \
  $(( ${health_url_arg[(i)/api/]} <= ${#health_url_arg} && 1 || 0 ))

_mock_curl_teardown

# ==============================================================================
# 14. _zai_ollama_check_model (AC-10, AC-11)
# ==============================================================================
print "# --- 14. _zai_ollama_check_model (AC-10, AC-11) ---"

_test_load_ollama

# AC-10: returns 0 when specified model is present
local tags_with_model
tags_with_model='{"models":[{"name":"qwen2.5-coder:3b","model":"qwen2.5-coder:3b","size":1234}]}'
_mock_curl_setup "${tags_with_model}" 0

_zai_ollama_check_model "qwen2.5-coder:3b"
assert_true "model check returns 0 when model present in tags (AC-10)" $?

_mock_curl_teardown

# AC-11: returns non-zero when model not in tags
local tags_without_model
tags_without_model='{"models":[{"name":"llama2:7b","model":"llama2:7b"}]}'
_mock_curl_setup "${tags_without_model}" 0

_zai_ollama_check_model "qwen2.5-coder:3b"
assert_false "model check returns non-zero when model not found (AC-11)" $?

_mock_curl_teardown

# AC-11: returns non-zero when Ollama is unreachable
_mock_curl_setup "" 7

_zai_ollama_check_model "qwen2.5-coder:3b"
assert_false "model check returns non-zero when Ollama unreachable (AC-11)" $?

_mock_curl_teardown

# ==============================================================================
# 15. _zai_ollama_check_model — precision matching
# ==============================================================================
print "# --- 15. _zai_ollama_check_model precision matching ---"

_test_load_ollama

# Exact name match required — partial prefix must not match
local tags_similar
tags_similar='{"models":[{"name":"qwen2.5-coder:3b-instruct","model":"qwen2.5-coder:3b-instruct"}]}'
_mock_curl_setup "${tags_similar}" 0

_zai_ollama_check_model "qwen2.5-coder:3b"
assert_false "model check does not match prefix: 3b != 3b-instruct" $?

_mock_curl_teardown

# Multiple models — correct one is found
local tags_multi
tags_multi='{"models":[{"name":"llama2:7b"},{"name":"qwen2.5-coder:3b"},{"name":"mistral:7b"}]}'
_mock_curl_setup "${tags_multi}" 0

_zai_ollama_check_model "qwen2.5-coder:3b"
assert_true "model check finds target among multiple models" $?

_zai_ollama_check_model "llama2:7b"
assert_true "model check finds first model in list" $?

_zai_ollama_check_model "mistral:7b"
assert_true "model check finds last model in list" $?

_zai_ollama_check_model "gpt-4"
assert_false "model check returns non-zero for model not in list" $?

_mock_curl_teardown

# Empty model name
_test_load_ollama
_zai_ollama_check_model ""
assert_false "model check returns non-zero for empty model name" $?

# Invalid URL
ZSH_AI_COMPLETE_OLLAMA_URL="http://evil.com:11434"
_zai_ollama_check_model "qwen2.5-coder:3b"
assert_false "model check returns non-zero for non-loopback URL" $?
unset ZSH_AI_COMPLETE_OLLAMA_URL

# ==============================================================================
# 16. Double-source guard
# ==============================================================================
print "# --- 16. Double-source guard ---"

_test_load_ollama
local iface_before="${_ZAI_LOOPBACK_IFACE}"

# Source again — guard prevents re-initialization
source "${_ZAI_TEST_OLLAMA_PLUGIN}"

assert_equal "double-source preserves _ZAI_LOOPBACK_IFACE" \
  "${iface_before}" "${_ZAI_LOOPBACK_IFACE}"

assert_equal "_ZAI_OLLAMA_LOADED remains 1 after double-source" \
  "1" "${_ZAI_OLLAMA_LOADED}"

# Force reload (unset guard) re-runs platform detection
unset _ZAI_OLLAMA_LOADED
unset _ZAI_LOOPBACK_IFACE
source "${_ZAI_TEST_OLLAMA_PLUGIN}"
assert_not_empty "force reload re-sets _ZAI_LOOPBACK_IFACE" "${_ZAI_LOOPBACK_IFACE}"

# ==============================================================================
# 17. _zai_ollama_generate — options_json defaults
# ==============================================================================
print "# --- 17. _zai_ollama_generate options_json defaults ---"

_test_load_ollama
_mock_curl_setup '{"response":"pwd","done":true}' 0

# Empty options_json should use {} default
local result
result="$(_zai_ollama_generate "current directory?" "")"
assert_equal "generate with empty options_json succeeds" "pwd" "${result}"

_mock_curl_teardown

_mock_curl_setup '{"response":"pwd","done":true}' 0

# Omitted options_json (single argument)
result="$(_zai_ollama_generate "current directory?")"
assert_equal "generate with omitted options_json succeeds" "pwd" "${result}"

_mock_curl_teardown

# ==============================================================================
# Cleanup
# ==============================================================================

# Ensure mock temp files are removed
rm -f "${_MOCK_CURL_ARGS_FILE}" "${_MOCK_CURL_STDIN_FILE}" 2>/dev/null
_mock_curl_teardown

# ==============================================================================
# Standalone mode: print TAP plan and summary
# ==============================================================================
if [[ "${0}" == "${(%):-%x}" ]] || [[ "${ZSH_ARGZERO:-}" == *"test_ollama.zsh" ]]; then
  tap_plan
  tap_summary
  exit $(( _TAP_FAIL_COUNT > 0 ? 1 : 0 ))
fi
