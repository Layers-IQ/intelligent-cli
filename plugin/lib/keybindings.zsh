# ==============================================================================
# zsh-ai-complete: KeybindingManager
# File: plugin/lib/keybindings.zsh
# ==============================================================================
#
# Registers all ZLE widgets and binds key sequences to completion triggers
# and interaction controls.
#
# Public API:
#   _zai_register_widgets()          → register all custom ZLE widgets via zle -N
#   _zai_bind_keys()                 → bind key sequences to registered widgets
#
# Widgets:
#   _zai_widget_self_insert          → wraps self-insert: char insert + instant
#                                       history match + async debounce
#   _zai_widget_backward_delete      → wraps backward-delete-char: delete +
#                                       clear suggestion + restart debounce
#   _zai_widget_accept_suggestion    → accepts ghost text if POSTDISPLAY non-empty,
#                                       falls through to forward-char / expand-or-complete
#   _zai_widget_dismiss              → clears ghost text + cancels in-flight requests
#   _zai_widget_manual_trigger       → bypasses debounce, fires AI request immediately
#   _zai_widget_accept_line          → cleanup + zle .accept-line (Enter)
#
# Key bindings set by _zai_bind_keys():
#   \e[C  \eOC  → _zai_widget_accept_suggestion  (Right Arrow: VT and application mode)
#   \t          → _zai_widget_accept_suggestion  (Tab: accept or expand-or-complete)
#   \e          → _zai_widget_dismiss            (Escape: with KEYTIMEOUT=10 = 100ms)
#   ^@  \000    → _zai_widget_manual_trigger     (Ctrl+Space: NUL, bypasses debounce)
#
# Note: self-insert, backward-delete-char, and accept-line are replaced globally
# via `zle -N widget-name function` in _zai_register_widgets() so that all
# existing key bindings for those actions automatically use our wrappers.
#
# Conflict advisory:
#   zsh-autosuggestions also overrides self-insert and uses POSTDISPLAY. Both
#   plugins cannot run simultaneously without conflict. The plugin loader
#   (init.zsh) detects and warns if zsh-autosuggestions is active.
#
# Requires:
#   - plugin/lib/config.zsh    (sourced automatically if not already loaded)
#   - plugin/lib/suggestion.zsh (sourced automatically if not already loaded)
#   - plugin/lib/async.zsh     (called defensively; sourced by plugin loader)
#   - zsh 5.3+ (POSTDISPLAY, zle -F, exec {fd}< <(), KEYTIMEOUT)
#
# ==============================================================================

# Guard against double-sourcing
(( ${+_ZAI_KEYBINDINGS_LOADED} )) && return 0
typeset -gi _ZAI_KEYBINDINGS_LOADED=1

# Auto-source dependencies if not already loaded
if (( ! ${+functions[_zai_config_get]} )); then
  builtin source "${0:a:h}/config.zsh"
fi

if (( ! ${+functions[_zai_suggestion_show]} )); then
  builtin source "${0:a:h}/suggestion.zsh"
fi

# Note: async.zsh functions (_zai_debounce_start, _zai_debounce_cancel,
# _zai_async_request, _zai_async_cancel, _zai_full_cleanup) are sourced by
# the plugin loader after all lib files are loaded. We call them defensively
# with (( ${+functions[...]} )) guards to keep this module testable in isolation.

# ==============================================================================
# _zai_widget_self_insert
#
# Wraps the ZLE built-in 'self-insert' widget, which is invoked for every
# printable character the user types.
#
# Execution order:
#   1. zle .self-insert        — insert the typed character into BUFFER normally
#   2. _zai_suggestion_clear   — invalidate the previous suggestion (prefix changed)
#   3. history prefix match    — instant (<10ms) visual feedback via fc -l search
#   4. _zai_debounce_start     — schedule async AI request (auto mode only)
#
# In 'manual' trigger mode, step 4 is skipped. The user must press Ctrl+Space
# to explicitly trigger an AI completion request.
# ==============================================================================
_zai_widget_self_insert() {
  # 1. Insert the typed character into BUFFER at the cursor position.
  #    .self-insert (with dot prefix) calls the built-in version, bypassing our wrapper.
  zle .self-insert

  # 2. Clear the stale suggestion — the character just typed changes the prefix,
  #    so any previously displayed ghost text is no longer valid.
  _zai_suggestion_clear

  # 3. Instant history match for immediate visual feedback.
  #    _zai_suggestion_get_from_history searches fc -l (in memory, no subprocess
  #    for the shell itself) for the most recent command that begins with BUFFER.
  #    This runs synchronously in the ZLE widget (< 10ms) so the user sees a
  #    suggestion immediately, before the async Ollama request completes.
  local hist_match
  hist_match="$(_zai_suggestion_get_from_history "${BUFFER}")"
  if [[ -n "${hist_match}" ]]; then
    _zai_suggestion_show "${hist_match}"
  fi

  # 4. Schedule an async AI completion request via debounce timer.
  #    In 'auto' mode: start/restart the debounce timer (each new character
  #    resets the 150ms countdown). In 'manual' mode: skip debounce entirely.
  local trigger_mode
  trigger_mode="$(_zai_config_get trigger 2>/dev/null)" || trigger_mode="auto"

  if [[ "${trigger_mode}" == "auto" ]]; then
    (( ${+functions[_zai_debounce_start]} )) && _zai_debounce_start
  fi
}

# ==============================================================================
# _zai_widget_backward_delete
#
# Wraps the ZLE built-in 'backward-delete-char' widget (Backspace key).
#
# Execution order:
#   1. zle .backward-delete-char  — delete the character before the cursor
#   2. _zai_suggestion_clear      — clear stale ghost text (prefix just shortened)
#   3. debounce restart or cancel — if buffer still qualifies, restart debounce
#                                   (auto mode only); otherwise cancel the timer
# ==============================================================================
_zai_widget_backward_delete() {
  # 1. Delete the character before the cursor using the built-in widget.
  zle .backward-delete-char

  # 2. Clear any existing ghost text — the shorter prefix invalidates it.
  _zai_suggestion_clear

  # 3. Manage the debounce timer based on the updated buffer length.
  local trigger_mode min_chars
  trigger_mode="$(_zai_config_get trigger 2>/dev/null)" || trigger_mode="auto"
  min_chars="$(_zai_config_get min_chars 2>/dev/null)" || min_chars="3"

  if [[ "${trigger_mode}" == "auto" ]]; then
    if (( ${#BUFFER} >= min_chars )); then
      # Buffer still long enough to warrant a new request — restart the debounce
      # timer for the updated (shorter) prefix.
      (( ${+functions[_zai_debounce_start]} )) && _zai_debounce_start
    else
      # Buffer too short — cancel both the debounce timer and any in-flight
      # request to avoid firing a request for a too-short prefix.
      (( ${+functions[_zai_debounce_cancel]} )) && _zai_debounce_cancel
      (( ${+functions[_zai_async_cancel]} ))    && _zai_async_cancel
    fi
  fi
}

# ==============================================================================
# _zai_widget_accept_suggestion
#
# Handles Right Arrow (\e[C, \eOC) and Tab (\t) key presses.
#
# If a ghost text suggestion is currently displayed (POSTDISPLAY non-empty):
#   → Insert the ghost text into BUFFER at CURSOR, advance CURSOR, clear POSTDISPLAY.
#   → Does NOT call accept-line. The inserted text is editable; user must press Enter.
#
# If no suggestion is showing (POSTDISPLAY empty):
#   → Fall through to the original key behavior:
#       Tab        → zle expand-or-complete  (normal zsh completion)
#       Right Arrow → zle forward-char        (normal cursor movement)
#
# $KEYS contains the raw key sequence that triggered this widget in ZLE context,
# which allows us to dispatch the correct fallthrough behavior.
# ==============================================================================
_zai_widget_accept_suggestion() {
  if [[ -n "${POSTDISPLAY}" ]]; then
    # Ghost text is visible — accept it into BUFFER (no accept-line).
    _zai_suggestion_accept
    return 0
  fi

  # No suggestion showing — fall through to the key's original behavior.
  case "${KEYS}" in
    $'\t')
      # Tab with no suggestion: trigger native zsh completion.
      zle expand-or-complete
      ;;
    $'\e[C'|$'\eOC')
      # Right Arrow with no suggestion: move cursor one character forward.
      zle forward-char
      ;;
    *)
      # Unknown trigger key — default to forward-char as a safe fallback.
      zle forward-char
      ;;
  esac
}

# ==============================================================================
# _zai_widget_dismiss
#
# Called when the user presses Escape. Dismisses the current ghost text
# suggestion and cancels any in-flight Ollama request or pending debounce timer.
#
# IMPORTANT — Escape disambiguation:
#   Terminal arrow keys are encoded as multi-character escape sequences
#   (\e[A, \e[B, \e[C, \e[D). Without KEYTIMEOUT, zsh would wait indefinitely
#   after receiving \e to see if more characters follow, causing arrow keys to
#   first fire this dismiss widget. Setting KEYTIMEOUT=10 (100ms) in
#   _zai_bind_keys() tells zsh to wait at most 100ms before treating a lone
#   \e as a standalone Escape keypress — fast enough not to block arrow keys
#   which arrive within microseconds, long enough to avoid false dismissal.
# ==============================================================================
_zai_widget_dismiss() {
  # Clear ghost text display.
  _zai_suggestion_clear

  # Cancel any pending debounce timer.
  (( ${+functions[_zai_debounce_cancel]} )) && _zai_debounce_cancel

  # Cancel any in-flight Ollama HTTP request.
  (( ${+functions[_zai_async_cancel]} )) && _zai_async_cancel
}

# ==============================================================================
# _zai_widget_manual_trigger
#
# Called when the user presses Ctrl+Space. Bypasses the debounce timer and
# immediately fires an Ollama completion request for the current BUFFER.
#
# This is the primary completion trigger in 'manual' mode (ZSH_AI_COMPLETE_TRIGGER=manual).
# In 'auto' mode, it fires an immediate request in addition to the debounce mechanism,
# which is useful for getting a fresh suggestion without waiting 150ms.
#
# Guards:
#   - Buffer must be >= min_chars to avoid firing on trivially short input.
#   - Cancels any pending debounce before firing to avoid a racing duplicate request.
# ==============================================================================
_zai_widget_manual_trigger() {
  local min_chars
  min_chars="$(_zai_config_get min_chars 2>/dev/null)" || min_chars="3"

  # Only trigger if buffer content meets the minimum character threshold.
  if (( ${#BUFFER} >= min_chars )); then
    # Cancel any pending debounce timer — we are bypassing it intentionally.
    (( ${+functions[_zai_debounce_cancel]} )) && _zai_debounce_cancel

    # Fire the async request immediately (no debounce delay).
    (( ${+functions[_zai_async_request]} )) && _zai_async_request "${BUFFER}"
  fi
}

# ==============================================================================
# _zai_widget_accept_line
#
# Wraps the ZLE built-in 'accept-line' widget (Enter key / Return).
#
# Ensures that all in-flight state is fully cleaned up BEFORE the command is
# executed and ZLE hands off control. Without this wrapper, a pending zle -F
# callback (debounce timer or Ollama result) could fire AFTER accept-line has
# been called, triggering a callback into a defunct ZLE context, which causes
# errors ("zle: widgets can only be called when ZLE is active").
#
# Execution order:
#   1. _zai_full_cleanup   — cancel debounce timer + async request + clear POSTDISPLAY
#   2. zle .accept-line    — execute the command (the original built-in)
# ==============================================================================
_zai_widget_accept_line() {
  # 1. Full cleanup: cancels timer FD + request FD/PID, clears POSTDISPLAY.
  #    _zai_full_cleanup is defined in async.zsh. Called defensively.
  (( ${+functions[_zai_full_cleanup]} )) && _zai_full_cleanup

  # 2. Execute the command using the built-in accept-line.
  zle .accept-line
}

# ==============================================================================
# _zai_register_widgets
#
# Registers all custom ZLE widgets by creating named widget → function mappings.
#
# For built-in widget overrides (self-insert, backward-delete-char, accept-line),
# the `zle -N widgetname function` form replaces the named widget globally, so
# all existing key bindings for those actions automatically use our wrapper.
# Inside each wrapper, `zle .widgetname` (dot prefix) calls the original built-in.
#
# For accept-suggestion, dismiss, and manual-trigger, we register named widgets
# that are then bound to specific key sequences by _zai_bind_keys().
#
# Must be called before _zai_bind_keys().
# ==============================================================================
_zai_register_widgets() {
  # ── Built-in widget overrides ──────────────────────────────────────────────
  # Replaces the named widget globally. All existing bindings for these names
  # will invoke our function instead of the built-in. The built-in remains
  # callable via zle .widget-name (dot prefix).

  # self-insert: every printable character typed by the user
  zle -N self-insert _zai_widget_self_insert

  # backward-delete-char: Backspace key
  zle -N backward-delete-char _zai_widget_backward_delete

  # accept-line: Enter/Return key
  zle -N accept-line _zai_widget_accept_line

  # ── Explicit key-bound widgets ─────────────────────────────────────────────
  # These are registered as standalone named widgets; _zai_bind_keys() will
  # bind specific key sequences to them.

  # Right Arrow + Tab: accept ghost text or fall through
  zle -N _zai_widget_accept_suggestion

  # Escape: dismiss ghost text + cancel requests
  zle -N _zai_widget_dismiss

  # Ctrl+Space: immediately trigger AI request bypassing debounce
  zle -N _zai_widget_manual_trigger
}

# ==============================================================================
# _zai_bind_keys
#
# Binds key sequences to the registered ZLE widgets.
# Must be called after _zai_register_widgets().
#
# Key sequence notes:
#
#   Right Arrow:
#     \e[C   — VT100/ANSI application normal mode (most Linux terminals, tmux)
#     \eOC   — ANSI application cursor key mode (xterm, macOS Terminal.app)
#     Both must be bound so the plugin works in all terminal emulators.
#
#   Tab:
#     \t (^I, 0x09) — standard horizontal tab character sent by the Tab key.
#     When no suggestion is shown, falls through to expand-or-complete.
#
#   Escape (KEYTIMEOUT=10):
#     \e (0x1B) — the Escape character.
#     Arrow keys begin with \e (e.g., \e[C), so a raw escape binding MUST be
#     paired with KEYTIMEOUT=10 (100ms). This tells ZLE to wait at most 100ms
#     for a follow-on byte before treating \e as a standalone Escape press.
#     100ms is enough to capture any following arrow-key byte (which arrives in
#     microseconds from a real terminal), but short enough not to add perceptible
#     lag to navigation.
#
#   Ctrl+Space:
#     Most terminals send NUL (0x00 / ^@) for Ctrl+Space.
#     \C-@ and \000 are equivalent notations in zsh bindkey.
#     Both are bound for maximum terminal compatibility.
#
#   Keymap:
#     Bindings are applied to the 'main' keymap (emacs mode, the zsh default).
#     If the 'viins' keymap is available (vi-mode enabled), the same bindings
#     are applied there too, except Escape which in viins transitions to vi
#     command mode — vi-mode users should use a custom key for dismiss or rely
#     on accepting the suggestion before pressing Escape.
# ==============================================================================
_zai_bind_keys() {
  # ── KEYTIMEOUT: Escape disambiguation ─────────────────────────────────────
  # Must be set BEFORE binding \e. 10 × 10ms = 100ms wait window.
  KEYTIMEOUT=10

  # ── Accept suggestion (Right Arrow) ───────────────────────────────────────
  # VT100/ANSI normal cursor key sequences
  bindkey '\e[C' _zai_widget_accept_suggestion  # Right Arrow (most terminals)
  # ANSI application cursor key mode (SS3 sequences)
  bindkey '\eOC' _zai_widget_accept_suggestion  # Right Arrow (xterm app mode)

  # ── Accept suggestion (Tab) ────────────────────────────────────────────────
  # When suggestion is shown: accept it. When not: expand-or-complete.
  bindkey '\t' _zai_widget_accept_suggestion

  # ── Dismiss (Escape) ──────────────────────────────────────────────────────
  # Requires KEYTIMEOUT=10 (set above) to avoid misinterpreting arrow keys.
  bindkey '\e' _zai_widget_dismiss

  # ── Manual trigger (Ctrl+Space) ───────────────────────────────────────────
  # Ctrl+Space sends NUL (0x00) in most terminal emulators.
  bindkey $'\000' _zai_widget_manual_trigger    # NUL literal  (^@)
  bindkey $'\C-@' _zai_widget_manual_trigger    # \C-@ notation (equivalent)

  # ── viins keymap support (vi-mode) ────────────────────────────────────────
  # Apply accept-suggestion and manual-trigger to vi insert mode if it exists.
  # Escape is intentionally NOT rebound in viins (it switches to vi-cmd-mode).
  if bindkey -l 2>/dev/null | grep -q '^viins$'; then
    bindkey -M viins '\e[C' _zai_widget_accept_suggestion
    bindkey -M viins '\eOC' _zai_widget_accept_suggestion
    bindkey -M viins '\t'   _zai_widget_accept_suggestion
    bindkey -M viins $'\000' _zai_widget_manual_trigger
    bindkey -M viins $'\C-@' _zai_widget_manual_trigger
  fi
}
