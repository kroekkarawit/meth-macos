# Security Policy

## Reporting a vulnerability

Please report security issues **privately** through
[GitHub Security Advisories](https://github.com/kroekkarawit/meth-macos/security/advisories/new).
Do not open public issues for vulnerabilities. You'll get an acknowledgement within a few days.

In scope, most importantly: the privileged helper (`MethHelper`), XPC authentication between the app, CLI, agent and helper,
and the update pipeline (Sparkle feed and signatures).

## Supported versions

Only the latest release receives security fixes. Sparkle delivers them automatically.

## Design summary

See [docs/SECURITY.md](docs/SECURITY.md) for the threat model and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for details.
