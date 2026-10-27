# Noctalia 5.4 integration

Reviewed on 2026-10-27: AI Triage 1.8.0, plugin_api = 43, installed Noctalia 5.4.0.
Miguel confirmed that the previous agent's resizing correction works. This
review changes documentation only; panel geometry and runtime behavior stay as
accepted by the user.

## Panel contract

| Field | Value |
| --- | --- |
| width | 1520 |
| height | "content" |
| max_height | 560 |
| placement / position | attached / auto |
| open_near_click | true |

Noctalia measures content height and limits it to the declared maximum. This
does not make the fixed width responsive. Dimensions are logical pixels; the
physical result depends on scale and available space. The visual confirmation
covers Miguel's machine, not every resolution, scale or a separate niri session.

The three columns retain independent scrolling for longer lists. Keep the
accepted maximum of 560; do not restore the initial migration's 780 limit or
remove internal scrolling merely to shrink the panel.

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
shell lists 1.8.0 as an enabled local plugin. Its symlink points to this checkout;
shared dotfiles reference the plugin without copying its source into their repos.
All twelve tests/*_test.lua suites passed with TZ=America/New_York. Mocked UI
tests validate widget trees and behavior, not actual Wayland pixel geometry.

The Python catalog guard found ai-usagebar 1.44.0 with 31 providers. Droid (id
droid) is new relative to the 1.43 fixture's 30 providers and is missing from
the selector. Reviewing that dependency and its labels remains pending. The
guard was not weakened, and full 1.44 compatibility is not claimed. This is
independent of the Noctalia 5.4 migration; no real quota request was made.

Official references:

- [Noctalia 5.4.0 release notes](https://github.com/noctalia-dev/noctalia/releases/tag/v5.4.0).
- [Manifest and minimum API contract](https://docs.noctalia.dev/noctalia/plugins/development/manifest/).
- [Runtime API](https://docs.noctalia.dev/noctalia/plugins/development/runtime-api/).

As of 2026-10-27, 5.4.0 is the only published release in the 5.4.x series.
Check release notes and validate again for future versions; this review cannot
certify unpublished changes.
