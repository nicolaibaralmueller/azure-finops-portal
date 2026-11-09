# Security Policy

## Supported versions

This project is provided as a self-hosted reference solution. Security fixes are
applied to the latest `master` (and the most recent tagged release). Older tags are
not maintained.

## Reporting a vulnerability

**Please do not open a public issue for security vulnerabilities.**

Report privately through GitHub's **[Private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)**:
Security tab → **Report a vulnerability**. (Maintainers: enable this under
Settings → Code security → *Private vulnerability reporting*.)

If you can't use that channel, contact the maintainer at `33453919+nicolaibaralmueller@users.noreply.github.com`.

Please include:

- A description of the issue and its impact.
- Steps to reproduce (or a proof of concept).
- The affected file(s)/component (portal, Function App API, Bicep, setup scripts, AI adapter).

We aim to acknowledge reports within **5 business days** and to agree on a
disclosure timeline once the issue is confirmed.

## Scope and shared responsibility

This solution deploys into **your own** Azure subscription and Entra ID tenant.
Some of the security posture is determined by how you deploy and configure it,
not by this codebase. In particular, deployers are responsible for:

- Granting the Function App managed identity **least-privilege** RBAC roles
  (see [docs/security.md](docs/security.md)) and reviewing them periodically.
- Protecting the **BYOK AI provider key** when one is used (`aiAuthMode=apiKey`; it lives in
  Key Vault, never in source). Prefer `aiAuthMode=managedIdentity` for Azure OpenAI / Foundry:
  no key at all. EasyAuth has **no client secret**: it signs in with the portal's managed
  identity through a federated credential.
- Restricting portal access (`portalAllowedIpRanges`, role assignments) as appropriate.
- Keeping `*.local.json` parameter files and `Setup/_setup-context.json` out of
  source control (they are git-ignored by default).

Issues that stem solely from a misconfiguration of *your* deployment (rather than a
flaw in this code) are best raised as a normal issue or discussion.
