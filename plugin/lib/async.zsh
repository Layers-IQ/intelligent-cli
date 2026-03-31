# ==============================================================================
# zsh-ai-complete: AsyncEngine Module + Resilience Layer
# File: plugin/lib/async.zsh
# ==============================================================================
#
# Two concerns are implemented here:
#
# 1. AsyncEngine (TASK-007)
#    Non-blocking completion pipeline using zle -F file-descriptor callbacks.
#    - Sub-second debounce via exec {fd}< <(sleep N; print .) + zle -F timer
#    - Background subshell: ContextGatherer → PromptBuilder → OllamaClient
#    - Monotonic generation counter rejects stale results
#    - Cancellation: deregister zle -F → close fd → kill PID → wait PID
#
# 2. Resilience Layer (TASK-011)
#    Transparent graceful degradation when Ollama becomes unavailable.
#    - _ZAI_OLLAMA_AVAILABLE tracks current reachability (1=up, 0=down)
#    - On first failure: flag set to 0, failure timestamp recorded
#    - _zai_check_ollama_periodic() gates every request: skips Ollama entirely
#      while in 30-second cooldown; allows a retry attempt once cooldown expires
#    - On successful retry: flag resets to 1, AI completions resume
#    - Zero user-visible changes: no errors, no warnings, history suggestions
#      continue uninterrupted throughout any Ollama outage
#
# Communication protocol between background subshell and parent via fd:
#   Success:     "<generation_token>:<completion_text>\n"
#   Unavailable: "UNAVAIL:<generation_token>\n"
#
# Public functions:
#   _zai_async_request(buffer)     Debounce bypass: immediately spawns pipeline
#   _zai_async_cancel()            Kill in-flight request subshell + close fd
#   _zai_debounce_start()          Start/restart debounce timer
#   _zai_debounce_cancel()         Cancel active debounce timer
#   _zai_full_cleanup()            Cancel all timers + requests + clear display
#   _zai_check_ollama_periodic()   Availability gate (0=proceed, 1=skip)
#
# Internal ZLE callbacks (registered via zle -F):
#   _zai_timer_cb(fd, err)         Fires after debounce delay; launches request
#   _zai_async_callback(fd, err)   Fires when subshell result is ready
#
# Test helper:
#   _zai_async_reset()             Resets all state (unit tests only)
#
# Dependencies (sourced before this file in the plugin loader):
#   plugin/lib/config.zsh
#   plugin/lib/suggestion.zsh
#   plugin/lib/ollama.zsh      (via background subshell pipeline)
#   plugin/lib/prompt.zsh      (via background subshell pipeline)
# ==============================================================================

# Guard against double-sourcing
(( ${+_ZAI_ASYNC_LOADED} )) && return 0
typeset -gi _ZAI_ASYNC_LOADED=1

# Auto-source config if not already loaded
if (( ! ${+functions[_zai_config_get]} )); then
  builtin source "${0:a:h}/config.zsh"
fi

# Auto-source suggestion module if not already loaded
if (( ! ${+functions[_zai_suggestion_show]} )); then
  builtin source "${0:a:h}/suggestion.zsh"
fi

# ==============================================================================
# AsyncEngine state
# ==============================================================================

# Monotonic generation counter — incremented for every new completion request.
# The counter value is embedded in the background subshell output as the
# "token".  _zai_async_callback rejects results whose token does not match the
# CURRENT counter, eliminating display of stale completions.
typeset -gi _ZAI_GEN_COUNTER=0

# Debounce timer file descriptor and the PID of its sleep subshell.
# Both are -1 when no timer is active (sentinel for "not set").
typeset -gi _ZAI_TIMER_FD=-1
typeset -gi _ZAI_TIMER_PID=-1

# Active completion request file descriptor and subshell PID.
# Both are -1 when no request is in flight.
typeset -gi _ZAI_REQ_FD=-1
typeset -gi _ZAI_REQ_PID=-1

# ==============================================================================
# Resilience Layer state
# ==============================================================================

# Current Ollama availability flag.
#   1 — Ollama is assumed available (initial state; set after every success)
#   0 — Ollama is known unavailable; AI requests are skipped until cooldown
typeset -gi _ZAI_OLLAMA_AVAILABLE=1

# Value of $SECONDS at the time Ollama was last determined to be unavailable.
# -1 means "never failed".
# $SECONDS in zsh is the number of seconds since the shell started — always
# monotonically increasing, no clock-skew risk, no external tools needed.
typeset -gi _ZAI_OLLAMA_FAIL_SECONDS=-1

# How many seconds to wait after a failure before attempting to reconnect.
# Configurable via _ZAI_OLLAMA_RECHECK_INTERVAL for tests; 30 is the default
# from the architecture specification.
typeset -gi _ZAI_OLLAMA_RECHECK_INTERVAL=30

# ==============================================================================
# _zai_check_ollama_periodic
#
# Availability gate called at the start of every _zai_async_request().
#
# Decision logic:
#   - AVAILABLE (flag=1)          → return 0  (proceed with Ollama request)
#   - UNAVAILABLE, cooldown active → return 1  (skip Ollama; history stays shown)
#   - UNAVAILABLE, cooldown expired→ return 0  (allow one reconnect attempt)
#   - UNAVAILABLE, fail_seconds=-1 → return 0  (edge case; treat as recheck allowed)
#
# Returns:
#   0  Caller should proceed with an Ollama request
#   1  Caller should skip Ollama; history-only mode continues silently
# ==============================================================================
_zai_check_ollama_periodic() {
  # Fast path: Ollama is currently considered reachable
  if (( _ZAI_OLLAMA_AVAILABLE )); then
    return 0
  fi

  # Never actually failed (should not reach here, but guard defensively)
  if (( _ZAI_OLLAMA_FAIL_SECONDS < 0 )); then
    return 0
  fi

  # Check if the cooldown window has elapsed
  local elapsed=$(( SECONDS - _ZAI_OLLAMA_FAIL_SECONDS ))
  if (( elapsed >= _ZAI_OLLAMA_RECHECK_INTERVAL )); then
    # Cooldown expired — allow the caller to attempt a reconnect
    return 0
  fi

  # Still within cooldown — tell caller to skip Ollama silently
  return 1
}

# ==============================================================================
# _zai_debounce_cancel
#
# Deregisters the active debounce timer's zle -F callback, closes its fd,
# and sends SIGTERM to the background sleep process.
# Safe to call when no timer is active (all operations guarded by fd != -1).
# ==============================================================================
_zai_debounce_cancel() {
  if (( _ZAI_TIMER_FD != -1 )); then
    # Remove the zle -F handler so the callback never fires for this fd
    zle -F "${_ZAI_TIMER_FD}" 2>/dev/null
    # Close the read end of the pipe
    exec {_ZAI_TIMER_FD}<&-
    _ZAI_TIMER_FD=-1
  fi

  if (( _ZAI_TIMER_PID != -1 )); then
    # Kill the sleep subshell; wait clears the zombie
    kill -TERM "${_ZAI_TIMER_PID}" 2>/dev/null
    wait "${_ZAI_TIMER_PID}" 2>/dev/null
    _ZAI_TIMER_PID=-1
  fi
}

# ==============================================================================
# _zai_debounce_start
#
# Cancels any active timer and starts a fresh debounce timer.
# Opens a new fd backed by a subshell that sleeps for the configured debounce
# delay then emits a single byte.  zle -F wakes the parent ZLE loop when data
# is available, firing _zai_timer_cb without blocking.
#
# Debounce delay comes from _zai_config_get debounce (default: 150ms).
# Delay is converted from milliseconds to a fractional-seconds argument for
# sleep (e.g. 150 → "0.150") using pure integer arithmetic to avoid any
# floating-point representation issues across zsh versions.
# ==============================================================================
_zai_debounce_start() {
  # Always cancel the previous timer before starting a new one so rapid typing
  # never accumulates dangling fds or sleep processes.
  _zai_debounce_cancel

  local debounce_ms
  debounce_ms="$(_zai_config_get debounce 2>/dev/null)" || debounce_ms=150

  # Convert ms to "seconds.milliseconds" string using integer arithmetic only.
  # e.g. debounce_ms=150 → whole=0, frac=150 → "0.150"
  #      debounce_ms=1500 → whole=1, frac=500 → "1.500"
  local whole=$(( debounce_ms / 1000 ))
  local frac=$(( debounce_ms % 1000 ))
  local sleep_secs
  printf -v sleep_secs '%d.%03d' "${whole}" "${frac}"

  # Open read-end fd connected to a process substitution that produces output
  # after the debounce delay.  {_ZAI_TIMER_FD} allocates a free fd number and
  # stores it in the named variable (zsh 4.2+ automatic fd allocation).
  exec {_ZAI_TIMER_FD}< <( sleep "${sleep_secs}"; print . )
  _ZAI_TIMER_PID=$!

  # Register _zai_timer_cb as the zle -F handler; it fires when data arrives
  zle -F "${_ZAI_TIMER_FD}" _zai_timer_cb
}

# ==============================================================================
# _zai_timer_cb <fd> [err]
#
# ZLE file-descriptor callback registered by _zai_debounce_start().
# Fires when the debounce sleep subshell writes its byte (or HUPs on cancel).
#
# Steps:
#   1. Immediately deregisters and closes the fd (single-fire callback).
#   2. On error (HUP = timer was cancelled), exits cleanly.
#   3. Checks BUFFER length against min_chars config gate.
#   4. Dispatches _zai_async_request if buffer is long enough.
#
# Called by the ZLE event loop; BUFFER and other ZLE variables are valid here.
# ==============================================================================
_zai_timer_cb() {
  local fd="${1}" err="${2:-}"

  # Deregister the handler — this callback must not fire again for this fd
  zle -F "${fd}" 2>/dev/null
  exec {fd}<&-
  _ZAI_TIMER_FD=-1
  _ZAI_TIMER_PID=-1

  # HUP signals that the fd was closed before data arrived (normal cancellation)
  [[ -n "${err}" ]] && return 0

  # Length gate: only fire if the user has typed enough characters
  local min_chars
  min_chars="$(_zai_config_get min_chars 2>/dev/null)" || min_chars=3

  if (( ${#BUFFER} >= min_chars )); then
    _zai_async_request "${BUFFER}"
  fi
}

# ==============================================================================
# _zai_async_cancel
#
# Kills any active Ollama request subshell, deregisters its zle -F callback,
# and closes the result fd.  Called before spawning a new request to ensure
# only one pipeline is running at a time.
# ==============================================================================
_zai_async_cancel() {
  if (( _ZAI_REQ_FD != -1 )); then
    zle -F "${_ZAI_REQ_FD}" 2>/dev/null
    exec {_ZAI_REQ_FD}<&-
    _ZAI_REQ_FD=-1
  fi

  if (( _ZAI_REQ_PID != -1 )); then
    kill -TERM "${_ZAI_REQ_PID}" 2>/dev/null
    wait "${_ZAI_REQ_PID}" 2>/dev/null
    _ZAI_REQ_PID=-1
  fi
}

# ==============================================================================
# _zai_async_request <buffer>
#
# Core dispatch function called by _zai_timer_cb (after debounce) or by the
# manual-trigger widget (immediate).
#
# Resilience gate (TASK-011):
#   Before spawning anything, _zai_check_ollama_periodic() is consulted:
#   - If it returns 1 (Ollama unavailable + in cooldown), this function returns
#     immediately.  The history-based ghost text already shown by the
#     self-insert widget remains visible — no flicker, no message to the user.
#   - If it returns 0, the full pipeline runs.  If Ollama turns out to be down,
#     the subshell writes "UNAVAIL:<token>" so _zai_async_callback can update
#     the flag; the history suggestion still stays on screen.
#
# Background subshell output contract:
#   Success:         "<token>:<cleaned_completion>"
#   Ollama failure:  "UNAVAIL:<token>"
#
# Args:
#   buffer  — Current ZLE BUFFER content at the time of dispatch.
# ==============================================================================
_zai_async_request() {
  local buffer="${1}"

  # Cancel any previous in-flight request before spawning a new one.
  # This prevents multiple callbacks arriving for different requests.
  _zai_async_cancel

  # ── Resilience gate ────────────────────────────────────────────────────────
  # If Ollama is known-unavailable and still within the cooldown window, skip
  # the entire pipeline.  The user continues to see history suggestions.
  if ! _zai_check_ollama_periodic; then
    return 0
  fi

  # ── Increment generation counter ───────────────────────────────────────────
  # Capture the token BEFORE spawning so the subshell closes over the correct
  # value even if another request fires and increments the counter while this
  # subshell is still running.
  (( _ZAI_GEN_COUNTER++ ))
  local token="${_ZAI_GEN_COUNTER}"

  # ── Spawn background subshell via process substitution ────────────────────
  # The subshell inherits all function definitions from the parent shell;
  # no re-sourcing is required.  The parent ZLE loop is never blocked —
  # zle -F wakes it only when data is available on the fd.
  exec {_ZAI_REQ_FD}< <(
    # Gather context → build prompt → call Ollama
    local context prompt options mode raw_completion clean

    # Detect natural-language-to-command mode: buffer starts with "# "
    mode="completion"
    if [[ "${buffer}" == "# "* ]]; then
      mode="nl_to_cmd"
    fi

    # Gather full context from directory, history, git (suppressing stderr)
    context="$(_zai_gather_full_context "${buffer}" 2>/dev/null)"

    # Build the mode-appropriate prompt
    if [[ "${mode}" == "nl_to_cmd" ]]; then
      local comment="${buffer#\# }"
      prompt="$(_zai_build_nl_translation_prompt "${comment}" "${context}" 2>/dev/null)"
    else
      prompt="$(_zai_build_completion_prompt "${buffer}" "${context}" 2>/dev/null)"
    fi

    # Get generation parameters JSON for this mode
    options="$(_zai_get_generation_params "${mode}" 2>/dev/null)"

    # Attempt Ollama generation — all errors suppressed (no stderr to user)
    raw_completion="$(_zai_ollama_generate "${prompt}" "${options}" 2>/dev/null)"
    local ollama_exit=$?

    if (( ollama_exit != 0 )) || [[ -z "${raw_completion}" ]]; then
      # Signal to parent that Ollama was unreachable / returned nothing
      print -r -- "UNAVAIL:${token}"
      return
    fi

    # Post-process: strip echoed prefix, remove fences, reject oversized output
    clean="$(_zai_clean_completion "${raw_completion}" "${buffer}" "${mode}" 2>/dev/null)"

    # Only emit a result if the cleaned completion is non-empty
    if [[ -n "${clean}" ]]; then
      print -r -- "${token}:${clean}"
    fi
    # If clean is empty, emit nothing — fd will HUP; callback handles it cleanly
  )
  _ZAI_REQ_PID=$!

  # Register the callback for when the subshell writes its result
  zle -F "${_ZAI_REQ_FD}" _zai_async_callback
}

# ==============================================================================
# _zai_async_callback <fd> [err]
#
# ZLE file-descriptor callback registered in _zai_async_request().
# Fires when the background subshell has written a result line (or HUPed).
#
# Result handling:
#   "UNAVAIL:<token>"    → Mark Ollama unavailable, record timestamp.
#                          History suggestion remains visible; no user message.
#   "<token>:<text>"     → Check generation counter for staleness.
#                          If fresh: mark Ollama available, update suggestion.
#                          If stale: discard silently.
#   HUP / empty          → Subshell exited without output (cancelled or timed
#                          out).  Close fd, return cleanly.
#
# Note: Successful results reset _ZAI_OLLAMA_AVAILABLE=1 so that a session
# which was reconnected automatically does not keep the fail timestamp.
# ==============================================================================
_zai_async_callback() {
  local fd="${1}" err="${2:-}"

  # ── Always close and deregister the fd first ───────────────────────────────
  # Read BEFORE closing so data is not lost.  On HUP, read returns "" which
  # is handled below.
  local result=""
  if [[ -z "${err}" ]]; then
    IFS='' read -r result <&"${fd}" 2>/dev/null || true
  fi

  # Deregister zle -F handler and close fd
  zle -F "${fd}" 2>/dev/null
  exec {fd}<&-
  _ZAI_REQ_FD=-1
  _ZAI_REQ_PID=-1

  # ── HUP / error / empty result ─────────────────────────────────────────────
  # Subshell was cancelled or produced no output (e.g. clean completion was
  # empty).  No state update; history suggestion continues to show.
  [[ -z "${result}" ]] && return 0

  # ── Unavailability signal ──────────────────────────────────────────────────
  if [[ "${result}" == "UNAVAIL:"* ]]; then
    # Mark Ollama unavailable and start the cooldown timer
    _ZAI_OLLAMA_AVAILABLE=0
    _ZAI_OLLAMA_FAIL_SECONDS="${SECONDS}"
    # History suggestion already displayed — nothing more to do
    return 0
  fi

  # ── Normal result: "<token>:<completion_text>" ─────────────────────────────
  local resp_token="${result%%:*}"
  local completion="${result#*:}"

  # Stale-result check: reject if the generation counter has advanced past
  # the token embedded in this result.  This means the user typed more
  # characters after this subshell was launched; its suggestion is obsolete.
  if [[ "${resp_token}" != "${_ZAI_GEN_COUNTER}" ]]; then
    return 0
  fi

  # Successful round-trip to Ollama — mark as available, clear fail timestamp
  _ZAI_OLLAMA_AVAILABLE=1
  _ZAI_OLLAMA_FAIL_SECONDS=-1

  # Delegate display to SuggestionManager (it performs its own BUFFER staleness
  # check as a second defensive layer)
  if [[ -n "${completion}" ]]; then
    _zai_suggestion_update "${completion}"
  fi
}

# ==============================================================================
# _zai_full_cleanup
#
# Cancels all in-flight timers and request subshells, closes their fds, and
# clears the ghost text display.
#
# Called from:
#   _zai_widget_accept_line   — before zle .accept-line to prevent stale
#                               callbacks firing after ZLE exits the line
#   zshexit hook              — on shell exit to prevent zombie processes
#
# Idempotent: safe to call multiple times or when nothing is active.
# ==============================================================================
_zai_full_cleanup() {
  _zai_debounce_cancel
  _zai_async_cancel

  # Clear ghost text — check if suggestion module is loaded first
  # (allows cleanup to run safely early in plugin initialisation)
  if (( ${+functions[_zai_suggestion_clear]} )); then
    _zai_suggestion_clear 2>/dev/null
  else
    # Fallback: clear directly if suggestion module not yet loaded
    POSTDISPLAY="" 2>/dev/null
  fi
}

# ==============================================================================
# _zai_async_reset (test helper)
#
# Resets all AsyncEngine and resilience-layer state to a clean initial
# baseline.  Intended for use between test cases only — never call in
# production as it silently drops any in-flight request.
# ==============================================================================
_zai_async_reset() {
  # Cancel active operations without ZLE (safe outside ZLE context in tests)
  if (( _ZAI_TIMER_FD != -1 )); then
    exec {_ZAI_TIMER_FD}<&- 2>/dev/null
    _ZAI_TIMER_FD=-1
  fi
  if (( _ZAI_TIMER_PID != -1 )); then
    kill -TERM "${_ZAI_TIMER_PID}" 2>/dev/null
    wait "${_ZAI_TIMER_PID}" 2>/dev/null
    _ZAI_TIMER_PID=-1
  fi
  if (( _ZAI_REQ_FD != -1 )); then
    exec {_ZAI_REQ_FD}<&- 2>/dev/null
    _ZAI_REQ_FD=-1
  fi
  if (( _ZAI_REQ_PID != -1 )); then
    kill -TERM "${_ZAI_REQ_PID}" 2>/dev/null
    wait "${_ZAI_REQ_PID}" 2>/dev/null
    _ZAI_REQ_PID=-1
  fi

  # Reset counters
  _ZAI_GEN_COUNTER=0

  # Reset resilience state to initial "assumed available" baseline
  _ZAI_OLLAMA_AVAILABLE=1
  _ZAI_OLLAMA_FAIL_SECONDS=-1
}
