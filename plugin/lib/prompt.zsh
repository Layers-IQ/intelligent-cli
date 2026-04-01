# ==============================================================================
# zsh-ai-complete: PromptBuilder Module
# File: plugin/lib/prompt.zsh
# ==============================================================================
#
# Constructs optimized LLM prompts from gathered context:
#
#   _zai_build_completion_prompt(buffer, context)
#       → FIM-format: <|fim_prefix|>context+buffer<|fim_suffix|><|fim_middle|>
#         The model fills in the text that completes the command in the middle.
#         raw:true prevents Ollama from applying the chat template, which would
#         corrupt the FIM special tokens.
#
#   _zai_build_nl_translation_prompt(comment, context)
#       → ChatML-format: system + user message containing the NL comment and
#         shell context. Used when buffer starts with "# ".
#
#   _zai_get_generation_params(mode)
#       → JSON string of Ollama /api/generate options, mode-specific:
#           completion  temperature=0.1, top_k=20,  num_predict=60,  stop=["\n"]
#           nl_to_cmd   temperature=0.2, top_k=40,  num_predict=150, stop=["\n\n"]
#
#   _zai_detect_prompt_mode(buffer)
#       → "nl_to_cmd" if buffer starts with "#", else "completion"
#
#   _zai_clean_completion(raw, buffer, mode)
#       → Post-processes model output: strip echoed prefix, reject >200 chars,
#         strip markdown fences, take first line only for completion mode.
#
#   _zai_truncate_context(context, max_chars)
#       → Trims context to fit within token budget (~2048 tokens):
#         removes oldest history entries first, then excess directory entries.
#
# Token budget:
#   ~2048 tokens × 4 chars/token = ~8192 total chars
#   Reserve ~1200 chars for: buffer + FIM/ChatML tokens + generation overhead
#   Max context: _ZAI_PROMPT_MAX_CONTEXT_CHARS (default 7000 chars ≈ 1750 tokens)
#
# ==============================================================================

# Guard against double-sourcing
(( ${+_ZAI_PROMPT_LOADED} )) && return 0
typeset -gi _ZAI_PROMPT_LOADED=1

# ==============================================================================
# Dependency auto-loading
# ==============================================================================

if ! (( ${+functions[_zai_config_get]} )); then
  builtin source "${0:a:h}/config.zsh"
fi

# ==============================================================================
# Constants
# ==============================================================================

# Maximum characters for context section (~1750 tokens, leaves room for
# buffer + prompt tokens + generation overhead within 2048-token budget)
typeset -gi _ZAI_PROMPT_MAX_CONTEXT_CHARS=7000

# ==============================================================================
# _zai_truncate_context <context> [max_chars]
#
# Trims the context string to stay within the token budget.
#
# Truncation strategy (per spec):
#   1. Remove oldest history entries first (from top of <history> section)
#   2. If still over limit, remove excess directory entries (from bottom of
#      <directory> section)
#
# This preserves the most recent/relevant context while bounding token count.
#
# Arguments:
#   context    — formatted context string with XML delimiter tags
#   max_chars  — character limit (default: _ZAI_PROMPT_MAX_CONTEXT_CHARS)
# ==============================================================================
_zai_truncate_context() {
  local context="${1:-}"
  local max_chars="${2:-${_ZAI_PROMPT_MAX_CONTEXT_CHARS}}"

  # Fast path: already within budget
  (( ${#context} <= max_chars )) && { printf '%s' "${context}"; return 0; }

  # ── Split context into lines for targeted section trimming ────────────────
  local -a lines
  lines=("${(f)context}")

  # ── Identify history and directory content line indices ───────────────────
  # We track only non-empty content lines inside each XML section.
  # hist_indices: positions of history entries (oldest first = smallest index)
  # dir_indices:  positions of directory entries (newest last = largest index)
  local -a hist_indices dir_indices
  local in_hist=0 in_dir=0 i

  for (( i = 1; i <= ${#lines}; i++ )); do
    case "${lines[$i]}" in
      '<history>')    in_hist=1 ;;
      '</history>')   in_hist=0 ;;
      '<directory>')  in_dir=1  ;;
      '</directory>') in_dir=0  ;;
      *)
        (( in_hist )) && [[ -n "${lines[$i]}" ]] && hist_indices+=($i)
        (( in_dir  )) && [[ -n "${lines[$i]}" ]] && dir_indices+=($i)
        ;;
    esac
  done

  # ── Phase 1: Remove oldest history entries ────────────────────────────────
  # We mark removed lines in an associative array and recompute length.
  typeset -A _zai_removed
  local h=1
  local cur_len=${#context}

  while (( h <= ${#hist_indices} && cur_len > max_chars )); do
    local idx=${hist_indices[$h]}
    # Subtract the removed line length + 1 (for newline)
    cur_len=$(( cur_len - ${#lines[$idx]} - 1 ))
    _zai_removed[$idx]=1
    (( h++ ))
  done

  # ── Phase 2: If still over budget, remove directory entries from back ─────
  local d=${#dir_indices}
  while (( d >= 1 && cur_len > max_chars )); do
    local idx=${dir_indices[$d]}
    if [[ -z "${_zai_removed[$idx]}" ]]; then
      cur_len=$(( cur_len - ${#lines[$idx]} - 1 ))
      _zai_removed[$idx]=1
    fi
    (( d-- ))
  done

  # ── Reconstruct output without removed lines ─────────────────────────────
  local result=""
  for (( i = 1; i <= ${#lines}; i++ )); do
    [[ -n "${_zai_removed[$i]}" ]] && continue
    result+="${lines[$i]}"$'\n'
  done

  # Strip the trailing newline added in the loop
  result="${result%$'\n'}"

  unset _zai_removed
  printf '%s' "${result}"
}

# ==============================================================================
# _zai_build_completion_prompt <buffer> <context>
#
# Constructs a FIM (Fill-In-the-Middle) prompt for command completion.
#
# Format:
#   <|fim_prefix|>{context}\n{buffer}<|fim_suffix|><|fim_middle|>
#
# The model generates text to fill the "middle" — what comes after the cursor.
# The suffix is intentionally empty: the cursor is at end of line and the
# model continues from there.
#
# CRITICAL: raw:true must be set in generation params so Ollama does NOT
# apply the chat template, which would corrupt the FIM special tokens.
#
# Token budget enforcement:
#   Context is truncated before embedding to keep total prompt ≤ 2048 tokens.
#
# Arguments:
#   buffer   — current ZLE command buffer (partial command typed so far)
#   context  — aggregated context from _zai_gather_full_context
# ==============================================================================
_zai_build_completion_prompt() {
  local buffer="${1:-}"
  local context="${2:-}"

  # Enforce token budget: truncate context if needed
  # Reserve budget for: buffer + FIM tokens (42 chars) + some headroom
  local reserve=$(( ${#buffer} + 100 ))
  local avail=$(( _ZAI_PROMPT_MAX_CONTEXT_CHARS - reserve ))
  (( avail < 500 )) && avail=500   # always allow at least 500 chars of context

  if [[ -n "${context}" ]] && (( ${#context} > avail )); then
    context="$(_zai_truncate_context "${context}" "${avail}")"
  fi

  # Emit prompt without trailing newline — model continues inline from middle.
  # The "\n$ " separator between context and buffer is critical: without it the
  # model may treat the buffer as a continuation of the context narrative (e.g.
  # "git sta" + git status context → verbose explanation instead of "tus").
  # The "$ " shell prompt marker signals that a command line follows.
  printf '%s' "<|fim_prefix|>${context}
\$ ${buffer}<|fim_suffix|><|fim_middle|>"
}

# ==============================================================================
# _zai_build_nl_translation_prompt <comment> <context>
#
# Constructs a ChatML prompt for natural-language-to-command translation.
# Used when the user's buffer starts with "# " (a comment).
#
# Format:
#   <|im_start|>system
#   {system_instruction}
#   <|im_end|>
#   <|im_start|>user
#   {context}
#   Translate to a shell command: {comment}
#   <|im_end|>
#   <|im_start|>assistant
#   (empty — model generates from here)
#
# The leading "# " or "#" is stripped from the comment before embedding.
#
# CRITICAL: raw:true must be set in generation params so Ollama does NOT
# double-wrap the ChatML tokens in an additional chat template.
#
# Arguments:
#   comment  — natural language text (may still have "# " prefix)
#   context  — aggregated context from _zai_gather_full_context
# ==============================================================================
_zai_build_nl_translation_prompt() {
  local comment="${1:-}"
  local context="${2:-}"

  # Strip leading "# " or "#" prefix to get the raw natural language text
  if [[ "${comment}" == '# '* ]]; then
    comment="${comment#\# }"
  elif [[ "${comment}" == '#'* ]]; then
    comment="${comment#\#}"
  fi

  # Enforce token budget: truncate context if needed
  # ChatML overhead: system instruction (~80 chars) + user/assistant tokens (~60)
  local reserve=$(( ${#comment} + 200 ))
  local avail=$(( _ZAI_PROMPT_MAX_CONTEXT_CHARS - reserve ))
  (( avail < 500 )) && avail=500

  if [[ -n "${context}" ]] && (( ${#context} > avail )); then
    context="$(_zai_truncate_context "${context}" "${avail}")"
  fi

  printf '%s' "<|im_start|>system
You are a shell command expert. Given a natural language description and shell context, output ONLY the exact shell command with no explanation, no markdown, and no extra text.
<|im_end|>
<|im_start|>user
${context}
Translate to a shell command: ${comment}
<|im_end|>
<|im_start|>assistant
"
}

# ==============================================================================
# _zai_detect_prompt_mode <buffer>
#
# Inspects the buffer to determine which prompt format to use.
#
# Returns:
#   "nl_to_cmd"   — buffer starts with "#" (natural language comment mode)
#   "completion"  — everything else (standard FIM completion mode)
#
# Note: bare "#" (length 1) is treated as completion since the user has not
# yet typed any natural language text.
# ==============================================================================
_zai_detect_prompt_mode() {
  local buffer="${1:-}"

  if [[ "${buffer}" == '#'* ]] && [[ ${#buffer} -gt 1 ]]; then
    print "nl_to_cmd"
  else
    print "completion"
  fi
}

# ==============================================================================
# _zai_get_generation_params <mode>
#
# Returns a JSON string of Ollama /api/generate options for the given mode.
#
# Parameters differ per mode to balance determinism vs creativity:
#
#   completion  — very low temperature, low top_k, short output, stop at newline
#                 Rationale: completions should be precise and brief.
#
#   nl_to_cmd   — slightly higher temperature, larger top_k, longer output,
#                 stop at double-newline.
#                 Rationale: natural language translation needs more tokens and
#                 slightly more variance to handle diverse phrasings.
#
# CRITICAL: raw:true is REQUIRED in BOTH modes.
#   completion: prevents Ollama's chat template from wrapping the FIM prompt,
#               which would corrupt <|fim_prefix|>, <|fim_suffix|>, <|fim_middle|>.
#   nl_to_cmd:  the ChatML tokens are already embedded in the prompt string;
#               raw:true prevents Ollama from double-wrapping in chat format.
#
# Arguments:
#   mode  — "completion" (default), "nl_to_cmd", "nl_translation", or "nl"
#           Any unrecognised mode falls back to "completion" parameters.
# ==============================================================================
_zai_get_generation_params() {
  local mode="${1:-completion}"

  case "${mode}" in
    nl_to_cmd|nl_translation|nl)
      printf '%s' '{"temperature":0.2,"top_k":40,"num_predict":150,"stop":["\n\n"]}'
      ;;
    completion|*)
      printf '%s' '{"temperature":0.1,"top_k":20,"num_predict":60,"stop":["\n"]}'
      ;;
  esac
}

# ==============================================================================
# _zai_clean_completion <raw> <buffer> <mode>
#
# Post-processes the raw model output before displaying it as a suggestion.
#
# Steps (applied in order):
#   1. Empty guard     — return 1 (no output) if raw is empty or whitespace-only
#   2. Strip prefix    — model sometimes echoes the buffer; remove that prefix
#   3. Strip fences    — remove markdown code fences (```lang\n...\n``` and ```)
#   4. First line only — in completion mode, discard everything after first \n
#   5. Length guard    — reject output >200 chars as hallucination
#   6. Whitespace trim — strip leading spaces (model sometimes adds one)
#   7. Empty guard     — return 1 if nothing useful remains after cleanup
#
# Returns 0 and prints the cleaned text on success.
# Returns 1 (prints nothing) if the completion is unusable.
#
# Arguments:
#   raw     — raw model output text
#   buffer  — original ZLE buffer (used to detect echoed prefix)
#   mode    — "completion" (default) or "nl_to_cmd"
# ==============================================================================
_zai_clean_completion() {
  local raw="${1:-}"
  local buffer="${2:-}"
  local mode="${3:-completion}"

  # ── 1. Empty / whitespace-only guard ──────────────────────────────────────
  # Strip all whitespace and newlines to check if anything meaningful is present
  local stripped_test="${raw//[[:space:]]/}"
  stripped_test="${stripped_test//$'\n'/}"
  [[ -z "${stripped_test}" ]] && return 1

  # ── 2. Strip echoed buffer prefix ─────────────────────────────────────────
  # qwen2.5-coder may echo the buffer content before outputting the completion.
  # Check using glob match (* is a wildcard for any suffix).
  if [[ -n "${buffer}" ]] && [[ "${raw}" == "${buffer}"* ]]; then
    raw="${raw:${#buffer}}"
  fi

  # ── 3. Strip markdown fences ───────────────────────────────────────────────
  # Remove opening fence with optional language tag (```bash\n, ```shell\n, etc.)
  raw="${raw//\`\`\`[a-z]*$'\n'/}"   # ```bash\n → removed
  raw="${raw//\`\`\`$'\n'/}"          # ```\n → removed
  raw="${raw//\`\`\`/}"               # remaining bare ``` → removed

  # ── 4. First-line-only for completion mode ─────────────────────────────────
  # Shell command completions must be single-line; strip everything after \n.
  if [[ "${mode}" == "completion" ]]; then
    raw="${raw%%$'\n'*}"
  fi

  # ── 5. Length guard: >200 chars = likely hallucination ────────────────────
  if (( ${#raw} > 200 )); then
    return 1
  fi

  # ── 6. Strip leading spaces ────────────────────────────────────────────────
  # Model occasionally prepends a space before completions; strip them.
  # Trailing whitespace is preserved — the model may intentionally add a
  # trailing space to indicate a word boundary.
  while [[ "${raw}" == ' '* ]]; do
    raw="${raw# }"
  done

  # ── 7. Final empty guard ───────────────────────────────────────────────────
  [[ -z "${raw}" ]] && return 1

  print -- "${raw}"
}
