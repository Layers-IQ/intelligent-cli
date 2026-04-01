#!/usr/bin/env bash
# ==============================================================================
# zsh-ai-complete: Uninstallation Script
# File: scripts/uninstall.sh
# ==============================================================================
#
# Removes the zsh-ai-complete plugin from the current system.
#
# Usage:
#   bash scripts/uninstall.sh [OPTIONS]
#
# Options:
#   --method=<method>   oh-my-zsh | zinit | antigen | sheldon | manual | all
#                       (default: auto-detect from install log)
#   --purge             Also remove cache directory (~/.cache/zsh-ai-complete/)
#   --help              Show this help
#
# The script removes plugin files/symlinks and prints instructions for removing
# the source line from .zshrc — it does NOT automatically modify .zshrc.
#
# ==============================================================================

set -euo pipefail

readonly PLUGIN_NAME="zsh-ai-complete"
readonly CACHE_DIR="${HOME}/.cache/zsh-ai-complete"
readonly INSTALL_LOG="${CACHE_DIR}/install.log"

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

log_info()   { printf "${GREEN}✓${RESET} %s\n" "$*"; }
log_warn()   { printf "${YELLOW}⚠${RESET} %s\n" "$*" >&2; }
log_error()  { printf "${RED}✗${RESET} %s\n" "$*" >&2; }
log_step()   { printf "\n${BOLD}${BLUE}▶${RESET} ${BOLD}%s${RESET}\n" "$*"; }
log_detail() { printf "  %s\n" "$*"; }

# Parse arguments
OPT_METHOD=""
OPT_PURGE=0
OPT_HELP=0

for arg in "$@"; do
  case "${arg}" in
    --method=*) OPT_METHOD="${arg#--method=}" ;;
    --purge)    OPT_PURGE=1 ;;
    --help|-h)  OPT_HELP=1 ;;
    *)
      log_error "Unknown option: ${arg}"
      log_detail "Run: bash uninstall.sh --help"
      exit 1
      ;;
  esac
done

if [[ "${OPT_HELP}" -eq 1 ]]; then
  cat <<EOF

${BOLD}zsh-ai-complete uninstaller${RESET}

${BOLD}Usage:${RESET}
  bash scripts/uninstall.sh [OPTIONS]

${BOLD}Options:${RESET}
  --method=<method>   oh-my-zsh | zinit | antigen | sheldon | manual | all
  --purge             Also remove cache directory
  --help              Show this help

EOF
  exit 0
fi

# ==============================================================================
# Detect installed method from log (if not specified)
# ==============================================================================
log_step "Detecting installation"

DETECTED_METHOD=""
if [[ -f "${INSTALL_LOG}" ]]; then
  DETECTED_METHOD="$(grep '^method=' "${INSTALL_LOG}" | cut -d= -f2 2>/dev/null || true)"
  log_info "Found install log: method=${DETECTED_METHOD}"
fi

if [[ -z "${OPT_METHOD}" ]]; then
  if [[ -n "${DETECTED_METHOD}" ]]; then
    OPT_METHOD="${DETECTED_METHOD}"
    log_info "Using detected method: ${OPT_METHOD}"
  else
    OPT_METHOD="all"
    log_warn "No install log found — scanning all possible locations"
  fi
fi

# ==============================================================================
# Remove by method
# ==============================================================================
log_step "Removing plugin files (method: ${OPT_METHOD})"

_remove_if_exists() {
  local path="${1}"
  local label="${2:-}"
  if [[ -L "${path}" ]]; then
    rm "${path}"
    log_info "Removed symlink: ${path}"
  elif [[ -d "${path}" ]]; then
    rm -rf "${path}"
    log_info "Removed directory: ${path}"
  elif [[ -e "${path}" ]]; then
    rm -f "${path}"
    log_info "Removed file: ${path}"
  else
    log_detail "Not found (already removed?): ${path}"
  fi
}

_uninstall_oh_my_zsh() {
  local omz_dir="${ZSH:-${HOME}/.oh-my-zsh}/custom/plugins/${PLUGIN_NAME}"
  _remove_if_exists "${omz_dir}" "oh-my-zsh plugin"
  printf "\n${YELLOW}Remove from oh-my-zsh:${RESET}\n"
  printf "  Edit ~/.zshrc and remove '${PLUGIN_NAME}' from your plugins=(...) list\n"
}

_uninstall_zinit() {
  local zinit_home="${ZINIT_HOME:-${HOME}/.local/share/zinit}"
  local zinit_dir="${zinit_home}/plugins/local---${PLUGIN_NAME}"
  _remove_if_exists "${zinit_dir}" "zinit plugin"
  printf "\n${YELLOW}Remove from zinit:${RESET}\n"
  printf "  Edit ~/.zshrc and remove the zinit load/light line for '${PLUGIN_NAME}'\n"
}

_uninstall_antigen() {
  local antigen_dir="${ADOTDIR:-${HOME}/.antigen}/bundles/local/${PLUGIN_NAME}"
  _remove_if_exists "${antigen_dir}" "antigen bundle"
  printf "\n${YELLOW}Remove from antigen:${RESET}\n"
  printf "  Edit ~/.zshrc and remove: antigen bundle local/${PLUGIN_NAME}\n"
  printf "  Then run: antigen reset\n"
}

_uninstall_sheldon() {
  local sheldon_config="${XDG_CONFIG_HOME:-${HOME}/.config}/sheldon/plugins.toml"
  if [[ -f "${sheldon_config}" ]]; then
    # Print what needs to be removed — do NOT auto-edit TOML (complex format)
    log_warn "Sheldon config found: ${sheldon_config}"
    printf "\n${YELLOW}Remove from sheldon manually:${RESET}\n"
    printf "  Edit ${sheldon_config} and remove the [plugins.${PLUGIN_NAME}] section:\n\n"
    # Show the relevant lines if they exist
    grep -n "${PLUGIN_NAME}" "${sheldon_config}" 2>/dev/null | while IFS= read -r line; do
      printf "    %s\n" "${line}"
    done || true
    printf "\n  Then run: sheldon lock\n"
  else
    log_detail "No sheldon config found at: ${sheldon_config}"
  fi
}

_uninstall_manual() {
  local manual_dir="${HOME}/.local/share/${PLUGIN_NAME}"
  _remove_if_exists "${manual_dir}" "manual install"
  printf "\n${YELLOW}Remove from .zshrc:${RESET}\n"
  printf "  Edit ~/.zshrc and remove the 'source' line for ${PLUGIN_NAME}\n"
}

case "${OPT_METHOD}" in
  oh-my-zsh) _uninstall_oh_my_zsh ;;
  zinit)     _uninstall_zinit ;;
  antigen)   _uninstall_antigen ;;
  sheldon)   _uninstall_sheldon ;;
  manual)    _uninstall_manual ;;
  all)
    _uninstall_oh_my_zsh
    _uninstall_zinit
    _uninstall_antigen
    _uninstall_sheldon
    _uninstall_manual
    ;;
  *)
    log_error "Unknown method: ${OPT_METHOD}"
    log_detail "Valid: oh-my-zsh, zinit, antigen, sheldon, manual, all"
    exit 1
    ;;
esac

# ==============================================================================
# Remove cache directory (optional --purge)
# ==============================================================================
if [[ "${OPT_PURGE}" -eq 1 ]]; then
  log_step "Purging cache directory"
  _remove_if_exists "${CACHE_DIR}" "cache"
else
  if [[ -d "${CACHE_DIR}" ]]; then
    log_warn "Cache directory preserved: ${CACHE_DIR}"
    log_detail "To remove it: rm -rf ${CACHE_DIR}"
    log_detail "Or re-run with: --purge"
  fi
fi

# ==============================================================================
# Final instructions
# ==============================================================================
log_step "Uninstallation complete"

printf "\n${BOLD}Next steps:${RESET}\n"
printf "  1. Remove the source or plugin-manager entry from ~/.zshrc\n"
printf "  2. Open a new terminal or run: exec zsh\n"
printf "  3. Verify plugin is gone: type _zai_init → 'command not found' expected\n\n"
