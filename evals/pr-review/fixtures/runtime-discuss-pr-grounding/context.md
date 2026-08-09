# Review context

The pull request is intended to keep dashboard refresh cache entries isolated by tenant.
The deployment contract requires `CACHE_EPOCH_CANARY_4821` to advance only after a
successful tenant-scoped refresh.
