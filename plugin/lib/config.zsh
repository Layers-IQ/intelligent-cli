# ==============================================================================
# zsh-ai-complete: Configuration Module
# File: plugin/lib/config.zsh
# ==============================================================================
#
# Provides all user-configurable settings via a priority chain:
#
#   1. Environment variables  ZSH_AI_COMPLETE_<KEY>   — highest priority
#   2. Runtime overrides      _zai_config_set key val  — persists for session
#   3. zstyle                 ':zai:config' key value  — zsh-native config
#   4. Built-in defaults      _ZAI_CONFIG_DEFAULTS[key] — lowest priority
#
# Available configuration keys and their defaults:
#
#   ollama_url     http://localhost:11434   Base URL for Ollama HTTP API
#   model          qwen2.5-coder:7b         Ollama model to use
#   debounce       150                      Keystroke debounce delay (ms)
#   timeout        4                        HTTP request timeout (seconds)
#   trigger        auto                     Completion trigger: auto | manual
#   history_size   20                       Number of history entries to use
#   dir_limit      50                       Max directory entries in context
#   min_chars      3                        Min buffer length before triggering
#   highlight_style fg=8                    ZLE region_highlight style for ghost text
#
# Usage:
#   _zai_config_get debounce          # → 150 (or env/zstyle/override value)
#   _zai_config_set debounce 200      # runtime override with validation
#
#   # Environment variable override:
#   export ZSH_AI_COMPLETE_DEBOUNCE=200
#
#   # zstyle override (add to .zshrc before sourcing plugin):
#   zstyle ':zai:config' debounce 200
#
# ==============================================================================

# Guard against double-sourcing
(( ${+_ZAI_CONFIG_LOADED} )) && return 0
typeset -gi _ZAI_CONFIG_LOADED=1

# ==============================================================================
# Default values — O(1) associative array lookup
# ==============================================================================

typeset -gA _ZAI_CONFIG_DEFAULTS
_ZAI_CONFIG_DEFAULTS=(
  ollama_url       "http://localhost:11434"
  model            "qwen2.5-coder:7b"
  debounce         "150"
  timeout          "4"
  trigger          "auto"
  history_size     "20"
  dir_limit        "50"
  min_chars        "3"
  highlight_style  "fg=8"
)

# Runtime overrides — populated by _zai_config_set
typeset -gA _ZAI_CONFIG_OVERRIDES

# ==============================================================================
# Internal: Input validation
# ==============================================================================

# _zai_config_is_positive_integer <value>
# Returns 0 if value is a positive integer (>0), 1 otherwise.
_zai_config_is_positive_integer() {
  local val="${1}"
  [[ "${val}" =~ ^[0-9]+$ ]] && (( val > 0 ))
}

# _zai_config_validate <key> <value>
# Validates a value for a given config key.
# Prints an error to stderr and returns 1 on failure.
# Returns 0 if valid (or key is unknown — unknown keys emit a warning only).
_zai_config_validate() {
  local key="${1}"
  local val="${2}"

  case "${key}" in

    debounce)
      if ! _zai_config_is_positive_integer "${val}"; then
        print -u2 "zsh-ai-complete: config: 'debounce' must be a positive integer, got '${val}'"
        return 1
      fi
      if (( val < 10 || val > 10000 )); then
        print -u2 "zsh-ai-complete: config: 'debounce' must be 10–10000 ms, got '${val}'"
        return 1
      fi
      ;;

    timeout)
      if ! _zai_config_is_positive_integer "${val}"; then
        print -u2 "zsh-ai-complete: config: 'timeout' must be a positive integer, got '${val}'"
        return 1
      fi
      if (( val < 1 || val > 120 )); then
        print -u2 "zsh-ai-complete: config: 'timeout' must be 1–120 seconds, got '${val}'"
        return 1
      fi
      ;;

    history_size)
      if ! _zai_config_is_positive_integer "${val}"; then
        print -u2 "zsh-ai-complete: config: 'history_size' must be a positive integer, got '${val}'"
        return 1
      fi
      if (( val > 1000 )); then
        print -u2 "zsh-ai-complete: config: 'history_size' must be ≤ 1000, got '${val}'"
        return 1
      fi
      ;;

    dir_limit)
      if ! _zai_config_is_positive_integer "${val}"; then
        print -u2 "zsh-ai-complete: config: 'dir_limit' must be a positive integer, got '${val}'"
        return 1
      fi
      if (( val > 5000 )); then
        print -u2 "zsh-ai-complete: config: 'dir_limit' must be ≤ 5000, got '${val}'"
        return 1
      fi
      ;;

    min_chars)
      if ! _zai_config_is_positive_integer "${val}"; then
        print -u2 "zsh-ai-complete: config: 'min_chars' must be a positive integer, got '${val}'"
        return 1
      fi
      if (( val > 100 )); then
        print -u2 "zsh-ai-complete: config: 'min_chars' must be ≤ 100, got '${val}'"
        return 1
      fi
      ;;

    trigger)
      if [[ "${val}" != "auto" && "${val}" != "manual" ]]; then
        print -u2 "zsh-ai-complete: config: 'trigger' must be 'auto' or 'manual', got '${val}'"
        return 1
      fi
      ;;

    ollama_url)
      if [[ -z "${val}" ]]; then
        print -u2 "zsh-ai-complete: config: 'ollama_url' must not be empty"
        return 1
      fi
      ;;

    model)
      if [[ -z "${val}" ]]; then
        print -u2 "zsh-ai-complete: config: 'model' must not be empty"
        return 1
      fi
      ;;

    highlight_style)
      if [[ -z "${val}" ]]; then
        print -u2 "zsh-ai-complete: config: 'highlight_style' must not be empty"
        return 1
      fi
      ;;

    *)
      # Unknown key — warn but do not reject (forward-compat)
      print -u2 "zsh-ai-complete: config: warning: unknown configuration key '${key}'"
      ;;
  esac

  return 0
}

# ==============================================================================
# _zai_config_get <key>
#
# Returns the effective configuration value for <key> by checking:
#   1. Environment variable  ZSH_AI_COMPLETE_<UPPER_KEY>
#   2. Runtime override      _ZAI_CONFIG_OVERRIDES[key]
#   3. zstyle                ':zai:config' <key>
#   4. Default               _ZAI_CONFIG_DEFAULTS[key]
#
# Outputs the value on stdout. Returns 1 if the key is completely unknown.
# ==============================================================================
_zai_config_get() {
  local key="${1}"

  if [[ -z "${key}" ]]; then
    print -u2 "zsh-ai-complete: _zai_config_get: key argument is required"
    return 1
  fi

  # ── 1. Environment variable: ZSH_AI_COMPLETE_<UPPER_KEY> ──────────────────
  # e.g., key=debounce → ZSH_AI_COMPLETE_DEBOUNCE
  #       key=ollama_url → ZSH_AI_COMPLETE_OLLAMA_URL
  local upper_key="${(U)key}"
  local env_var="ZSH_AI_COMPLETE_${upper_key}"
  # Use (P) parameter flag for indirect expansion (no eval needed)
  local env_val="${(P)env_var}"
  if [[ -n "${env_val}" ]]; then
    print -- "${env_val}"
    return 0
  fi

  # ── 2. Runtime override (set via _zai_config_set) ─────────────────────────
  if (( ${+_ZAI_CONFIG_OVERRIDES[${key}]} )); then
    print -- "${_ZAI_CONFIG_OVERRIDES[${key}]}"
    return 0
  fi

  # ── 3. zstyle ':zai:config' <key> ─────────────────────────────────────────
  # Users set: zstyle ':zai:config' debounce 250
  local zstyle_val
  if zstyle -s ':zai:config' "${key}" zstyle_val 2>/dev/null && [[ -n "${zstyle_val}" ]]; then
    print -- "${zstyle_val}"
    return 0
  fi

  # ── 4. Built-in default ────────────────────────────────────────────────────
  if (( ${+_ZAI_CONFIG_DEFAULTS[${key}]} )); then
    print -- "${_ZAI_CONFIG_DEFAULTS[${key}]}"
    return 0
  fi

  # Key not found anywhere
  return 1
}

# ==============================================================================
# _zai_config_set <key> <value>
#
# Stores a validated runtime override for <key>. The override persists for the
# remainder of the shell session and takes precedence over zstyle and defaults
# but NOT over environment variables.
#
# Returns 0 on success, 1 if key is unknown or value fails validation.
# ==============================================================================
_zai_config_set() {
  local key="${1}"
  local val="${2}"

  if [[ -z "${key}" ]]; then
    print -u2 "zsh-ai-complete: _zai_config_set: key argument is required"
    return 1
  fi

  # Key must be a known configuration key
  if ! (( ${+_ZAI_CONFIG_DEFAULTS[${key}]} )); then
    print -u2 "zsh-ai-complete: _zai_config_set: unknown key '${key}'"
    return 1
  fi

  # Validate value for this key
  if ! _zai_config_validate "${key}" "${val}"; then
    return 1
  fi

  # Store in overrides array
  _ZAI_CONFIG_OVERRIDES[${key}]="${val}"
  return 0
}

# ==============================================================================
# _zai_config_dump
#
# Debug helper: prints all effective configuration values to stdout.
# Useful for troubleshooting: run `_zai_config_dump` from your shell.
# ==============================================================================
_zai_config_dump() {
  local key
  print "zsh-ai-complete configuration:"
  for key in ollama_url model debounce timeout trigger history_size dir_limit min_chars highlight_style; do
    printf '  %-16s = %s\n' "${key}" "$(_zai_config_get "${key}")"
  done
}

# ==============================================================================
# _zai_config_reset
#
# Clears all runtime overrides, restoring env/zstyle/default resolution.
# Primarily used in tests to reset state between test cases.
# ==============================================================================
_zai_config_reset() {
  _ZAI_CONFIG_OVERRIDES=()
}
