# zsh-ai-complete

AI-powered shell completions for Zsh using local LLM inference via [Ollama](https://ollama.ai).

Get intelligent, context-aware ghost text suggestions as you type — entirely offline, with no data leaving your machine.

## Features

- **Ghost text completions** — inline suggestions via Zsh's `POSTDISPLAY`, accept with `Right Arrow` or `Tab`
- **Fully local** — runs on localhost via Ollama, no external API calls
- **Fast startup** — sub-100ms overhead with two-phase async initialization
- **Context-aware** — uses directory listing, command history, and git state to inform suggestions
- **Privacy-first** — built-in secret redaction (API keys, tokens, credentials are never sent to the model)
- **Configurable** — env vars, `zstyle`, or runtime overrides
- **Resilient** — async debouncing, exponential backoff, graceful fallback to history-based completions

## Prerequisites

| Requirement | Version | Check |
|-------------|---------|-------|
| zsh | >= 5.3 | `zsh --version` |
| curl | any | `curl --version` |
| [Ollama](https://ollama.ai) | latest | `ollama --version` |

```bash
# Install Ollama (macOS)
brew install ollama

# Install Ollama (Linux)
curl -fsSL https://ollama.ai/install.sh | sh

# Pull the model
ollama pull qwen2.5-coder:7b

# Start Ollama
ollama serve &
```

## Installation

### Quick Install (auto-detects your plugin manager)

```bash
git clone https://github.com/amangupta/zsh-ai-complete.git
cd zsh-ai-complete
bash scripts/install.sh
```

### oh-my-zsh

```bash
git clone https://github.com/amangupta/zsh-ai-complete.git \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-ai-complete
```

Add to your `~/.zshrc`:

```zsh
plugins=(... zsh-ai-complete)
```

### zinit

```zsh
zinit light amangupta/zsh-ai-complete
```

### antigen

```zsh
antigen bundle amangupta/zsh-ai-complete
```

### sheldon

Add to `~/.config/sheldon/plugins.toml`:

```toml
[plugins.zsh-ai-complete]
github = "amangupta/zsh-ai-complete"
```

### Manual

```bash
git clone https://github.com/amangupta/zsh-ai-complete.git ~/.zsh/zsh-ai-complete
echo 'source ~/.zsh/zsh-ai-complete/plugin/zsh-ai-complete.plugin.zsh' >> ~/.zshrc
```

## Usage

Once installed, suggestions appear automatically as you type (after 3+ characters). Use these keybindings:

| Key | Action |
|-----|--------|
| `Right Arrow` | Accept full suggestion |
| `Tab` | Accept suggestion (word-by-word in some contexts) |
| `Escape` | Dismiss suggestion |
| `Ctrl+Space` | Manually trigger completion |
| `Ctrl+E` | Accept and execute suggestion |

## Configuration

All settings can be configured via environment variables, `zstyle`, or runtime API.

| Setting | Default | Description |
|---------|---------|-------------|
| `ZSH_AI_COMPLETE_OLLAMA_URL` | `http://localhost:11434` | Ollama API base URL |
| `ZSH_AI_COMPLETE_MODEL` | `qwen2.5-coder:7b` | Model to use for completions |
| `ZSH_AI_COMPLETE_DEBOUNCE` | `150` | Keystroke debounce delay (ms) |
| `ZSH_AI_COMPLETE_TIMEOUT` | `4` | HTTP request timeout (seconds) |
| `ZSH_AI_COMPLETE_TRIGGER` | `auto` | Trigger mode: `auto` or `manual` |
| `ZSH_AI_COMPLETE_HISTORY_SIZE` | `20` | Number of history entries for context |
| `ZSH_AI_COMPLETE_DIR_LIMIT` | `50` | Max directory entries in context |
| `ZSH_AI_COMPLETE_MIN_CHARS` | `3` | Min characters before triggering |

### zstyle alternative

```zsh
# Add to .zshrc before sourcing the plugin
zstyle ':zai:config' model 'qwen2.5-coder:7b'
zstyle ':zai:config' debounce 200
zstyle ':zai:config' trigger manual
```

## Troubleshooting

See the full [Runbook](RUNBOOK.md) for detailed troubleshooting, verification steps, and operational guidance.

**Common issues:**

- **No suggestions appearing** — ensure Ollama is running (`curl -s http://localhost:11434`) and the model is pulled (`ollama list`)
- **Slow suggestions** — try a smaller model (`qwen2.5-coder:3b`) or increase the debounce delay
- **High CPU usage** — increase debounce delay or switch to `manual` trigger mode

## Uninstallation

```bash
cd zsh-ai-complete
bash scripts/uninstall.sh        # remove plugin files
bash scripts/uninstall.sh --purge # also remove cache directory
```

## Contributing

Contributions are welcome! Please read the [Contributing Guide](CONTRIBUTING.md) before submitting a pull request.

## Security

This plugin enforces a localhost-only security model. No data is sent to external servers. See [SECURITY.md](SECURITY.md) for the full security policy and how to report vulnerabilities.

## License

[MIT](LICENSE)
