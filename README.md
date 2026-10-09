# AI Triage

**AI Triage** is an intelligent AI quota monitoring, triage routing, and rolling session management plugin for the [Noctalia](https://noctalia.dev) Wayland shell.

Built on top of the telemetry engine provided by [`ai-usagebar`](https://github.com/akitaonrails/ai-usagebar), AI Triage elevates basic quota numbers into actionable routing decisions, real-time pace analysis, and automated session priming.

---

## ✨ Features

- 🎯 **Cross-Weighted Best Pick Engine**:
  - Automatically identifies and recommends the optimal model to route prompts to.
  - Dynamically balances **5-hour rolling session headroom** against **7-day weekly consumption health**.
  - Penalizes models risking weekly starvation (e.g., $<15\%$ free or $\le -15\text{pts}$ behind pace).
  - Boosts models with healthy weekly pace ($\ge 60\%$ headroom) and increases urgency when weekly reset is near ($<36$h) with unspent quota.
  - Transparent banner displaying the exact decision rationale and current pace stats.

- ⚡ **Interactive Rolling Window Kickstart (`ai-kickstart`)**:
  - Provider 5-hour quota windows only start ticking once you send the first prompt.
  - Cards with 0% usage display an interactive **`[⚡ Start 5h]`** button.
  - Triggers a minimal 1-token probe via `ai-kickstart` to start the clock at the beginning of your work block and issues desktop notifications upon priming.

- 📊 **Visual Gauge with Live Time Needle**:
  - Dual-layer bar indicating both consumed quota and elapsed time.
  - Real-time time needle marker continuously ticks down with active countdowns.
  - Immediate visual contrast: consumption bars ahead of the needle indicate excessive consumption rate.

- 🏷️ **Smart Triage Badging**:
  - Instant status pills on model cards: `Optimal`, `Safe`, `Low`, `Critical`, `Starved`, and `Fresh`.
  - Hover tooltips provide detailed pace breakdown (e.g., `43% free · 9pts under`).

- 🖥️ **Compact, High-Density Dashboard**:
  - Streamlined 710px vertical geometry, eliminating dead space.
  - Quick multi-provider tab switcher (Anthropic, OpenAI, Antigravity, and community providers).
  - Provider dashboard shortcuts with `xdg-open`.

- ⚡ **Zero-Overhead Headless Architecture**:
  - A single lightweight Luau daemon poller handles updates across all bars and panels.
  - Fully decoupled and independent from upstream community plugins.

---

## 📦 Plugin Information

| Field | Value |
| --- | --- |
| **ID** | `miguelfm/ai-triage` |
| **Author** | `miguelfm` |
| **Plugin API** | `22` |
| **Entries** | Widget: `bar`, Panel: `panel`, Service: `poller` |
| **Dependencies** | `ai-usagebar`, `xdg-open`, `ai-kickstart` (optional, for session priming) |

---

## 🚀 Installation & Setup

### 1. Requirements

Ensure `ai-usagebar` is installed and available on your `$PATH`:
- Arch Linux (AUR): `yay -S ai-usagebar-bin`
- Or download the binary from [ai-usagebar Releases](https://github.com/akitaonrails/ai-usagebar/releases).

Configure your provider credentials in `~/.config/ai-usagebar/config.toml`.

*(Optional)* For the **Session Kickstart** feature, install or link `ai-kickstart` to `~/.local/bin/ai-kickstart`.

### 2. Install the Plugin

Clone or copy this repository into your local Noctalia plugins directory:

```bash
mkdir -p ~/.config/noctalia/plugins
git clone https://github.com/miguelfm/ai-triage.git ~/.config/noctalia/plugins/ai-triage
```

### 3. Enable in Noctalia

Enable the plugin via Noctalia IPC:

```bash
noctalia msg plugins enable miguelfm/ai-triage
```

Or configure it in `~/.local/state/noctalia/settings.toml`:

```toml
[plugin_settings."miguelfm/ai-triage"]
panel_placement = "floating"
refresh_minutes = 2

[plugins]
enabled = [ "miguelfm/ai-triage" ]

# Add bar widgets to your status bar
[widget.bar_claude]
type = "miguelfm/ai-triage:bar"
vendor = "anthropic"

[widget.bar_openai]
type = "miguelfm/ai-triage:bar"
vendor = "openai"

[widget.bar_antigravity]
type = "miguelfm/ai-triage:bar"
vendor = "antigravity"
```

Restart or reload Noctalia:

```bash
systemctl --user restart noctalia
```

---

## 🕹️ Interaction & Controls

- **Left Click (Bar Capsule)**: Opens the AI Triage panel focused on that provider.
- **Right Click (Bar Capsule)**: Triggers an immediate quota refresh via background poller.
- **Middle Click (Bar Capsule)**: Opens widget settings.
- **[⚡ Start 5h] Button (Panel)**: Fires a 1-token kickstart to begin the 5-hour rolling session.
- **Keyboard Shortcuts (inside panel)**:
  - `Escape`: Close panel.
  - `r`: Force quota refresh.
  - Arrow keys: Navigate providers.

### IPC Commands

Force an immediate background poll:
```bash
noctalia msg plugin miguelfm/ai-triage:poller all refresh
```

Toggle the triage panel:
```bash
noctalia msg panel-toggle miguelfm/ai-triage:panel
```

Select a specific provider in the panel:
```bash
noctalia msg plugin miguelfm/ai-triage:poller all select anthropic
```

---

## ⚙️ Configuration Reference

### Plugin Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `refresh_minutes` | `int` | `5` | Interval in minutes between quota checks (1–120). |

### Widget (`bar`) Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `vendor` | `select` | `auto` | Tracked provider (`auto`, `anthropic`, `openai`, `antigravity`, etc.). |
| `account` | `string` | `""` | Optional named account label from CLI config. |
| `visualization` | `select` | `gauge` | Visual indicator style: `gauge` or `none`. |
| `show_value` | `bool` | `true` | Show numeric usage percentage. |
| `show_glyph` | `bool` | `true` | Display provider icon. |
| `glyph_position` | `select` | `before` | Position of icon: `before` or `after`. |
| `provider_limit` | `int` | `1` | Max providers shown per widget when set to `auto` (1–4). |
| `extras` | `select` | `countdown` | Auxiliary info: `countdown`, `pace`, `both`, or `none`. |
| `show_name` | `bool` | `false` | Display provider name. |
| `color_by_usage` | `bool` | `true` | Colorize capsule based on usage severity. |

---

## 🧪 Testing

Run test suites from the plugin directory:

```bash
lua tests/scrub_test.lua
lua tests/refresh_test.lua
lua tests/bar_test.lua
lua tests/panel_test.lua
TZ=America/New_York lua tests/shared_test.lua
```

You can also run the Noctalia plugin linter:
```bash
noctalia plugins lint ~/.config/noctalia/plugins/ai-triage
```

---

## 📄 License

MIT © [miguelfm](https://github.com/miguelfm)
Based on original UI components from [felipeartur/ai-usagebar](https://github.com/felipeartur) and CLI telemetry by [akitaonrails/ai-usagebar](https://github.com/akitaonrails/ai-usagebar).
