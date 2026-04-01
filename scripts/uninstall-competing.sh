#!/usr/bin/env bash
# ==============================================================================
# zsh-ai-complete: Remove Competing Autocomplete Tools
# File: scripts/uninstall-competing.sh
# ==============================================================================
#
# Detects and removes zsh autocomplete/inline-suggestion tools that conflict
# with zsh-ai-complete:
#   - zsh-autosuggestions  (brew package + .zshrc source line)
#   - kollzsh              (~/.kollzsh.zsh + .zshrc config block)
#   - ollama-inline-suggest (~/.ollama-inline-suggest.zsh + .zshrc config block)
#
# Usage:
#   bash scripts/uninstall-competing.sh [OPTIONS]
#
# Options:
#   --dry-run     Show what would be removed without making changes
#   --keep-files  Remove .zshrc entries only; keep tool config files on disk
#   --help        Show this help
#
# Safety:
#   - Always backs up ~/.zshrc to ~/.zshrc.bak.<timestamp> before editing
#   - Prints a summary of every change made
#   - Never removes files outside of ~/.zshrc and known tool config paths
#
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Text formatting
# ------------------------------------------------------------------------------
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

log_info()    { printf "${GREEN}✓${RESET} %s\n" "$*"; }
log_warn()    { printf "${YELLOW}⚠${RESET} %s\n" "$*" >&2; }
log_error()   { printf "${RED}✗${RESET} %s\n" "$*" >&2; }
log_step()    { printf "\n${BOLD}${BLUE}▶${RESET} ${BOLD}%s${RESET}\n" "$*"; }
log_detail()  { printf "  %s\n" "$*"; }
log_dry()     { printf "${YELLOW}[dry-run]${RESET} %s\n" "$*"; }

# ------------------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------------------
OPT_DRY_RUN=0
OPT_KEEP_FILES=0
OPT_HELP=0

for arg in "$@"; do
  case "${arg}" in
    --dry-run)     OPT_DRY_RUN=1 ;;
    --keep-files)  OPT_KEEP_FILES=1 ;;
    --help|-h)     OPT_HELP=1 ;;
    *)
      log_error "Unknown option: ${arg}"
      log_detail "Run: bash scripts/uninstall-competing.sh --help"
      exit 1
      ;;
  esac
done

if [[ "${OPT_HELP}" -eq 1 ]]; then
  cat <<EOF

${BOLD}Remove competing zsh autocomplete tools${RESET}

${BOLD}Usage:${RESET}
  bash scripts/uninstall-competing.sh [OPTIONS]

${BOLD}Options:${RESET}
  --dry-run       Preview changes without applying them
  --keep-files    Only clean .zshrc entries; keep config files on disk
  --help          Show this help

${BOLD}Tools removed:${RESET}
  zsh-autosuggestions   brew package + source line in .zshrc
  kollzsh               ~/.kollzsh.zsh + config block in .zshrc
  ollama-inline-suggest ~/.ollama-inline-suggest.zsh + config block in .zshrc

EOF
  exit 0
fi

# ------------------------------------------------------------------------------
# Globals
# ------------------------------------------------------------------------------
ZSHRC="${HOME}/.zshrc"
ZSHRC_BACKUP="${HOME}/.zshrc.bak.$(date +%Y%m%d_%H%M%S)"
CHANGES_MADE=0

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

# Backup .zshrc once before any edit
_backup_zshrc() {
  if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
    log_dry "Would backup: ${ZSHRC} → ${ZSHRC_BACKUP}"
    return
  fi
  if [[ ! -f "${ZSHRC}" ]]; then
    log_warn "~/.zshrc not found — nothing to edit"
    return
  fi
  cp "${ZSHRC}" "${ZSHRC_BACKUP}"
  log_info "Backed up: ${ZSHRC} → ${ZSHRC_BACKUP}"
}

# Remove lines from .zshrc that match a pattern (grep -E regex)
_remove_zshrc_lines() {
  local description="${1}"
  local pattern="${2}"

  if [[ ! -f "${ZSHRC}" ]]; then
    return
  fi

  if grep -qE "${pattern}" "${ZSHRC}" 2>/dev/null; then
    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
      log_dry "Would remove from .zshrc (${description}):"
      grep -nE "${pattern}" "${ZSHRC}" | while IFS= read -r line; do
        log_detail "  ${line}"
      done
    else
      # Use a temp file to avoid in-place sed portability issues (macOS vs Linux)
      local tmpfile
      tmpfile="$(mktemp)"
      grep -vE "${pattern}" "${ZSHRC}" > "${tmpfile}"
      mv "${tmpfile}" "${ZSHRC}"
      log_info "Removed from .zshrc: ${description}"
      CHANGES_MADE=1
    fi
  else
    log_detail "Not present in .zshrc: ${description}"
  fi
}

# Remove a file from disk
_remove_file() {
  local filepath="${1}"
  local label="${2}"

  if [[ "${OPT_KEEP_FILES}" -eq 1 ]]; then
    log_detail "Keeping file on disk (--keep-files): ${filepath}"
    return
  fi

  if [[ -f "${filepath}" ]]; then
    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
      log_dry "Would remove file: ${filepath}"
    else
      rm -f "${filepath}"
      log_info "Removed file: ${filepath} (${label})"
      CHANGES_MADE=1
    fi
  else
    log_detail "File not found (already removed?): ${filepath}"
  fi
}

# ==============================================================================
# STEP 1: Detect which tools are present
# ==============================================================================
log_step "Scanning for competing autocomplete tools"

HAS_AUTOSUGGESTIONS=0
HAS_KOLLZSH=0
HAS_OLLAMA_INLINE=0

# zsh-autosuggestions
if brew list zsh-autosuggestions >/dev/null 2>&1 || \
   grep -qE 'zsh-autosuggestions' "${ZSHRC}" 2>/dev/null; then
  HAS_AUTOSUGGESTIONS=1
  log_warn "Found: zsh-autosuggestions"
fi

# kollzsh
if [[ -f "${HOME}/.kollzsh.zsh" ]] || \
   grep -qE 'kollzsh' "${ZSHRC}" 2>/dev/null; then
  HAS_KOLLZSH=1
  log_warn "Found: kollzsh"
fi

# ollama-inline-suggest
if [[ -f "${HOME}/.ollama-inline-suggest.zsh" ]] || \
   grep -qE 'ollama-inline' "${ZSHRC}" 2>/dev/null; then
  HAS_OLLAMA_INLINE=1
  log_warn "Found: ollama-inline-suggest"
fi

if [[ "${HAS_AUTOSUGGESTIONS}" -eq 0 && "${HAS_KOLLZSH}" -eq 0 && "${HAS_OLLAMA_INLINE}" -eq 0 ]]; then
  log_info "No competing autocomplete tools detected."
  exit 0
fi

if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
  printf "\n${YELLOW}Dry-run mode — no changes will be made.${RESET}\n"
fi

# ==============================================================================
# STEP 2: Backup .zshrc
# ==============================================================================
log_step "Backing up .zshrc"
_backup_zshrc

# ==============================================================================
# STEP 3: Remove zsh-autosuggestions
# ==============================================================================
if [[ "${HAS_AUTOSUGGESTIONS}" -eq 1 ]]; then
  log_step "Removing zsh-autosuggestions"

  # Remove the source line from .zshrc
  _remove_zshrc_lines \
    "zsh-autosuggestions source line" \
    "zsh-autosuggestions"

  # Uninstall brew package
  if brew list zsh-autosuggestions >/dev/null 2>&1; then
    if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
      log_dry "Would run: brew uninstall zsh-autosuggestions"
    else
      brew uninstall zsh-autosuggestions
      log_info "Uninstalled brew package: zsh-autosuggestions"
      CHANGES_MADE=1
    fi
  else
    log_detail "Brew package not installed (already removed or installed differently)"
  fi
fi

# ==============================================================================
# STEP 4: Remove kollzsh
# ==============================================================================
if [[ "${HAS_KOLLZSH}" -eq 1 ]]; then
  log_step "Removing kollzsh"

  # Remove all kollzsh-related lines from .zshrc
  # Covers: plugins entry, env vars (KOLLZSH_*), and source line
  _remove_zshrc_lines \
    "kollzsh plugin entry in plugins=()" \
    "kollzsh"

  _remove_zshrc_lines \
    "KOLLZSH_* environment variables" \
    "^export KOLLZSH_"

  # Remove config file from disk
  _remove_file "${HOME}/.kollzsh.zsh" "kollzsh"
fi

# ==============================================================================
# STEP 5: Remove ollama-inline-suggest
# ==============================================================================
if [[ "${HAS_OLLAMA_INLINE}" -eq 1 ]]; then
  log_step "Removing ollama-inline-suggest"

  # Remove source line
  _remove_zshrc_lines \
    "ollama-inline-suggest source line" \
    "ollama-inline-suggest"

  # Remove env vars block
  _remove_zshrc_lines \
    "OLLAMA_INLINE_* environment variables" \
    "^export OLLAMA_INLINE_"

  # Remove the comment line that precedes the config block
  _remove_zshrc_lines \
    "ollama inline ghost-text comment" \
    "Ollama inline ghost-text"

  # Remove config file from disk
  _remove_file "${HOME}/.ollama-inline-suggest.zsh" "ollama-inline-suggest"
fi

# ==============================================================================
# STEP 6: Clean up residual blank lines in .zshrc (optional tidy-up)
# ==============================================================================
if [[ "${CHANGES_MADE}" -eq 1 ]] && [[ -f "${ZSHRC}" ]]; then
  log_step "Cleaning up blank lines in .zshrc"
  # Collapse 3+ consecutive blank lines into 2 (preserves intentional spacing)
  local tmpfile
  tmpfile="$(mktemp)"
  awk '/^$/{blank++; if(blank<=2) print; next} {blank=0; print}' "${ZSHRC}" > "${tmpfile}"
  mv "${tmpfile}" "${ZSHRC}"
  log_info "Collapsed excess blank lines"
fi

# ==============================================================================
# Summary
# ==============================================================================
log_step "Summary"

if [[ "${OPT_DRY_RUN}" -eq 1 ]]; then
  printf "\n${YELLOW}Dry-run complete — no changes were made.${RESET}\n"
  printf "Run without --dry-run to apply the changes.\n\n"
else
  if [[ "${CHANGES_MADE}" -eq 1 ]]; then
    printf "\n${BOLD}${GREEN}Competing tools removed.${RESET}\n\n"
    printf "  .zshrc backup: ${ZSHRC_BACKUP}\n"
    printf "  To restore:    cp ${ZSHRC_BACKUP} ${ZSHRC}\n\n"
    printf "Reload your shell to apply changes:\n"
    printf "  ${BOLD}exec zsh${RESET}\n\n"
  else
    printf "\nNo changes were needed.\n\n"
  fi
fi
