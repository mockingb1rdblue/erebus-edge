# Charon-Cicada Onboarding Notes — erebus-edge

## No-deploy classification

erebus-edge has no Cloudflare Worker deploy targets. The project distributes
Bash/TypeScript installers that users run locally. No `wrangler.toml` files
exist at the repo root or in subdirectories.

Charon-Cicada onboarding: Steps 1 (VaultKeeper), 3 (webhook), and 4 (GH Actions cleanup)
are not applicable. Only Step 2 (namespace) and Step 5 (.namespace file) apply.
