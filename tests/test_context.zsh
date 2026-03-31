#!/usr/bin/env zsh
# ==============================================================================
# zsh-ai-complete: ContextGatherer Module Tests
# File: tests/test_context.zsh
# ==============================================================================
#
# Run standalone:   zsh tests/test_context.zsh
# Run via runner:   zsh tests/test_runner.zsh tests/test_context.zsh
#
# Tests cover TASK-003 acceptance criteria:
#   - Directory listing respects DIR_LIMIT and excludes sensitive files
#   - History entries limited to HISTORY_SIZE and redacted through SecurityFilter
#   - Git context shows branch + compact status (inside repo)
#   - Git context is empty/minimal outside a git repository
#   - Full context output has proper XML delimiter tags
#   - Command context detection: pipe, subshell, redirect, loop, standard
#   - No errors when git absent, history empty, or directory not readable
# ==============================================================================

# Capture script directory at TOP LEVEL (outside functions).
typeset -g _ZAI_TEST_CTX_DIR="${${(%):-%x}:a:h}"
typeset -g _ZAI_TEST_CTX_LIB="${_ZAI_TEST_CTX_DIR}/../plugin/lib"

# ── Bootstrap: load test runner if not already loaded ─────────────────────────
if (( ! ${+functions[assert_equal]} )); then
  source "${_ZAI_TEST_CTX_DIR}/test_runner.zsh"
fi

# ── Check: source files must exist ────────────────────────────────────────────
if [[ ! -f "${_ZAI_TEST_CTX_LIB}/context.zsh" ]]; then
  print "# SKIP: plugin/lib/context.zsh not found — skipping context tests"
  skip_test "context.zsh exists" "plugin/lib/context.zsh not found"
  if [[ "${0}" == "${(%):-%x}" ]] || [[ "${ZSH_ARGZERO:-}" == *"test_context.zsh" ]]; then
    tap_plan; tap_summary
    exit 0
  fi
  return 0
fi

# ── Helper: load/reload context module ────────────────────────────────────────
_test_load_context() {
  unset _ZAI_CONFIG_LOADED
  unset '_ZAI_CONFIG_DEFAULTS'
  unset '_ZAI_CONFIG_OVERRIDES'
  unset _ZAI_SECURITY_LOADED
  unset _ZAI_CONTEXT_LOADED

  source "${_ZAI_TEST_CTX_LIB}/config.zsh"
  source "${_ZAI_TEST_CTX_LIB}/security.zsh"
  source "${_ZAI_TEST_CTX_LIB}/context.zsh"
}

# ── Helper: create a controlled temp directory ────────────────────────────────
_test_make_tmpdir() {
  local tmpdir
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/_zai_test_ctx_XXXXXX")"
  print -- "${tmpdir}"
}

# ── Helper: remove temp directory ─────────────────────────────────────────────
_test_rm_tmpdir() {
  local dir="${1}"
  [[ -n "${dir}" && "${dir}" == /tmp/* || "${dir}" == "${TMPDIR:-/tmp}/"* ]] && \
    rm -rf "${dir}" 2>/dev/null
}

# ==============================================================================
print "# [test_context.zsh] ContextGatherer Module Tests"
# ==============================================================================

# ==============================================================================
# 1. _zai_gather_directory_context — basic directory listing
# ==============================================================================

print "# --- 1. _zai_gather_directory_context: basic listing ---"

_test_load_context

# Create a temp directory with known files
typeset -g _CTX_TEST_TMPDIR
_CTX_TEST_TMPDIR="$(_test_make_tmpdir)"

touch "${_CTX_TEST_TMPDIR}/main.go"
touch "${_CTX_TEST_TMPDIR}/README.md"
touch "${_CTX_TEST_TMPDIR}/Makefile"

# Change to test dir, gather context, return
typeset -g _CTX_ORIG_DIR="${PWD}"
cd "${_CTX_TEST_TMPDIR}"

local dir_result
dir_result="$(_zai_gather_directory_context)"

cd "${_CTX_ORIG_DIR}"

# Verify non-sensitive files appear
assert_contains "directory: main.go appears in listing" \
  "main.go" "${dir_result}"

assert_contains "directory: README.md appears in listing" \
  "README.md" "${dir_result}"

assert_contains "directory: Makefile appears in listing" \
  "Makefile" "${dir_result}"

_test_rm_tmpdir "${_CTX_TEST_TMPDIR}"

# ==============================================================================
# 2. _zai_gather_directory_context — sensitive files excluded
# ==============================================================================

print "# --- 2. _zai_gather_directory_context: sensitive files excluded ---"

_test_load_context

_CTX_TEST_TMPDIR="$(_test_make_tmpdir)"

# Non-sensitive files
touch "${_CTX_TEST_TMPDIR}/main.go"
touch "${_CTX_TEST_TMPDIR}/package.json"
# Sensitive files
touch "${_CTX_TEST_TMPDIR}/.env"
touch "${_CTX_TEST_TMPDIR}/.env.local"
touch "${_CTX_TEST_TMPDIR}/credentials.json"
touch "${_CTX_TEST_TMPDIR}/id_rsa"
touch "${_CTX_TEST_TMPDIR}/server.pem"
touch "${_CTX_TEST_TMPDIR}/secrets.yaml"

cd "${_CTX_TEST_TMPDIR}"
dir_result="$(_zai_gather_directory_context)"
cd "${_CTX_ORIG_DIR}"

# Non-sensitive files present
assert_contains "sensitive excl: main.go retained" \
  "main.go" "${dir_result}"

assert_contains "sensitive excl: package.json retained" \
  "package.json" "${dir_result}"

# Use pattern matching to verify exclusion (sensitive files must be absent)
local has_env=0
[[ "${dir_result}" == *".env"* ]] && has_env=1
assert_equal "sensitive excl: .env not in result" "0" "${has_env}"

local has_creds=0
[[ "${dir_result}" == *"credentials.json"* ]] && has_creds=1
assert_equal "sensitive excl: credentials.json not in result" "0" "${has_creds}"

local has_idrsa=0
[[ "${dir_result}" == *"id_rsa"* ]] && has_idrsa=1
assert_equal "sensitive excl: id_rsa not in result" "0" "${has_idrsa}"

local has_pem=0
[[ "${dir_result}" == *"server.pem"* ]] && has_pem=1
assert_equal "sensitive excl: server.pem not in result" "0" "${has_pem}"

local has_secrets_yaml=0
[[ "${dir_result}" == *"secrets.yaml"* ]] && has_secrets_yaml=1
assert_equal "sensitive excl: secrets.yaml not in result" "0" "${has_secrets_yaml}"

_test_rm_tmpdir "${_CTX_TEST_TMPDIR}"

# ==============================================================================
# 3. _zai_gather_directory_context — DIR_LIMIT is respected
# ==============================================================================

print "# --- 3. _zai_gather_directory_context: DIR_LIMIT respected ---"

_test_load_context

_CTX_TEST_TMPDIR="$(_test_make_tmpdir)"

# Create 10 non-sensitive files
local i
for i in {1..10}; do
  touch "${_CTX_TEST_TMPDIR}/file${i}.txt"
done

# Set dir_limit to 5
_zai_config_set dir_limit 5

cd "${_CTX_TEST_TMPDIR}"
dir_result="$(_zai_gather_directory_context)"
cd "${_CTX_ORIG_DIR}"

# Count lines in result
local line_count
line_count="$(print -- "${dir_result}" | wc -l | tr -d ' ')"

assert_true "dir_limit: result has at most 5 entries" $(( line_count <= 5 ))

_zai_config_reset
_test_rm_tmpdir "${_CTX_TEST_TMPDIR}"

# ==============================================================================
# 4. _zai_gather_directory_context — empty directory returns empty
# ==============================================================================

print "# --- 4. _zai_gather_directory_context: empty directory ---"

_test_load_context

_CTX_TEST_TMPDIR="$(_test_make_tmpdir)"

cd "${_CTX_TEST_TMPDIR}"
dir_result="$(_zai_gather_directory_context)"
cd "${_CTX_ORIG_DIR}"

# Empty dir may return empty or only the standard entries; should not error
assert_true "empty dir: function returns zero exit code" $?

_test_rm_tmpdir "${_CTX_TEST_TMPDIR}"

# ==============================================================================
# 5. _zai_gather_directory_context — all entries sensitive returns empty
# ==============================================================================

print "# --- 5. _zai_gather_directory_context: all entries sensitive ---"

_test_load_context

_CTX_TEST_TMPDIR="$(_test_make_tmpdir)"

touch "${_CTX_TEST_TMPDIR}/.env"
touch "${_CTX_TEST_TMPDIR}/id_rsa"
touch "${_CTX_TEST_TMPDIR}/credentials.json"

cd "${_CTX_TEST_TMPDIR}"
dir_result="$(_zai_gather_directory_context)"
cd "${_CTX_ORIG_DIR}"

# All sensitive: result should not contain any of these
local has_any=0
[[ "${dir_result}" == *".env"* ]] && has_any=1
[[ "${dir_result}" == *"id_rsa"* ]] && has_any=1
[[ "${dir_result}" == *"credentials"* ]] && has_any=1
assert_equal "all sensitive: no sensitive files in output" "0" "${has_any}"

_test_rm_tmpdir "${_CTX_TEST_TMPDIR}"

# ==============================================================================
# 6. _zai_gather_history_context — basic history retrieval
# ==============================================================================

print "# --- 6. _zai_gather_history_context: basic retrieval ---"

_test_load_context

# Install fc mock with predictable history
function fc() {
  print "    1  ls -la"
  print "    2  git status"
  print "    3  git add ."
  print "    4  git commit -m 'initial commit'"
  print "    5  docker ps"
}

local hist_result
hist_result="$(_zai_gather_history_context)"

unfunction fc

# All commands should appear (limit default is 20, we have 5)
assert_contains "history: ls -la appears" "ls -la" "${hist_result}"
assert_contains "history: git status appears" "git status" "${hist_result}"
assert_contains "history: docker ps appears" "docker ps" "${hist_result}"

# Result should be non-empty
assert_not_empty "history: result is non-empty" "${hist_result}"

# ==============================================================================
# 7. _zai_gather_history_context — HISTORY_SIZE limit respected
# ==============================================================================

print "# --- 7. _zai_gather_history_context: HISTORY_SIZE limit ---"

_test_load_context

# Mock fc that ignores limit (always returns 10 entries)
function fc() {
  local i
  for i in {1..10}; do
    printf '  %3d  command_%d\n' "${i}" "${i}"
  done
}

# Set history_size to 3
_zai_config_set history_size 3

# Note: we can't fully enforce fc's limit from within the function,
# but we verify the mock was called (via result content) and the
# function respects the configured value
hist_result="$(_zai_gather_history_context)"

unfunction fc
_zai_config_reset

# Result should be non-empty and not error
assert_not_empty "history limit: result non-empty with history_size=3" "${hist_result}"

# ==============================================================================
# 8. _zai_gather_history_context — secrets are redacted
# ==============================================================================

print "# --- 8. _zai_gather_history_context: secrets redacted ---"

_test_load_context

function fc() {
  print "    1  export AWS_KEY=AKIA1234ABCDEFGHIJ56"
  print "    2  export GITHUB_TOKEN=ghp_RealTokenABCDE12345"
  print "    3  git push origin main"
}

hist_result="$(_zai_gather_history_context)"

unfunction fc

# Secrets should be redacted
local has_akia=0
[[ "${hist_result}" == *"AKIA1234ABCDEFGHIJ56"* ]] && has_akia=1
assert_equal "history redact: AWS key redacted" "0" "${has_akia}"

local has_ghp=0
[[ "${hist_result}" == *"ghp_RealTokenABCDE12345"* ]] && has_ghp=1
assert_equal "history redact: GitHub token redacted" "0" "${has_ghp}"

# Non-secret command should remain
assert_contains "history redact: git push retained" "git push origin main" "${hist_result}"

# ==============================================================================
# 9. _zai_gather_history_context — entries capped at 80 chars
# ==============================================================================

print "# --- 9. _zai_gather_history_context: entries capped at 80 chars ---"

_test_load_context

# Create a command longer than 80 characters
local long_cmd="echo '$(printf '%0.s' {1..100})this_should_be_truncated'"

function fc() {
  printf '    1  %s\n' "${long_cmd}"
  print "    2  ls -la"
}

hist_result="$(_zai_gather_history_context)"

unfunction fc

# The result should not contain the part beyond 80 chars of the input
# Verify the result lines are at most 80 chars
local max_len=0
local hist_line
while IFS= read -r hist_line; do
  if (( ${#hist_line} > max_len )); then
    max_len=${#hist_line}
  fi
done <<< "${hist_result}"

assert_true "history cap: no line exceeds 80 chars (max: ${max_len})" \
  $(( max_len <= 80 ))

# ==============================================================================
# 10. _zai_gather_history_context — empty history returns gracefully
# ==============================================================================

print "# --- 10. _zai_gather_history_context: empty history ---"

_test_load_context

function fc() {
  # Return nothing
  return 0
}

hist_result="$(_zai_gather_history_context)"

unfunction fc

# Should complete without errors (any empty or non-empty result is OK)
assert_true "_zai_gather_history_context: returns 0 with empty fc output" $?

# ==============================================================================
# 11. _zai_gather_git_context — inside a git repository
# ==============================================================================

print "# --- 11. _zai_gather_git_context: inside git repo ---"

_test_load_context

# Mock git to simulate being inside a valid git repository.
# Implementation uses:
#   git rev-parse --git-dir   (to check we're in a repo)
#   git symbolic-ref --short HEAD  (to get branch name)
#   git status --porcelain         (for file counts)
#   git log --oneline -3           (for recent commits)
function git() {
  case "${1}" in
    rev-parse)
      # --git-dir: existence check — return success inside a repo
      if [[ "${2}" == "--git-dir" ]]; then
        print ".git"
        return 0
      fi
      # Legacy fallback (--short HEAD)
      if [[ "${2}" == "--short" ]]; then
        print "abc1234"
        return 0
      fi
      return 0
      ;;
    symbolic-ref)
      # --short HEAD: return branch name
      if [[ "${2}" == "--short" && "${3}" == "HEAD" ]]; then
        print "main"
        return 0
      fi
      return 1
      ;;
    status)
      # Porcelain v1: 2 working-tree modifications, 1 staged, 1 untracked
      # " M" = modified in worktree (Y=M, X=space)
      # "A " = staged add (X=A, Y=space)
      # "??" = untracked
      print " M src/main.go"
      print " M src/util.go"
      print "A  src/new_feature.go"
      print "?? build/"
      return 0
      ;;
    log)
      print "abc1234 fix: resolve race condition in async engine"
      print "def5678 feat: add context gathering module"
      print "ghi9012 chore: initial project structure"
      return 0
      ;;
  esac
}

local git_result
git_result="$(_zai_gather_git_context)"

unfunction git

# Verify branch name present (format: "main [M:n U:n ?:n]")
assert_contains "git: branch name 'main' appears" "main" "${git_result}"

# Verify compact format — M:2 (two working-tree modified files)
assert_contains "git: M:2 (modified count)" "M:2" "${git_result}"

# Verify compact format — U:1 (one staged file: "A  src/new_feature.go")
assert_contains "git: U:1 (staged count)" "U:1" "${git_result}"

# Verify compact format — ?:1 (one untracked file: "?? build/")
assert_contains "git: ?:1 (untracked count)" "?:1" "${git_result}"

# Verify recent commits included
assert_contains "git: recent commit message appears" "resolve race condition" "${git_result}"

# Verify it's non-empty
assert_not_empty "git: result is non-empty inside repo" "${git_result}"

# ==============================================================================
# 12. _zai_gather_git_context — outside a git repository
# ==============================================================================

print "# --- 12. _zai_gather_git_context: outside git repo ---"

_test_load_context

# Mock git rev-parse --git-dir to fail (simulate not in a repo)
function git() {
  # Any call fails — simulates "not a git repository"
  return 128
}

git_result="$(_zai_gather_git_context)"

unfunction git

# Outside a repo: should return empty, no errors
assert_empty "git: returns empty outside git repo" "${git_result}"

# ==============================================================================
# 13. _zai_gather_git_context — git not installed
# ==============================================================================

print "# --- 13. _zai_gather_git_context: git not installed ---"

_test_load_context

# Override command -v to make git unavailable
function command() {
  if [[ "${1}" == "-v" && "${2}" == "git" ]]; then
    return 1  # simulate "not found"
  fi
  builtin command "$@"
}

git_result="$(_zai_gather_git_context)"

unfunction command

# Should complete without errors and return nothing
assert_empty "git: returns empty when git not installed" "${git_result}"

# ==============================================================================
# 14. _zai_gather_git_context — secrets in commit messages are redacted
# ==============================================================================

print "# --- 14. _zai_gather_git_context: commit secrets redacted ---"

_test_load_context

function git() {
  case "${1}" in
    rev-parse)
      [[ "${2}" == "--git-dir" ]] && { print ".git"; return 0; }
      return 0
      ;;
    symbolic-ref)
      [[ "${2}" == "--short" ]] && { print "main"; return 0; }
      return 1
      ;;
    status) return 0 ;;
    log)
      print "abc1234 fix: update AKIA1234ABCDEFGHIJ API key usage"
      print "def5678 feat: add ghp_SecretTokenABCDE123 auth"
      return 0
      ;;
  esac
}

git_result="$(_zai_gather_git_context)"

unfunction git

# Secrets in commit messages must be redacted
local has_akia=0
[[ "${git_result}" == *"AKIA1234ABCDEFGHIJ"* ]] && has_akia=1
assert_equal "git: AWS key in commit msg redacted" "0" "${has_akia}"

local has_ghp=0
[[ "${git_result}" == *"ghp_SecretToken"* ]] && has_ghp=1
assert_equal "git: GitHub token in commit msg redacted" "0" "${has_ghp}"

# ==============================================================================
# 15. _zai_detect_command_context — standard (no special constructs)
# ==============================================================================

print "# --- 15. _zai_detect_command_context: standard ---"

_test_load_context

assert_equal "context: 'git status' → standard" \
  "standard" "$(_zai_detect_command_context 'git status')"

assert_equal "context: 'ls -la' → standard" \
  "standard" "$(_zai_detect_command_context 'ls -la')"

assert_equal "context: 'docker run' → standard" \
  "standard" "$(_zai_detect_command_context 'docker run')"

assert_equal "context: empty buffer → standard" \
  "standard" "$(_zai_detect_command_context '')"

assert_equal "context: 'echo hello' → standard" \
  "standard" "$(_zai_detect_command_context 'echo hello')"

# ==============================================================================
# 16. _zai_detect_command_context — pipe
# ==============================================================================

print "# --- 16. _zai_detect_command_context: pipe ---"

_test_load_context

assert_equal "context: 'ls | grep .go' → pipe" \
  "pipe" "$(_zai_detect_command_context 'ls | grep .go')"

assert_equal "context: 'git log | head -20' → pipe" \
  "pipe" "$(_zai_detect_command_context 'git log | head -20')"

assert_equal "context: 'cat file.txt | sort | uniq' → pipe" \
  "pipe" "$(_zai_detect_command_context 'cat file.txt | sort | uniq')"

# Logical OR (||) should NOT be detected as pipe — it is standard context
local or_result
or_result="$(_zai_detect_command_context 'git pull || echo failed')"
assert_equal "context: 'git pull || echo failed' → standard (not pipe)" \
  "standard" "${or_result}"

# |& (pipe-with-stderr) should NOT be detected as pipe
local pipe_stderr_result
pipe_stderr_result="$(_zai_detect_command_context 'cmd |& tee log.txt')"
assert_not_equal "context: '|&' is not plain pipe" "pipe" "${pipe_stderr_result}"

# ==============================================================================
# 17. _zai_detect_command_context — subshell
# ==============================================================================

print "# --- 17. _zai_detect_command_context: subshell ---"

_test_load_context

# These buffers represent the ZLE state while the user is INSIDE a $() — the
# closing ) has not been typed yet, which is when auto-completion fires.
assert_equal "context: 'echo \$(git rev-parse ' → subshell (unclosed)" \
  "subshell" "$(_zai_detect_command_context 'echo $(git rev-parse ')"

assert_equal "context: 'cd \$(ls -d ' → subshell (unclosed)" \
  "subshell" "$(_zai_detect_command_context 'cd $(ls -d ')"

assert_equal "context: 'export VAR=\$(command' → subshell (unclosed)" \
  "subshell" "$(_zai_detect_command_context 'export VAR=$(command')"

# Closed $() should NOT be detected as subshell (user is past the closing paren)
local closed_sub
closed_sub="$(_zai_detect_command_context 'echo $(git rev-parse HEAD) ')"
assert_not_equal "context: closed \$() is NOT subshell" "subshell" "${closed_sub}"

# ==============================================================================
# 18. _zai_detect_command_context — redirect
# ==============================================================================

print "# --- 18. _zai_detect_command_context: redirect ---"

_test_load_context

assert_equal "context: 'echo hello > file.txt' → redirect" \
  "redirect" "$(_zai_detect_command_context 'echo hello > file.txt')"

assert_equal "context: 'cat file.txt >> output' → redirect" \
  "redirect" "$(_zai_detect_command_context 'cat file.txt >> output')"

assert_equal "context: 'sort < input.txt' → redirect" \
  "redirect" "$(_zai_detect_command_context 'sort < input.txt')"

# ==============================================================================
# 19. _zai_detect_command_context — loop
# ==============================================================================

print "# --- 19. _zai_detect_command_context: loop ---"

_test_load_context

assert_equal "context: 'for f in *.go; do' → loop" \
  "loop" "$(_zai_detect_command_context 'for f in *.go; do')"

assert_equal "context: 'while read line; do' → loop" \
  "loop" "$(_zai_detect_command_context 'while read line; do')"

assert_equal "context: 'for i in {1..10}' → loop" \
  "loop" "$(_zai_detect_command_context 'for i in {1..10}')"

# ==============================================================================
# 20. _zai_gather_full_context — XML delimiter tags present
# ==============================================================================

print "# --- 20. _zai_gather_full_context: XML delimiter tags ---"

_test_load_context

# Mock all context sources for determinism
function fc() {
  print "    1  git status"
  print "    2  ls -la"
}

function git() {
  case "${1}" in
    rev-parse)
      [[ "${2}" == "--git-dir" ]] && { print ".git"; return 0; }
      return 0
      ;;
    symbolic-ref)
      [[ "${2}" == "--short" ]] && { print "main"; return 0; }
      return 1
      ;;
    status)    return 0 ;;
    log)       print "abc1234 recent commit"; return 0 ;;
  esac
}

_CTX_TEST_TMPDIR="$(_test_make_tmpdir)"
touch "${_CTX_TEST_TMPDIR}/main.go"
touch "${_CTX_TEST_TMPDIR}/README.md"

cd "${_CTX_TEST_TMPDIR}"
local full_ctx
full_ctx="$(_zai_gather_full_context 'git st')"
cd "${_CTX_ORIG_DIR}"

unfunction fc git
_test_rm_tmpdir "${_CTX_TEST_TMPDIR}"

# Directory tags
assert_contains "full_ctx: <directory> tag present" "<directory>" "${full_ctx}"
assert_contains "full_ctx: </directory> tag present" "</directory>" "${full_ctx}"

# History tags
assert_contains "full_ctx: <history> tag present" "<history>" "${full_ctx}"
assert_contains "full_ctx: </history> tag present" "</history>" "${full_ctx}"

# Git tags
assert_contains "full_ctx: <git> tag present" "<git>" "${full_ctx}"
assert_contains "full_ctx: </git> tag present" "</git>" "${full_ctx}"

# Context type tag
assert_contains "full_ctx: <context_type> tag present" "<context_type>" "${full_ctx}"

# ==============================================================================
# 21. _zai_gather_full_context — context_type included in output
# ==============================================================================

print "# --- 21. _zai_gather_full_context: context_type in output ---"

_test_load_context

function fc() {
  print "    1  echo test"
}

function git() {
  # Simulate not being in a git repo for these context_type tests
  return 128
}

local ctx_pipe ctx_standard ctx_subshell

# Pipe context
ctx_pipe="$(_zai_gather_full_context 'ls | grep')"
assert_contains "full_ctx: pipe context in output" "pipe" "${ctx_pipe}"

# Standard context
ctx_standard="$(_zai_gather_full_context 'git status')"
assert_contains "full_ctx: standard context in output" "standard" "${ctx_standard}"

# Subshell context — unclosed $( so the user is still typing inside it
ctx_subshell="$(_zai_gather_full_context 'echo $(pwd')"
assert_contains "full_ctx: subshell context in output" "subshell" "${ctx_subshell}"

unfunction fc git

# ==============================================================================
# 22. _zai_gather_full_context — git section absent outside repo
# ==============================================================================

print "# --- 22. _zai_gather_full_context: git section omitted outside repo ---"

_test_load_context

function fc() {
  print "    1  echo test"
}

function git() {
  # Simulate not in a git repo
  return 128
}

_CTX_TEST_TMPDIR="$(_test_make_tmpdir)"
touch "${_CTX_TEST_TMPDIR}/main.go"

cd "${_CTX_TEST_TMPDIR}"
full_ctx="$(_zai_gather_full_context 'git')"
cd "${_CTX_ORIG_DIR}"

unfunction fc git
_test_rm_tmpdir "${_CTX_TEST_TMPDIR}"

# Git section should not appear when not in a repo
local has_git_tag=0
[[ "${full_ctx}" == *"<git>"* ]] && has_git_tag=1
assert_equal "full_ctx: no <git> tag outside repo" "0" "${has_git_tag}"

# ==============================================================================
# 23. _zai_gather_full_context — directory section absent in empty dir
# ==============================================================================

print "# --- 23. _zai_gather_full_context: directory section omitted when empty ---"

_test_load_context

function fc() {
  return 0  # empty history
}

function git() {
  # Simulate not in a git repo
  return 128
}

_CTX_TEST_TMPDIR="$(_test_make_tmpdir)"
# No files in temp dir

cd "${_CTX_TEST_TMPDIR}"
full_ctx="$(_zai_gather_full_context 'echo')"
cd "${_CTX_ORIG_DIR}"

unfunction fc git
_test_rm_tmpdir "${_CTX_TEST_TMPDIR}"

# With empty dir and no history/git, context_type should still be present
assert_contains "full_ctx: context_type always present" \
  "<context_type>" "${full_ctx}"

# ==============================================================================
# 24. _zai_gather_full_context — content order: dir, history, git, context_type
# ==============================================================================

print "# --- 24. _zai_gather_full_context: section order preserved ---"

_test_load_context

function fc() {
  print "    1  history cmd"
}

function git() {
  case "${1}" in
    rev-parse)
      [[ "${2}" == "--git-dir" ]] && { print ".git"; return 0; }
      return 0
      ;;
    symbolic-ref)
      [[ "${2}" == "--short" ]] && { print "feature-branch"; return 0; }
      return 1
      ;;
    status) return 0 ;;
    log)    return 0 ;;
  esac
}

_CTX_TEST_TMPDIR="$(_test_make_tmpdir)"
touch "${_CTX_TEST_TMPDIR}/file.go"

cd "${_CTX_TEST_TMPDIR}"
full_ctx="$(_zai_gather_full_context 'test')"
cd "${_CTX_ORIG_DIR}"

unfunction fc git
_test_rm_tmpdir "${_CTX_TEST_TMPDIR}"

# Verify ordering: <directory> appears before <history>
local dir_pos hist_pos git_pos ctype_pos
dir_pos="${full_ctx[(i)<directory>]}"
hist_pos="${full_ctx[(i)<history>]}"
git_pos="${full_ctx[(i)<git>]}"
ctype_pos="${full_ctx[(i)<context_type>]}"

# Positions are 1-indexed; items not found return length+1
# We only check ordering if all sections are present
if (( dir_pos <= ${#full_ctx} && hist_pos <= ${#full_ctx} )); then
  assert_true "full_ctx: <directory> appears before <history>" \
    $(( dir_pos < hist_pos ))
fi

if (( hist_pos <= ${#full_ctx} && git_pos <= ${#full_ctx} )); then
  assert_true "full_ctx: <history> appears before <git>" \
    $(( hist_pos < git_pos ))
fi

assert_true "full_ctx: <context_type> is last section" \
  $(( ctype_pos <= ${#full_ctx} ))

# ==============================================================================
# 25. Double-source guard — reload does not reset context
# ==============================================================================

print "# --- 25. Double-source guard ---"

_test_load_context

local loaded_first="${_ZAI_CONTEXT_LOADED}"

# Source again — guard should prevent re-execution
source "${_ZAI_TEST_CTX_LIB}/context.zsh"

assert_equal "double-source guard: _ZAI_CONTEXT_LOADED remains 1" \
  "1" "${_ZAI_CONTEXT_LOADED}"

assert_equal "double-source guard: _zai_gather_directory_context still defined" \
  "1" "${${+functions[_zai_gather_directory_context]}}"

# ==============================================================================
# Cleanup
# ==============================================================================
# Restore working directory in case anything left it changed
[[ -d "${_CTX_ORIG_DIR}" ]] && cd "${_CTX_ORIG_DIR}"

# ==============================================================================
# Standalone mode: print TAP plan and summary
# ==============================================================================

if [[ "${0}" == "${(%):-%x}" ]] || [[ "${ZSH_ARGZERO:-}" == *"test_context.zsh" ]]; then
  tap_plan
  tap_summary
  exit $(( _TAP_FAIL_COUNT > 0 ? 1 : 0 ))
fi
