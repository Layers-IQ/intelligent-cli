# ==============================================================================
# zsh-ai-complete: Plugin Loader (Main Entry Point)
# File: plugin/zsh-ai-complete.plugin.zsh
# ==============================================================================
#
# This file is sourced by the user's .zshrc — either directly or via a plugin
# manager. It is the ONLY file the user (or plugin manager) needs to reference.
#
# What this file does:
#   1. Detects its own base directory via ${0:a:h} (absolute, symlink-resolved)
#   2. Checks the minimum zsh version requirement (5.3+)
#   3. Sources all lib/*.zsh modules in strict dependency order
#   4. Calls _zai_init() for synchronous fast setup (<20ms)
#   5. Measures and stores startup overhead in _ZAI_INIT_DURATION_MS
#
# Module sourcing order (dependency-driven, matches architecture spec):
#   1. config.zsh      — Configuration: env vars, zstyle, defaults (no deps)
#   2. security.zsh    — SecurityFilter: secret redaction, prompt sanitization
#   3. context.zsh     — ContextGatherer: dir listing, history, git state
#   4. prompt.zsh      — PromptBuilder: FIM + ChatML prompt construction
#   5. ollama.zsh      — OllamaClient: HTTP API, URL validation (deps: config)
#   6. suggestion.zsh  — SuggestionManager: POSTDISPLAY ghost text (deps: config)
#   7. async.zsh       — AsyncEngine + Resilience: debounce, FD callbacks, cooldown
#   8. keybindings.zsh — KeybindingManager: ZLE widget + key registration
#   9. init.zsh        — Initialization: _zai_init, _zai_deferred_init
#
# Startup timing model:
#   ┌────────────────────────────────────────────────────────────────┐
#   │  Shell start                                                    │
#   │    └─ source zsh-ai-complete.plugin.zsh                        │
#   │         ├─ source lib/*.zsh          (file I/O, ~5–15ms)       │
#   │         └─ _zai_init()               (<20ms synchronous)       │
#   │              ├─ mkdir cache dir                                 │
#   │              ├─ _zai_register_widgets()                         │
#   │              ├─ _zai_bind_keys()                                │
#   │              └─ add-zsh-hook precmd _zai_deferred_init          │
#   │                                                                 │
#   │  First prompt displayed  ◄──────── user sees prompt here       │
#   │    └─ precmd: _zai_deferred_init()   (runs ONCE, then removes) │
#   │         ├─ _zai_ollama_check_health()  (network, ~50ms)        │
#   │         ├─ _zai_ollama_check_model()   (network, ~50ms)        │
#   │         └─ _zai_warmup_model() &       (background, ~2–10s)    │
#   └────────────────────────────────────────────────────────────────┘
#
# Plugin manager compatibility:
#   oh-my-zsh:  plugins/zsh-ai-complete/zsh-ai-complete.plugin.zsh
#               (add "zsh-ai-complete" to plugins array in .zshrc)
#   zinit:      zinit light <user>/zsh-ai-complete
#   antigen:    antigen bundle <user>/zsh-ai-complete
#   sheldon:    [plugins.zsh-ai-complete]
#               github = "<user>/zsh-ai-complete"
#   manual:     source /path/to/zsh-ai-complete/plugin/zsh-ai-complete.plugin.zsh
#
# Configuration (set before sourcing this file):
#   export ZSH_AI_COMPLETE_MODEL="qwen2.5-coder:7b"
#   export ZSH_AI_COMPLETE_OLLAMA_URL="http://localhost:11434"
#   export ZSH_AI_COMPLETE_DEBOUNCE="150"
#   export ZSH_AI_COMPLETE_TRIGGER="auto"   # or "manual"
#   See plugin/lib/config.zsh for the full list of configuration keys.
# ==============================================================================

# Guard against double-sourcing.
# If this plugin is included in both the manual source and a plugin manager,
# only the first load executes; subsequent sources are silent no-ops.
(( ${+_ZAI_PLUGIN_LOADED} )) && return 0
typeset -gi _ZAI_PLUGIN_LOADED=1

# ==============================================================================
# Base directory detection
#
# ${0:a:h} resolves the directory of THIS file, not the caller's directory:
#   :a  — expand to absolute path, resolving symlinks (like readlink -f)
#   :h  — strip the filename component (head = directory)
#
# This works correctly with all plugin managers because each manager sets $0
# to the path of the file being sourced before invoking source/. on it.
#
# Examples:
#   Direct source:   $0 = /home/user/.zshrc → wrong, but ${(%):-%x} is used
#   oh-my-zsh:       $0 = /home/user/.oh-my-zsh/plugins/zsh-ai-complete/...
#   zinit:           $0 = /home/user/.local/share/zinit/plugins/.../...
#   antigen:         $0 = /home/user/.antigen/bundles/.../...
#
# Note: We use $0 directly because zsh sets $0 to the sourced file path when
# the shell is processing a sourced file (not inside a function). This file
# is sourced at the top level, so $0 is reliable.
# ==============================================================================
typeset -g _ZAI_PLUGIN_DIR="${0:a:h}"
typeset -g _ZAI_LIB_DIR="${_ZAI_PLUGIN_DIR}/lib"

# ==============================================================================
# Minimum zsh version check: 5.3+
#
# Required features introduced in zsh 5.3 (2016-05-15):
#   exec {fd}< <()    — automatic file descriptor number allocation
#   zle -F <fd> <fn>  — ZLE asynchronous file descriptor event callbacks
#   POSTDISPLAY       — ZLE post-display area (ghost text rendering)
#   add-zsh-hook      — reliable hook registration (also in earlier versions
#                        but the interface was stabilized in 5.x)
#
# We use is-at-least from the zsh/mathfunc module (available since zsh 4.1).
# If is-at-least cannot be autoloaded (very old zsh), fall back to string
# comparison of ZSH_VERSION.
# ==============================================================================
autoload -Uz is-at-least 2>/dev/null
if (( ${+functions[is-at-least]} )); then
  if ! is-at-least 5.3; then
    print -u2 "zsh-ai-complete: ERROR — zsh 5.3 or newer is required."
    print -u2 "  Current version: ${ZSH_VERSION}"
    print -u2 "  Required for: exec {fd}< <(), zle -F, POSTDISPLAY"
    return 1
  fi
else
  # Fallback string comparison (lexicographic — works for X.Y.Z format)
  if [[ "${ZSH_VERSION}" < "5.3" ]]; then
    print -u2 "zsh-ai-complete: ERROR — zsh 5.3 or newer is required."
    print -u2 "  Current version: ${ZSH_VERSION}"
    return 1
  fi
fi

# ==============================================================================
# Source all library modules in dependency order
#
# Each module:
#   - Guards against double-sourcing via a typeset -gi _ZAI_*_LOADED=1 flag
#   - Uses 'builtin source' to bypass any user-defined 'source' shell function
#   - Returns 1 on internal error (propagated here via || return 1)
#
# Source order matches the dependency graph:
#   config → security → context → prompt → ollama → suggestion → async
#          → keybindings → init
#
# Rationale for this specific order:
#   - config first: all other modules call _zai_config_get at load time
#   - security before context: context filters entries through security
#   - context before prompt: prompt calls context gathering functions
#   - ollama independently after config: no context/prompt dependency
#   - suggestion independently after config: no context/prompt dependency
#   - async after ollama+prompt+suggestion: spawns subshells that call all three
#   - keybindings after async+suggestion: widgets call debounce/request/clear
#   - init last: calls register_widgets/bind_keys/check_health which need all above
# ==============================================================================

# ── Phase 1: Foundation ──────────────────────────────────────────────────────
# config.zsh has no dependencies — must be sourced first.
builtin source "${_ZAI_LIB_DIR}/config.zsh" || {
  print -u2 "zsh-ai-complete: ERROR — failed to source lib/config.zsh"
  return 1
}

# ── Phase 2: Security + Context pipeline ─────────────────────────────────────
builtin source "${_ZAI_LIB_DIR}/security.zsh" || {
  print -u2 "zsh-ai-complete: ERROR — failed to source lib/security.zsh"
  return 1
}

builtin source "${_ZAI_LIB_DIR}/context.zsh" || {
  print -u2 "zsh-ai-complete: ERROR — failed to source lib/context.zsh"
  return 1
}

# ── Phase 3: Prompt engineering ───────────────────────────────────────────────
builtin source "${_ZAI_LIB_DIR}/prompt.zsh" || {
  print -u2 "zsh-ai-complete: ERROR — failed to source lib/prompt.zsh"
  return 1
}

# ── Phase 4: Ollama client + Suggestion manager (independent of each other) ───
builtin source "${_ZAI_LIB_DIR}/ollama.zsh" || {
  print -u2 "zsh-ai-complete: ERROR — failed to source lib/ollama.zsh"
  return 1
}

builtin source "${_ZAI_LIB_DIR}/suggestion.zsh" || {
  print -u2 "zsh-ai-complete: ERROR — failed to source lib/suggestion.zsh"
  return 1
}

# ── Phase 5: Async engine (depends on ollama + prompt + suggestion) ───────────
builtin source "${_ZAI_LIB_DIR}/async.zsh" || {
  print -u2 "zsh-ai-complete: ERROR — failed to source lib/async.zsh"
  return 1
}

# ── Phase 6: Keybinding manager (depends on async + suggestion) ───────────────
builtin source "${_ZAI_LIB_DIR}/keybindings.zsh" || {
  print -u2 "zsh-ai-complete: ERROR — failed to source lib/keybindings.zsh"
  return 1
}

# ── Phase 7: Initialization logic (depends on all above) ─────────────────────
builtin source "${_ZAI_LIB_DIR}/init.zsh" || {
  print -u2 "zsh-ai-complete: ERROR — failed to source lib/init.zsh"
  return 1
}

# ==============================================================================
# Synchronous initialization
#
# _zai_init() is the main synchronous setup function defined in lib/init.zsh.
# It must complete in <20ms (out of the 100ms total startup budget).
#
# EPOCHREALTIME is a zsh 5.x float variable giving seconds since epoch with
# sub-second precision. We use it to measure the actual init duration and store
# it for debugging/regression detection. Users can check:
#   print "Init time: ${_ZAI_INIT_DURATION_MS}ms"
#
# NOTE: 'local' is only valid inside functions in zsh. Top-level timing uses
# namespaced globals (_ZAI_INIT_T0/T1) that are unset after use to avoid
# polluting the shell environment.
# ==============================================================================

# Capture start time (float seconds with microsecond precision)
_ZAI_INIT_T0="${EPOCHREALTIME}"

# Run synchronous init — must complete in <20ms
_zai_init

# Capture end time and compute duration in milliseconds
_ZAI_INIT_T1="${EPOCHREALTIME}"

# Format as "X.XX" milliseconds string for debugging / regression detection.
# EPOCHREALTIME is a float (e.g. "1711900800.123456"); arithmetic gives ms.
printf -v _ZAI_INIT_DURATION_MS '%.2f' "$(( (_ZAI_INIT_T1 - _ZAI_INIT_T0) * 1000.0 ))"

# Clean up temp timing variables — don't leave _T0/_T1 in the environment
unset _ZAI_INIT_T0 _ZAI_INIT_T1
