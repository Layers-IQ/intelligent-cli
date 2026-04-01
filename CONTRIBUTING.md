# Contributing to zsh-ai-complete

Thanks for your interest in contributing! This guide will help you get started.

## Getting Started

### Prerequisites

- Zsh >= 5.3
- [Ollama](https://ollama.ai) with `qwen2.5-coder:7b` model pulled
- [ShellCheck](https://www.shellcheck.net/) for linting

### Local Development Setup

```bash
# Clone the repo
git clone https://github.com/amangupta/zsh-ai-complete.git
cd zsh-ai-complete

# Source the plugin directly for testing
source plugin/zsh-ai-complete.plugin.zsh
```

### Running Tests

The test suite uses a TAP-compatible runner:

```bash
# Run all tests
zsh tests/test_runner.zsh

# Run a specific test file
zsh tests/test_config.zsh
```

### Linting

```bash
# Run ShellCheck on all plugin files
shellcheck plugin/lib/*.zsh plugin/zsh-ai-complete.plugin.zsh scripts/*.sh
```

## Making Changes

1. **Fork the repo** and create a feature branch from `main`:
   ```bash
   git checkout -b feature/my-change
   ```

2. **Make your changes** — keep commits focused and atomic.

3. **Run the tests** to make sure nothing is broken.

4. **Run ShellCheck** and fix any warnings.

5. **Submit a pull request** against `main`.

## Code Style

- Pure Zsh — no external dependencies beyond `curl` and Ollama
- All internal functions are prefixed with `_zai_`
- All global variables are prefixed with `_ZAI_`
- Guard against double-sourcing with `(( ${+_ZAI_<MODULE>_LOADED} )) && return 0`
- Keep modules independent where possible; dependencies are documented in file headers

## Pull Request Guidelines

- Keep PRs focused on a single change
- Include a clear description of what and why
- Add or update tests for new functionality
- Ensure CI passes (lint + test workflows)
- Reference any related issues

## Reporting Bugs

Use [GitHub Issues](https://github.com/amangupta/zsh-ai-complete/issues) with the bug report template. Please include:

- Zsh version (`zsh --version`)
- OS and version
- Ollama version (`ollama --version`)
- Steps to reproduce
- Expected vs actual behavior

## Suggesting Features

Open a [GitHub Issue](https://github.com/amangupta/zsh-ai-complete/issues) with the feature request template. Describe the use case and why it would be valuable.

## Code of Conduct

This project follows the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md). By participating, you agree to uphold these standards.
