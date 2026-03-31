# ==============================================================================
# zsh-ai-complete: SecurityFilter Module
# File: plugin/lib/security.zsh
# ==============================================================================
#
# Filters and redacts sensitive data from all context sources before they are
# sent to the Ollama LLM.  Three layers of protection:
#
#   1. Filename filtering   _zai_is_sensitive_file / _zai_filter_directory_entries
#                           Keeps .env, *.key, *.pem, credentials files, etc.
#                           out of the directory-listing context.
#
#   2. Secret redaction     _zai_redact_secrets
#                           Replaces 17+ known secret patterns (API keys, tokens,
#                           connection strings, PEM blocks …) with [REDACTED].
#
#   3. Prompt sanitisation  _zai_sanitize_for_prompt
#                           Strips non-printable / zero-width Unicode, FIM tokens,
#                           ChatML tokens, and LLM prompt-injection keywords.
#
# Portability:
#   sed variant is detected ONCE at load time and cached in _ZAI_SED_ERE.
#   GNU sed (Linux) uses  -r  for extended regular expressions (ERE).
#   BSD sed (macOS)  uses  -E  for ERE.
#   All patterns use POSIX ERE with POSIX character classes ([:alnum:] etc.)
#   so they are identical for both variants.
#
# Usage (consumed by ContextGatherer):
#   _zai_is_sensitive_file ".env.local"   → returns 0 (is sensitive)
#   _zai_filter_directory_entries "${ls_output}"
#   _zai_redact_secrets "${history_line}"
#   _zai_sanitize_for_prompt "${context_block}"
#
# ==============================================================================

# Guard against double-sourcing
(( ${+_ZAI_SECURITY_LOADED} )) && return 0
typeset -gi _ZAI_SECURITY_LOADED=1

# ==============================================================================
# Dependency: Configuration module
# ==============================================================================

if ! (( ${+_ZAI_CONFIG_LOADED} )); then
  local _zai_sec_selfdir="${${(%):-%x}:a:h}"
  if [[ -f "${_zai_sec_selfdir}/config.zsh" ]]; then
    source "${_zai_sec_selfdir}/config.zsh"
  fi
fi

# ==============================================================================
# sed variant detection — run once at load time
#
# Store the ERE flag in a global so every function uses the same string.
# Detection: GNU sed prints a version line when called with --version;
# BSD sed treats --version as an unknown option and exits non-zero.
# ==============================================================================

if sed --version 2>/dev/null | grep -q 'GNU'; then
  typeset -g _ZAI_SED_ERE='-r'
else
  typeset -g _ZAI_SED_ERE='-E'
fi

# ==============================================================================
# _zai_is_sensitive_file <filename>
#
# Returns 0 (true) if <filename> matches any of the sensitive file patterns
# listed below; returns 1 (false) otherwise.
#
# Matching is done against both the basename and the original path so that
# entries like ".aws/credentials" are caught regardless of context.
#
# Exact basenames:
#   .env, id_rsa, id_ed25519, id_dsa, id_ecdsa, kubeconfig,
#   .htpasswd, .vault-token, .git-credentials, credentials.json,
#   secrets.yaml, .npmrc (may contain auth tokens)
#
# Glob-style basename patterns:
#   .env.*, *.pem, *.key, *.p12, *.pfx, *.jks, *.keystore, *.tfvars,
#   *.asc, service-account*.json
#
# Path patterns (checked against full input):
#   .docker/config.json, .aws/credentials
#
# Substring matches (case-insensitive, basename):
#   'secret', 'credential', 'password', 'passwd', 'token', 'auth'
#
# ==============================================================================
_zai_is_sensitive_file() {
  local filename="${1}"

  # Nothing to test
  [[ -z "${filename}" ]] && return 1

  # Derive the basename (last path component) using zsh-native modifier
  local bname="${filename:t}"
  local lower_bname="${(L)bname}"

  # ── 1. Exact basename matches ───────────────────────────────────────────────
  case "${bname}" in
    .env|\
    id_rsa|id_ed25519|id_dsa|id_ecdsa|\
    kubeconfig|\
    .htpasswd|\
    .vault-token|\
    .git-credentials|\
    credentials.json|\
    secrets.yaml|\
    .npmrc)
      return 0
      ;;
  esac

  # ── 2. .env.* pattern (.env.local, .env.production, .env.development …) ────
  [[ "${bname}" == .env.* ]] && return 0

  # ── 3. Extension / glob-based basename patterns ─────────────────────────────
  case "${bname}" in
    *.pem|*.key|*.p12|*.pfx|*.jks|*.keystore|*.tfvars|*.asc)
      return 0
      ;;
    service-account*.json)
      return 0
      ;;
  esac

  # ── 4. Full-path patterns ────────────────────────────────────────────────────
  # Covers both relative (".docker/config.json") and absolute paths
  # ("…/.docker/config.json")
  case "${filename}" in
    .docker/config.json|*/.docker/config.json)
      return 0
      ;;
    .aws/credentials|*/.aws/credentials)
      return 0
      ;;
  esac

  # ── 5. Substring matches (case-insensitive) ──────────────────────────────────
  # Any filename whose lowercase form contains these words is treated as
  # potentially sensitive.  Conservative: better to over-redact than leak.
  case "${lower_bname}" in
    *secret*|*credential*|*password*|*passwd*|*token*|*auth*)
      return 0
      ;;
  esac

  return 1
}

# ==============================================================================
# _zai_filter_directory_entries <entries>
#
# Reads a newline-delimited list of filenames (as produced by `ls -1`),
# removes any entry that _zai_is_sensitive_file considers sensitive, and
# writes the filtered list to stdout.
#
# Empty lines are preserved as-is (they don't match any pattern).
# The function is pure zsh — no subshells, no external processes.
#
# ==============================================================================
_zai_filter_directory_entries() {
  local entries="${1}"
  local line

  while IFS= read -r line; do
    # Pass through empty lines unchanged; they carry no filename info
    if [[ -z "${line}" ]]; then
      print -- "${line}"
      continue
    fi
    # Only emit the line when it is NOT sensitive
    if ! _zai_is_sensitive_file "${line}"; then
      print -- "${line}"
    fi
  done <<< "${entries}"
}

# ==============================================================================
# _zai_redact_secrets <text>
#
# Pipes <text> through a chain of sed ERE substitutions that replace
# known secret patterns with [REDACTED] (or a pattern-specific tag).
# The entire matched token — including its prefix — is replaced so that
# a second pass cannot partially re-match the replacement string.
#
# Patterns covered (17):
#   1.  sk-proj-*           OpenAI project API keys (processed before sk-*)
#   2.  sk-*                OpenAI API keys
#   3.  ghp_*               GitHub personal access tokens
#   4.  github_pat_*        GitHub fine-grained personal access tokens
#   5.  AKIA*               AWS IAM access key IDs
#   6.  npm_*               npm publish/auth tokens
#   7.  xox[baprs]-*        Slack bot/app/user/workspace tokens
#   8.  sk_live_*           Stripe secret live keys
#   9.  pk_live_*           Stripe publishable live keys
#  10.  scheme://user@host  URL-embedded credentials (connection strings)
#  11.  Bearer <token>      HTTP Authorization: Bearer header values
#  12.  Token <token>       HTTP Authorization: Token header values
#  13.  export VAR=<val>    Shell variable assignments with long values
#  14.  -p<password>        MySQL/mysqldump inline password flag
#  15.  -----BEGIN * KEY-----  PEM private key block headers
#  16.  eyJ*.*.* JWT tokens (Header.Payload.Signature format)
#  17.  64+ char base64     High-entropy opaque tokens
#
# Notes:
#   • sk-proj-* is placed BEFORE sk-* in the same sed call.  Because the
#     full string is replaced (not just the suffix) there is no
#     double-redaction of the prefix.
#   • The replacement "[REDACTED]" contains "[" which is not in [A-Za-z0-9_-],
#     so none of the subsequent patterns can re-match the replacement text.
#   • Multiple `-e` expressions in a single `sed` invocation share one
#     pass over the input, which is more efficient than chained pipes.
#
# ==============================================================================
_zai_redact_secrets() {
  local text="${1}"

  if [[ -z "${text}" ]]; then
    print -- ""
    return 0
  fi

  # ── Pass 1: prefix-based token patterns ─────────────────────────────────────
  # sk-proj- MUST appear before sk- so the longer prefix wins.
  # The entire token (prefix + value) is replaced with [REDACTED] so that
  # the sk- pattern on the next expression cannot partially re-match.
  print -- "${text}" \
  | sed "${_ZAI_SED_ERE}" \
    -e 's/sk-proj-[A-Za-z0-9_-]{3,}/[REDACTED]/g' \
    -e 's/sk-[A-Za-z0-9_-]{3,}/[REDACTED]/g' \
    -e 's/ghp_[A-Za-z0-9]{3,}/[REDACTED]/g' \
    -e 's/github_pat_[A-Za-z0-9_]{3,}/[REDACTED]/g' \
    -e 's/AKIA[A-Z0-9]{3,}/[REDACTED]/g' \
    -e 's/npm_[A-Za-z0-9]{3,}/[REDACTED]/g' \
    -e 's/xox[baprs]-[A-Za-z0-9-]{3,}/[REDACTED]/g' \
    -e 's/sk_live_[A-Za-z0-9]{3,}/[REDACTED]/g' \
    -e 's/pk_live_[A-Za-z0-9]{3,}/[REDACTED]/g' \
  \
  | sed "${_ZAI_SED_ERE}" \
    \
    -e 's|[a-zA-Z][a-zA-Z0-9+.-]*://[^@[:space:]]+@[^/[:space:]]+|[REDACTED_URL]|g' \
    \
    -e 's/(Bearer|Token)[[:space:]]+[A-Za-z0-9_.\/+=-]{8,}/\1 [REDACTED]/g' \
    \
    -e 's/(export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*)=[^[:space:]]{8,}/\1=[REDACTED]/g' \
    \
    -e 's/-p([A-Za-z0-9][^[:space:]]{7,})/-p[REDACTED]/g' \
  \
  | sed "${_ZAI_SED_ERE}" \
    \
    -e 's/-----BEGIN [A-Z ]+(KEY|PRIVATE)-----/[REDACTED_PEM]/g' \
    \
    -e 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/[REDACTED_JWT]/g' \
    \
    -e 's/[A-Za-z0-9+\/]{64,}={0,2}/[REDACTED_TOKEN]/g'
}

# ==============================================================================
# _zai_sanitize_for_prompt <text>
#
# Applies three sanitisation steps to <text> before it is embedded in an
# LLM prompt, defending against prompt-injection attacks and model confusion
# from special tokens:
#
#   Step 1 — Non-printable / zero-width Unicode
#     LC_ALL=C tr -cd '[:print:]\n\t'
#     Strips every byte that is not a printable ASCII character, horizontal
#     tab, or newline.  LC_ALL=C ensures the POSIX "C" locale so that
#     [:print:] refers to ASCII 0x20–0x7E only (not multi-byte Unicode).
#     This eliminates zero-width spaces, BOM characters, directional marks,
#     and any other invisible Unicode that could be used to obfuscate
#     injections.
#
#   Step 2 — FIM and ChatML special tokens  (BRE sed — no ERE flag)
#     Using basic regex (BRE) because the vertical bar "|" in
#     "<|fim_prefix|>" is a LITERAL character, not an alternation operator.
#     In BRE, "|" has no special meaning, so the pattern matches verbatim.
#     Tokens removed:
#       <|fim_prefix|>  <|fim_suffix|>  <|fim_middle|>  <|endoftext|>
#       <|im_start|>    <|im_end|>
#
#   Step 3 — LLM prompt-injection keywords  (ERE sed, case-insensitive)
#     Since POSIX portable sed has no /i flag, case-insensitivity is
#     achieved by expanding each letter to [Xx] character classes.
#     Patterns removed:
#       ignore.*previous.*instruction(s)?  (with optional spacing/Unicode)
#       SYSTEM:  /  [SYSTEM]  /  <system>  /  </system>
#
# Returns the sanitised text on stdout.
#
# ==============================================================================
_zai_sanitize_for_prompt() {
  local text="${1}"

  if [[ -z "${text}" ]]; then
    print -- ""
    return 0
  fi

  # ── Step 1: Strip non-printable and zero-width Unicode ──────────────────────
  # LC_ALL=C restricts [:print:] to ASCII 0x20-0x7E; strips all multi-byte
  # and non-printable bytes, including zero-width spaces (U+200B etc.).
  local sanitised
  sanitised="$(print -- "${text}" | LC_ALL=C tr -cd '[:print:]\n\t')"

  # ── Step 2: Remove FIM tokens and ChatML tokens (BRE — literal "|") ─────────
  # NOTE: Do NOT add -r/-E here.  We rely on BRE where "|" is a literal
  # character so "<|fim_prefix|>" is matched as-is.
  sanitised="$(print -- "${sanitised}" \
    | sed \
      -e 's/<|fim_prefix|>//g' \
      -e 's/<|fim_suffix|>//g' \
      -e 's/<|fim_middle|>//g' \
      -e 's/<|endoftext|>//g' \
      -e 's/<|im_start|>//g' \
      -e 's/<|im_end|>//g')"

  # ── Step 3: Remove LLM prompt-injection keywords ─────────────────────────────
  # Case-insensitive matching via explicit [Xx] character-class expansion.
  # This is portable to both GNU sed (-r) and BSD sed (-E).
  #
  # Pattern: "ignore (any chars) previous (any chars) instruction(s)?"
  # Matches common variants:
  #   "ignore previous instructions"
  #   "Ignore all previous instructions and ..."
  #   "IGNORE PREVIOUS INSTRUCTION"
  #
  # SYSTEM: / [SYSTEM] / <system> / </system>
  sanitised="$(print -- "${sanitised}" \
    | sed "${_ZAI_SED_ERE}" \
      -e 's/[Ii][Gg][Nn][Oo][Rr][Ee][[:space:]]+[A-Za-z[:space:]]*[Pp][Rr][Ee][Vv][Ii][Oo][Uu][Ss][[:space:]]+[A-Za-z[:space:]]*[Ii][Nn][Ss][Tt][Rr][Uu][Cc][Tt][Ii][Oo][Nn][Ss]?//g' \
      -e 's/[Ss][Yy][Ss][Tt][Ee][Mm][[:space:]]*://g' \
      -e 's/\[[Ss][Yy][Ss][Tt][Ee][Mm]\]//g' \
      -e 's/<[\/]?[Ss][Yy][Ss][Tt][Ee][Mm]>//g')"

  print -- "${sanitised}"
}
