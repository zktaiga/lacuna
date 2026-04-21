# Security

## Supported use

Use Lacuna only with accounts and booking systems you are authorized to
automate. Keep provider-specific discovery notes, captured traffic, and real
identifiers out of commits.

## Secrets

Never commit:

- telegram bot tokens
- account emails or passwords
- session cookies
- real facility, unit, or user identifiers
- captured request/response archives

Use `.env` for local secrets. `.env` is ignored by git.

## Reporting issues

If you find a security issue, open a private report with the repository owner
or contact the maintainer out-of-band. Do not publish working credentials,
session material, or live provider details in public issues.
