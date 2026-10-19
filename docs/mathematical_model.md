# AI Triage: Internal Technical & Mathematical Specification

This reference document outlines the complete technical architecture, mathematical optimization model, circadian active-hours pacing, model gearing coupling, reset credit collision desynchronization, and calibrated UI layout implemented in `miguelfm/ai-triage`.

---

## 1. Mathematical Triage Optimization Model

### 1.1 Objective & Resource Constraints
The triage engine solves a continuous, multi-horizon resource allocation problem across heterogeneous AI providers with non-synchronized cycle boundaries and distinct pricing/throttling mechanics:

1. **Short-Term Rolling Sessions** ($T_s = 5\text{h} = 18000\text{s}$): Once initiated, quota headroom not consumed before the rolling window expires is permanently forfeit.
2. **Long-Term Weekly Caps** ($T_w = 7\text{d} = 604800\text{s}$): Quota resets periodically. Unused weekly allocation at reset date is lost to the subscription cycle.
3. **Multi-Window Gearing Disparity ($K_m$)**: Different models consume weekly budgets at drastically different rates per 5h session ($K_m$ baseline defaults range from $2.5$ to $10.0$), requiring structural protection against premature weekly starvation or session capacity bottlenecks.
4. **Circadian Active Pacing**: Humans do not interact with models 24 hours a day. Effective consumption capacity is strictly bounded by active waking hours ($H_{\text{active}}$), requiring sleeping and meal pauses to be discounted when projecting quota exhaustion.
5. **Perishable Time-Arbitrage & Sprint Logic**: A model whose weekly quota resets within $\le 3\text{h}$ must be sprinted aggressively to exhaust any remaining allocation, even down to $1\text{–}4\%$, extracting $100\%$ paid value before the reset zeroes the counter.
6. **Hard Feasibility Constraints**: Queries must never be routed to models whose weekly ($U_{i,w} \ge 100\%$) or session ($U_{i,s} \ge 100\%$) quotas are fully depleted.

---

### 1.2 Mathematical Formulation

For each active provider / model tier $i$:

#### Fundamental Variables
- $U_{i,s} \in [0, 100]$: Current 5-hour rolling session quota utilization (percentage).
- $s_{\text{free}} = \max(0, 100 - U_{i,s})$: Remaining session quota headroom.
- $\tau_s \in [0, T_s]$: Time remaining until session reset (seconds). $T_s = 18000\text{s}$.
- $U_{i,w} \in [0, 100]$: Current 7-day weekly quota utilization (percentage).
- $w_{\text{free}} = \max(0, 100 - U_{i,w})$: Remaining weekly quota headroom.
- $\tau_w \in [0, T_w]$: Time remaining until weekly reset (seconds). $T_w = 604800\text{s}$.

---

#### 1.2.1 Circadian Schedule & Effective Active Hours ($H_{\text{active}}$)
Calendar seconds overestimate usable time by including sleep and off-work periods. We project future time intervals $[t_{\text{now}}, t_{\text{target}}]$ into **effective active working hours** $H(t_{\text{now}}, t_{\text{target}})$:

- **Nominal Sleep Windows**:
  - Weekdays (Mon–Fri): 00:00 – 08:00 (8h discounted).
  - Weekends (Sat–Sun): 01:00 – 09:00 (8h discounted).
- **Nominal Meal / Rest Window**:
  - Daily: 14:00 – 15:00 (1h discounted).
- **Out-of-Schedule Awake Burst Credit ($T_{\text{burst}}$)**:
  - If the user interacts with or runs the triage tool during nominal sleep/off-hours ($t_{\text{now}} \in \text{SleepWindow}$), an immediate awake burst of $T_{\text{burst}} = 2.0\text{h}$ is credited at $100\%$ active weight ($w_t = 1.0$), after which the trajectory smoothly reverts to the baseline schedule.
- **Active Hours Metric**:
  $$H_{\text{active}}(t_1, t_2) = \int_{t_1}^{t_2} \alpha(t) \, dt$$
  where $\alpha(t) = 1.0$ during active waking intervals and $\alpha(t) = 0.0$ during sleep intervals (except during active burst overrides).

For model triage, we calculate:
- $H_w = \max(0.5, H_{\text{active}}(t_{\text{now}}, t_{\text{weekly\_reset}}))$: Effective active hours until weekly reset.
- $H_s = \max(0.05, H_{\text{active}}(t_{\text{now}}, t_{\text{session\_reset}}))$: Effective active hours until session reset.

---

#### 1.2.2 Model Quota Gearing Ratios ($K_m$) & Duty Cycle
The structural coupling ratio between weekly quota and session window capacity is defined by:
$$K_m = \frac{L_{\text{weekly}}}{L_{\text{session}}}$$

Empirically calibrated baseline values across supported providers:
| Provider Tier | Benchmark Model | Gearing Ratio $K_m$ | Single 5h Session Weekly Burn ($R_m$) | Full Sessions per Week |
| :--- | :--- | :---: | :---: | :---: |
| `claude-oss` | Claude 3.7 Sonnet & GPT-OSS | **2.5** | $40.0\%$ | $2.5$ sessions |
| `gemini` | Gemini 2.5 Pro / Flash | **8.0** | $12.5\%$ | $8.0$ sessions |
| `anthropic` | Claude Pro (Direct Anthropic) | **7.0** | $14.3\%$ | $7.0$ sessions |
| `openai` | OpenAI Codex | **6.3** | $15.9\%$ | $6.3$ sessions |
| *Default* | Custom / Unknown Provider | **10.0** | $10.0\%$ | $10.0$ sessions |

The Codex baseline is estimated from 12 comparable usage intervals on October 1–12, 2026: $\sum \Delta S / \sum \Delta W = 512 / 81 \approx 6.3$. Intervals spanning session or weekly resets are excluded. A full session means consumption of 100% of the 5h quota; reset credits are excluded from this capacity estimate. Rounded percentages and future changes in limits can affect the ratio.

##### Dynamic Telemetry-Based Gearing Calibration:
In addition to baseline defaults, `ai-triage` continuously observes real consumption deltas during active sessions:
$$K_{\text{obs}} = \frac{\Delta S}{\Delta W} = \frac{S(t) - S(t_0)}{W(t) - W(t_0)}$$
When a session advances by $\Delta S \ge 15\%$ and weekly quota registers $\Delta W \ge 1\%$, the model updates its calibrated ratio using an exponential moving average (EMA with $\alpha = 0.35$):
$$K_{\text{calibrated}} \leftarrow \alpha K_{\text{obs}} + (1 - \alpha) K_{\text{prior}}$$
This allows the plugin to automatically self-tune to the user's actual prompt size, reasoning effort, and model mix (e.g. Claude 3.7 Sonnet vs Opus vs Haiku).

##### Capacity Stress & Session Duty Cycle:
In $H_w^*$ remaining active hours, assuming an average session consumes over $5\text{h}$:
$$C_{\max} = \frac{H_w^* \times 20.0}{K_m}$$
$$\text{DutyCycle} = \frac{w_{\text{free}}}{\max(1.0, C_{\max})}$$
- When $\text{DutyCycle} \ge 0.70$: A model requiring many sessions relative to the remaining active hours faces a **session capacity bottleneck**—there are not enough 5h session slots left before the reset to exhaust the remaining quota unless consumed continuously.
- When $\text{DutyCycle} \le 0.65$ with $K_m \le 3.5$: A low-gearing model (e.g. Claude & GPT OSS) risks **premature weekly exhaustion** and must be conserved.

---

#### 1.2.3 Geared Weekly Consumption Velocity ($\Pi_{w, \text{geared}}$) & Pacing Factor ($W_{\text{weekly}}$)
The required weekly burn velocity $\Pi_w$ normalized relative to nominal sustainable active pace ($H_{\text{weekly\_active}} = 105.0\text{h}$, representing 7 days × 15 active waking hours/day):
$$\Pi_w = \left(\frac{w_{\text{free}}}{H_w^*}\right) \times \left(\frac{105.0}{100.0}\right) = \left(\frac{w_{\text{free}}}{H_w^*}\right) \times 1.05$$
$$\Pi_{w, \text{geared}} = \Pi_w \times \left(\frac{K_m}{K_0}\right)^{0.60}$$
where $K_0 = 10.0$ is the reference baseline gearing.

##### Threshold for Low Headroom:
The threshold for considering a model "low on headroom" scales with its gearing:
$$\text{oneSessionPct} = \frac{100.0}{K_m}$$
$$\text{lowHeadroomPct} = \min(30.0, \max(8.0, \text{oneSessionPct} \times 0.80))$$

##### Temporal Distribution & Anti-Burst Smoothing ($P_{\text{smooth}}$):
To optimize global multi-service consumption while preventing rapid quota concentration followed by availability droughts ("baleiros"), the model monitors deviation from nominal weekly pace:
$$\Delta_{\text{pace}} = U_{i,w} - \left(\frac{T_w - \tau_w}{T_w} \times 100\right)$$
When $H_w > 24.0\text{h}$ and the model is not fast-tracking a reset credit:
$$P_{\text{smooth}} = \begin{cases}
\max\left(0.35, 1.0 - 0.02 \times (\Delta_{\text{pace}} - 15.0)\right) & \text{if } \Delta_{\text{pace}} > 15.0\% \text{ (ahead of pace)} \\
\min\left(1.35, 1.0 + 0.015 \times (-\Delta_{\text{pace}} - 15.0)\right) & \text{if } \Delta_{\text{pace}} < -15.0\% \text{ (lagging behind pace)} \\
1.0 & \text{otherwise}
\end{cases}$$
When $H_w \le 24.0\text{h}$, $P_{\text{smooth}} = 1.0$ (damping is released for the final sprint).

##### Weekly Modulation Factor $W_{\text{weekly}}$:
$$W_{\text{weekly}} = \begin{cases}
\left(0.08 + 0.15 \times \left(\frac{w_{\text{free}}}{\text{lowHeadroomPct}}\right)\right) \times P_{\text{smooth}} & \text{if } w_{\text{free}} \le \text{lowHeadroomPct} \text{ and } H_w > 24\text{h} \text{ and not StaggerLeader} \\
\min\left(W_{\max}, \max\left(0.20, (0.40 + 0.60 \times \Pi_{w, \text{geared}}) \times P_{\text{smooth}}\right)\right) & \text{otherwise}
\end{cases}$$
where $W_{\max} = 2.20$ if the model is the designated Stagger Advance Leader, and $1.80$ otherwise.

---

#### 1.2.4 Dynamic Urgency Additives

##### 1. Perishability & Final Sprint Urgency ($U_{\text{reset\_weekly}}$)
For any model with unspent weekly quota ($w_{\text{free}} > 0.5\%$) within the perishable horizon ($H_w \le 24.0\text{h}$):
$$\text{ratio} = \min\left(8.0, \left(\frac{24.0}{\max(0.5, H_w)}\right)^{1.25}\right)$$
$$\text{sprintBonus} = \begin{cases}
220.0 \times \left(\frac{3.0 - H_w}{3.0}\right) & \text{if } H_w \le 3.0\text{h} \\
0.0 & \text{otherwise}
\end{cases}$$
$$U_{\text{reset\_weekly}} = 50.0 + \text{sprintBonus} + (w_{\text{free}} \times 4.0 \times \text{ratio})$$

> [!IMPORTANT]
> The final sprint bonus ($\text{sprintBonus}$) ensures that when a provider's weekly reset is within $\le 3\text{h}$, any remaining quota (even $2\text{–}5\%$) receives top triage priority over all distant models, eliminating the previous $5\%$ cutoff cliff and ensuring zero quota is forfeit.

##### 2. Session Capacity Bottleneck Urgency ($U_{\text{bottleneck}}$)
For models facing an impending session capacity squeeze ($\text{DutyCycle} \ge 0.70$):
$$U_{\text{bottleneck}} = \begin{cases}
20.0 \times \left(\frac{w_{\text{free}}}{100.0}\right) \times \min(1.5, \text{DutyCycle} - 0.50) & \text{if } \text{DutyCycle} \ge 0.70, w_{\text{free}} \ge 5.0\%, H_w > 24\text{h} \\
0.0 & \text{otherwise}
\end{cases}$$

---

#### 1.2.5 5h Session Window Modeling & Composite Score $J_i(t)$

##### Case A: Active Session Running ($s_{\text{started}} = \text{true}$)
Quadratic session decay factor:
$$\Omega_s(\tau_s) = 1.0 + 1.80 \times \left(\frac{T_s - \tau_s}{T_s}\right)^2$$
$$\text{baseSession} = s_{\text{free}} \times \Omega_s(\tau_s)$$

Critical session burn urgency ($U_{\text{burn}, s}$) if active time before sleep/expiry is $\le 1.5\text{h}$:
$$U_{\text{burn}, s} = \begin{cases}
50.0 \times \left(\frac{s_{\text{free}}}{100.0}\right) \times \left(\frac{1.50 - H_s}{1.50}\right) & \text{if } H_s \le 1.50\text{h} \text{ and } s_{\text{free}} \ge 15.0\% \\
0.0 & \text{otherwise}
\end{cases}$$

$$J_i(t) = (\text{baseSession} \times W_{\text{weekly}}) + U_{\text{burn}, s} + U_{\text{reset\_weekly}} + U_{\text{bottleneck}}$$

##### Case B: Unstarted Session ($s_{\text{started}} = \text{false}$, $U_{i,s} = 0\%$)
Unstarted sessions are discounted based on available active hours before sleep:
$$\text{availabilityDiscount} = \min\left(1.0, \max\left(0.35, \frac{H_s}{5.0}\right)\right)$$
$$\text{baseSession} = s_{\text{free}} \times 0.75 \times \text{availabilityDiscount}$$

$$J_i(t) = (\text{baseSession} \times W_{\text{weekly}}) + U_{\text{reset\_weekly}} + U_{\text{bottleneck}}$$

##### Case C: Hard Constraints (Lockouts)
$$J_i(t) = \begin{cases}
-1000 & \text{if provider in error / unreachable} \\
-500 - U_{i,s} & \text{if } U_{i,w} \ge 100\% \text{ (weekly exhausted)} \\
-300 - U_{i,w} & \text{if } U_{i,s} \ge 100\% \text{ (session exhausted)}
\end{cases}$$

---

## 2. Reset Credit Collision & Staggering Engine

### 2.1 Problem
When multiple providers offer on-demand weekly reset credits (e.g. Claude launch credits, Codex reset tokens) expiring concurrently within $\le 7$ days of each other in a near horizon ($\le 16\text{d}$), attempting to double token consumption for both in the final week creates an impossible human workload bottleneck.

### 2.2 Value of a Claim
A claim is worth the quota it lets you burn before the natural weekly renewal would have refilled the week anyway, minus the unused quota it forfeits. This holds whether the claim zeroes the counter under the same renewal date or opens a fresh 7d window (which then stands in for the natural renewal). With $H$ the active hours between two instants, $K_m$ the model gearing and $C(H) = 20H / K_m$ the weekly share that full 5h sessions can burn in $H$:

$$G_{\text{now}} = \min(100, C(H_{\text{now} \to R})) - w_{\text{free}}$$

where $R$ is the natural renewal. Claiming 5h before $R$ therefore buys back one session at most ($\approx 14\%$ of a week for Claude Pro), and wastes the rest of the credit.

The engine compares two quantities:
- **This cycle** ($G_{\text{cycle}}$): burn $w_{\text{free}}$ at full pace, claim as soon as it runs out (or right before the credit expires), then burn the refill until $R$.
- **Next cycle** ($G_{\text{later}}$): evaluated only if the credit outlives the renewal by at least a viable runway ($E > R + 72\text{h}$) and allows burning at least $\approx 40\%$ of the fresh week naturally. For credits expiring on the same day as renewal or within 72h, $G_{\text{later}} = 0$.

A credit is flagged as **`lastChance = true`** whenever:
$$E \le R + 72\text{h} \quad\lor\quad G_{\text{later}} < \max(40, 100/K_m) \quad\lor\quad G_{\text{later}} < 0.65\, G_{\text{cycle}}$$

It recommends:
- **`claim`** when the week is effectively spent ($U_{i,w} \ge 95\%$), or the credit is in imminent expiry peril ($\tau_{\text{expiry}} \le 6\text{h}$ calendar or $H_{\text{expiry}} \le 4\text{h}$ active with $U_{i,w} \ge 80\%$), and $G_{\text{cycle}} \ge \max(100 / K_m,\ 0.5\, G_{\text{later}})$.
- **`advance`** when that condition on $G_{\text{cycle}}$ holds but the week is not ready to claim yet. If `lastChance` is active, the engine advises a proactive sprint before renewal.
- **`hold`** otherwise, showing $G_{\text{cycle}}$ against $G_{\text{later}}$.

When a credit is on its `lastChance` (or chosen as advance leader), it enters `fastTrack` mode, compressing the target weekly horizon to half the cycle ($\text{target}H_w = \max(6.0, 0.5\, H_w)$) and engaging urgency sprint scoring whenever $\text{target}H_w \le 24\text{h}$.

### 2.3 Desynchronization Algorithm
1. **Collision Detection**: Identifies expiring credits across distinct providers separated by $< 7$ days within a 16-day window.
2. **Advance Leader Selection**:
   - Evaluates reserve scarcity and cycle progress. Providers on their `lastChance` receive an immediate $+100\text{pt}$ fitness priority to prevent credit forfeiture, regardless of nominal total reserves.
   - Designates the leader to **Advance**: burn remaining weekly quota early ($\approx 3.5\text{d} / 45\text{h}$ active time) and claim its reset credit mid-cycle.
   - For the secondary provider: if its credit also expires in this cycle (`lastChance = true`), it is **never deferred to `hold`**; both providers are fast-tracked and directed to sprint and claim before expiration. Only credits with safe runway into the subsequent cycle are deferred.
3. **Claim Window**:
   - When a provider's advice is `claim`, the engine generates a prominent `⭐ Claim Reset` action card with the quota it buys back and a one-click dashboard link (`xdg-open`). Only the earliest-expiring credit of a provider is marked to claim.

---

## 3. UI Architecture & Calibrated Geometry

### 3.1 3-Column Synchronized Layout
The Noctalia panel displays three functional columns aligned in real-time triage order:
- **Column 1: Session (5h)**:
  - Provider glyph and model name.
  - Live session progress gauge overlaid with active countdown needle marker.
  - Active rolling countdown pill (e.g. `21:07`, `⚡ 4h 23m`) or interactive priming button (`[⚡ Start 5h]`).
  - Automatic `⊗ 7d exhausted` suppression if weekly quota is depleted.
- **Column 2: Weekly (7d)**:
  - Model name and dynamic triage badge (`🔥 Use now`, `⚡ Fast-track`, `Balanced`, `Conserve`, `⊗ Exhausted`).
  - Active time-to-reset pill (e.g. `Dom, Out 11 17:37 (~0.9h active)`).
  - Gearing ratio indicator badge (e.g. `~8s/w`, `~6s/w`). Session estimates and tooltips are rounded to whole numbers for display; calculations and automatic calibration retain the underlying decimal precision.
- **Column 3: Reset Credits & Strategy**:
  - Reset Plan collision card with numbered staggering directives.
  - Optimal Reset Window claim action card (when quota is 100%).
  - Chronologically ordered credit expiration countdown cards with direct dashboard buttons.

### 3.2 Native Scrolling (`ui.scroll`) & Calibrated 600px Height
- **Native Scrolling**: Each of the three columns wraps its cards in `ui.scroll({ flexGrow = 1, gap = 6, align = "stretch" })`, guaranteeing zero pixel overflow out of the window border under any configuration.
- **Calibrated Height (600px)**: The window surface in `plugin.toml` is calibrated to exactly 600px:
  - Top header row: ~52px
  - 4 Model Cards (Session & Weekly): ~407px
  - Strategy Card + 4 Reset Credit Cards: ~405px
  - Top/Bottom Margins: 10px each
  - **Result**: Fits 4 full model tiers and 4 credit cards with 0 scrollbars and 0 wasted dead vertical space.

---

## 4. Rolling Session Priming (`bin/ai-kickstart`)

Headless, non-interactive priming commands send a single token to start rolling windows at the beginning of the workday:
- **Claude**: `claude -p "hi" </dev/null`
- **Codex**: `codex exec -C /tmp -m gpt-6.1-sol -c model_reasoning_effort="low" "hi" </dev/null`
- **Gemini**: `agy -p "hi" </dev/null`
- **Claude & GPT OSS**: `agy -p "hi" -m claude-3-7-sonnet </dev/null`

Execution guardrails:
- Redirects stdin from `/dev/null` to prevent terminal freezes.
- Runs with isolated working directory (`/tmp`) to prevent repo pollution.
- **State persistence & clock resolution**: Priming events notify Noctalia via IPC (`kickstart` event), persisting session initiation timestamps in `noctalia.state`. Even at $0\%$ quota consumption, the panel immediately unlocks and displays the active expiration clock time (rather than an unstarted `--:--` placeholder), transitions the session status indicator to `5h rolling`, and suppresses redundant kickstart triggers.

---

## 5. Service & Model Visibility Filtering

### 5.1 Architecture & Objectives
Users often have subscriptions to multi-model providers (e.g. Google Antigravity) that report disparate tiers under a unified account (such as **Gemini 2.5 Pro / Flash** alongside third-party pass-through tiers like **Claude & GPT OSS**). In many workflows, third-party sub-tiers are unutilized, have lower quality thresholds, or exhaust rapidly, introducing UI clutter and false critical alarms.

The filtering subsystem provides granular control via two settings:
1. `hide_claude_oss` (`bool`, default `false`): Dedicated toggle to eliminate the Claude & GPT OSS tier from Antigravity while retaining full monitoring for Gemini.
2. `hidden_services` (`string`, default `""`): Comma-delimited list of provider or model identifiers to omit from display and triage.

### 5.2 Mathematical & Algorithmic Implications
- **Candidate Filtering**: Hidden services and sub-models are filtered during candidate discovery (`M.isModelHidden(providerId, modelName)`). They are excluded from the optimization set $\mathcal{M}$ before triage score calculations.
- **Decoupled Exhaustion Lockouts**: In multi-model providers, exhaustion of a sub-tier ($U_{i} \ge 100\%$) previously triggered a critical lock on the parent entry. The filtering subsystem excludes hidden metrics from `blockingMetric(metrics, providerId)`, ensuring that exhaustion of Claude & GPT OSS never colors the bar capsule red or flags Antigravity as depleted when Gemini still possesses usable headroom.
- **Preservation of Distinct Providers**: String matching safeguards ensure direct Anthropic Claude subscriptions (`id = "anthropic"`) are never conflated with Antigravity's third-party Claude OSS tier.
- **Triage Matrix Synchronization**: Filtering cascades seamlessly across all three panel columns (Session, Weekly, Schedules) and the status bar capsule, keeping per-row coordination intact without rendering empty or misaligned slots.
- **Taskbar Capsule Dynamic Collapsing**: Pinned bar widgets configured for hidden models (e.g. `vendor = "claude-oss"` when `hide_claude_oss` is active) dynamically invoke `barWidget.setVisible(false)`, collapsing the capsule completely from the taskbar without leaving empty spaces or ambiguous fallback icons.
- **Provider Identity Preservation During Transient Outages**: Outage detection decouples transport failures (such as upstream HTTP 429 rate limits or network connection drops) from configuration state. Pinned capsules preserve the provider's semantic glyph in warning state with diagnostic tooltips, while the panel renders the card with an `Offline` badge instead of pruning the configured model.

---

### 6. Dynamic Upstream Weekly Horizon & Allowance Advancement

### 6.1 The Rate Limit Reset Mechanism (Codex & Rolling Windows)
Rate-limited upstream providers (notably OpenAI Codex) operate on rolling and anchor-based 7-day quota windows ($T_w = 7\text{d} = 604800\text{s}$). When a user redeems an on-demand reset credit (*Banked Reset*) or purchases a quota reset (*Instant Reset*):
1. **Allowance Advancement**: Upstream platforms implement resets via *allowance advancement* ("pulling the normal weekly allowance forward"). The reset does not create a parallel or isolated token block; instead, it immediately moves the subscriber's upcoming weekly quota into the present.
2. **Anchor Shift**: Concurrently, the platform resets usage counters ($U_{i,w} \leftarrow 0\%$) and **permanently shifts the scheduled weekly renewal horizon** to 7 days from redemption / first post-reset request:
   $$R_{\text{effective}} = t_{\text{now}} + 7\text{d}$$
3. **Cancellation of Prior Renewal Date**: The former renewal anchor (e.g. Thursday at 17:45 UTC) is cancelled and superseded. There is **no secondary or background reset** on the previous calendar date.

### 6.2 Telemetry Authority & Pacing Integrity
Because the upstream API timestamp ($R_{\text{API}}$) reflects the genuine new 7-day renewal timeline:
- **Authoritative Telemetry**: `ai-triage` synchronizes directly with $R_{\text{API}}$, calculating remaining active working hours $H_w$ over the authentic newly opened 7-day period.
- **Sprint Urgency Calibration**: Artificially anchoring to a superseded pre-reset date would incorrectly calculate a dangerously short runway, triggering false sprint urgency ($U_{\text{reset\_weekly}}$) and leading the user to burn through quota prematurely days before the real renewal arrives.
- **Reset Staggering Coupling**: The Reset Staggering Engine (Section 4) evaluates remaining banked credits and expirations against the authentic post-advancement weekly schedule, guaranteeing optimal token arbitrage without distorted deadlines.

---

### 7. Antigravity Local Session Telemetry Reconciliation

### 7.1 The Remote Endpoint Discrepancy
Google Antigravity exposes quotas through two channels:
1. **Local Language Server / CLI Daemon**: Accessible on loopback (`127.0.0.1`), but modern `agy` releases protect the RPC interface with an internal process-private CSRF token (`unauthenticated: missing CSRF token`).
2. **Remote Cloud Code REST API (`cloudcode-pa.googleapis.com`)**: While third-party quotas (Claude & GPT models) decrement accurately on this endpoint, individual consumer tier accounts report dummy quotas for native **Gemini Models**:
   $$U_{\text{remote}}(t) = 0\%, \quad R_{\text{remote}}(t) = t + 5\text{h}$$
   The remote endpoint returns a synthetic floating 5h horizon and zero utilization, failing to track active CLI token consumption.

### 7.2 Rolling Window Detection Heuristic
In standard rolling-window providers (e.g. Codex, Copilot), idle accounts report synthetic future windows ($R_s = t + T_s$). To prevent uninitiated sessions from showing false active countdowns on idle days, `isSessionStarted(m)` applies the threshold:
$$\text{Started}(m) = \begin{cases} \text{true} & \text{if } U_s > 0\% \\ \text{true} & \text{if } R_s - t < 0.90 \cdot T_s \\ \text{false} & \text{otherwise} \end{cases}$$
Because $U_{\text{remote}} = 0\%$ and $R_{\text{remote}} - t \approx 4\text{h } 59\text{m} \ge 0.90 \cdot T_s$, the heuristic previously classified active Gemini sessions as unstarted.

### 7.3 Telemetry Reconciliation Architecture
To resolve this discrepancy without incurring remote polling delays or requiring elevated RPC credentials, the poller implements a two-tier local telemetry reconciler:
1. **Real-time Statusline Observation Snapshot**: Whenever `agy` executes in any terminal, its configured `statusLine` command writes the active session payload to `agy-statusline.observation.json`. The poller inspects this observation snapshot synchronously in $\mathcal{O}(1)$ time ($\approx 0\text{ms}$ latency):
   $$U_{\text{local}} = 1.0 - \text{remaining\_fraction}, \quad R_{\text{local}} = \text{reset\_time}$$
2. **Asynchronous CLI Fallback**: If the observation snapshot is missing or past its expiration ($R_{\text{local}} \le t$), the poller queries `agy -p /quota` asynchronously.
3. **Metric & Section Enrichment**: The authoritative local values ($U_{\text{local}}, R_{\text{local}}$) overwrite the synthetic remote metrics. `isSessionStarted()` evaluates to `true`, the mathematical urgency factor $S_{\text{urgency}} = 1.0 + 1.80 \cdot (r_{\text{elapsed}})^2$ engages, and the user receives authentic countdowns and pacing telemetry.





