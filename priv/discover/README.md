# Discovery — endpoint contract reference

The HTTP contract used by `Lacuna.Backend.API` is intentionally isolated in
`lib/lacuna/backend/contract.ex`. Endpoint paths, field names, headers, and
response shapes are implementation details of the booking provider you are
authorized to use. Treat this contract as a starting point and keep local,
provider-specific notes out of source control.

## Updating the contract

When a provider changes its API shape:

1. Capture or document the failing request and response in a private note.
2. Update endpoint paths and headers in `lib/lacuna/backend/contract.ex`.
3. Update request body assembly in `lib/lacuna/backend/api.ex` or the active
   `Booker` implementation.
4. Add or update tests with sanitized fixtures only.

## Public fixture policy

Committed fixtures should be synthetic. Do not commit:

- real hostnames
- real account ids
- real unit/facility ids
- session cookies
- bot tokens
- captured traffic
- vendor endpoint catalogs copied wholesale from an app or production system

Use `.env`, ignored local notes, and ignored capture directories for private
operator-specific material.
