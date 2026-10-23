# ai-usagebar compatibility audit

AI Triage **1.6.3** introduced the compatibility corrections documented below.
Version **1.7.0** added failure diagnostics; **1.7.1** adds the weekly renewal
observations and confirmation behavior described below.

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
| Weekly renewal observations | Provider dates remain authoritative. A bounded local history explains early renewals and date-only changes without inventing another renewal calendar. Old or expired schedules cannot trigger weekly sprint or reset-credit recommendations. |

## Weekly renewal observations in 1.7.1

The poller stores its last valid observation per provider/account, metric label
and window plus the 32 latest changes in `weekly-resets.json` in the plugin data
directory. Baselines expire after 30 days. Credentials and full reports are not
stored in this history; failed, cached and out-of-order reads cannot replace a
valid baseline. A missing or corrupt history file starts a new history without
interrupting quota reads.

A usage drop of at least 5 percentage points and a later reset timestamp (beyond
60 seconds of drift) indicates a renewal. A renewal observed before the previous
deadline is recorded as early. Date-only shifts of at least one hour and changes
across different sources remain schedule changes, without claiming a renewal or
manual credit redemption. A smaller credit inventory is recorded as supporting
evidence only. The plugin never replaces the provider's `reset_at`.

The existing weekly clock and schedule tooltips show source, reading time and
changes detected within the last 24 hours. There are no new cards or settings.
Readings older than the greater of 15 minutes and twice the polling interval
show `~` in the schedule. Missing or expired dates show `Check` / `Pending
confirmation`, rather than a fabricated seven-day countdown. Old/unconfirmed
schedules do not generate weekly sprint or reset-credit advice; reported quota
exhaustion still blocks routing.

Polling is brought forward to the announced deadline. Expired dates are checked
again at the smaller of one minute and the configured interval, including after
failed queries. History starts with the first valid observation and cannot
reconstruct older renewals or predict an unannounced provider reset.

`tests/weekly_resets_test.lua` replays the October 22–23 Codex transition and
covers scheduled renewals, timestamp drift, source changes, credit inventory
evidence, old/failed reads, account/model isolation and bounded history.
`tests/refresh_test.lua` verifies deadline polling, retry intervals, persistence,
restart recovery and corrupt-file handling. `tests/panel_test.lua` checks that
renewal explanations stay in tooltips and unconfirmed schedules do not create
false countdowns or urgent alerts. On the installed shell, version 1.7.1 was
loaded and its history file populated with the configured provider baselines.

## Failure diagnostics in 1.7.0

Failed providers remain visible in the panel, including HTTP 401/403 responses
that previously removed their cards. Each failure shows a classified cause, a
recommended action and the CLI's original diagnostic. Explicitly hidden providers
remain hidden. The automatic bar continues to meter working providers while its
tooltip retains failed providers and their recovery guidance.

| Cause | Recommended action |
| --- | --- |
| Missing or rejected default Claude login | Run `claude auth login`, then refresh. The panel offers a command copy button. |
| Named account login failure | Reconnect that named account in ai-usagebar, then refresh. |
| Missing or rejected API key | Check the provider's API key configuration, then refresh. |
| HTTP 403 without a specific authentication rejection | Check account permissions and subscription. |
| HTTP 429 | Wait for the retry window and the next automatic refresh. |
| HTTP 5xx | Wait for the provider to recover. |
| Connection or timeout | Check network/VPN/proxy or increase the query timeout when appropriate. |
| Unexpected response format | Update ai-usagebar; report persistent schema errors. |
| Missing local Antigravity session | Open Antigravity or an `agy` session, sign in if needed, then refresh. |
| Credential file problem | Check saved credentials and file permissions. |

Rate-limit and server failures take precedence over authentication words in the
same error, so they never recommend logging in again. Unknown failures preserve
the original detail with a general refresh/status recommendation. A failed
overall quota refresh also remains visible when an older report is available.
Successful reads remove the old diagnosis. Failed quota snapshots do not enter
calibration, reset-credit recommendations or renewal schedules.

The failure cards were also checked visually in an isolated temporary Noctalia
preview with simulated sign-in, API-key and rate-limit errors. The preview was
removed after verification; the live provider logins were unchanged.

These messages depend on the diagnostic ai-usagebar reports: an upstream error
that withholds its cause cannot be made more specific reliably. The panel's
sign-in command is copied only when its button is clicked, for manual execution.

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

The ten Lua suites pass, including weekly renewal observations, 22 diagnostic
classification cases, visible recovery guidance, clipboard actions, automatic-bar failures and recovery after
a successful read. The Python check compares the installed provider
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
