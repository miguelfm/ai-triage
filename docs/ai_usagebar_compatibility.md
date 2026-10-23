# ai-usagebar compatibility audit

AI Triage **1.6.3** includes the compatibility corrections documented below.

Checked on 2026-10-23 against the latest published release,
[v1.43.0](https://github.com/akitaonrails/ai-usagebar/releases/tag/v1.43.0),
commit `d1af986`. Installed shell: Noctalia v5.3.0.

The integration consumes `ai-usagebar usage --json`, schema version 1. The CLI
continues to own authentication, provider requests, caching, token renewal and
rate-limit backoff. The plugin consumes the report without modifying credentials.
See upstream's [report projection](https://github.com/akitaonrails/ai-usagebar/blob/v1.43.0/src/report.rs)
and [Antigravity CLI deadlines](https://github.com/akitaonrails/ai-usagebar/blob/v1.43.0/src/antigravity/agy.rs).

## Findings and corrections

| Area | Verified behavior |
| --- | --- |
| Commands and exit codes | `usage --json` remains valid. Complete reports are accepted with individual provider errors; a timed-out process never publishes its partial stdout. Missing commands and refused spawns clear the busy state. |
| Long queries | Upstream permits 90 seconds for a cold `agy` quota read. Noctalia caps `runAsync` at 60 seconds, so the poller now uses `runStream` with coreutils `timeout`, a completion marker and a configurable 180-second overall deadline. Deadlines terminate the CLI process group. |
| Provider catalog | All 30 IDs from `ai-usagebar vendors --json` are selectable and have glyphs, links and labels in all shipped locales. `gemini` and `claude-oss` remain plugin aliases for Antigravity model groups. |
| Grouped metrics | Claude's `group: Sessions` context windows and other grouped breakdowns do not exhaust an account's quota or fill an absent weekly window. |
| Partial quotas | A weekly-only response stays weekly-only; two session metrics do not fabricate a weekly quota. Missing windows render as `Not reported`, and weekly-only tooltips contain no `nil` prefix. |
| Amounts and balances | `headline: value` is honored by the capsule and tooltip. Existing balance-only providers remain supported. |
| Model pools | Exhausted `model_pool` rows do not override shared provider capacity; Gemini Argon keeps its model identity instead of becoming Claude/GPT OSS. |
| Accounts | Antigravity model selectors honor account suffixes. Local default-login observations do not overwrite named-account reports. Reset inventories, advice, calibration and schedule rows retain separate account identities. A named account never receives a kickstart button that would silently use the CLI's default login. |
| Reset inventory | Structured `reset_credits` is authoritative, including `available: 0`. Count-only inventories remain visible without invented expiration dates; absent weekly quota or unknown expiration produces no automatic claim recommendation. Legacy text-only inventories remain supported. |
| Failures and stale data | HTTP diagnostics remain visible in pinned tooltips; stale HTTP-error readings are not treated as live quota. Successful reads replace failures. Existing redaction tests continue to pass. |
| Antigravity reconciliation | The plugin only enriches default-account Cloud Code fallback readings (`Source: Google API`). It preserves newer upstream `agy`/statusline readings instead of querying the default account again. |

## Verification

From the repository root:

```sh
for test in tests/*_test.lua; do
  TZ=America/New_York lua "$test" || exit
done
python tests/check_ai_usagebar.py --live
noctalia plugins lint .
noctalia config validate
```

The eight Lua suites pass. The Python check compares the installed provider
catalog with the recorded 1.43.0 catalog and the manifest/translations. It also
executes the poller's actual shell command with isolated fake CLI processes to
check success, failure and timeout markers. With `--live`, it queries configured
providers and feeds their actual JSON document through the poller and mocked
bar/panel hosts. Without `--live`, it makes no quota requests.

Live authenticated checks on this machine returned `ready`, `stale: false` for
Claude, Codex and Antigravity. After reloading the plugin, its panel was also
opened and visually checked in Noctalia: current Claude/Codex quotas and the
locally reconciled Gemini quota appeared correctly. Native lint reports zero
errors and zero warnings; the active shell configuration validates.

## Scope and limits

Compatibility with the JSON contract does not mean feature parity with every
ai-usagebar frontend. This panel focuses on short/weekly quota triage and reset
credits. Supplementary context/activity rows, Cursor's text-based on-demand cap,
and additional monthly/provider-specific breakdowns are not all rendered as
dedicated cards. Grouped context data is deliberately excluded from quota ranking.
Custom providers can appear in Automatic mode with generic presentation; the
fixed selector lists built-in providers and the two Antigravity aliases.

Only the three configured providers above were tested against live authenticated
endpoints. Other providers and account shapes were checked through the common
contract, catalog, synthetic regression cases and source review; their individual
accounts/endpoints cannot be certified without configuring them. Future upstream
releases need the checks repeated. The catalog check fails if the installed CLI
adds or removes a built-in provider.
