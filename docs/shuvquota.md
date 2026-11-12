# Optional Shuvquota backend

AI Triage 1.12.0 adds an experimental collector option. AIUsageBar remains the
default. Both readers publish the same internal report structure to the bar,
panel, routing engine and reset-history tracker.

## Setup

Configure and authenticate Shuvquota outside Noctalia. AI Triage does not read
credentials, manage accounts, start the service, or perform OAuth flows.

For the Arch package with its optional user service:

```sh
systemctl --user enable --now shuvquota.service
```

In AI Triage settings, choose **Quota source → Shuvquota (experimental)**.
The **Shuvquota collector URL** defaults to `http://127.0.0.1:4789`. The plugin
appends `/api/quota`. Accepted bases use plain HTTP and `127.0.0.1`, `localhost`,
or `[::1]`, optionally with a port. Remote hosts, credentials in URLs, paths,
query strings and redirects are not used. The public API is unauthenticated;
keep the collector on loopback.

To return to the original reader, select **AIUsageBar (default)**. Each backend
is responsible for its own account configuration. The provider dropdown retains
the original AIUsageBar catalog; selecting a provider absent from the selected
collector does not configure or authenticate it.

## Supported contract and projection

The reader requires a complete Shuvquota schema-2 snapshot with a valid
`generatedAt` timestamp. Native `noctalia.http` performs one request per poll;
no `curl`, Node process, or Shuvquota CLI process is spawned by the plugin.
Responses are bounded to 1 MiB. A 30-second service watchdog releases a lost
callback and rejects late responses. The normal refresh interval remains five
minutes unless changed by the user or brought forward to a weekly reset.

| Shuvquota | AI Triage |
| --- | --- |
| `codex` | `openai@<label>`; session and weekly windows |
| `claude` | `anthropic@<label>`; shared session, all-model weekly, optional Fable detail |
| `antigravity` | `antigravity@<label>`; separate Gemini and Claude/GPT session/weekly pools |
| `percentRemaining` | `100 - percentRemaining`, retaining fractional precision |
| `windowSeconds` | `window_secs`; absent cadence is not inferred from array position |
| `resetsAt` | Provider reset deadline, never replaced with a synthetic cycle |
| `generatedAt` | Snapshot completion time; not a per-window provider timestamp |

This first adapter handles Codex, Claude and Antigravity. Other Shuvquota
providers require explicit mappings before they can participate in triage.
Unknown or unclassified windows are supplementary data, not shared provider
capacity. Unsupported schema versions, duplicate identities, future timestamps
and contradictory percentages are rejected. Unavailable values remain unknown.

All Shuvquota accounts retain their label suffix, including a single account
named `personal`. Use the same label in a pinned capsule's account setting when
selecting it explicitly. The API's masked email and label are not proof that the
account is the CLI's current login, so the session kickstart button stays disabled
for these named accounts. Fable keeps its existing informational behavior and
does not acquire independent routing or calibration.

## Resets and missing detail

Claude grants retain type, count and known expiration. Groups are expanded into
bounded individual records for the existing credit planner. Future grants are
shown as scheduled information and excluded from currently available credits;
session-only or unknown-scope grants do not drive weekly-reset advice. Invalid or
incomplete grant inventories retain an authoritative count when available,
without inventing missing records.

The current Codex API projection contains a count and **next** banked expiry,
not the full grant inventory. AI Triage shows an aggregate card explicitly marked
as the next expiry. It does not assume every credit shares that date, reconstruct
missing individual grants, or use the partial inventory for automatic reset
claim/hold/collision recommendations. AIUsageBar remains the option for its
existing detailed inventory behavior.

## Failures and state isolation

Collector connection, HTTP, URL, schema and timeout errors have dedicated hints.
Per-account errors remain separate from healthy accounts. Authentication
diagnostics point to Shuvquota rather than asking users to change the native
agent's login. The reader never falls back to AIUsageBar automatically and never
enriches a Shuvquota account using the local default `agy` session.

Last valid data can remain visible after a failed request. Failed account reads
retain only the dated metrics of the same account and collector and are marked
stale/unavailable. Snapshot times are never advanced just by reading cached data.
Restored Shuvquota reports remain historical until a fresh poll confirms them.
Old snapshots use the existing freshness horizon: at least fifteen minutes or
twice the configured refresh interval.

The default backend retains the legacy `last-report.json` and
`weekly-resets.json` paths. Shuvquota uses filenames suffixed by its loopback
host and port. Its archived reset-event IDs and calibration keys also include
that collector scope. Switching source or URL clears the active report and
invalidates old callbacks; it cannot turn another backend's reading into a new
reset or calibration sample. Manually replacing an account under the same label
is not detectable from the public API; use stable account labels and reconfigure
the collector deliberately when changing billing identity.

## Verification

```sh
for test in tests/*_test.lua; do
  TZ=America/New_York lua "$test" || exit
done
TZ=Europe/Brussels lua tests/schedule_test.lua
TZ=Europe/Brussels lua tests/credit_deadline_test.lua
python tests/check_shuvquota.py --live
noctalia plugins lint .
```

Version 1.12.1 keeps the model-specific Fable limit separate from Claude's shared
quota in the headline, weekly gauge and routing inputs, even when Shuvquota
returns Fable before the overall weekly window. Its 100% reading remains in the
optional Fable detail. See the [quota-selection regression audit](ai_usagebar_compatibility.md#claude-account-quota-selection-in-1121).

The fixture tests cover rounding versus calculation precision, cadence, separate
Antigravity pools, Fable, missing/partial/future credits, named accounts,
equivalent-quota routing scores, backend and URL changes, persistent report and
history paths, calibration keys, partial failures, lost callbacks, late replies
and refused requests. The live check reads only the public local endpoint,
stores its snapshot in a private temporary file and passes it through the actual
adapter, poller, bar and panel in mocked Noctalia hosts.

On 2026-11-11 the live service returned one healthy account for each of Codex,
Claude and Antigravity. All three rendered through that host replay, including
fractional Antigravity percentages. Existing Lua suites and both Brussels
schedule/deadline checks passed; plugin lint reported no errors or warnings.
The separate installed AIUsageBar catalog check still reports the previously
documented catalog mismatch; this backend change does not update that catalog.
