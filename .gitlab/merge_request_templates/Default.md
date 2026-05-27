## Summary

(What does this MR change?)

## Security checklist

- [ ] No new uncapped allocations driven by external data
- [ ] No new `@intCast` of untrusted values (use `std.math.cast` or `std.math.add` with overflow handling)
- [ ] New parsers include bounds checks and have fuzz coverage where reasonable
- [ ] Inputs at API boundary are validated before side effects
- [ ] Tests cover failure modes, not just the happy path
- [ ] No secrets in the diff (API keys, tokens, hardcoded credentials)
- [ ] Single-thread contract preserved for any mutating Engine method

## Test plan

- [ ] `zig build test` (unit)
- [ ] `zig build test-integration` (integration)
- [ ] `zig build test-stress` (stress, if touching durability or memory paths)

## Closes / related

(Link Gap-IDs from `docs/*GAP_ANALYSIS.md`, e.g. `Closes SEC-EXT-0123, PERF-0045`)
