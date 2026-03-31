# ==============================================================================
# zsh-ai-complete: SuggestionManager
# File: plugin/lib/suggestion.zsh
# ==============================================================================
#
# Owns the suggestion display lifecycle:
#   - Renders ghost text via POSTDISPLAY with dimmed region_highlight styling
#   - Manages the layered suggestion strategy: instant history match → async AI
#   - Handles accept / dismiss / clear operations
#   - CRITICAL: Suggestions are NEVER auto-executed — text is always inserted
#               into the editable BUFFER only; the user MUST press Enter
#
# Public API:
#   _zai_suggestion_show(text)            → set POSTDISPLAY ghost text
#   _zai_suggestion_clear()               → dismiss ghost text
#   _zai_suggestion_accept()              → insert ghost text into BUFFER
#   _zai_suggestion_get_from_history(pfx) → prefix-match in fc -l history
#   _zai_suggestion_update(text)          → replace ghost text if BUFFER unchanged
#
# Internal helpers:
#   _zai_suggestion_highlight_remove()    → remove our region_highlight entry
#   _zai_suggestion_reset()               → test helper: clear all state
#
# Requires:
#   - plugin/lib/config.zsh (sourced automatically if not already loaded)
#   - zsh 5.3+ (POSTDISPLAY, region_highlight P-prefix, zle -F)
#   - ZLE context for zle -R calls (no-op safe when called outside ZLE in tests)
#
# ==============================================================================

# Guard against double-sourcing
(( ${+_ZAI_SUGGESTION_LOADED} )) && return 0
typeset -gi _ZAI_SUGGESTION_LOADED=1

# Auto-source config if not already loaded
if (( ! ${+functions[_zai_config_get]} )); then
  builtin source "${0:a:h}/config.zsh"
fi

# ==============================================================================
# Module-level state
# ==============================================================================

# The exact region_highlight array entry we added — stored so we can remove it.
# Empty string means no entry is currently owned by this module.
typeset -g _ZAI_SUGGESTION_HIGHLIGHT=""

# BUFFER value at the time the current suggestion was shown.
# Used by _zai_suggestion_update to reject stale async results.
typeset -g _ZAI_SUGGESTION_PREFIX=""

# ==============================================================================
# _zai_suggestion_highlight_remove (internal)
#
# Removes the region_highlight entry previously added by _zai_suggestion_show.
# Safe to call when no entry is owned (no-op).
# Uses exact-string pattern removal so other plugins' highlights are unaffected.
# ==============================================================================
_zai_suggestion_highlight_remove() {
  if [[ -n "${_ZAI_SUGGESTION_HIGHLIGHT}" ]]; then
    # Remove only the element matching our stored entry (exact string match).
    # The (#i) flag is NOT used — this is intentionally case-sensitive.
    region_highlight=("${(@)region_highlight:#${_ZAI_SUGGESTION_HIGHLIGHT}}")
    _ZAI_SUGGESTION_HIGHLIGHT=""
  fi
}

# ==============================================================================
# _zai_suggestion_show <text>
#
# Sets POSTDISPLAY to <text> and applies dimmed region_highlight.
# Stores the current BUFFER as _ZAI_SUGGESTION_PREFIX for stale-checking.
# Calls zle -R to redraw.
#
# Arguments:
#   text  — The completion suffix to display as ghost text. Must be non-empty.
# ==============================================================================
_zai_suggestion_show() {
  local text="${1}"

  # Reject empty suggestion — nothing to display
  [[ -z "${text}" ]] && return 0

  # Store current BUFFER as the prefix this suggestion was generated for.
  # _zai_suggestion_update uses this to detect if BUFFER has since changed.
  _ZAI_SUGGESTION_PREFIX="${BUFFER}"

  # Remove any highlight we previously added before applying the new one.
  _zai_suggestion_highlight_remove

  # Set ghost text in POSTDISPLAY (displayed after cursor, not part of BUFFER).
  POSTDISPLAY="${text}"

  # Resolve highlight style from config (default: fg=8 = terminal colour 8 / dark grey)
  local style
  style="$(_zai_config_get highlight_style 2>/dev/null)" || style="fg=8"
  [[ -z "${style}" ]] && style="fg=8"

  # Build region_highlight entry:
  #   P0          — start at position 0 of POSTDISPLAY (P = POSTDISPLAY-relative)
  #   ${#POSTDISPLAY} — end at the byte-length of POSTDISPLAY (exclusive)
  #   ${style}    — e.g. "fg=8" for dimmed grey
  local entry="P0 ${#POSTDISPLAY} ${style}"
  _ZAI_SUGGESTION_HIGHLIGHT="${entry}"
  region_highlight+=("${entry}")

  # Trigger ZLE redraw to make ghost text visible immediately
  zle -R
}

# ==============================================================================
# _zai_suggestion_clear
#
# Dismisses the current ghost text without inserting it.
# Clears POSTDISPLAY, removes our region_highlight entry, resets internal state.
# Calls zle -R to redraw.
# ==============================================================================
_zai_suggestion_clear() {
  _zai_suggestion_highlight_remove
  POSTDISPLAY=""
  _ZAI_SUGGESTION_PREFIX=""
  zle -R
}

# ==============================================================================
# _zai_suggestion_accept
#
# Inserts the current POSTDISPLAY ghost text into BUFFER at CURSOR position.
# Advances CURSOR to point immediately after the inserted text.
# Clears POSTDISPLAY after insertion.
#
# CRITICAL SAFETY RULE:
#   This function MUST NOT call accept-line or zle .accept-line.
#   Inserting text into BUFFER only makes the suggestion editable — the user
#   must press Enter themselves to execute the resulting command.
#
# No-op if POSTDISPLAY is empty (nothing to accept).
# ==============================================================================
_zai_suggestion_accept() {
  # Nothing to accept
  [[ -z "${POSTDISPLAY}" ]] && return 0

  local suggestion="${POSTDISPLAY}"

  # Insert suggestion at the current cursor position.
  # CURSOR is 0-indexed in ZLE:
  #   BUFFER[1,CURSOR]          — characters before the cursor
  #   BUFFER[$((CURSOR+1)),-1]  — characters from cursor onward (may be empty)
  BUFFER="${BUFFER[1,CURSOR]}${suggestion}${BUFFER[$((CURSOR + 1)),-1]}"

  # Advance cursor to just after the inserted text
  (( CURSOR += ${#suggestion} ))

  # Remove highlight and clear ghost text display
  _zai_suggestion_highlight_remove
  POSTDISPLAY=""
  _ZAI_SUGGESTION_PREFIX=""

  # ── SAFETY: Do NOT call accept-line ─────────────────────────────────────
  # Suggestion text is now in the editable BUFFER; user must press Enter.
  # ────────────────────────────────────────────────────────────────────────

  # Redraw to reflect BUFFER change and cleared POSTDISPLAY
  zle -R
}

# ==============================================================================
# _zai_suggestion_get_from_history <prefix>
#
# Searches the last 1000 shell history entries (via fc -l) for the most recent
# command that begins with <prefix>. On a match, prints only the suffix — the
# text that comes after the matched prefix.
#
# Returns 0 and prints the suffix on success.
# Returns 1 (prints nothing) if no match is found or prefix is empty.
#
# Arguments:
#   prefix  — The current BUFFER content to match against history entries.
# ==============================================================================
_zai_suggestion_get_from_history() {
  local prefix="${1}"

  # Nothing to match
  [[ -z "${prefix}" ]] && return 1

  local prefix_len=${#prefix}

  # Enable extended glob patterns within this function scope only.
  # Required for [[:blank:]]# and [0-9]## patterns used to strip fc numbers.
  setopt localoptions extendedglob

  local -a lines
  local line cmd

  # fc -l output format:  "  NUM  command text"
  # We read the last 1000 entries into an array so we can iterate newest-first.
  # Reverse iteration (from end) gives us the most-recently-used match first.
  while IFS='' read -r line; do
    # Strip leading whitespace + history number + following whitespace.
    # Pattern: zero-or-more blanks, one-or-more digits, zero-or-more blanks.
    cmd="${line##[[:blank:]]#[0-9]##[[:blank:]]#}"
    # Keep only non-empty entries
    [[ -n "${cmd}" ]] && lines+=("${cmd}")
  done < <(fc -l -1000 2>/dev/null)

  # Search newest-to-oldest (highest index = most recent)
  local i
  for (( i = ${#lines[@]}; i >= 1; i-- )); do
    cmd="${lines[$i]}"

    # Candidate must start with prefix AND be strictly longer
    # (so there is an actual suffix to offer as a completion)
    if [[ "${cmd}" == "${prefix}"* ]] && (( ${#cmd} > prefix_len )); then
      # Print only the completion suffix — text after the matched prefix
      print -- "${cmd:${prefix_len}}"
      return 0
    fi
  done

  return 1
}

# ==============================================================================
# _zai_suggestion_update <text>
#
# Replaces the current ghost text with an AI-generated suggestion.
# Acts as a stale-check gatekeeper: only applies the update if BUFFER still
# equals the value stored in _ZAI_SUGGESTION_PREFIX from the last show call.
#
# Called by the AsyncEngine after a successful Ollama completion, AFTER the
# generation-counter check. This provides a second layer of staleness defence
# at the SuggestionManager level.
#
# Arguments:
#   text  — AI-generated completion suffix.
# ==============================================================================
_zai_suggestion_update() {
  local text="${1}"

  # Nothing to update with
  [[ -z "${text}" ]] && return 0

  # Stale-check: if we have a stored prefix and BUFFER has since changed,
  # the async result is for an older input state — discard it silently.
  if [[ -n "${_ZAI_SUGGESTION_PREFIX}" ]] && \
     [[ "${BUFFER}" != "${_ZAI_SUGGESTION_PREFIX}" ]]; then
    return 0
  fi

  # BUFFER still matches — show the upgraded AI suggestion
  _zai_suggestion_show "${text}"
}

# ==============================================================================
# _zai_suggestion_reset (test helper)
#
# Resets all SuggestionManager state to a clean baseline.
# Intended for use between test cases — should NOT be called in production.
# ==============================================================================
_zai_suggestion_reset() {
  _zai_suggestion_highlight_remove
  POSTDISPLAY=""
  _ZAI_SUGGESTION_PREFIX=""
}
