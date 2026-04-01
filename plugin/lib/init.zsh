# ==============================================================================
# zsh-ai-complete: Initialization Module
# File: plugin/lib/init.zsh
# ==============================================================================
#
# Provides the two-phase initialization logic for the plugin:
#
# Phase 1 — _zai_init() [synchronous, <20ms budget]
#   Called immediately by the plugin loader after sourcing all lib files.
#   - Creates the plugin cache directory (~/.cache/zsh-ai-complete/, mode 700)
#   - Registers all ZLE widgets via _zai_register_widgets()
#   - Binds key sequences via _zai_bind_keys()
#   - Registers _zai_deferred_init as a one-shot precmd hook
#   - Registers _zai_full_cleanup as a zshexit hook
#   - Detects zsh-autosuggestions coexistence and prints advisory
#
# Phase 2 — _zai_deferred_init() [async, runs once after first prompt]
#   Fires via the precmd hook mechanism — AFTER the first prompt is displayed.
#   - Removes itself from precmd_functions (one-shot semantics)
#   - Performs Ollama health check (_zai_ollama_check_health)
#   - Verifies model availability (_zai_ollama_check_model)
#   - Sends a warm-up request (keep_alive=-1) to preload model into GPU memory
#   - Prints user-visible warnings if Ollama or the model is unavailable
#
# This two-phase design keeps ALL network I/O out of the synchronous startup
# path, ensuring shell startup overhead stays well within the 100ms budget
# (with the synchronous phase targeting <20ms).
#
# Startup time measurement (for debugging):
#   The plugin loader measures EPOCHREALTIME before and after _zai_init() and
#   stores the delta in _ZAI_INIT_DURATION_MS. Values above 20ms indicate a
#   regression in the synchronous path.
#
# Internal helpers:
#   _zai_check_autosuggestions_conflict()  — detects POSTDISPLAY plugin conflicts
#   _zai_warmup_model(model, url)          — sends keep_alive=-1 warm-up request
#
# Dependencies (sourced by plugin loader before this file):
#   plugin/lib/config.zsh      — _zai_config_get
#   plugin/lib/ollama.zsh      — _zai_ollama_check_health, _zai_ollama_check_model,
#                                 _zai_validate_ollama_url, _ZAI_LOOPBACK_IFACE
#   plugin/lib/keybindings.zsh — _zai_register_widgets, _zai_bind_keys
#   plugin/lib/async.zsh       — _zai_full_cleanup
# ==============================================================================

# Guard against double-sourcing
(( ${+_ZAI_INIT_LOADED} )) && return 0
typeset -gi _ZAI_INIT_LOADED=1

# ==============================================================================
# Module constants
# ==============================================================================

# Cache directory for all plugin runtime files.
# Mode 700: owner read/write/execute only — no group/world access.
# Never use /tmp; this location respects the XDG_CACHE_HOME convention.
typeset -g _ZAI_CACHE_DIR="${HOME}/.cache/zsh-ai-complete"

# Startup duration storage (milliseconds, float string).
# Set by the plugin loader after measuring EPOCHREALTIME around _zai_init().
# Kept here (in the init module) for logical grouping.
typeset -g _ZAI_INIT_DURATION_MS=""

# ==============================================================================
# _zai_init
#
# Synchronous fast-path initialization. Must complete in <20ms.
# Called once by the plugin loader (plugin/zsh-ai-complete.plugin.zsh)
# immediately after sourcing all lib/*.zsh modules.
#
# No network I/O is performed here. All checks that require Ollama are
# delegated to _zai_deferred_init() which fires via precmd after the first
# prompt is displayed.
# ==============================================================================
_zai_init() {
  # ── 1. Create cache directory ──────────────────────────────────────────────
  # Use mkdir -p so the full path is created even if parent dirs are missing.
  # chmod 700 is applied regardless of whether the directory already existed
  # to ensure correct permissions are enforced on every startup.
  #
  # Suppressing stderr: failures here are non-fatal — if the cache dir cannot
  # be created, individual features will degrade gracefully at use time.
  if [[ ! -d "${_ZAI_CACHE_DIR}" ]]; then
    mkdir -p "${_ZAI_CACHE_DIR}" 2>/dev/null
  fi
  chmod 700 "${_ZAI_CACHE_DIR}" 2>/dev/null

  # ── 2. Register all ZLE widgets ───────────────────────────────────────────
  # _zai_register_widgets creates zle -N entries for all custom widgets.
  # Must be called BEFORE _zai_bind_keys.
  if (( ${+functions[_zai_register_widgets]} )); then
    _zai_register_widgets
  else
    print -u2 "zsh-ai-complete: init: _zai_register_widgets not found — keybindings unavailable"
  fi

  # ── 3. Bind key sequences to registered widgets ───────────────────────────
  # _zai_bind_keys maps key sequences (arrows, Tab, Escape, Ctrl+Space) to the
  # widgets registered in step 2.
  if (( ${+functions[_zai_bind_keys]} )); then
    _zai_bind_keys
  else
    print -u2 "zsh-ai-complete: init: _zai_bind_keys not found — keybindings unavailable"
  fi

  # ── 4. Schedule deferred init as one-shot precmd hook ─────────────────────
  # add-zsh-hook registers _zai_deferred_init in precmd_functions[].
  # The function removes itself from precmd_functions on its first invocation.
  # autoload add-zsh-hook first in case the caller's shell hasn't loaded it yet.
  if (( ! ${+functions[add-zsh-hook]} )); then
    autoload -Uz add-zsh-hook 2>/dev/null
  fi

  if (( ${+functions[add-zsh-hook]} )); then
    add-zsh-hook precmd _zai_deferred_init
  else
    # Fallback: manually append to precmd_functions[] if add-zsh-hook is absent.
    # This should not happen on any zsh 5.3+ installation but guards edge cases.
    precmd_functions+=(_zai_deferred_init)
  fi

  # ── 5. Register cleanup hook for shell exit ───────────────────────────────
  # _zai_full_cleanup cancels in-flight timer fds, request fds and pids, and
  # clears POSTDISPLAY. Registered via zshexit so it runs on clean exit,
  # SIGTERM, and exec replacement.
  if (( ${+functions[add-zsh-hook]} )); then
    add-zsh-hook zshexit _zai_full_cleanup
  else
    zshexit_functions+=(_zai_full_cleanup)
  fi

  # ── 6. Detect zsh-autosuggestions conflict ────────────────────────────────
  # Checked synchronously because if both plugins are already loaded at this
  # point, the conflict has already occurred. The advisory helps users act.
  _zai_check_autosuggestions_conflict
}

# ==============================================================================
# _zai_check_autosuggestions_conflict (internal)
#
# Detects whether zsh-autosuggestions is loaded alongside this plugin.
#
# Both plugins:
#   - Override the self-insert ZLE widget
#   - Write to the POSTDISPLAY ZLE variable for ghost text
#
# Running both simultaneously causes:
#   - Ghost text flickering (both plugins overwrite POSTDISPLAY)
#   - Widget registration order races (last writer wins self-insert)
#   - Unpredictable accept/dismiss behavior
#
# Detection strategy:
#   Check whether _zsh_autosuggest_start is defined — this is the function
#   that zsh-autosuggestions registers as a precmd hook during its own init.
#   If it exists, zsh-autosuggestions has been (or is being) initialized.
#
# The advisory is printed to stderr so it appears during startup, where the
# user is most likely to see it before normal shell usage begins.
# ==============================================================================
_zai_check_autosuggestions_conflict() {
  if (( ${+functions[_zsh_autosuggest_start]} )); then
    print -u2 ""
    print -u2 "zsh-ai-complete: ⚠ ADVISORY — zsh-autosuggestions detected"
    print -u2 "  Both plugins override the self-insert ZLE widget and write to POSTDISPLAY."
    print -u2 "  Running them simultaneously causes ghost text conflicts and widget races."
    print -u2 ""
    print -u2 "  Recommendation: disable zsh-autosuggestions when using zsh-ai-complete."
    print -u2 "  Remove the zsh-autosuggestions source/plugin line from your .zshrc"
    print -u2 "  or comment it out, then restart your shell."
    print -u2 ""
  fi
}

# ==============================================================================
# _zai_deferred_init
#
# One-shot precmd hook: runs ONCE after the first shell prompt is displayed,
# then removes itself from precmd_functions.
#
# All Ollama network I/O lives here so it does NOT block shell startup.
# The user's first prompt appears immediately; health checks and model warmup
# happen in the background or synchronously in the post-prompt window.
#
# Execution flow:
#   1. Self-remove from precmd_functions (must be first — ensures one-shot)
#   2. Ollama health check — warn if unreachable; skip steps 3–4 if down
#   3. Model availability check — warn if model not pulled
#   4. Model warm-up — background keep_alive=-1 request to pre-load into GPU
# ==============================================================================
_zai_deferred_init() {
  # ── 1. Remove self from precmd_functions (one-shot) ───────────────────────
  # This MUST be the first action so that even if the subsequent steps fail
  # or error out, this function never fires again.
  if (( ${+functions[add-zsh-hook]} )); then
    add-zsh-hook -d precmd _zai_deferred_init 2>/dev/null
  else
    # Manual removal: rebuild array without this function name
    precmd_functions=("${(@)precmd_functions:#_zai_deferred_init}")
  fi

  # ── 2. Ollama health check ────────────────────────────────────────────────
  local ollama_url model
  ollama_url="$(_zai_config_get ollama_url 2>/dev/null)" || ollama_url="http://localhost:11434"
  model="$(_zai_config_get model 2>/dev/null)"           || model="qwen2.5-coder:7b"

  if ! _zai_ollama_check_health 2>/dev/null; then
    print -u2 ""
    print -u2 "zsh-ai-complete: ⚠ WARNING — Ollama is not reachable at ${ollama_url}"
    print -u2 "  AI completions are disabled until Ollama is started."
    print -u2 "  To start Ollama: ollama serve"
    print -u2 "  History-based suggestions remain available."
    print -u2 ""
    # Model check and warmup are pointless if Ollama is not running
    return 0
  fi

  # ── 3. Model availability check ───────────────────────────────────────────
  if ! _zai_ollama_check_model "${model}" 2>/dev/null; then
    print -u2 ""
    print -u2 "zsh-ai-complete: ⚠ WARNING — Model '${model}' not found in Ollama."
    print -u2 "  AI completions are disabled until the model is pulled."
    print -u2 "  To pull the model: ollama pull ${model}"
    print -u2 "  History-based suggestions remain available."
    print -u2 ""
    # No point warming up a model that isn't there
    return 0
  fi

  # ── 4. Warm-up request (fire-and-forget background) ──────────────────────
  # Sending keep_alive=-1 to Ollama tells it to keep the model loaded in
  # GPU/CPU memory indefinitely (until Ollama exits), bypassing the default
  # 5-minute idle unload timer.
  #
  # This is a background subshell (& + disown) so:
  #   - The user's first prompt is NOT blocked by the warmup HTTP request
  #   - The user will see noticeably faster first-keystroke completions
  #   - If the warmup fails, it degrades silently (no user impact)
  #
  # disown removes the background job from the shell's job table so the
  # user does not see "[1] Done ..." messages when it completes.
  _zai_warmup_model "${model}" "${ollama_url}" &
  disown $! 2>/dev/null
}

# ==============================================================================
# _zai_warmup_model <model> <url>
#
# Sends a keep_alive=-1 POST /api/generate request to Ollama to preload the
# specified model into GPU/CPU memory.
#
# keep_alive=-1:
#   Tells Ollama to keep the model loaded indefinitely — it will not be
#   unloaded due to idle timeout for the duration of this shell session.
#   This eliminates the cold-start latency on the first real completion
#   request, which would otherwise have to wait for model load (~2–10s).
#
# Called from _zai_deferred_init as a background subshell. This function
# runs in a child process and MUST NOT:
#   - Call any ZLE functions (zle -R, zle -F, etc.)
#   - Modify ZLE variables (BUFFER, POSTDISPLAY, region_highlight, etc.)
#   - Print to stderr in normal operation
#   - Block indefinitely (--max-time 30 enforces a hard timeout)
#
# Args:
#   model  — Model name, e.g. "qwen2.5-coder:7b"
#   url    — Ollama base URL, e.g. "http://localhost:11434"
#
# Returns:
#   0 on success (request sent, response discarded)
#   1 on URL validation failure or curl error (silent — caller is background)
# ==============================================================================
_zai_warmup_model() {
  local model="${1}"
  local url="${2}"

  # Refuse to send warmup to a non-loopback URL
  if ! _zai_validate_ollama_url "${url}" 2>/dev/null; then
    return 1
  fi

  # Use the loopback interface constant from ollama.zsh if available.
  # Fall back to platform detection if the constant is not set (e.g. tests).
  local loopback_iface
  if [[ -n "${_ZAI_LOOPBACK_IFACE}" ]]; then
    loopback_iface="${_ZAI_LOOPBACK_IFACE}"
  elif [[ "$( uname -s 2>/dev/null )" == "Darwin" ]]; then
    loopback_iface="lo0"
  else
    loopback_iface="lo"
  fi

  # JSON-escape the model name (handles unusual model name characters)
  local model_escaped="${model//\\/\\\\}"
  model_escaped="${model_escaped//\"/\\\"}"

  # Warm-up payload: minimal prompt, stream:false, keep_alive:-1
  #   keep_alive: -1  → keep model in memory indefinitely (never auto-unload)
  #   prompt: ""      → minimal compute; we only want the model loaded
  #   stream: false   → single response, simpler parsing
  local warmup_json
  warmup_json="{\"model\":\"${model_escaped}\",\"prompt\":\"\",\"stream\":false,\"keep_alive\":-1}"

  # Send warm-up request.
  # Response is discarded (>/dev/null) — we only care about the side effect
  # of the model being loaded into memory.
  # --max-time 30: generous timeout since model loading can take several seconds.
  # Prompt is piped via stdin (-d @-) to avoid exposure in process listings.
  print -r -- "${warmup_json}" | curl \
    --silent \
    --fail \
    -X POST \
    -H 'Content-Type: application/json' \
    --max-time 30 \
    --interface "${loopback_iface}" \
    -d @- \
    "${url}/api/generate" >/dev/null 2>&1
}
