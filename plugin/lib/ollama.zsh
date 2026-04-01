# ==============================================================================
# zsh-ai-complete: OllamaClient Module
# File: plugin/lib/ollama.zsh
# ==============================================================================
#
# Manages all HTTP communication with the local Ollama API server.
# Enforces strict localhost-only communication via URL allowlist validation
# and loopback interface enforcement (defense-in-depth).
#
# Public functions:
#   _zai_validate_ollama_url(url)             Strict allowlist: loopback only
#   _zai_ollama_generate(prompt, opts_json)   POST /api/generate, returns text
#   _zai_ollama_check_health()                GET /, returns 0 if reachable
#   _zai_ollama_check_model(model)            GET /api/tags, 0 if model present
#   _zai_ollama_parse_response(raw_json)      Extract 'response' field from JSON
#
# Security controls:
#   - URL host must be exactly: localhost, 127.0.0.1, or ::1
#   - URLs containing @ (credential embedding tricks) are rejected
#   - curl uses --interface lo/lo0 to enforce OS-level loopback routing
#   - Prompt piped via stdin (-d @-) to avoid exposure in process listings
#
# Dependencies:
#   - plugin/lib/config.zsh (TASK-001) must be sourced first
# ==============================================================================

# Guard against double-sourcing
(( ${+_ZAI_OLLAMA_LOADED} )) && return 0
typeset -gi _ZAI_OLLAMA_LOADED=1

# ==============================================================================
# Platform detection — performed ONCE at module load time
# ==============================================================================
#
# macOS uses the loopback interface "lo0"; Linux uses "lo".
# Detected here so every curl call uses the correct interface name without
# repeated uname invocations.

if [[ "$( uname -s 2>/dev/null )" == "Darwin" ]]; then
  typeset -g _ZAI_LOOPBACK_IFACE="lo0"
else
  typeset -g _ZAI_LOOPBACK_IFACE="lo"
fi

# ==============================================================================
# _zai_json_escape_string <string>
#
# Escapes a string for safe embedding as a JSON string value.
# Outputs the escaped string on stdout WITHOUT surrounding quotes.
#
# JSON special characters handled (order matters — backslash must be first):
#   \   → \\    (must be processed first to avoid double-escaping)
#   "   → \"
#   LF  → \n
#   CR  → \r
#   TAB → \t
# ==============================================================================
_zai_json_escape_string() {
  local str="${1}"

  # 1. Backslash first — prevents double-escaping subsequent replacements
  str="${str//\\/\\\\}"

  # 2. Double quotes
  str="${str//\"/\\\"}"

  # 3. Control characters
  str="${str//$'\n'/\\n}"
  str="${str//$'\r'/\\r}"
  str="${str//$'\t'/\\t}"

  print -rn -- "${str}"
}

# ==============================================================================
# _zai_validate_ollama_url <url>
#
# Validates that <url> targets a loopback address only.
#
# Algorithm:
#   1. Reject empty URL.
#   2. Reject any URL containing @ — covers credential-embedding attacks
#      such as http://user:pass@host and the trick http://localhost@evil.com
#      where evil.com is the actual destination host per RFC 3986 §3.2.1.
#   3. Strip http:// or https:// scheme; reject unrecognised schemes.
#   4. Strip URL path (everything from the first "/" onwards).
#   5. Strip URL query string (everything from "?" onwards).
#   6. Strip URL fragment (everything from "#" onwards).
#   7. Extract hostname:
#      - IPv6 bracket notation [host]:port → extract content inside brackets.
#      - Regular hostname/IPv4: strip optional ":port" suffix from the right.
#   8. Allowlist check: ONLY accept exactly localhost, 127.0.0.1, or ::1.
#      Any other value — including subdomains, IPv4-mapped IPv6 addresses
#      like ::ffff:7f00:1, or partial matches — is rejected.
#
# Returns 0 (success) if the URL is valid; 1 (failure) if rejected.
#
# Accepts:
#   http://localhost:11434
#   http://127.0.0.1:11434
#   http://[::1]:11434
#   http://localhost           (no port)
#
# Rejects:
#   http://localhost@evil.com      (@ credential embedding)
#   http://localhost.evil.com      (subdomain — not in allowlist)
#   http://127.0.0.1.evil.com      (subdomain trick)
#   http://[::ffff:7f00:1]:11434   (IPv4-mapped IPv6 — not ::1)
#   ftp://localhost:11434          (unrecognised scheme)
# ==============================================================================
_zai_validate_ollama_url() {
  local url="${1}"

  # ── 1. Reject empty URL ────────────────────────────────────────────────────
  if [[ -z "${url}" ]]; then
    return 1
  fi

  # ── 2. Reject any URL containing @ ────────────────────────────────────────
  # RFC 3986 §3.2.1: userinfo is the text before @ in the authority component.
  # http://localhost@evil.com → authority is "localhost@evil.com", host is evil.com.
  # We reject ALL URLs with @ to eliminate this attack class entirely.
  if [[ "${url}" == *@* ]]; then
    return 1
  fi

  # ── 3. Strip scheme ────────────────────────────────────────────────────────
  local rest
  if [[ "${url}" == http://* ]]; then
    rest="${url#http://}"
  elif [[ "${url}" == https://* ]]; then
    rest="${url#https://}"
  else
    # Unrecognised or missing scheme — reject
    return 1
  fi

  # ── 4. Strip URL path: everything from first "/" onwards ──────────────────
  # "localhost:11434/api/generate?q=1#frag" → "localhost:11434"
  rest="${rest%%/*}"

  # ── 5. Strip query string (after ?) ───────────────────────────────────────
  rest="${rest%%\?*}"

  # ── 6. Strip fragment (after #) ───────────────────────────────────────────
  rest="${rest%%#*}"

  # ── 7. Extract hostname ────────────────────────────────────────────────────
  local host
  if [[ "${rest}" == \[* ]]; then
    # IPv6 bracket notation: [::1]:11434 or [::1]
    # Strip the leading "[" then everything from "]" onwards.
    host="${rest#[}"
    host="${host%%]*}"
  else
    # Hostname or IPv4: "localhost", "localhost:11434", "127.0.0.1:11434"
    # Remove ":port" suffix — strip from the rightmost colon to end of string.
    # If no colon is present (no port), the pattern does not match and the
    # original string is returned unchanged.
    host="${rest%:*}"
  fi

  # ── 8. Strict allowlist check ──────────────────────────────────────────────
  # Only EXACTLY these three values are accepted — no substrings, no subdomains,
  # no IPv4-mapped IPv6 variants.
  case "${host}" in
    localhost | 127.0.0.1 | "::1")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# ==============================================================================
# _zai_ollama_parse_response <raw_json>
#
# Extracts and decodes the value of the "response" field from Ollama's
# /api/generate JSON output.
#
# Uses awk for portable, character-by-character scanning that correctly handles
# all JSON string escape sequences within the response value.
#
# JSON escape sequences decoded:
#   \n  → LF (newline)
#   \t  → TAB
#   \\  → backslash
#   \"  → double quote
#   \r  → CR
#   \b  → backspace
#   \f  → form feed
#   \/  → forward slash (valid JSON escape)
#   \uXXXX → passed through literally (Unicode surrogate pairs not decoded)
#
# Example input:
#   {"model":"qwen2.5-coder:7b","response":"ls -la","done":true}
# Example input with escapes:
#   {"response":"echo \"hello\\nworld\"","done":true}
#
# Outputs the decoded response text on stdout.
# Returns 0 on success (including empty response), 1 if input is empty.
# ==============================================================================
_zai_ollama_parse_response() {
  local raw_json="${1}"

  if [[ -z "${raw_json}" ]]; then
    return 1
  fi

  # Use awk for reliable, portable JSON field extraction.
  # Character-by-character scanning correctly handles:
  #   - Escaped quotes inside the response value (\" must not end the string)
  #   - Escaped backslashes (\\ must not escape the closing quote)
  #   - All other JSON escape sequences
  print -r -- "${raw_json}" | awk '
  {
    # Locate the "response":" marker
    marker = "\"response\":\""
    idx = index($0, marker)
    if (idx == 0) next

    # Position after the opening quote of the string value
    s = substr($0, idx + length(marker))
    n = length(s)

    result = ""
    i = 1
    while (i <= n) {
      c = substr(s, i, 1)

      if (c == "\\") {
        # Escape sequence — consume backslash and the following character
        if (i >= n) break
        nc = substr(s, i + 1, 1)
        i += 2
        if      (nc == "n")  { result = result "\n"; continue }
        else if (nc == "t")  { result = result "\t"; continue }
        else if (nc == "\\") { result = result "\\"; continue }
        else if (nc == "\"") { result = result "\""; continue }
        else if (nc == "r")  { result = result "\r"; continue }
        else if (nc == "b")  { result = result "\b"; continue }
        else if (nc == "f")  { result = result "\f"; continue }
        else if (nc == "/")  { result = result "/";  continue }
        else                 { result = result nc;   continue }
      }

      if (c == "\"") {
        # Unescaped closing quote — end of string value
        break
      }

      result = result c
      i++
    }

    print result
    exit
  }'
}

# ==============================================================================
# _zai_ollama_generate <prompt> <options_json>
#
# Sends a POST request to Ollama's /api/generate endpoint and returns the
# decoded response text.
#
# Security:
#   - URL validated via _zai_validate_ollama_url before any request is made
#   - JSON body piped via stdin (-d @-) so the prompt is NOT visible in
#     process listings (ps aux would show only "curl ... -d @-")
#   - curl --interface enforces OS-level routing through the loopback adapter
#
# Args:
#   prompt       Complete prompt string (special chars are JSON-escaped)
#   options_json JSON object for model options, e.g. '{"temperature":0.1}'
#                Defaults to '{}' if empty or omitted
#
# Outputs the decoded completion text on stdout.
# Returns curl's exit code on HTTP/network failure, or 1 on invalid URL.
#
# Called from the background subshell spawned by AsyncEngine — never from ZLE
# context directly.
# ==============================================================================
_zai_ollama_generate() {
  local prompt="${1}"
  local options_json="${2}"

  # Default to empty options object when not provided
  if [[ -z "${options_json}" ]]; then
    options_json='{}'
  fi

  # ── Read configuration ─────────────────────────────────────────────────────
  local url model timeout
  url="$(_zai_config_get ollama_url)"
  model="$(_zai_config_get model)"
  timeout="$(_zai_config_get timeout)"

  # ── Validate URL before making any network request ────────────────────────
  if ! _zai_validate_ollama_url "${url}"; then
    print -u2 "zsh-ai-complete: OllamaClient: rejected invalid Ollama URL: ${url}"
    return 1
  fi

  # ── JSON-encode model name and prompt ─────────────────────────────────────
  # Both values are escaped so special characters (backslashes, quotes,
  # newlines, etc.) do not break the JSON structure or enable injection.
  local prompt_escaped model_escaped
  prompt_escaped="$(_zai_json_escape_string "${prompt}")"
  model_escaped="$(_zai_json_escape_string "${model}")"

  # ── Build request body ────────────────────────────────────────────────────
  # stream:false — collect full response in one curl call (simpler for short
  #                completions, avoids incremental ndjson parsing in pure zsh)
  local json
  json="{\"model\":\"${model_escaped}\",\"prompt\":\"${prompt_escaped}\",\"stream\":false,\"raw\":true,\"options\":${options_json}}"

  # ── Execute HTTP POST via stdin pipe ──────────────────────────────────────
  #
  # SECURITY: The JSON body is written to curl's stdin (-d @-) rather than
  # passed as a command-line argument.  Command-line arguments are visible in
  # process listings (ps aux, /proc/<pid>/cmdline), which would expose the
  # full prompt text to other users on the same machine.
  #
  # curl flags:
  #   --silent          Suppress progress output
  #   --fail            Return non-zero exit on HTTP 4xx / 5xx responses
  #   -X POST           HTTP method
  #   -H '...'          Content-Type header required by Ollama
  #   --max-time N      Hard wall-clock timeout (from ZSH_AI_COMPLETE_TIMEOUT)
  #   --interface lo/lo0  Defense-in-depth: OS refuses to route outside loopback
  #   -d @-             Read request body from stdin (our pipe)
  local response
  response=$(print -r -- "${json}" | curl \
    --silent \
    --fail \
    -X POST \
    -H 'Content-Type: application/json' \
    --max-time "${timeout}" \
    --interface "${_ZAI_LOOPBACK_IFACE}" \
    -d @- \
    "${url}/api/generate" 2>/dev/null)

  local curl_exit=$?
  if (( curl_exit != 0 )); then
    return ${curl_exit}
  fi

  # ── Parse and return completion text ──────────────────────────────────────
  _zai_ollama_parse_response "${response}"
}

# ==============================================================================
# _zai_ollama_check_health
#
# Performs a lightweight GET request to the Ollama root endpoint to verify
# the server is running and accepting connections.
#
# Ollama responds to GET / with the text "Ollama is running" (HTTP 200).
# Any non-200 response or connection failure causes a non-zero return.
#
# Returns:
#   0  — Ollama is running and reachable at the configured URL
#   1+ — Ollama not running, unreachable, timed out, or URL invalid
# ==============================================================================
_zai_ollama_check_health() {
  local url
  url="$(_zai_config_get ollama_url)"

  # Validate URL first — refuse to attempt any connection to an invalid target
  if ! _zai_validate_ollama_url "${url}"; then
    return 1
  fi

  # GET root endpoint; discard response body, check exit code only
  curl \
    --silent \
    --fail \
    --max-time 3 \
    --interface "${_ZAI_LOOPBACK_IFACE}" \
    "${url}" >/dev/null 2>&1
}

# ==============================================================================
# _zai_ollama_check_model <model>
#
# Checks whether the specified model is present in Ollama's local model store
# by querying the /api/tags endpoint.
#
# The /api/tags response has the form:
#   {"models":[{"name":"qwen2.5-coder:7b","model":"qwen2.5-coder:7b",...},...]}
#
# The model name is searched for as a JSON string value ("name") to avoid
# false positives from partial substring matches.
#
# Args:
#   model — Model name to check (e.g., "qwen2.5-coder:7b")
#
# Returns:
#   0 — Model is present in the local Ollama store
#   1 — Model not found, Ollama unreachable, or invalid arguments
# ==============================================================================
_zai_ollama_check_model() {
  local model="${1}"

  if [[ -z "${model}" ]]; then
    return 1
  fi

  local url
  url="$(_zai_config_get ollama_url)"

  if ! _zai_validate_ollama_url "${url}"; then
    return 1
  fi

  local response
  response=$(curl \
    --silent \
    --fail \
    --max-time 5 \
    --interface "${_ZAI_LOOPBACK_IFACE}" \
    "${url}/api/tags" 2>/dev/null)

  if (( $? != 0 )); then
    return 1
  fi

  # Search for the model name as a JSON string value.
  # The /api/tags response lists models with "name":"<model>" entries.
  # We match the exact string in double quotes to avoid partial matches
  # (e.g., "qwen2.5-coder:7b" should not match "qwen2.5-coder:7b-instruct").
  [[ "${response}" == *"\"${model}\""* ]]
}
