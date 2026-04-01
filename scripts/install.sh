#!/usr/bin/env bash
# ==============================================================================
# zsh-ai-complete: Installation Script
# File: scripts/install.sh
# ==============================================================================
#
# Installs the zsh-ai-complete plugin into any zsh environment.
#
# Usage:
#   bash scripts/install.sh [OPTIONS]
#
# Options:
#   --method=<method>   Installation method: oh-my-zsh | zinit | antigen |
#                       sheldon | manual  (default: auto-detect)
#   --dir=<path>        Custom installation directory (manual method only)
#   --no-ollama-check   Skip Ollama availability check during install
#   --help              Show this help
#
# Supported plugin managers:
#   oh-my-zsh  — Symlinks plugin into ${ZSH}/custom/plugins/
#   zinit      — Symlinks plugin into zinit plugins directory
#   antigen    — Copies plugin into antigen bundles directory
#   sheldon    — Creates sheldon plugin config entry
#   manual     — Copies plugin to ~/.local/share/zsh-ai-complete/
#                and prints the source line to add to .zshrc
#
# Prerequisites:
#   - zsh 5.3+
#   - curl
#   - Ollama (running, with qwen2.5-coder model pulled) — for AI completions
#     (history-based completions work without Ollama)
#
# Security:
#   - Verifies zsh version before any installation
#   - Never writes to system directories without explicit --dir override
#   - Sets plugin directory permissions to 755, cache directory to 700
#   - Does NOT modify system files
#
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------
readonly PLUGIN_NAME="zsh-ai-complete"
readonly MIN_ZSH_MAJOR=5
readonly MIN_ZSH_MINOR=3
readonly DEFAULT_MODEL="qwen2.5-coder:7b"
readonly DEFAULT_OLLAMA_URL="${ZSH_AI_COMPLETE_OLLAMA_URL:-http://localhost:11434}"
readonly INSTALL_LOG="${HOME}/.cache/zsh-ai-complete/install.log"

# Text formatting
if [[ -t 1 ]]; then
  BOLD="\033[1m"
  GREEN="\033[0;32m"
  YELLOW="\033[1;33m"
  RED="\033[0;31m"
  BLUE="\033[0;34m"
  RESET="\033[0m"
else
  BOLD="" GREEN="" YELLOW="" RED="" BLUE="" RESET=""
fi

# ------------------------------------------------------------------------------
# Logging helpers
# ------------------------------------------------------------------------------
log_info()    { printf "${GREEN}✓${RESET} %s\n" "$*"; }
log_warn()    { printf "${YELLOW}⚠${RESET} %s\n" "$*" >&2; }
log_error()   { printf "${RED}✗${RESET} %s\n" "$*" >&2; }
log_step()    { printf "\n${BOLD}${BLUE}▶${RESET} ${BOLD}%s${RESET}\n" "$*"; }
log_detail()  { printf "  %s\n" "$*"; }

# ------------------------------------------------------------------------------
# Script directory detection — resolves symlinks to get the real source path
# Works with: bash, zsh, direct invocation, source, curl|bash
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
PLUGIN_SRC="${REPO_DIR}/plugin"

# ------------------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------------------
OPT_METHOD=""
OPT_DIR=""
OPT_NO_OLLAMA_CHECK=0
OPT_HELP=0

for arg in "$@"; do
  case "${arg}" in
    --method=*)   OPT_METHOD="${arg#--method=}" ;;
    --dir=*)      OPT_DIR="${arg#--dir=}" ;;
    --no-ollama-check) OPT_NO_OLLAMA_CHECK=1 ;;
    --help|-h)    OPT_HELP=1 ;;
    *)
      log_error "Unknown option: ${arg}"
      log_detail "Run: bash install.sh --help"
      exit 1
      ;;
  esac
done

# ------------------------------------------------------------------------------
# Help
# ------------------------------------------------------------------------------
if [[ "${OPT_HELP}" -eq 1 ]]; then
  cat <<EOF

${BOLD}zsh-ai-complete installer${RESET}

${BOLD}Usage:${RESET}
  bash scripts/install.sh [OPTIONS]

${BOLD}Options:${RESET}
  --method=<method>     oh-my-zsh | zinit | antigen | sheldon | manual
  --dir=<path>          Custom install path (manual method only)
  --no-ollama-check     Skip Ollama availability check
  --help                Show this help

${BOLD}Examples:${RESET}
  bash scripts/install.sh                      # auto-detect plugin manager
  bash scripts/install.sh --method=manual      # manual install to ~/.local/share/
  bash scripts/install.sh --method=oh-my-zsh   # install for oh-my-zsh

${BOLD}After installation, open a new terminal and verify:${RESET}
  print \$_ZAI_INIT_DURATION_MS    # should show startup time in ms
  _zai_config_dump                  # show effective configuration

EOF
  exit 0
fi

# ==============================================================================
# STEP 1: Verify prerequisites
# ==============================================================================
log_step "Checking prerequisites"

# -- 1a. Check that zsh is available and meets minimum version ----------------
if ! command -v zsh >/dev/null 2>&1; then
  log_error "zsh is not installed or not in PATH."
  log_detail "Install zsh via your package manager:"
  log_detail "  macOS:  brew install zsh"
  log_detail "  Ubuntu: sudo apt-get install zsh"
  log_detail "  Fedora: sudo dnf install zsh"
  exit 1
fi

ZSH_VER_STR="$(zsh --version | awk '{print $2}')"
ZSH_MAJOR="$(printf '%s' "${ZSH_VER_STR}" | cut -d. -f1)"
ZSH_MINOR="$(printf '%s' "${ZSH_VER_STR}" | cut -d. -f2)"

if [[ "${ZSH_MAJOR}" -lt "${MIN_ZSH_MAJOR}" ]] || \
   { [[ "${ZSH_MAJOR}" -eq "${MIN_ZSH_MAJOR}" ]] && [[ "${ZSH_MINOR}" -lt "${MIN_ZSH_MINOR}" ]]; }; then
  log_error "zsh ${ZSH_VER_STR} is below the minimum required version ${MIN_ZSH_MAJOR}.${MIN_ZSH_MINOR}."
  log_detail "Please upgrade zsh to 5.3 or newer."
  exit 1
fi
log_info "zsh ${ZSH_VER_STR} — meets minimum requirement (≥ ${MIN_ZSH_MAJOR}.${MIN_ZSH_MINOR})"

# -- 1b. Check curl -----------------------------------------------------------
if ! command -v curl >/dev/null 2>&1; then
  log_error "curl is not installed or not in PATH."
  log_detail "curl is required for Ollama API communication."
  log_detail "  macOS:  brew install curl"
  log_detail "  Ubuntu: sudo apt-get install curl"
  exit 1
fi
log_info "curl $(curl --version | head -1 | awk '{print $2}') — found"

# -- 1c. Check plugin source directory ----------------------------------------
if [[ ! -d "${PLUGIN_SRC}" ]]; then
  log_error "Plugin source directory not found: ${PLUGIN_SRC}"
  log_detail "This script must be run from the cloned repository directory."
  log_detail "Example: git clone https://github.com/<user>/${PLUGIN_NAME} && cd ${PLUGIN_NAME} && bash scripts/install.sh"
  exit 1
fi

if [[ ! -f "${PLUGIN_SRC}/${PLUGIN_NAME}.plugin.zsh" ]]; then
  log_error "Plugin main file not found: ${PLUGIN_SRC}/${PLUGIN_NAME}.plugin.zsh"
  log_detail "Repository may be incomplete. Try: git checkout HEAD -- plugin/"
  exit 1
fi
log_info "Plugin source: ${PLUGIN_SRC}"

# -- 1d. Ollama availability check (warn only — non-fatal) --------------------
if [[ "${OPT_NO_OLLAMA_CHECK}" -eq 0 ]]; then
  OLLAMA_REACHABLE=0
  if curl --silent --fail --max-time 2 "${DEFAULT_OLLAMA_URL}" >/dev/null 2>&1; then
    OLLAMA_REACHABLE=1
    log_info "Ollama is running at ${DEFAULT_OLLAMA_URL}"

    # Check if default model is available
    MODEL_NAME="${ZSH_AI_COMPLETE_MODEL:-${DEFAULT_MODEL}}"
    if curl --silent --fail --max-time 3 "${DEFAULT_OLLAMA_URL}/api/tags" 2>/dev/null \
       | grep -q "\"${MODEL_NAME}\"" 2>/dev/null; then
      log_info "Model '${MODEL_NAME}' is available"
    else
      log_warn "Model '${MODEL_NAME}' not found in Ollama."
      log_detail "Pull it after installation with: ollama pull ${MODEL_NAME}"
    fi
  else
    log_warn "Ollama is not running at ${DEFAULT_OLLAMA_URL} (non-fatal)."
    log_detail "AI completions require Ollama. Start it with: ollama serve"
    log_detail "Then pull the model: ollama pull ${DEFAULT_MODEL}"
    log_detail "History-based suggestions will work without Ollama."
  fi
fi

# ==============================================================================
# STEP 2: Auto-detect plugin manager (if --method not specified)
# ==============================================================================
log_step "Detecting installation method"

if [[ -z "${OPT_METHOD}" ]]; then
  # Priority: oh-my-zsh > zinit > antigen > sheldon > manual
  if [[ -n "${ZSH:-}" ]] && [[ -d "${ZSH}/custom/plugins" ]]; then
    OPT_METHOD="oh-my-zsh"
    log_info "Detected: oh-my-zsh (ZSH=${ZSH})"
  elif [[ -d "${ZINIT_HOME:-${HOME}/.local/share/zinit}" ]]; then
    OPT_METHOD="zinit"
    log_info "Detected: zinit"
  elif [[ -d "${ADOTDIR:-${HOME}/.antigen}" ]]; then
    OPT_METHOD="antigen"
    log_info "Detected: antigen"
  elif command -v sheldon >/dev/null 2>&1; then
    OPT_METHOD="sheldon"
    log_info "Detected: sheldon"
  else
    OPT_METHOD="manual"
    log_info "No plugin manager detected — using manual installation"
  fi
else
  log_info "Installation method: ${OPT_METHOD} (explicit)"
fi

# Validate method
case "${OPT_METHOD}" in
  oh-my-zsh|zinit|antigen|sheldon|manual) ;;
  *)
    log_error "Unknown installation method: '${OPT_METHOD}'"
    log_detail "Valid methods: oh-my-zsh, zinit, antigen, sheldon, manual"
    exit 1
    ;;
esac

# ==============================================================================
# STEP 3: Install plugin
# ==============================================================================
log_step "Installing plugin (method: ${OPT_METHOD})"

# Helper: safely create a directory with specific permissions
_install_mkdir() {
  local dir="${1}"
  local mode="${2:-755}"
  if [[ ! -d "${dir}" ]]; then
    mkdir -p "${dir}"
  fi
  chmod "${mode}" "${dir}"
}

# Helper: copy plugin files preserving structure
_install_copy_plugin() {
  local dest_dir="${1}"
  _install_mkdir "${dest_dir}" "755"
  cp -R "${PLUGIN_SRC}/." "${dest_dir}/"
  # Set permissions on lib files
  chmod 644 "${dest_dir}"/*.zsh 2>/dev/null || true
  chmod 644 "${dest_dir}/lib/"*.zsh 2>/dev/null || true
  log_info "Plugin files copied to: ${dest_dir}"
}

# Helper: create a symlink (replacing any existing link/file)
_install_symlink() {
  local src="${1}"
  local dst="${2}"
  if [[ -L "${dst}" ]]; then
    rm "${dst}"
  elif [[ -e "${dst}" ]]; then
    log_warn "Removing existing non-symlink at ${dst} (backup: ${dst}.bak)"
    mv "${dst}" "${dst}.bak"
  fi
  ln -s "${src}" "${dst}"
  log_info "Symlink: ${dst} → ${src}"
}

case "${OPT_METHOD}" in

  # ── oh-my-zsh ──────────────────────────────────────────────────────────────
  oh-my-zsh)
    OMZ_PLUGINS_DIR="${ZSH}/custom/plugins"
    DEST_DIR="${OMZ_PLUGINS_DIR}/${PLUGIN_NAME}"

    # Verify we're not installing to a world-writable directory (security check)
    if [[ "$(stat -f '%Mp%Lp' "${OMZ_PLUGINS_DIR}" 2>/dev/null || stat -c '%a' "${OMZ_PLUGINS_DIR}" 2>/dev/null)" =~ [0-9][2367][2367]$ ]]; then
      log_warn "Plugin directory has permissive permissions: ${OMZ_PLUGINS_DIR}"
      log_detail "Consider: chmod 755 ${OMZ_PLUGINS_DIR}"
    fi

    if [[ -d "${DEST_DIR}" ]]; then
      log_warn "Plugin directory already exists: ${DEST_DIR}"
      log_detail "Updating existing installation..."
      rm -rf "${DEST_DIR}"
    fi

    _install_symlink "${PLUGIN_SRC}" "${DEST_DIR}"

    cat <<EOF

${BOLD}${GREEN}✓ oh-my-zsh installation complete!${RESET}

Add '${PLUGIN_NAME}' to your plugins list in ~/.zshrc:

  ${BOLD}plugins=(... ${PLUGIN_NAME})${RESET}

Then reload your shell:
  ${BOLD}exec zsh${RESET}

EOF
    ;;

  # ── zinit ──────────────────────────────────────────────────────────────────
  zinit)
    ZINIT_HOME="${ZINIT_HOME:-${HOME}/.local/share/zinit}"
    ZINIT_PLUGINS_DIR="${ZINIT_HOME}/plugins"
    ZINIT_PLUGIN_DIR="${ZINIT_PLUGINS_DIR}/local---${PLUGIN_NAME}"

    _install_mkdir "${ZINIT_PLUGINS_DIR}" "755"

    if [[ -d "${ZINIT_PLUGIN_DIR}" ]]; then
      log_warn "Existing zinit plugin directory found. Updating..."
      rm -rf "${ZINIT_PLUGIN_DIR}"
    fi

    _install_symlink "${PLUGIN_SRC}" "${ZINIT_PLUGIN_DIR}"

    cat <<EOF

${BOLD}${GREEN}✓ zinit installation complete!${RESET}

Add to your ~/.zshrc (before zinit ice calls):

  ${BOLD}zinit light local/${PLUGIN_NAME}${RESET}

Or to load from this local directory directly:

  ${BOLD}zinit load ${PLUGIN_SRC}${RESET}

Then reload your shell:
  ${BOLD}exec zsh${RESET}

EOF
    ;;

  # ── antigen ────────────────────────────────────────────────────────────────
  antigen)
    ANTIGEN_DIR="${ADOTDIR:-${HOME}/.antigen}"
    DEST_DIR="${ANTIGEN_DIR}/bundles/local/${PLUGIN_NAME}"

    _install_mkdir "$(dirname "${DEST_DIR}")" "755"

    if [[ -d "${DEST_DIR}" ]]; then
      log_warn "Existing antigen bundle directory found. Updating..."
      rm -rf "${DEST_DIR}"
    fi

    _install_copy_plugin "${DEST_DIR}"

    cat <<EOF

${BOLD}${GREEN}✓ antigen installation complete!${RESET}

Add to your ~/.zshrc:

  ${BOLD}antigen bundle local/${PLUGIN_NAME}${RESET}

Or to source directly:

  ${BOLD}source ${PLUGIN_SRC}/${PLUGIN_NAME}.plugin.zsh${RESET}

Then reload your shell:
  ${BOLD}source ~/.zshrc${RESET}

EOF
    ;;

  # ── sheldon ────────────────────────────────────────────────────────────────
  sheldon)
    SHELDON_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/sheldon"
    SHELDON_PLUGINS_FILE="${SHELDON_CONFIG_DIR}/plugins.toml"

    _install_mkdir "${SHELDON_CONFIG_DIR}" "755"

    # Check if plugin is already configured
    if [[ -f "${SHELDON_PLUGINS_FILE}" ]] && grep -q "\[plugins.${PLUGIN_NAME}\]" "${SHELDON_PLUGINS_FILE}" 2>/dev/null; then
      log_warn "Plugin '${PLUGIN_NAME}' already exists in ${SHELDON_PLUGINS_FILE}"
      log_detail "Edit manually to update the path."
    else
      # Append sheldon plugin config
      cat >> "${SHELDON_PLUGINS_FILE}" <<TOML

[plugins.${PLUGIN_NAME}]
local = "${PLUGIN_SRC}"
TOML
      log_info "Added plugin config to: ${SHELDON_PLUGINS_FILE}"
    fi

    cat <<EOF

${BOLD}${GREEN}✓ sheldon installation complete!${RESET}

Plugin config added to: ${SHELDON_PLUGINS_FILE}

Rebuild sheldon cache:
  ${BOLD}sheldon lock${RESET}

Then add to your ~/.zshrc (if not already present):
  ${BOLD}eval "\$(sheldon source)"${RESET}

Then reload your shell:
  ${BOLD}exec zsh${RESET}

EOF
    ;;

  # ── manual ─────────────────────────────────────────────────────────────────
  manual)
    if [[ -n "${OPT_DIR}" ]]; then
      DEST_DIR="${OPT_DIR}"
    else
      DEST_DIR="${HOME}/.local/share/${PLUGIN_NAME}"
    fi

    if [[ -d "${DEST_DIR}" ]]; then
      log_warn "Existing installation found at: ${DEST_DIR}"
      log_detail "Removing old version before installing new one..."
      rm -rf "${DEST_DIR}"
    fi

    _install_copy_plugin "${DEST_DIR}"
    _install_mkdir "${DEST_DIR}/lib" "755"

    PLUGIN_FILE="${DEST_DIR}/${PLUGIN_NAME}.plugin.zsh"

    cat <<EOF

${BOLD}${GREEN}✓ Manual installation complete!${RESET}

Add the following line to your ~/.zshrc:

  ${BOLD}source ${PLUGIN_FILE}${RESET}

Optional configuration (add BEFORE the source line):

  # Ollama settings
  export ZSH_AI_COMPLETE_OLLAMA_URL="http://localhost:11434"
  export ZSH_AI_COMPLETE_MODEL="qwen2.5-coder:7b"

  # Completion behavior
  export ZSH_AI_COMPLETE_TRIGGER="auto"    # or "manual" (Ctrl+Space only)
  export ZSH_AI_COMPLETE_DEBOUNCE="150"    # ms delay before requesting completion
  export ZSH_AI_COMPLETE_TIMEOUT="4"       # seconds before aborting request

Then reload your shell:
  ${BOLD}exec zsh${RESET}

EOF
    ;;
esac

# ==============================================================================
# STEP 4: Create cache directory with secure permissions
# ==============================================================================
log_step "Setting up cache directory"

CACHE_DIR="${HOME}/.cache/zsh-ai-complete"
_install_mkdir "${CACHE_DIR}" "700"
log_info "Cache directory: ${CACHE_DIR} (mode 700)"

# Write install log (permissions: 600 — no group/world read)
_install_mkdir "${CACHE_DIR}" "700"
{
  echo "install_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "method=${OPT_METHOD}"
  echo "zsh_version=${ZSH_VER_STR}"
  echo "plugin_src=${PLUGIN_SRC}"
  echo "installer_version=1.0.0"
} > "${INSTALL_LOG}" 2>/dev/null || true
chmod 600 "${INSTALL_LOG}" 2>/dev/null || true

# ==============================================================================
# STEP 5: Post-install verification
# ==============================================================================
log_step "Verifying installation"

# Syntax-check the main plugin file
if zsh -n "${PLUGIN_SRC}/${PLUGIN_NAME}.plugin.zsh" 2>/dev/null; then
  log_info "Plugin syntax check: OK"
else
  log_warn "Plugin syntax check reported warnings (see above)"
fi

# Syntax-check lib files
SYNTAX_OK=1
for lib_file in "${PLUGIN_SRC}/lib/"*.zsh; do
  if ! zsh -n "${lib_file}" 2>/dev/null; then
    log_error "Syntax error in: ${lib_file}"
    SYNTAX_OK=0
  fi
done
if [[ "${SYNTAX_OK}" -eq 1 ]]; then
  log_info "All lib files syntax check: OK"
fi

# ==============================================================================
# STEP 6: Final summary
# ==============================================================================
log_step "Installation summary"

log_detail "Plugin name:    ${PLUGIN_NAME}"
log_detail "Method:         ${OPT_METHOD}"
log_detail "Cache dir:      ${CACHE_DIR}"
log_detail "zsh version:    ${ZSH_VER_STR}"
log_detail "Default model:  ${DEFAULT_MODEL}"

printf "\n"

if [[ "${OPT_NO_OLLAMA_CHECK}" -eq 0 ]] && [[ "${OLLAMA_REACHABLE:-0}" -eq 0 ]]; then
  log_warn "Remember to start Ollama before using AI completions:"
  log_detail "  1. ollama serve"
  log_detail "  2. ollama pull ${DEFAULT_MODEL}"
fi

printf "\n${BOLD}${GREEN}Installation complete!${RESET} Open a new terminal or reload your shell.\n\n"
printf "Quick verification:\n"
printf "  ${BOLD}print \$_ZAI_INIT_DURATION_MS${RESET}   # startup overhead in ms\n"
printf "  ${BOLD}_zai_config_dump${RESET}               # show active configuration\n\n"
