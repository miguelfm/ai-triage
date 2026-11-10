# Noctalia 5.4 integration

Reviewed on 2026-11-05: AI Triage 1.8.4, plugin_api = 43, installed Noctalia 5.4.0.
Version 1.8.4 introduces Fast Boot resilience and persistent report caching.
Version 1.8.3 adds DeepRelay and validates full compatibility against ai-usagebar 1.47.0.
Panel geometry and runtime contract remain unchanged.

Version 1.9.0 adds concise model-specific reset labels while keeping general
resets unlabeled. See the [reset scope audit](ai_usagebar_compatibility.md#model-specific-reset-labels-in-190)
for the November 10 review, real-panel verification and the remaining
overall-weekly estimate limitation. The API 43 and panel geometry contract below
remain unchanged.

## Fast Boot and cold-start report persistence in 1.8.4

Under Noctalia 5.4 and systemd/UWSM with parallel session launch (`-g -1`), the graphical shell and plugin service start before network/DNS connectivity (`network-online.target`) is fully resolved.

Version 1.8.4 introduces:
- **Zero-millisecond cold start via disk caching**: The service persists the latest authoritative report into `~/.local/state/noctalia/plugins/data/miguelfm/ai-triage/last-report.json`. On initialization, `service.luau` reads this file immediately to populate `noctalia.state` with `report` before the first CLI spawn.
- **Progressive failure retry**: If `ai-usagebar usage --json` fails due to unready network/DNS (`Could not resolve host` or timeout), `scheduleFailureRetry` replaces the standard 3–5 minute polling interval with progressive backoff (8s, 16s... up to 60s). Once network connectivity is established and a refresh succeeds, the retry counter resets to zero and normal periodic polling resumes.
- **Panel loading states and instant render**: `onOpen()` reads cached state and calls `render()` immediately before triggering a refresh request, eliminating startup latency and blank/flickering cards. When opening the panel while polling without candidates, the UI displays a clean loading status instead of falsely reporting "No providers configured or reachable."

## Panel contract

| Field | Value |
| --- | --- |
| width | 1520 |
| height | "content" |
| max_height | 675 |
| placement / position | attached / auto |
| open_near_click | true |

Noctalia measures content height automatically and sizes the panel to fit the
rendered tree, capped at the declared maximum. Because the layout uses
`height = "content"`, the panel only takes as much vertical space as the cards
and headers require, leaving zero empty space for smaller setups while allowing
configurations with 3–5 models and reset credit schedules under the Huge (130%)
typography scale preset to render without triggering vertical scrollbars.

The three columns retain independent native scrolling (`ui.scroll`) as a safe
fallback for extended provider lists that exceed the 675px ceiling.

## Colors and API compatibility

The plugin uses surface_container and outline_variant. on_surface_variant
remains a valid role. variant = "outline" is a button style and must not be
renamed. The review found no remaining surface_variant or outline color roles.

Layer surfaces, idle watches, calendar access, drag and drop and pixel streams
are optional capabilities, not dependencies of this panel. Desktop scripts use
OSD separately; persistent results and errors keep their notification behavior.
A compatible plugin does not need to adopt every new API.

## Verification and sources

Both noctalia plugins lint and noctalia config validate passed. The running
shell lists 1.8.1 as an enabled local plugin. Its symlink points to this checkout;
shared dotfiles reference the plugin without copying its source into their repos.
All twelve tests/*_test.lua suites passed with TZ=America/New_York. Mocked UI
tests validate widget trees and behavior, not actual Wayland pixel geometry.

The catalog mismatch found in the initial review was fixed in 1.8.1. The
selector, three translated catalogs, glyph/dashboard mappings and recorded
1.44 catalog now include Droid; the strict guard covers all 31 provider IDs.
Regressions cover pinning Droid alongside another provider, Standard 5h/weekly
quotas, monthly/Core supplementary data and the poller-to-bar/panel path.
The original twelve suites and both additional timezone checks pass.

Droid is not configured on this machine, so its rendering was checked with
synthetic schema-1 reports, not an authenticated Factory quota response. The
shared report remains focused on short/weekly triage rather than implementing
every provider-specific monthly/Core view. See the
[compatibility audit](ai_usagebar_compatibility.md#factory-droid-and-the-144-catalog-in-181).

Official references:

- [Noctalia 5.4.0 release notes](https://github.com/noctalia-dev/noctalia/releases/tag/v5.4.0).
- [Manifest and minimum API contract](https://docs.noctalia.dev/noctalia/plugins/development/manifest/).
- [Runtime API](https://docs.noctalia.dev/noctalia/plugins/development/runtime-api/).

As of 2026-10-27, 5.4.0 is the only published release in the 5.4.x series.
Check release notes and validate again for future versions; this review cannot
certify unpublished changes.
