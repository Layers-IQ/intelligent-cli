# Security Policy

## Security Model

zsh-ai-complete enforces a **strict localhost-only** communication model:

- All LLM inference requests are sent exclusively to `localhost` / `127.0.0.1` / `::1`
- URL validation rejects credential-embedding attacks, subdomain tricks, and non-loopback addresses
- `curl --interface lo/lo0` enforces OS-level loopback routing as defense-in-depth
- Prompt data is piped via stdin (`-d @-`) so it never appears in process listings

## Secret Redaction

The plugin includes a 3-layer security filter that runs before any data is sent to the model:

1. **Filename filtering** - Sensitive files (`.env`, `*.pem`, `*.key`, credentials) are excluded from context
2. **Secret redaction** - 17+ patterns (API keys, tokens, PEM blocks, JWTs, high-entropy strings) are replaced with `[REDACTED]`
3. **Prompt sanitization** - Non-printable Unicode, FIM injection tokens, and LLM prompt-injection keywords are stripped

## Supported Versions

| Version | Supported |
|---------|-----------|
| latest  | Yes       |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly:

1. **Do NOT open a public GitHub issue** for security vulnerabilities
2. Use [GitHub Security Advisories](https://github.com/amangupta/zsh-ai-complete/security/advisories/new) to report privately
3. Include: description, steps to reproduce, potential impact, and suggested fix (if any)
4. You will receive an acknowledgment within 48 hours
5. We will work with you to understand and address the issue before any public disclosure

## Security Best Practices for Users

- Keep Ollama running on the default `localhost:11434` - do not expose it to a network
- Do not modify `ZSH_AI_COMPLETE_OLLAMA_URL` to point to a remote server
- Keep the plugin updated to receive security patches
- Review the cache directory permissions: `~/.cache/zsh-ai-complete/` should be mode `700`
