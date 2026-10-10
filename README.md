# AI Triage

AI Triage is an intelligent AI quota monitoring, smart routing, and rolling session triage plugin for the Noctalia Wayland shell.

Built on top of the telemetry engine provided by [ai-usagebar](https://github.com/akitaonrails/ai-usagebar), AI Triage elevates basic quota numbers into actionable routing decisions, real-time pace analysis, and automated session priming.

## Plugin

| Field | Value |
| --- | --- |
| ID | `miguelfm/ai-triage` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `poller` |

## Requirements

Install `ai-usagebar` on `PATH`. The plugin runs it by name and has no separate
path setting. It ships as `ai-usagebar-bin` on the AUR, and as release
tarballs on the project's GitHub Releases page. Configure your providers once in
`~/.config/ai-usagebar/config.toml`; the CLI manages credentials and provider
connections.

When the CLI is missing or provider dashboards are clicked, the panel opens URLs
with `xdg-open`. Install `xdg-open` alongside `ai-usagebar`.

The plugin requires Noctalia plugin API 22 for `require()`.

For the interactive rolling session kickstart feature (`[⚡ Start 5h]`), ensure `bin/ai-kickstart` is
accessible or placed on your PATH (e.g. `~/.local/bin/ai-kickstart`). The helper triggers rolling sessions via provider-specific CLI tools:
- `claude` (Anthropic Claude Code CLI) for Claude
- `codex` (OpenAI Codex CLI) for Codex
- `agy` (Antigravity CLI) for Gemini and Claude & GPT OSS
Install the respective CLI for any backend provider you wish to prime.

## Features

- **Multi-Provider & Antigravity Model Separation**: Full independent tracking for all supported providers, including dedicated cards and individual triage scoring for Antigravity's **Gemini** (Gemini 2.5 Pro / Flash) and **Claude & GPT OSS** (Claude 3.7 Sonnet, GPT-OSS) tiers.
- **Mathematical Triage & Prioritization Engine**: Dynamically ranks providers using a continuous optimization model that balances 5-hour rolling session exhaustion against 7-day weekly pace. Prioritizes under-utilized quotas, boosts providers with upcoming weekly resets ($\le 48\text{h}$) to avoid wasting expiring allocations, and enforces hard lockouts for exhausted quotas.
- **Interactive Session Priming (`ai-kickstart`)**: Providers with rolling windows (Claude, Codex, Antigravity) start their countdown when the first prompt is sent. The panel displays a `[⚡ Start 5h]` button to prime sessions at the start of your workday with a single click. Priming is automatically suppressed for providers whose weekly quotas are already depleted.
- **Robust Rolling Window Detection**: Real-time detection of active rolling session clocks across all supported providers, ensuring countdowns and needle markers begin immediately upon usage.
- **Reset Credit Collision & Staggering Engine**: Detects concurrent on-demand reset credit expirations across providers (e.g. Claude and Codex expiring in the same week). Automatically calculates a desynchronization strategy—accelerating the candidate provider to reach 100% weekly usage at mid-cycle ($\approx 3.5\text{d}$) to claim its reset early, while deferring the other provider to the final week. Identifies the optimal moment to claim resets (`⭐ Claim Reset`) with one-click dashboard access.
- **Streamlined Triage Panel**: An aligned, three-column ranking view displaying provider identity, dynamic urgency score, and real-time status badges (`⚡ Rush`, `🔥 Burn`, `⭐ Fresh`, `Optimal`, `Safe`, `Low`, `⊗ Exhausted`). The top row is always your optimal routing choice.
- **Dynamic Time Needle Marker**: The dual-layer gauge features a live needle marker that ticks with the active countdown, visually indicating whether consumption is ahead or behind elapsed time.
- **Compact Geometry**: Optimized 710px vertical height with clean spacing and tabbed provider inspection.

## Usage

Add `miguelfm/ai-triage:bar` to a bar in Settings, Bar. The capsule shows
one provider's headline reading beside its icon. Readings use the bar's text
color, the theme's `secondary` color for high usage, and `error` for critical
usage. Icons keep their normal color unless a read fails.

- **Left click**: Opens the AI Triage panel for the provider that capsule tracks.
- **Right click**: Requests an immediate quota refresh via background poller.
- **Middle click**: Opens widget settings.

To toggle or open the panel from a terminal or keybinding:

```sh
noctalia msg panel-toggle miguelfm/ai-triage:panel
```

Keyboard shortcuts inside the panel:
- `Escape`: Close panel.
- `r`: Force quota refresh.
- `Left` / `Right`: Navigate provider tabs.

## Settings

Plugin-level settings (shared across poller, capsules, and panel):

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refresh_minutes` | `int` | `5` | Minutes between CLI calls (1 to 120). Countdowns tick locally in between. |

Per-widget settings (configurable for each bar capsule):

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `vendor` | `select` | `auto` | Tracked provider (`auto`, `anthropic`, `openai`, `gemini`, `claude-oss`, `antigravity`, etc.). `auto` tracks the busiest plan. |
| `account` | `string` | empty | Optional named account label from the CLI config. |
| `visualization` | `select` | `gauge` | Visual indicator style: `gauge` or `none`. |
| `show_value` | `bool` | `true` | Show percentage text. |
| `show_glyph` | `bool` | `true` | Show provider icon. |
| `glyph_position` | `select` | `before` | Icon position: `before` or `after`. |
| `provider_limit` | `int` | `1` | Providers carried in one capsule (1 to 4). Only applies on `auto`. |
| `extras` | `select` | `countdown` | Auxiliary info beside percentage: `countdown`, `pace`, `both`, or `none`. |
| `show_name` | `bool` | `false` | Show provider name beside reading. |
| `color_by_usage` | `bool` | `true` | Color readings according to quota severity. |

## IPC

Force an immediate quota check without waiting for the polling interval:

```sh
noctalia msg plugin miguelfm/ai-triage:poller all refresh
```

Point the panel at a specific provider:

```sh
noctalia msg plugin miguelfm/ai-triage:poller all select anthropic
```

## License

MIT © [miguelfm](https://github.com/miguelfm)
