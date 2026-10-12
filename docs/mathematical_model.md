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
The required weekly burn velocity $\Pi_w$, adjusted for model capacity gearing:
$$\Pi_w = \left(\frac{w_{\text{free}}}{H_w^*}\right) \times 1.68$$
$$\Pi_{w, \text{geared}} = \Pi_w \times \left(\frac{K_m}{10.0}\right)^{0.60}$$

##### Threshold for Low Headroom:
The threshold for considering a model "low on headroom" scales with its gearing:
$$\text{oneSessionPct} = \frac{100.0}{K_m}$$
$$\text{lowHeadroomPct} = \min(30.0, \max(8.0, \text{oneSessionPct} \times 0.80))$$

##### Weekly Modulation Factor $W_{\text{weekly}}$:
$$W_{\text{weekly}} = \begin{cases}
0.08 + 0.15 \times \left(\frac{w_{\text{free}}}{\text{lowHeadroomPct}}\right) & \text{if } w_{\text{free}} \le \text{lowHeadroomPct} \text{ and } H_w > 24\text{h} \text{ and not StaggerLeader} \\
\min\left(W_{\max}, \max(0.20, 0.40 + 0.60 \times \Pi_{w, \text{geared}})\right) & \text{otherwise}
\end{cases}$$
where $W_{\max} = 2.20$ if the model is the designated Stagger Advance Leader, and $1.80$ otherwise.

---

#### 1.2.4 Dynamic Urgency Additives

##### 1. Stagger Leader Acceleration Bonus ($U_{\text{stagger\_advance}}$)
When designated as the collision advance leader to trigger a mid-cycle reset:
$$U_{\text{stagger\_advance}} = \begin{cases}
25.0 \times \left(\frac{w_{\text{free}}}{100.0}\right) \times \min\left(1.0, \frac{100.0 - H_w^*}{100.0}\right) & \text{if isStaggerLeader and } w_{\text{free}} > 0.5\% \\
0.0 & \text{otherwise}
\end{cases}$$
where $H_w^* = \min(H_w, \max(6.0, H_w \times 0.50))$ compresses the horizon to half-cycle ($\approx 3.5\text{d} / 45\text{h}$).

##### 2. Perishability & Final Sprint Urgency ($U_{\text{reset\_weekly}}$)
For any model with unspent weekly quota ($w_{\text{free}} > 0.5\%$) within the perishable horizon ($H_w \le 24.0\text{h}$):
$$\text{ratio} = \min\left(8.0, \left(\frac{24.0}{\max(0.5, H_w)}\right)^{1.25}\right)$$
$$\text{sprintBonus} = \begin{cases}
220.0 \times \left(\frac{3.0 - H_w}{3.0}\right) & \text{if } H_w \le 3.0\text{h} \\
0.0 & \text{otherwise}
\end{cases}$$
$$U_{\text{reset\_weekly}} = 50.0 + \text{sprintBonus} + (w_{\text{free}} \times 4.0 \times \text{ratio})$$

> [!IMPORTANT]
> The final sprint bonus ($\text{sprintBonus}$) ensures that when a provider's weekly reset is within $\le 3\text{h}$, any remaining quota (even $2\text{–}5\%$) receives top triage priority over all distant models, eliminating the previous $5\%$ cutoff cliff and ensuring zero quota is forfeit.

##### 3. Session Capacity Bottleneck Urgency ($U_{\text{bottleneck}}$)
For high-gearing models ($K_m \ge 8.0$) facing an impending session capacity squeeze:
$$U_{\text{bottleneck}} = \begin{cases}
25.0 \times \left(\frac{w_{\text{free}}}{100.0}\right) \times \min(2.0, \text{DutyCycle} - 0.50) & \text{if } \text{DutyCycle} \ge 0.70, w_{\text{free}} \ge 5.0\%, H_w > 24\text{h} \\
0.0 & \text{otherwise}
\end{cases}$$

##### 4. Low-Gearing Early-Cycle Conservation Penalty ($U_{\text{lowK\_conserve}}$)
For low-gearing models ($K_m \le 3.5$, e.g. Claude & GPT OSS) with ample weekly horizon:
$$U_{\text{lowK\_conserve}} = \begin{cases}
-20.0 \times \left(\frac{3.5 - K_m}{3.5}\right) \times (1.0 - \text{DutyCycle}) \times \min\left(1.0, \frac{H_w - 18.0}{36.0}\right) & \text{if } K_m \le 3.5, H_w \ge 18.0\text{h}, \text{DutyCycle} \le 0.65 \\
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

$$J_i(t) = (\text{baseSession} \times W_{\text{weekly}}) + U_{\text{burn}, s} + U_{\text{reset\_weekly}} + U_{\text{stagger\_advance}} + U_{\text{bottleneck}} + U_{\text{lowK\_conserve}}$$

##### Case B: Unstarted Session ($s_{\text{started}} = \text{false}$, $U_{i,s} = 0\%$)
Unstarted sessions are discounted based on available active hours before sleep:
$$\text{availabilityDiscount} = \min\left(1.0, \max\left(0.35, \frac{H_s}{5.0}\right)\right)$$
$$\text{baseSession} = s_{\text{free}} \times 0.75 \times \text{availabilityDiscount}$$

Kickstart priming incentive for high-stress quotas:
$$U_{\text{kickstart}} = \begin{cases}
12.0 \times \min(1.5, \text{DutyCycle} - 0.50) & \text{if } \text{DutyCycle} \ge 0.75 \text{ and } H_w > 24.0\text{h} \\
0.0 & \text{otherwise}
\end{cases}$$

$$J_i(t) = (\text{baseSession} \times W_{\text{weekly}}) + U_{\text{kickstart}} + U_{\text{reset\_weekly}} + U_{\text{stagger\_advance}} + U_{\text{bottleneck}} + U_{\text{lowK\_conserve}}$$

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

### 2.2 Desynchronization Algorithm
1. **Collision Detection**: Identifies expiring credits across distinct providers separated by $< 7$ days within a 16-day window.
2. **Advance Leader Selection**:
   - Compares weekly progress and credit counts.
   - Designates the leader (e.g. Claude) to **Advance**: burn its remaining weekly quota to $100\%$ in half the time ($\approx 3.5\text{d} / 45\text{h}$ active time) to trigger and claim its reset credit mid-cycle.
   - Designates the secondary provider (e.g. Codex) to **Defer**: reserve its reset credit for the following week.
3. **Optimal Claim Window**:
   - When any credit-eligible provider reaches $U_{i,w} \ge 100\%$ (or $95\%$), the engine generates a prominent `⭐ Claim Reset` action card with a one-click dashboard link (`xdg-open`) to claim fresh quota immediately.

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
- Completely suppressed when weekly quota is $100\%$ depleted.
