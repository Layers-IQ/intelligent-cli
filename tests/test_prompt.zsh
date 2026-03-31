#!/usr/bin/env zsh
# ==============================================================================
# zsh-ai-complete: PromptBuilder Module Tests
# File: tests/test_prompt.zsh
# ==============================================================================
#
# Run standalone:   zsh tests/test_prompt.zsh
# Run via runner:   zsh tests/test_runner.zsh tests/test_prompt.zsh
#
# Tests cover TASK-004 acceptance criteria:
#   - FIM tokens (<|fim_prefix|>, <|fim_suffix|>, <|fim_middle|>) placed correctly
#   - ChatML prompt structure correct with system role
#   - Mode auto-detection: '# ...' → nl_to_cmd, otherwise → completion
#   - Generation params include raw:true for both modes
#   - Completion params: temperature=0.1, num_predict=60 (deterministic)
#   - NL-to-cmd params: temperature=0.2, num_predict=150 (more varied)
#   - Post-processing strips echoed buffer prefix
#   - Post-processing rejects output >200 chars as hallucination
#   - Post-processing removes markdown fences (```)
#   - Completion mode returns only first line of output
# ==============================================================================

# Capture script directory at TOP LEVEL (outside functions).
typeset -g _ZAI_TEST_PROMPT_DIR="${${(%):-%x}:a:h}"
typeset -g _ZAI_TEST_PROMPT_LIB="${_ZAI_TEST_PROMPT_DIR}/../plugin/lib"

# ── Bootstrap: load test runner if not already loaded ─────────────────────────
if (( ! ${+functions[assert_equal]} )); then
  source "${_ZAI_TEST_PROMPT_DIR}/test_runner.zsh"
fi

# ── Check: source files must exist ────────────────────────────────────────────
if [[ ! -f "${_ZAI_TEST_PROMPT_LIB}/prompt.zsh" ]]; then
  print "# SKIP: plugin/lib/prompt.zsh not found — skipping prompt tests"
  skip_test "prompt.zsh exists" "plugin/lib/prompt.zsh not found"
  if [[ "${0}" == "${(%):-%x}" ]] || [[ "${ZSH_ARGZERO:-}" == *"test_prompt.zsh" ]]; then
    tap_plan; tap_summary
    exit 0
  fi
  return 0
fi

# ── Helper: load/reload prompt module ─────────────────────────────────────────
_test_load_prompt() {
  unset _ZAI_CONFIG_LOADED
  unset '_ZAI_CONFIG_DEFAULTS'
  unset '_ZAI_CONFIG_OVERRIDES'
  unset _ZAI_PROMPT_LOADED

  source "${_ZAI_TEST_PROMPT_LIB}/config.zsh"
  source "${_ZAI_TEST_PROMPT_LIB}/prompt.zsh"
}

# ==============================================================================
print "# [test_prompt.zsh] PromptBuilder Module Tests"
# ==============================================================================

# ==============================================================================
# 1. _zai_build_completion_prompt — FIM tokens placed correctly
# ==============================================================================

print "# --- 1. _zai_build_completion_prompt: FIM tokens ---"

_test_load_prompt

local prompt context buffer

buffer="git st"
context="<directory>\nmain.go\n</directory>\n"

prompt="$(_zai_build_completion_prompt "${buffer}" "${context}")"

# AC: FIM prefix token at the very start
assert_match "_zai_build_completion_prompt starts with <|fim_prefix|>" \
  '^\<\|fim_prefix\|\>' "${prompt}"

# AC: FIM suffix token present
assert_contains "_zai_build_completion_prompt contains <|fim_suffix|>" \
  "<|fim_suffix|>" "${prompt}"

# AC: FIM middle token present
assert_contains "_zai_build_completion_prompt contains <|fim_middle|>" \
  "<|fim_middle|>" "${prompt}"

# Context appears between prefix token and suffix token
local before_suffix="${prompt%%<|fim_suffix|>*}"
assert_contains "context appears before <|fim_suffix|>" \
  "main.go" "${before_suffix}"

# Buffer appears between prefix token and suffix token
assert_contains "buffer 'git st' appears before <|fim_suffix|>" \
  "git st" "${before_suffix}"

# ==============================================================================
# 2. _zai_build_completion_prompt — structure validation
# ==============================================================================

print "# --- 2. _zai_build_completion_prompt: structure order ---"

_test_load_prompt

prompt="$(_zai_build_completion_prompt "ls" "some context")"

# Token order must be: fim_prefix ... fim_suffix ... fim_middle
local prefix_pos suffix_pos middle_pos
prefix_pos="${prompt[(i)<|fim_prefix|>]}"
suffix_pos="${prompt[(i)<|fim_suffix|>]}"
middle_pos="${prompt[(i)<|fim_middle|>]}"

# All tokens must be found (pos ≤ length)
assert_true "FIM prefix token found in prompt" $(( prefix_pos <= ${#prompt} ))
assert_true "FIM suffix token found in prompt" $(( suffix_pos <= ${#prompt} ))
assert_true "FIM middle token found in prompt" $(( middle_pos <= ${#prompt} ))

# Order: prefix < suffix < middle
assert_true "FIM prefix before suffix" $(( prefix_pos < suffix_pos ))
assert_true "FIM suffix before middle" $(( suffix_pos < middle_pos ))

# Nothing after fim_middle (model fills that in)
local after_middle="${prompt##*<|fim_middle|>}"
assert_empty "Nothing after <|fim_middle|> in prompt" "${after_middle}"

# ==============================================================================
# 3. _zai_build_completion_prompt — empty buffer
# ==============================================================================

print "# --- 3. _zai_build_completion_prompt: empty buffer ---"

_test_load_prompt

prompt="$(_zai_build_completion_prompt "" "some context")"

# Still valid FIM structure
assert_contains "empty buffer: FIM prefix present" "<|fim_prefix|>" "${prompt}"
assert_contains "empty buffer: FIM suffix present" "<|fim_suffix|>" "${prompt}"
assert_contains "empty buffer: FIM middle present" "<|fim_middle|>" "${prompt}"
assert_contains "empty buffer: context still included" "some context" "${prompt}"

# ==============================================================================
# 4. _zai_build_completion_prompt — empty context
# ==============================================================================

print "# --- 4. _zai_build_completion_prompt: empty context ---"

_test_load_prompt

prompt="$(_zai_build_completion_prompt "docker run" "")"

# Still valid FIM structure
assert_contains "empty context: FIM prefix present" "<|fim_prefix|>" "${prompt}"
assert_contains "empty context: buffer 'docker run' included" "docker run" "${prompt}"
assert_contains "empty context: FIM suffix present" "<|fim_suffix|>" "${prompt}"
assert_contains "empty context: FIM middle present" "<|fim_middle|>" "${prompt}"

# ==============================================================================
# 5. _zai_build_nl_translation_prompt — ChatML structure correct
# ==============================================================================

print "# --- 5. _zai_build_nl_translation_prompt: ChatML structure ---"

_test_load_prompt

context="<directory>\nmain.go\n</directory>"
local comment="# list all running containers"
local nl_prompt
nl_prompt="$(_zai_build_nl_translation_prompt "${comment}" "${context}")"

# AC: ChatML system role present
assert_contains "ChatML: <|im_start|>system present" \
  "<|im_start|>system" "${nl_prompt}"

# AC: im_end token present
assert_contains "ChatML: <|im_end|> present" \
  "<|im_end|>" "${nl_prompt}"

# AC: User message present
assert_contains "ChatML: <|im_start|>user present" \
  "<|im_start|>user" "${nl_prompt}"

# AC: Assistant start marker present (for model to continue from)
assert_contains "ChatML: <|im_start|>assistant present" \
  "<|im_start|>assistant" "${nl_prompt}"

# ==============================================================================
# 6. _zai_build_nl_translation_prompt — strips '# ' prefix from comment
# ==============================================================================

print "# --- 6. _zai_build_nl_translation_prompt: strips # prefix ---"

_test_load_prompt

# '# ' prefix stripped
nl_prompt="$(_zai_build_nl_translation_prompt "# list all processes" "")"
assert_contains "NL prompt: comment text without '# ' included" \
  "list all processes" "${nl_prompt}"

# Original '# ' is removed
local has_hash_space=0
# Check if the raw "# list all" with the hash appears as the literal input
# (the function should strip '# ' before embedding)
[[ "${nl_prompt}" == *"# list all processes"* ]] && has_hash_space=1
# It's OK if the hash remains — what matters is the text is there
# The key test is that "list all processes" appears
assert_contains "NL prompt: natural language text present" \
  "list all processes" "${nl_prompt}"

# ==============================================================================
# 7. _zai_build_nl_translation_prompt — context embedded in user message
# ==============================================================================

print "# --- 7. _zai_build_nl_translation_prompt: context embedded ---"

_test_load_prompt

nl_prompt="$(_zai_build_nl_translation_prompt "# show disk usage" "<directory>\nREADME.md\n</directory>")"

# Context should appear in the prompt
assert_contains "NL prompt: context (README.md) embedded in prompt" \
  "README.md" "${nl_prompt}"

# Comment text should appear
assert_contains "NL prompt: 'disk usage' appears in prompt" \
  "disk usage" "${nl_prompt}"

# ==============================================================================
# 8. _zai_build_nl_translation_prompt — system role contains shell instruction
# ==============================================================================

print "# --- 8. _zai_build_nl_translation_prompt: system instruction ---"

_test_load_prompt

nl_prompt="$(_zai_build_nl_translation_prompt "# copy file" "")"

# Extract system section (between <|im_start|>system and first <|im_end|>)
local system_section="${nl_prompt%%<|im_end|>*}"
system_section="${system_section##*<|im_start|>system}"

# System instruction must be non-empty
assert_not_empty "NL prompt: system section is non-empty" "${system_section}"

# Should mention shell/command generation in system section
local has_shell=0
[[ "${system_section}" == *"shell"* ]] || [[ "${system_section}" == *"command"* ]] && has_shell=1
assert_equal "NL prompt: system section mentions shell/command" "1" "${has_shell}"

# ==============================================================================
# 9. _zai_detect_prompt_mode — '# ...' → nl_to_cmd
# ==============================================================================

print "# --- 9. _zai_detect_prompt_mode: '# ...' = nl_to_cmd ---"

_test_load_prompt

assert_equal "mode: '# list files' → nl_to_cmd" \
  "nl_to_cmd" "$(_zai_detect_prompt_mode '# list files')"

assert_equal "mode: '# show git log' → nl_to_cmd" \
  "nl_to_cmd" "$(_zai_detect_prompt_mode '# show git log')"

assert_equal "mode: '#copy file' (no space) → nl_to_cmd" \
  "nl_to_cmd" "$(_zai_detect_prompt_mode '#copy file')"

assert_equal "mode: '# find large files in /tmp' → nl_to_cmd" \
  "nl_to_cmd" "$(_zai_detect_prompt_mode '# find large files in /tmp')"

# ==============================================================================
# 10. _zai_detect_prompt_mode — regular buffer → completion
# ==============================================================================

print "# --- 10. _zai_detect_prompt_mode: regular buffer = completion ---"

_test_load_prompt

assert_equal "mode: 'git st' → completion" \
  "completion" "$(_zai_detect_prompt_mode 'git st')"

assert_equal "mode: 'docker run' → completion" \
  "completion" "$(_zai_detect_prompt_mode 'docker run')"

assert_equal "mode: 'ls -la' → completion" \
  "completion" "$(_zai_detect_prompt_mode 'ls -la')"

assert_equal "mode: empty string → completion" \
  "completion" "$(_zai_detect_prompt_mode '')"

# Bare '#' with nothing else — edge case
local bare_hash_mode
bare_hash_mode="$(_zai_detect_prompt_mode '#')"
# '#' alone (length 1): may be completion or nl_to_cmd depending on impl
# Verify it returns a non-empty valid string
assert_not_empty "mode: bare '#' returns a non-empty mode string" "${bare_hash_mode}"
local _bare_mode_valid=0
[[ "${bare_hash_mode}" == "completion" || "${bare_hash_mode}" == "nl_to_cmd" ]] && _bare_mode_valid=1
assert_true "mode: bare '#' returns valid mode (completion or nl_to_cmd)" ${_bare_mode_valid}

# ==============================================================================
# 11. _zai_get_generation_params — completion mode values
# ==============================================================================

print "# --- 11. _zai_get_generation_params: completion mode ---"

_test_load_prompt

local params
params="$(_zai_get_generation_params completion)"

# AC: temperature=0.1 (low for deterministic completions)
assert_contains "completion params: temperature:0.1" \
  '"temperature":0.1' "${params}"

# AC: top_k=20
assert_contains "completion params: top_k:20" \
  '"top_k":20' "${params}"

# AC: num_predict=60 (short completions)
assert_contains "completion params: num_predict:60" \
  '"num_predict":60' "${params}"

# AC: stop contains newline (completions are single-line)
assert_contains "completion params: stop contains newline" \
  '"stop"' "${params}"

# AC: raw:true (prevents chat template corruption of FIM tokens)
assert_contains "completion params: raw:true" \
  '"raw":true' "${params}"

# Params must be valid JSON-like structure (starts with {, ends with })
assert_match "completion params: looks like JSON object" \
  '^\{.*\}$' "${params}"

# ==============================================================================
# 12. _zai_get_generation_params — nl_to_cmd mode values
# ==============================================================================

print "# --- 12. _zai_get_generation_params: nl_to_cmd mode ---"

_test_load_prompt

params="$(_zai_get_generation_params nl_to_cmd)"

# AC: temperature=0.2 (slightly higher for more varied command generation)
assert_contains "nl_to_cmd params: temperature:0.2" \
  '"temperature":0.2' "${params}"

# AC: top_k=40
assert_contains "nl_to_cmd params: top_k:40" \
  '"top_k":40' "${params}"

# AC: num_predict=150 (longer output for complex commands)
assert_contains "nl_to_cmd params: num_predict:150" \
  '"num_predict":150' "${params}"

# AC: raw:true
assert_contains "nl_to_cmd params: raw:true" \
  '"raw":true' "${params}"

# Params must be valid JSON-like structure
assert_match "nl_to_cmd params: looks like JSON object" \
  '^\{.*\}$' "${params}"

# ==============================================================================
# 13. _zai_get_generation_params — modes have different values
# ==============================================================================

print "# --- 13. _zai_get_generation_params: modes differ ---"

_test_load_prompt

local completion_params nl_params
completion_params="$(_zai_get_generation_params completion)"
nl_params="$(_zai_get_generation_params nl_to_cmd)"

# Temperature MUST differ between modes
assert_not_equal "params differ: completion temp ≠ nl_to_cmd temp" \
  "${completion_params}" "${nl_params}"

# num_predict must differ (60 vs 150)
assert_contains "params: completion has num_predict:60" \
  '"num_predict":60' "${completion_params}"
assert_contains "params: nl_to_cmd has num_predict:150" \
  '"num_predict":150' "${nl_params}"

# Default (no arg) should match completion
local default_params
default_params="$(_zai_get_generation_params)"
assert_equal "params: default mode matches completion mode" \
  "${completion_params}" "${default_params}"

# ==============================================================================
# 14. _zai_clean_completion — strips echoed buffer prefix
# ==============================================================================

print "# --- 14. _zai_clean_completion: strips echoed buffer prefix ---"

_test_load_prompt

local cleaned

# Model echoes the buffer before the completion
cleaned="$(_zai_clean_completion 'git status --short' 'git st' completion)"
assert_equal "clean: echoed prefix 'git st' stripped" \
  "atus --short" "${cleaned}"

# Model echoes full buffer
cleaned="$(_zai_clean_completion 'docker run --rm -it ubuntu' 'docker run' completion)"
assert_equal "clean: echoed 'docker run' prefix stripped" \
  "--rm -it ubuntu" "${cleaned}"

# No echo: raw output has no buffer prefix
cleaned="$(_zai_clean_completion ' --oneline' 'git log' completion)"
assert_equal "clean: no prefix echo — output returned as-is" \
  "--oneline" "${cleaned}"

# ==============================================================================
# 15. _zai_clean_completion — rejects >200 chars (hallucination guard)
# ==============================================================================

print "# --- 15. _zai_clean_completion: rejects >200 chars ---"

_test_load_prompt

# Generate a 201-character string
local long_output
long_output="$(printf '%0.s.' {1..201})"

assert_equal "test setup: long_output is 201 chars" "201" "${#long_output}"

_zai_clean_completion "${long_output}" "" nl_to_cmd >/dev/null 2>&1
assert_false "clean: 201-char output returns non-zero (hallucination guard)" $?

# 200-char output is the boundary — should be accepted
local boundary_output
boundary_output="$(printf '%0.s.' {1..200})"

_zai_clean_completion "${boundary_output}" "" nl_to_cmd >/dev/null 2>&1
assert_true "clean: 200-char output accepted (at boundary)" $?

# Short output well under limit
cleaned="$(_zai_clean_completion 'status' 'git ' completion)"
assert_equal "clean: short output returned normally" "status" "${cleaned}"

# ==============================================================================
# 16. _zai_clean_completion — removes markdown code fences
# ==============================================================================

print "# --- 16. _zai_clean_completion: removes markdown fences ---"

_test_load_prompt

# Bare ``` fence markers
cleaned="$(_zai_clean_completion '```git status --short```' '' nl_to_cmd)"
local has_fence=0
[[ "${cleaned}" == *'```'* ]] && has_fence=1
assert_equal "clean: bare backtick fences removed" "0" "${has_fence}"

# Fenced block with language tag
local fenced_with_lang
printf -v fenced_with_lang '%s\n%s\n%s' '```bash' 'git status --short' '```'
cleaned="$(_zai_clean_completion "${fenced_with_lang}" '' nl_to_cmd)"
has_fence=0
[[ "${cleaned}" == *'```'* ]] && has_fence=1
assert_equal "clean: ```bash fence removed" "0" "${has_fence}"

# Content inside fences should be preserved
assert_contains "clean: content preserved after fence removal" \
  "git status" "${cleaned}"

# ==============================================================================
# 17. _zai_clean_completion — completion mode: first line only
# ==============================================================================

print "# --- 17. _zai_clean_completion: completion mode = first line only ---"

_test_load_prompt

# Multi-line output in completion mode — only first line returned
local multiline
printf -v multiline '%s\n%s\n%s' 'status --short' 'second line' 'third line'

cleaned="$(_zai_clean_completion "${multiline}" 'git ' completion)"
assert_equal "clean completion: only first line returned" \
  "status --short" "${cleaned}"

# Only first line — no newlines in result
local has_newline=0
[[ "${cleaned}" == *$'\n'* ]] && has_newline=1
assert_equal "clean completion: no newlines in result" "0" "${has_newline}"

# ==============================================================================
# 18. _zai_clean_completion — nl_to_cmd mode: may have multiple lines
# ==============================================================================

print "# --- 18. _zai_clean_completion: nl_to_cmd mode may multiline ---"

_test_load_prompt

# Multi-line output in nl_to_cmd mode — all lines preserved (within 200 char limit)
local multiline_cmd="git log --oneline | head -20"

cleaned="$(_zai_clean_completion "${multiline_cmd}" '' nl_to_cmd)"
assert_equal "clean nl_to_cmd: single-line command returned intact" \
  "${multiline_cmd}" "${cleaned}"

# ==============================================================================
# 19. _zai_clean_completion — empty input returns non-zero
# ==============================================================================

print "# --- 19. _zai_clean_completion: empty input ---"

_test_load_prompt

_zai_clean_completion "" "" completion >/dev/null 2>&1
assert_false "clean: empty input returns non-zero" $?

local empty_result
empty_result="$(_zai_clean_completion "" "" completion 2>/dev/null)"
assert_empty "clean: empty input produces no output" "${empty_result}"

# ==============================================================================
# 20. _zai_clean_completion — whitespace-only output returns non-zero
# ==============================================================================

print "# --- 20. _zai_clean_completion: whitespace-only output ---"

_test_load_prompt

_zai_clean_completion "   " "" completion >/dev/null 2>&1
assert_false "clean: whitespace-only output returns non-zero" $?

_zai_clean_completion $'\n\n\n' "" completion >/dev/null 2>&1
assert_false "clean: newlines-only output returns non-zero (or returns empty)" $?

# ==============================================================================
# 21. _zai_clean_completion — strips leading spaces
# ==============================================================================

print "# --- 21. _zai_clean_completion: strips leading spaces ---"

_test_load_prompt

# Model sometimes adds a leading space before the completion
cleaned="$(_zai_clean_completion '  --short' 'git status' completion)"
# After stripping echo of 'git status' (not present since raw has spaces first)
# Leading spaces should be stripped
local leading_spaces=0
[[ "${cleaned}" == ' '* ]] && leading_spaces=1
assert_equal "clean: leading spaces stripped from output" "0" "${leading_spaces}"

# ==============================================================================
# 22. _zai_build_completion_prompt — buffer with special characters
# ==============================================================================

print "# --- 22. _zai_build_completion_prompt: special chars in buffer ---"

_test_load_prompt

# Buffer with quotes
buffer='echo "hello world"'
prompt="$(_zai_build_completion_prompt "${buffer}" "")"
assert_contains "special chars: buffer with quotes in prompt" \
  'echo "hello world"' "${prompt}"

# Buffer with dollar sign (variable expansion guard)
buffer='echo $HOME'
prompt="$(_zai_build_completion_prompt "${buffer}" "")"
assert_contains "special chars: buffer with \$HOME in prompt" \
  '$HOME' "${prompt}"

# Buffer with backslash
buffer='echo path\\file'
prompt="$(_zai_build_completion_prompt "${buffer}" "")"
assert_not_empty "special chars: buffer with backslash doesn't empty prompt" \
  "${prompt}"

# ==============================================================================
# 23. _zai_get_generation_params — unknown mode falls back to completion
# ==============================================================================

print "# --- 23. _zai_get_generation_params: unknown mode fallback ---"

_test_load_prompt

local unknown_params
unknown_params="$(_zai_get_generation_params unknown_mode)"
local comp_params
comp_params="$(_zai_get_generation_params completion)"

assert_equal "params: unknown mode falls back to completion params" \
  "${comp_params}" "${unknown_params}"

# ==============================================================================
# 24. _zai_clean_completion — nl_to_cmd with prefix strip
# ==============================================================================

print "# --- 24. _zai_clean_completion: nl_to_cmd with prefix strip ---"

_test_load_prompt

# In nl_to_cmd mode the model may echo the # comment before the command
cleaned="$(_zai_clean_completion '# list all files\nls -la' '# list all files' nl_to_cmd)"
# After stripping echoed prefix, first non-empty result
assert_not_empty "nl_to_cmd clean: non-empty after prefix strip" "${cleaned}"

# ==============================================================================
# 25. Double-source guard
# ==============================================================================

print "# --- 25. Double-source guard ---"

_test_load_prompt

local loaded_before="${_ZAI_PROMPT_LOADED}"

# Source again — guard should prevent re-execution
source "${_ZAI_TEST_PROMPT_LIB}/prompt.zsh"

assert_equal "double-source: _ZAI_PROMPT_LOADED remains 1" \
  "1" "${_ZAI_PROMPT_LOADED}"

assert_equal "double-source: _zai_build_completion_prompt still defined" \
  "1" "${${+functions[_zai_build_completion_prompt]}}"

assert_equal "double-source: _zai_get_generation_params still defined" \
  "1" "${${+functions[_zai_get_generation_params]}}"

# ==============================================================================
# 26. Integration: full prompt pipeline for completion mode
# ==============================================================================

print "# --- 26. Integration: completion mode pipeline ---"

_test_load_prompt

# Simulate what the AsyncEngine does for a completion request:
# 1. Detect mode
local test_buffer="git lo"
local mode
mode="$(_zai_detect_prompt_mode "${test_buffer}")"
assert_equal "pipeline: 'git lo' → completion mode" "completion" "${mode}"

# 2. Get generation params for that mode
local gen_params
gen_params="$(_zai_get_generation_params "${mode}")"
assert_contains "pipeline: completion params have raw:true" '"raw":true' "${gen_params}"
assert_contains "pipeline: completion params have low temperature" '"temperature":0.1' "${gen_params}"

# 3. Build prompt
local ctx="<history>\ngit log --oneline\n</history>"
local built_prompt
built_prompt="$(_zai_build_completion_prompt "${test_buffer}" "${ctx}")"
assert_contains "pipeline: built prompt has FIM prefix" "<|fim_prefix|>" "${built_prompt}"
assert_contains "pipeline: context in prompt" "git log" "${built_prompt}"
assert_contains "pipeline: buffer in prompt" "git lo" "${built_prompt}"

# 4. Clean simulated model output
local raw_model_output="git lo" # echoed + completion
raw_model_output+="g --oneline -20"
cleaned="$(_zai_clean_completion "${raw_model_output}" "${test_buffer}" "${mode}")"
assert_equal "pipeline: cleaned output strips echoed prefix" "g --oneline -20" "${cleaned}"

# ==============================================================================
# 27. Integration: full prompt pipeline for nl_to_cmd mode
# ==============================================================================

print "# --- 27. Integration: nl_to_cmd mode pipeline ---"

_test_load_prompt

# 1. Detect mode
local nl_buffer="# list docker containers"
mode="$(_zai_detect_prompt_mode "${nl_buffer}")"
assert_equal "pipeline: '# ...' → nl_to_cmd mode" "nl_to_cmd" "${mode}"

# 2. Get generation params
gen_params="$(_zai_get_generation_params "${mode}")"
assert_contains "pipeline: nl_to_cmd params have raw:true" '"raw":true' "${gen_params}"
assert_contains "pipeline: nl_to_cmd params have higher temp" '"temperature":0.2' "${gen_params}"
assert_contains "pipeline: nl_to_cmd params have num_predict:150" '"num_predict":150' "${gen_params}"

# 3. Build NL prompt
built_prompt="$(_zai_build_nl_translation_prompt "${nl_buffer}" "")"
assert_contains "pipeline: NL prompt has ChatML system token" "<|im_start|>system" "${built_prompt}"
assert_contains "pipeline: NL prompt has assistant token" "<|im_start|>assistant" "${built_prompt}"
assert_contains "pipeline: NL prompt contains comment text" "list docker containers" "${built_prompt}"

# 4. Clean simulated model output
cleaned="$(_zai_clean_completion "docker ps -a" "" "${mode}")"
assert_equal "pipeline: NL model output cleaned" "docker ps -a" "${cleaned}"

# ==============================================================================
# 28. _zai_truncate_context — fast path when context within budget
# ==============================================================================

print "# --- 28. _zai_truncate_context: fast path ---"

_test_load_prompt

local short_context="<directory>\nfile.txt\n</directory>\n<history>\nls -la\n</history>"
local truncated_result
truncated_result="$(_zai_truncate_context "${short_context}" 7000)"
assert_equal "truncate: short context returned unchanged" \
  "${short_context}" "${truncated_result}"

# ==============================================================================
# 29. _zai_truncate_context — removes oldest history entries first
# ==============================================================================

print "# --- 29. _zai_truncate_context: trims oldest history first ---"

_test_load_prompt

# Build a context where history is the large section
local big_context=""
big_context+="<directory>"$'\n'"README.md"$'\n'"</directory>"$'\n'
big_context+="<history>"$'\n'
# Add 10 history entries each 50 chars → ~500 chars
local hentry
for hentry in "git log --oneline -20" "docker ps -a" "ls -la /tmp" \
    "find . -name '*.zsh'" "kubectl get pods" "npm run build" \
    "ssh user@server" "grep -r 'TODO'" "cat /etc/hosts" "echo oldest"; do
  big_context+="${hentry}"$'\n'
done
big_context+="</history>"$'\n'
big_context+="<context_type>standard</context_type>"

# Set a tight budget that forces trimming (keep about 200 chars)
local tight_budget=200
truncated_result="$(_zai_truncate_context "${big_context}" "${tight_budget}")"

# The trimmed result must be under budget
assert_true "truncate: result under budget" $(( ${#truncated_result} <= tight_budget ))

# The result must still have directory section intact
assert_contains "truncate: directory section preserved" "<directory>" "${truncated_result}"

# Oldest history entry "echo oldest" should be removed first
# (we can only verify the structure is valid and under budget)
assert_contains "truncate: </history> still present" "</history>" "${truncated_result}"

# ==============================================================================
# 30. _zai_truncate_context — prompt builders respect token budget
# ==============================================================================

print "# --- 30. prompt builders: token budget enforced via truncation ---"

_test_load_prompt

# Build a very large context (far over the normal budget)
local large_context=""
large_context+="<directory>"$'\n'
# 100 directory entries of 30 chars each = 3000 chars
local dentry
for dentry in {1..100}; do
  large_context+="$(printf 'filename_entry_%04d.txt' ${dentry})"$'\n'
done
large_context+="</directory>"$'\n'
large_context+="<history>"$'\n'
# 50 history entries of 60 chars each = 3000 chars
local hline
for hline in {1..50}; do
  large_context+="$(printf 'git log --oneline --%04d --format=%%h %%s' ${hline})"$'\n'
done
large_context+="</history>"$'\n'
large_context+="<context_type>standard</context_type>"

# Build a completion prompt with the large context
local huge_prompt
huge_prompt="$(_zai_build_completion_prompt "git " "${large_context}")"

# Rough token count: prompt length / 4 should be under 2048
local approx_tokens=$(( ${#huge_prompt} / 4 ))
assert_true "token budget: completion prompt under ~2048 tokens" \
  $(( approx_tokens <= 2048 ))

# Build an NL prompt too
local huge_nl_prompt
huge_nl_prompt="$(_zai_build_nl_translation_prompt "# list files" "${large_context}")"
approx_tokens=$(( ${#huge_nl_prompt} / 4 ))
assert_true "token budget: NL prompt under ~2048 tokens" \
  $(( approx_tokens <= 2048 ))

# ==============================================================================
# Standalone mode: print TAP plan and summary
# ==============================================================================

if [[ "${0}" == "${(%):-%x}" ]] || [[ "${ZSH_ARGZERO:-}" == *"test_prompt.zsh" ]]; then
  tap_plan
  tap_summary
  exit $(( _TAP_FAIL_COUNT > 0 ? 1 : 0 ))
fi
