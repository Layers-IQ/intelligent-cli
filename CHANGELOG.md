# Changelog

All notable changes to zsh-ai-complete will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **Plugin loader** (`zsh-ai-complete.plugin.zsh`) — single entry point that sources all modules in dependency order, measures startup overhead, and enforces zsh 5.3+ requirement
- **Initialization module** (`plugin/lib/init.zsh`) — two-phase startup: synchronous widget/keybinding registration (<20ms), then async Ollama health check and model warm-up via precmd hook
- **Apply-completion widget** (`_zai_widget_apply_completion`) — routes async completions through a real ZLE widget so BUFFER and POSTDISPLAY work correctly on all zsh/macOS builds
- **Install/uninstall scripts** (`scripts/install.sh`, `scripts/uninstall.sh`, `scripts/uninstall-competing.sh`) — auto-detect plugin manager and configure accordingly
- **CI: lint workflow** (`.github/workflows/lint.yml`) — static analysis for shell scripts
- **CI: release workflow** (`.github/workflows/release.yml`) — automated release pipeline
- **New test suites** — `test_async.zsh`, `test_init.zsh`, `test_keybindings.zsh` (all wired into CI)
- **Project docs** — `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `RUNBOOK.md`, `LICENSE` (MIT)

### Changed

- **Default model** upgraded from `qwen2.5-coder:3b` to `qwen2.5-coder:7b` for better completion quality
- **Prompt construction** — added `\n$ ` separator between context and buffer so the model treats the buffer as a shell command line, not a continuation of the context narrative
- **`raw: true`** moved from per-mode generation params into the top-level Ollama request body (applies to all modes uniformly)
- **CI test matrix** expanded — file-existence checks and test steps now cover keybindings, async, init, plugin loader, and scripts
- **CI branch triggers** now include `release/**` branches

### Fixed

- **BUFFER empty in `zle -F` callbacks** — captured BUFFER at debounce-start time (`_ZAI_DEBOUNCE_BUFFER`) and applied completions via a dedicated ZLE widget instead of directly in the fd callback; fixes ghost text not rendering on some zsh/macOS builds
- **Premature Ollama unavailability** — now requires 3 consecutive `UNAVAIL` responses before marking Ollama down (previously a single transient failure would disable completions until cooldown expired)
