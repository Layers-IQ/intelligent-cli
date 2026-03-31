# ==============================================================================
# zsh-ai-complete: ContextGatherer Module
# File: plugin/lib/context.zsh
# ==============================================================================
#
# Collects contextual information from the shell environment for LLM prompts:
#
#   _zai_gather_directory_context()   ls -1 up to DIR_LIMIT, sensitive filtered
#   _zai_gather_history_context()     fc -l up to HISTORY_SIZE, redacted, ≤80c
#   _zai_gather_git_context()         branch [M:n U:n] + recent commits
#   _zai_gather_full_context(buffer)  all sources with XML delimiter tags
#   _zai_detect_command_context(buf)  pipe|subshell|redirect|loop|standard
#
# All context passes through SecurityFilter before returning.
#
# XML delimiter tags wrap each section to prevent LLM prompt injection via
# crafted filenames or commit messages that could embed instructions.
#
# ==============================================================================

# Guard against double-sourcing
(( ${+_ZAI_CONTEXT_LOADED} )) && return 0
typeset -gi _ZAI_CONTEXT_LOADED=1

# ==============================================================================
# Dependency auto-loading
# ==============================================================================

if ! (( ${+functions[_zai_config_get]} )); then
  builtin source "${0:a:h}/config.zsh"
fi

if ! (( ${+functions[_zai_filter_directory_entries]} )); then
  builtin source "${0:a:h}/security.zsh"
fi

# ==============================================================================
# _zai_gather_directory_context
#
# Lists the current working directory via `ls -1`, limits the output to
# DIR_LIMIT entries, and filters sensitive filenames through SecurityFilter.
#
# Returns filtered entries (one per line) on stdout, or nothing if the
# directory is empty, unreadable, or all entries are sensitive.
# ==============================================================================
_zai_gather_directory_context() {
  local dir_limit
  dir_limit="$(_zai_config_get dir_limit 2>/dev/null)" || dir_limit=50

  # Gather up to dir_limit entries from the current directory.
  # `ls -1` lists one entry per line; `head` applies the count limit.
  local raw_entries
  raw_entries="$(ls -1 2>/dev/null | head -n "${dir_limit}")"

  [[ -z "${raw_entries}" ]] && return 0

  # Remove sensitive filenames via SecurityFilter
  local filtered
  filtered="$(_zai_filter_directory_entries "${raw_entries}")"

  [[ -z "${filtered}" ]] && return 0

  # Sanitize remaining entries against LLM prompt injection
  # (e.g. crafted filenames embedding "</directory><system>" style attacks)
  _zai_sanitize_for_prompt "${filtered}"
}

# ==============================================================================
# _zai_gather_history_context
#
# Returns the last HISTORY_SIZE shell history entries via `fc -l`, with each
# command:
#   - Truncated to at most 80 characters
#   - Run through _zai_redact_secrets to strip any embedded credentials
#
# Returns history entries (one per line) on stdout, or nothing if history
# is empty.
# ==============================================================================
_zai_gather_history_context() {
  local history_size
  history_size="$(_zai_config_get history_size 2>/dev/null)" || history_size=20

  # Enable extended glob patterns for whitespace/number stripping
  setopt localoptions extendedglob

  local -a lines
  local line cmd

  # fc -l output format: "  NUM  command text"
  # Read the last history_size entries into an array (oldest to newest).
  while IFS='' read -r line; do
    # Strip leading blanks + history number + following blanks
    cmd="${line##[[:blank:]]#[0-9]##[[:blank:]]#}"
    [[ -n "${cmd}" ]] && lines+=("${cmd}")
  done < <(fc -l -${history_size} 2>/dev/null)

  [[ ${#lines[@]} -eq 0 ]] && return 0

  local result=""
  local entry redacted sanitized capped
  for entry in "${lines[@]}"; do
    # Redact secrets FIRST (before capping so full token is matched)
    redacted="$(_zai_redact_secrets "${entry}")"
    # Sanitize for LLM prompt injection
    sanitized="$(_zai_sanitize_for_prompt "${redacted}")"
    [[ -z "${sanitized}" ]] && continue
    # Cap at 80 characters (zsh 1-based substring)
    capped="${sanitized[1,80]}"
    result+="${capped}"$'\n'
  done

  # Print without trailing newline from final iteration
  print -n -- "${result}"
}

# ==============================================================================
# _zai_gather_git_context
#
# When inside a git repository, returns a compact status summary:
#   branch <name> [M:<count> U:<count>]
#   <recent commit 1>
#   <recent commit 2>
#   ...
#
# Returns nothing (empty string) when:
#   - git is not installed
#   - the current directory is not inside a git repository
#   - git commands fail for any reason
#
# Commit messages are run through _zai_redact_secrets before returning.
# ==============================================================================
_zai_gather_git_context() {
  # Guard: git must be available
  if ! command -v git > /dev/null 2>&1; then
    return 0
  fi

  # Guard: must be inside a git repo (rev-parse fails outside)
  if ! git rev-parse --git-dir > /dev/null 2>&1; then
    return 0
  fi

  # ── Branch name ──────────────────────────────────────────────────────────────
  # Try symbolic ref first (normal branches); detached HEAD falls back to hash
  local branch
  branch="$(git symbolic-ref --short HEAD 2>/dev/null)" \
    || branch="$(git rev-parse --short HEAD 2>/dev/null)" \
    || branch="(detached)"

  # Sanitize branch name — may contain user-crafted strings
  branch="$(_zai_redact_secrets "${branch}")"
  branch="$(_zai_sanitize_for_prompt "${branch}")"

  # ── File counts from git status --porcelain ──────────────────────────────────
  # Porcelain v1 format: "XY filename"
  #   X = index/staged status  (' ', M, A, D, R, C, U, ?, !)
  #   Y = working-tree status  (' ', M, A, D, R, C, U, ?, !)
  # Special: "??" = completely untracked file
  local modified_count=0   # working-tree changes  (Y != ' ' and not '?')
  local staged_count=0     # staged changes        (X != ' ' and X != '?')
  local untracked_count=0  # untracked files       (XY == '??')

  local status_line x y
  while IFS= read -r status_line; do
    [[ -z "${status_line}" ]] && continue
    # Characters are 1-indexed in zsh
    x="${status_line[1]}"
    y="${status_line[2]}"
    if [[ "${x}" == "?" && "${y}" == "?" ]]; then
      (( untracked_count++ ))
    else
      [[ "${x}" != " " && "${x}" != "?" ]] && (( staged_count++ ))
      [[ "${y}" != " " && "${y}" != "?" ]] && (( modified_count++ ))
    fi
  done < <(git status --porcelain 2>/dev/null)

  # ── Recent commits (last 3 one-liners), secrets redacted ─────────────────────
  local raw_commits recent_commits
  raw_commits="$(git log --oneline -3 2>/dev/null)" || raw_commits=""
  if [[ -n "${raw_commits}" ]]; then
    # _zai_redact_secrets expects a string argument, not stdin
    recent_commits="$(_zai_redact_secrets "${raw_commits}")"
    recent_commits="$(_zai_sanitize_for_prompt "${recent_commits}")"
  fi

  # ── Compact output: "<branch> [M:n U:n ?:n]" then recent commits ─────────────
  print -- "${branch} [M:${modified_count} U:${staged_count} ?:${untracked_count}]"
  [[ -n "${recent_commits}" ]] && print -- "${recent_commits}"
}

# ==============================================================================
# _zai_detect_command_context <buffer>
#
# Inspects the current command buffer and returns a single token describing
# the structural context so the PromptBuilder can generate appropriate
# completions.
#
# Returns one of: pipe, subshell, redirect, loop, standard
#
# Detection order (first match wins):
#   pipe      — buffer contains an unescaped pipe operator (| but not ||)
#   subshell  — buffer contains $( indicating command substitution
#   redirect  — buffer contains > >> < operators
#   loop      — buffer starts a for/while loop construct
#   standard  — everything else
# ==============================================================================
_zai_detect_command_context() {
  local buffer="${1:-}"

  # Empty buffer → standard context
  [[ -z "${buffer}" ]] && { print "standard"; return 0; }

  # ── 1. Loop: starts with 'for' or 'while' keyword ───────────────────────────
  # Check before anything else so "for f in $(ls " returns loop, not subshell.
  # Allows optional leading whitespace.
  if [[ "${buffer}" =~ ^[[:space:]]*(for|while)[[:space:]] ]]; then
    print "loop"
    return 0
  fi

  # ── 2. Subshell: last $( in buffer has no matching ) after it ───────────────
  # \$\([^)]*$  matches $( followed by any non-) chars to end of string.
  # Detects open command substitutions: echo $(ls  or  git log $(
  if [[ "${buffer}" =~ '\$\([^)]*$' ]]; then
    print "subshell"
    return 0
  fi

  # ── Narrow to the "current pipeline segment" to avoid false positives ────────
  # Strip everything before the last ; or && so that in compound commands like
  # "ls | wc && echo " we detect "echo " (standard), not the earlier pipe.
  local seg="${buffer}"
  [[ "${seg}" == *";"*  ]] && seg="${seg##*;}"
  [[ "${seg}" == *"&&"* ]] && seg="${seg##*&&}"

  # ── 3. Redirect: >, >>, <, 2>, &> as last operator before current word ───────
  # Pattern: optional fd prefix ([0-9&]?), redirect operator (>> or > or <),
  # optional whitespace, optional partial filename with no shell operators after.
  if [[ "${seg}" =~ '(>>|[0-9&]?>|<)[[:space:]]*[^[:space:]|;&]*$' ]]; then
    print "redirect"
    return 0
  fi

  # ── 4. Pipe: single | (not || or |&) as last operator ───────────────────────
  # Pattern A covers the common case — a non-| char precedes the |.
  #   [^|]\|[^|&][^|;]*$
  #   The char after | must not be | or & (rules out || and |&).
  # Pattern B covers pipe at start of the segment: ^\|[^|&]
  if [[ "${seg}" =~ '[^|]\|[^|&][^|;]*$' ]] || \
     [[ "${seg}" =~ '^\|[^|&]'           ]]; then
    print "pipe"
    return 0
  fi

  # ── 5. Standard mode (default) ──────────────────────────────────────────────
  print "standard"
  return 0
}

# ==============================================================================
# _zai_gather_full_context <buffer>
#
# Aggregates all context sources into a single formatted string with XML
# delimiter tags.  Each data source is wrapped in its own tag:
#
#   <directory>
#   ... filtered directory listing ...
#   </directory>
#   <history>
#   ... redacted history entries ...
#   </history>
#   <git>
#   ... compact git status + commits ...
#   </git>
#   <context_type>pipe|subshell|redirect|loop|standard</context_type>
#
# Sections with no content are omitted entirely so empty context does not
# confuse the model.
#
# Arguments:
#   buffer  — current ZLE command buffer (used only for context-type detection)
# ==============================================================================
_zai_gather_full_context() {
  local buffer="${1:-}"

  local dir_ctx hist_ctx git_ctx cmd_ctx result=""

  dir_ctx="$(_zai_gather_directory_context)"
  hist_ctx="$(_zai_gather_history_context)"
  git_ctx="$(_zai_gather_git_context)"
  cmd_ctx="$(_zai_detect_command_context "${buffer}")"

  # Directory and history sections are always present (may have empty bodies).
  # This guarantees a consistent structure for the PromptBuilder regardless of
  # whether the directory is empty or history is unavailable.
  result+="<directory>"$'\n'
  [[ -n "${dir_ctx}" ]] && result+="${dir_ctx}"$'\n'
  result+="</directory>"$'\n'

  result+="<history>"$'\n'
  [[ -n "${hist_ctx}" ]] && result+="${hist_ctx}"$'\n'
  result+="</history>"$'\n'

  # Git section is omitted entirely when not in a git repository — an empty
  # <git></git> section would mislead the model into thinking git is available.
  if [[ -n "${git_ctx}" ]]; then
    result+="<git>"$'\n'"${git_ctx}"$'\n'"</git>"$'\n'
  fi

  result+="<context_type>${cmd_ctx}</context_type>"

  print -- "${result}"
}
