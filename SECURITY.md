# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please report it responsibly.

**Do not open a public GitHub issue for security vulnerabilities.**

Instead, please email the maintainer directly or use [GitHub's private vulnerability reporting](../../security/advisories/new).

## Scope

This project is a **demonstration environment** for software supply chain security concepts. It is designed for workshop and learning scenarios, not for production use.

Default credentials (`admin`/`openshift`, `root`/`openshift`) are intentionally simple for demo purposes. In a production deployment, you would:

- Use external identity providers (LDAP, OIDC) instead of static passwords
- Store secrets with HashiCorp Vault or Sealed Secrets with real encryption keys
- Restrict network access with proper NetworkPolicies
- Enable TLS certificate rotation
- Pin operator versions rather than tracking `latest` channels

## Supported Versions

| Version | Supported |
|---------|-----------|
| main branch | ✅ |
| Other branches | ❌ |
