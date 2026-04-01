# zsh-ai-complete Operational Runbook

> **Plugin:** `zsh-ai-complete` — AI-powered zsh autocomplete via Ollama + qwen2.5-coder
> **Version:** 1.x
> **Last Updated:** 2026-04-01

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Installation](#installation)
3. [Configuration Reference](#configuration-reference)
4. [Verification](#verification)
5. [Troubleshooting](#troubleshooting)
6. [Update / Upgrade](#update--upgrade)
7. [Uninstallation](#uninstallation)
8. [Rollback](#rollback)
9. [Security Checklist](#security-checklist)

---

## Prerequisites

| Requirement | Version | Check |
|-------------|---------|-------|
| zsh | ≥ 5.3 | `zsh --version` |
| curl | any | `curl --version` |
| Ollama | latest | `ollama --version` |
| qwen2.5-coder model | 3b or 7b | `ollama list` |

### Install Ollama

```bash
# macOS
brew install ollama

# Linux (official script)
curl -fsSL https://ollama.ai/install.sh | sh

# Verify
ollama --version
```

### Pull the model

```bash
ollama pull qwen2.5-coder:7b   # ~2GB, fast on CPU
# or
ollama pull qwen2.5-coder:7b   # ~4GB, better quality
```

### Start Ollama (if not using system service)

```bash
ollama serve &
# Verify reachability
curl -s http://localhost:11434 | head -1
```

---

## Installation

### Quick install (auto-detect plugin manager)

```bash
git clone https://github.com/<user>/zsh-ai-complete.git
cd zsh-ai-complete
bash scripts/install.sh
```

### Install for oh-my-zsh

```bash
bash scripts/install.sh --method=oh-my-zsh
```

Then add to `~/.zshrc`:
```zsh
plugins=(... zsh-ai-complete)
```

### Install for zinit

```bash
bash scripts/install.sh --method=zinit
```

Then add to `~/.zshrc`:
```zsh
zinit light <user>/zsh-ai-complete
```

Or for local install:
```zsh
zinit load /path/to/zsh-ai-complete/plugin
```

### Install for antigen

```bash
bash scripts/install.sh --method=antigen
```

Then add to `~/.zshrc`:
```zsh
antigen bundle local/zsh-ai-complete
```

### Install for sheldon

```bash
bash scripts/install.sh --method=sheldon
sheldon lock
```

### Manual install

```bash
bash scripts/install.sh --method=manual
```

Then add to `~/.zshrc`:
```zsh
source ~/.local/share/zsh-ai-complete/zsh-ai-complete.plugin.zsh
```

### Reload shell

```bash
exec zsh
```

---

## Configuration Reference

All configuration is via environment variables (set in `.zshrc` **before** sourcing the plugin):

| Variable | Default | Description |
|----------|---------|-------------|
| `ZSH_AI_COMPLETE_OLLAMA_URL` | `http://localhost:11434` | Ollama API base URL. Must be localhost. |
| `ZSH_AI_COMPLETE_MODEL` | `qwen2.5-coder:7b` | Ollama model to use |
| `ZSH_AI_COMPLETE_TRIGGER` | `auto` | `auto` = debounced on every keystroke; `manual` = only on Ctrl+Space |
| `ZSH_AI_COMPLETE_DEBOUNCE` | `150` | Keystroke debounce delay in milliseconds (10–10000) |
| `ZSH_AI_COMPLETE_TIMEOUT` | `4` | HTTP request timeout in seconds (1–120) |
| `ZSH_AI_COMPLETE_HISTORY_SIZE` | `20` | Number of history entries to include as context |
| `ZSH_AI_COMPLETE_DIR_LIMIT` | `50` | Max directory entries in context |
| `ZSH_AI_COMPLETE_MIN_CHARS` | `3` | Minimum buffer length before triggering |

### zstyle alternative

```zsh
# These are checked as fallback after env vars
zstyle ':zai:config' debounce 200
zstyle ':zai:config' trigger manual
zstyle ':zai:config' model qwen2.5-coder:7b
```

### Recommended `.zshrc` configuration block

```zsh
# zsh-ai-complete configuration
export ZSH_AI_COMPLETE_OLLAMA_URL="http://localhost:11434"
export ZSH_AI_COMPLETE_MODEL="qwen2.5-coder:7b"
export ZSH_AI_COMPLETE_TRIGGER="auto"
export ZSH_AI_COMPLETE_DEBOUNCE="150"
export ZSH_AI_COMPLETE_TIMEOUT="4"

# Source the plugin (manual install example)
source ~/.local/share/zsh-ai-complete/zsh-ai-complete.plugin.zsh
```

### Keybindings

| Key | Action |
|-----|--------|
| `Right Arrow` | Accept current suggestion |
| `Tab` | Accept current suggestion |
| `Escape` | Dismiss current suggestion |
| `Ctrl+Space` | Manually trigger completion (bypasses debounce) |
| `Ctrl+E` | Explain current command (if enabled) |

---

## Verification

After installation and opening a new shell:

```bash
# 1. Check that the plugin loaded
print $_ZAI_PLUGIN_LOADED          # → 1

# 2. Check startup overhead (should be < 100ms)
print $_ZAI_INIT_DURATION_MS       # → e.g. "8.42"

# 3. Show active configuration
_zai_config_dump

# 4. Check Ollama connectivity manually
curl -s http://localhost:11434     # → "Ollama is running"

# 5. Check model availability
curl -s http://localhost:11434/api/tags | grep qwen2.5-coder

# 6. Test completion manually
# Type: git ch  (then pause ~300ms)
# → You should see ghost text like "eckout" appear inline
```

---

## Troubleshooting

### Problem: Plugin not loading / no completions

**Symptom:** No ghost text appears; `print $_ZAI_PLUGIN_LOADED` is empty.

**Diagnosis:**
```bash
# Check if plugin is sourced
grep -n 'zsh-ai-complete' ~/.zshrc

# Check for syntax errors
zsh -n ~/.zshrc 2>&1 | head -20

# Check zsh version
zsh --version
```

**Fix:**
1. Ensure the source/plugin line is in `~/.zshrc`
2. Ensure zsh ≥ 5.3: `zsh --version`
3. Run `exec zsh` to reload

---

### Problem: "Ollama not reachable" warning on startup

**Symptom:**
```
zsh-ai-complete: ⚠ WARNING — Ollama is not reachable at http://localhost:11434
```

**Diagnosis:**
```bash
# Is Ollama running?
pgrep -l ollama

# Can we reach the API?
curl -sv http://localhost:11434 2>&1 | tail -5

# Check if port is in use by something else
lsof -i :11434 2>/dev/null || ss -tlnp | grep 11434
```

**Fix:**
```bash
# Start Ollama
ollama serve

# Or start as background service (macOS)
brew services start ollama

# Or start as systemd service (Linux)
sudo systemctl start ollama
sudo systemctl enable ollama   # auto-start on boot
```

**Expected result:** Next keystroke in a new shell session will trigger AI completions.
History-based completions remain available while Ollama is stopped.

---

### Problem: "Model not found" warning

**Symptom:**
```
zsh-ai-complete: ⚠ WARNING — Model 'qwen2.5-coder:7b' not found in Ollama.
```

**Diagnosis:**
```bash
# List available models
ollama list

# Check configured model
print $ZSH_AI_COMPLETE_MODEL
```

**Fix:**
```bash
# Pull the default model
ollama pull qwen2.5-coder:7b

# Or switch to a model you already have
export ZSH_AI_COMPLETE_MODEL="$(ollama list | awk 'NR>1 {print $1}' | head -1)"
```

---

### Problem: Completions are very slow (> 2 seconds)

**Symptom:** Ghost text takes 2–5+ seconds to appear.

**Diagnosis:**
```bash
# Test raw Ollama latency
time curl -s -X POST http://localhost:11434/api/generate \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5-coder:7b","prompt":"git ","stream":false,"options":{"num_predict":20}}' \
  | grep -o '"response":"[^"]*"'
```

**Fixes:**
1. **Use a smaller model:** `export ZSH_AI_COMPLETE_MODEL="qwen2.5-coder:1.5b"`
2. **Increase timeout tolerance:** The 4s default already handles slow hardware
3. **Use manual mode to avoid constant requests:**
   ```bash
   export ZSH_AI_COMPLETE_TRIGGER="manual"
   ```
4. **Warm up the model first:**
   ```bash
   ollama run qwen2.5-coder:7b ""
   ```
5. **Check for GPU support:** Ollama uses CPU by default; GPU dramatically improves speed
   ```bash
   # On macOS (Apple Silicon)
   ollama --version   # Metal GPU support is built-in

   # On Linux (NVIDIA)
   nvidia-smi         # verify GPU is detected by Ollama
   ```

---

### Problem: Ghost text conflicts with zsh-autosuggestions

**Symptom:**
```
zsh-ai-complete: ⚠ ADVISORY — zsh-autosuggestions detected
```
Ghost text flickers or duplicates.

**Fix:**
Choose one of the two plugins. Both use `POSTDISPLAY` and the `self-insert` widget override — running them simultaneously causes conflicts.

```zsh
# In .zshrc — disable zsh-autosuggestions when using zsh-ai-complete:
# Comment out or remove:
# source ~/.oh-my-zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
# Or remove from plugins=() array
```

---

### Problem: Startup overhead > 100ms

**Symptom:** `print $_ZAI_INIT_DURATION_MS` shows > 100.

**Diagnosis:**
The synchronous init should be <20ms. High values indicate filesystem slowness or an unusual environment.

```bash
# Profile the startup
time zsh --login -i -c 'exit'

# Check for slow .zshrc operations
zsh -x ~/.zshrc 2>&1 | grep -E '^\+[0-9]+' | head -30
```

**Fix:**
- The plugin's synchronous init (<20ms) is not the issue at >100ms total
- Profile other `.zshrc` content
- Move heavy initializations (pyenv, nvm, conda) to lazy loading

---

### Problem: Completions include sensitive data warnings

**Symptom:** You're concerned that history or directory context might include secrets.

**Verify what context is sent:**
```bash
# Test the security filter manually (in a test directory)
mkdir /tmp/test-zai && cd /tmp/test-zai
touch normal-file.txt .env secrets.yaml

# The security filter should exclude .env and secrets.yaml
# You can inspect the context gathering function:
zsh -c 'source ~/.local/share/zsh-ai-complete/zsh-ai-complete.plugin.zsh 2>/dev/null
  echo "Dir context:" && _zai_gather_directory_context'
```

**Verify network is localhost-only:**
```bash
# While the plugin is active, monitor network connections
# (macOS)
lsof -i -P -n | grep curl

# (Linux)
ss -tp | grep curl
```

All `curl` connections should show `127.0.0.1:11434` or `localhost:11434` only.

---

### Problem: zle -F errors / async errors in terminal

**Symptom:** Occasional errors like `zle: unknown argument -F` or `bad file descriptor`.

**Diagnosis:** Likely a zsh version issue — zle -F requires zsh 5.3+.

```bash
zsh --version   # Must be ≥ 5.3
```

**Fix:**
```bash
# macOS (upgrade via Homebrew)
brew install zsh
# Add to /etc/shells and set as default shell:
echo "$(brew --prefix)/bin/zsh" | sudo tee -a /etc/shells
chsh -s "$(brew --prefix)/bin/zsh"

# Ubuntu
sudo apt-get install -y zsh   # usually 5.8+
```

---

### Problem: "zsh: command not found: ollama" on Ollama start

**Fix:**
```bash
# macOS
brew install ollama

# Linux — download binary
curl -Lo /usr/local/bin/ollama https://ollama.ai/download/ollama-linux-amd64
chmod +x /usr/local/bin/ollama

# Verify PATH
which ollama
ollama --version
```

---

### Collect debug information for bug reports

```bash
# Run this and include the output in your issue report
{
  echo "=== System Info ==="
  uname -a
  zsh --version
  curl --version | head -1

  echo ""
  echo "=== Plugin Info ==="
  print "Loaded: $_ZAI_PLUGIN_LOADED"
  print "Init time: ${_ZAI_INIT_DURATION_MS}ms"
  _zai_config_dump 2>&1

  echo ""
  echo "=== Ollama Status ==="
  curl -s http://localhost:11434 2>/dev/null | head -1 || echo "Ollama not reachable"
  ollama list 2>/dev/null | head -5 || echo "ollama not found"

  echo ""
  echo "=== Cache Dir ==="
  ls -la ~/.cache/zsh-ai-complete/ 2>/dev/null || echo "Cache dir not found"
} 2>&1 | tee /tmp/zai-debug-$(date +%Y%m%d-%H%M%S).txt
```

---

## Update / Upgrade

### Update from git (if installed from source)

```bash
cd /path/to/zsh-ai-complete-repo
git fetch origin
git checkout main
git pull origin main

# Re-run installer to update the plugin files
bash scripts/install.sh --method=<your-method>

# Reload shell
exec zsh
```

### Update via oh-my-zsh

```bash
# If installed as a git submodule / symlink:
cd ~/.oh-my-zsh/custom/plugins/zsh-ai-complete
git pull origin main
exec zsh
```

### Update via zinit

```bash
zinit update <user>/zsh-ai-complete
exec zsh
```

### Update Ollama model

```bash
# Pull latest version of the model
ollama pull qwen2.5-coder:7b

# Verify the update
ollama list | grep qwen2.5-coder
```

---

## Uninstallation

### Automated uninstall

```bash
# From the repository directory
bash scripts/uninstall.sh

# With cache directory removal
bash scripts/uninstall.sh --purge
```

### Manual uninstall

1. Remove from `~/.zshrc` — delete or comment out the source line:
   ```zsh
   # Remove this line:
   source ~/.local/share/zsh-ai-complete/zsh-ai-complete.plugin.zsh
   # Or remove from plugins=() array
   ```

2. Remove plugin files:
   ```bash
   rm -rf ~/.local/share/zsh-ai-complete          # manual install
   rm -rf ~/.oh-my-zsh/custom/plugins/zsh-ai-complete  # oh-my-zsh
   ```

3. Remove cache:
   ```bash
   rm -rf ~/.cache/zsh-ai-complete
   ```

4. Reload shell:
   ```bash
   exec zsh
   ```

---

## Rollback

### Rollback to a previous release

```bash
# List available release tags
git tag -l 'v*' | sort -V

# Checkout a specific version
git checkout v1.0.0

# Re-run installer
bash scripts/install.sh --method=<your-method>

# Reload
exec zsh
```

### Emergency disable (without uninstalling)

If the plugin causes issues and you need to disable it immediately:

```bash
# Disable for current session only (no restart needed)
unfunction _zai_init 2>/dev/null
_ZAI_PLUGIN_LOADED=0

# OR: start a new shell without loading .zshrc
zsh -f   # fast mode — no .zshrc loaded
```

### Disable permanently (without uninstalling)

Add to `~/.zshrc` before the source line:
```zsh
# Temporarily disable zsh-ai-complete
export ZSH_AI_COMPLETE_DISABLED=1
```

The plugin checks this variable and skips initialization if set.

---

## Security Checklist

Use this checklist periodically to verify the plugin's security posture:

- [ ] **No external network connections:**
  ```bash
  lsof -i -P -n 2>/dev/null | grep curl | grep -v '127.0.0.1\|localhost'
  # Expected: no output
  ```

- [ ] **Cache directory permissions are 700:**
  ```bash
  stat -f '%Mp%Lp %N' ~/.cache/zsh-ai-complete 2>/dev/null || \
  stat -c '%a %n' ~/.cache/zsh-ai-complete 2>/dev/null
  # Expected: 700 ~/.cache/zsh-ai-complete
  ```

- [ ] **Log files are 600 (owner-read only):**
  ```bash
  ls -la ~/.cache/zsh-ai-complete/*.log 2>/dev/null
  # Expected: -rw------- for all log files
  ```

- [ ] **Sensitive files excluded from context:**
  Navigate to a directory containing `.env` or `*.pem` files and verify
  the plugin does NOT include those filenames in completions.

- [ ] **Secrets redacted from history context:**
  Run: `export TEST_SK=sk-abcdefghij1234567890abcdefghij12`
  Then trigger a completion. The `sk-...` value should NOT appear in
  the ghost text or Ollama requests.

- [ ] **Plugin files have expected permissions:**
  ```bash
  ls -la ~/.local/share/zsh-ai-complete/plugin/lib/
  # Expected: 644 for .zsh files
  ```

- [ ] **Ollama URL is localhost only:**
  ```bash
  print $ZSH_AI_COMPLETE_OLLAMA_URL
  # Expected: http://localhost:11434 (or 127.0.0.1)
  ```

---

## Appendix: Ollama as a System Service

### macOS (launchd via Homebrew)

```bash
brew services start ollama
brew services list | grep ollama

# Enable auto-start on login
brew services enable ollama
```

### Linux (systemd)

```ini
# /etc/systemd/system/ollama.service
[Unit]
Description=Ollama LLM Service
After=network.target

[Service]
Type=simple
User=ollama
Group=ollama
ExecStart=/usr/local/bin/ollama serve
Restart=always
RestartSec=3
Environment=HOME=/home/ollama
Environment=OLLAMA_HOST=127.0.0.1:11434

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ollama
sudo systemctl status ollama
```

**Note:** The `OLLAMA_HOST=127.0.0.1:11434` binding ensures Ollama only listens on loopback, consistent with the plugin's localhost-only policy.
