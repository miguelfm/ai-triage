-- Weekly reset observations: no network, filesystem, or synthetic calendar.
local function read(path)
    local f = assert(io.open(path))
    local s = f:read("*a")
    f:close()
    return s
end
local env = setmetatable({ noctalia = {
    string = { trim = function(s) return tostring(s):match("^%s*(.-)%s*$") end },
    getConfig = function() return nil end,
} }, { __index = _G })
local shared = assert(load(read("shared.luau"), "shared", "t", env))()
local function iso(at) return os.date("!%Y-%m-%dT%H:%M:%SZ", at) end
local now = shared.parseIso("2026-10-22T12:04:37Z")
local oldReset = shared.parseIso("2026-10-27T06:37:01Z")
local newReset = shared.parseIso("2026-10-30T04:00:54Z")
local function entry(at, reset, percent, id, label)
    return { id = id or "openai", status = "ready", fetched_at = iso(at),
        reset_credits = { available = 2 },
        metrics = { { label = label or "Codex weekly", percent = percent, window_secs = 604800, reset_at = iso(reset) } } }
end
local function track(e, history, at)
    return shared.trackWeeklyResets({ entries = { e } }, history, at or shared.parseIso(e.fetched_at))
end

-- Replay Oct 22 -> 23. Zero usage + a later deadline means an early renewal,
-- not a prediction that the old deadline must still occur.
local before = entry(now, oldReset, 50)
local history = track(before)
assert(#history.events == 0 and before.metrics[1].reset_at == iso(oldReset))
local today = shared.parseIso("2026-10-23T06:51:59Z")
local after = entry(today, newReset, 0)
history = track(after, history)
assert(#history.events == 1 and history.events[1].change.kind == "early_renewal")
assert(not history.events[1].change.fewer_credits, "a quota drop must not imply a credit was spent")
assert(after.metrics[1].reset_at == iso(newReset), "never override the upstream date")
local tip = shared.weeklyResetTooltip(after.metrics[1], after, today)
assert(tip:find("Early renewal detected", 1, true) and tip:find("Previously announced", 1, true))
assert(shared.weeklyResetStatus(after.metrics[1], after, today) == "announced")

-- A later unchanged read retains the explanation; duplicates never add events.
local later = entry(today + 300, newReset, 2)
history = track(later, history)
history = track(later, history)
assert(#history.events == 1 and later.metrics[1].reset_observation.event.kind == "early_renewal")
assert(not shared.weeklyResetTooltip(later.metrics[1], later, today + 86401):find("Early renewal detected", 1, true))

-- Old, cached and failed reports cannot replace the baseline or get a new date.
local baseline = history.samples.openai["Codex weekly/604800"]
for _, state in ipairs({ "stale", "error", "older" }) do
    local e = entry(state == "older" and now or today + 600, oldReset, 40)
    e.stale, e.status = state == "stale", state == "error" and "error" or "ready"
    history = track(e, history, today + 600)
    assert(history.samples.openai["Codex weekly/604800"] == baseline, state .. " read must not change history")
    assert(e.metrics[1].reset_observation.event == nil, "an old calendar must not inherit a new renewal")
end
local older = entry(now, newReset, 0)
track(older, history, today)
assert(older.metrics[1].reset_observation.at == now, "an older reading must keep its own age")
assert(shared.weeklyResetStatus(older.metrics[1], older, today) == "stale")
assert(shared.weeklyResetStatus(later.metrics[1], later, today + 1201) == "stale")
assert(shared.weeklyResetStatus(after.metrics[1], after, newReset) == "pending")
assert(shared.weeklyResetStatus({}, after, today) == "pending", "missing deadline must not mean 7d")

-- A scheduled renewal, a date correction, and a source change stay distinct.
local scheduled = entry(oldReset + 1, oldReset + 604800, 0)
local scheduledHistory = track(scheduled, track(before))
assert(scheduledHistory.events[1].change.kind == "renewal")
local correction = entry(now + 300, oldReset + 7200, 50)
local corrected = track(correction, track(before))
assert(corrected.events[1].change.kind == "schedule_changed")
local sourceChange = entry(now + 300, newReset, 0)
sourceChange.sections = { { label = "Source", value = "Local agy session" } }
assert(track(sourceChange, track(before)).events[1].change.kind == "schedule_changed",
    "a source switch alone cannot confirm a renewal")
local drift = entry(now + 300, oldReset + 1, 49)
assert(#track(drift, track(before)).events == 0, "ignore second-level timestamp drift")
local credit = entry(today, newReset, 0)
credit.reset_credits.available = 1
assert(track(credit, track(before)).events[1].change.fewer_credits)

-- Baselines remain separate for accounts and model pools, including hidden ones.
local separate = shared.trackWeeklyResets({ entries = {
    entry(now, oldReset, 60, "antigravity@work", "Gemini"),
    entry(now, oldReset, 90, "antigravity@home", "Gemini"),
} }, nil, now)
local pools = entry(now + 300, newReset, 0, "antigravity@work", "Claude & GPT OSS")
separate = track(pools, separate)
assert(#separate.events == 0, "models/accounts must not share a renewal baseline")
assert(separate.samples["antigravity@work"]["Gemini/604800"].percent == 60)
assert(separate.samples["antigravity@home"]["Gemini/604800"].percent == 90)

-- Corrupt state and partial/non-quota metrics are harmless. History is bounded.
local partial = { entries = { 42, { id = "openai", metrics = { 42,
    { label = "Context", group = "context", window_secs = 604800, percent = 50 },
    { label = "Weekly", window_secs = 604800 },
} } } }
assert(#shared.trackWeeklyResets(partial, { version = 1, samples = false, events = false }, now).events == 0)
local bounded = track(before)
for i = 1, 40 do bounded = track(entry(now + i * 300, oldReset + i * 7200, 50), bounded) end
assert(#bounded.events == 32)
shared.trackWeeklyResets({ entries = {} }, bounded, now + 31 * 86400)
assert(next(bounded.samples) == nil, "discard abandoned baselines after 30d")

-- Unknown/old schedules cannot trigger credit claims or weekly sprint urgency.
local pending = entry(now, now - 1, 50)
pending.reset_credits = { available = 1, credits = { { expires_at = iso(now + 86400) } } }
local plan = shared.analyzeResetCredits({ pending }, now)
assert(plan.creditAdvice.openai.status == "hold")
local score = shared.calculateModelTriageScore({ providerId = "openai", entry = pending,
    weeklyMetric = pending.metrics[1] }, nil, now)
assert(score < 100, "an unconfirmed renewal must not cause a weekly sprint")
io.write("ok: weekly renewal replay, stale/out-of-order reads, sources, account isolation and bounded history\n")
