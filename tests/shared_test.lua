-- Regression tests for shared date parsing. Run with a timezone that observes DST:
--
--   TZ=America/New_York lua tests/shared_test.lua

assert(os.getenv("TZ") == "America/New_York", "run with TZ=America/New_York")

local function read(path)
    local file = assert(io.open(path, "r"))
    local source = file:read("*a")
    file:close()
    return source
end

local noctalia = {
    string = {
        trim = function(value) return tostring(value):match("^%s*(.-)%s*$") end,
    },
}
local env = setmetatable({ noctalia = noctalia }, { __index = _G })
local shared = assert(load(read("shared.luau"), "shared", "t", env))()

local cases = {
    { "winter", "2024-01-10T12:00:00Z", 1704888000 },
    { "summer", "2024-07-10T12:00:00Z", 1720612800 },
    { "before spring transition", "2024-03-10T06:30:00Z", 1710052200 },
    { "after spring transition", "2024-03-10T07:30:00Z", 1710055800 },
}

for _, case in ipairs(cases) do
    local name, input, expected = case[1], case[2], case[3]
    local actual = shared.parseIso(input)
    assert(actual == expected,
        string.format("%s: expected %d for %s, got %s", name, expected, input, tostring(actual)))
end

assert(type(shared.terminalAuth) == "function", "terminal authentication classifier should exist")
assert(type(shared.transportError) == "function", "transport error classifier should exist")

local retired = {
    id = "anthropic",
    error = "",
    sections = {
        { type = "text", label = "HTTP 403", value = "authentication rejected" },
    },
}
assert(shared.terminalAuth(retired), "403 authentication rejection should be terminal")
assert(shared.terminalAuth({ error = "HTTP 401: authorization token expired" }),
       "401 expired authorization should be terminal")
assert(not shared.terminalAuth({ error = "HTTP 429 authentication rate limited" }),
       "rate limiting should stay transient")
assert(not shared.terminalAuth({ error = "HTTP 500 authentication service unavailable" }),
       "server errors should stay transient")
assert(not shared.terminalAuth({ error = "authentication rejected by local configuration" }),
       "authentication wording without HTTP 401 or 403 should stay visible")
assert(shared.transportError("HTTP 500: internal error"), "HTTP failures should be transport details")
assert(not shared.transportError("The weekly window resets soon"), "ordinary prose should remain content")

local filtered = shared.entries({ entries = {
    retired,
    { id = "openai", sections = {} },
} })
assert(#filtered == 1 and filtered[1].id == "openai",
       "terminal providers should be filtered from shared entries")

local function usageEntry(id, percent)
    return {
        id = id,
        status = "ready",
        stale = false,
        metrics = { { percent = percent } },
        sections = {},
    }
end

local parserFailure = { id = "openai", status = "error", metrics = {}, sections = {},
    error = "schema mismatch: openai usage response: invalid type: null, expected a sequence" }
assert(#shared.entries({ entries = { parserFailure } }) == 1,
       "a parser failure must remain visible because it does not prove the account is unavailable")
assert(shared.unavailable(parserFailure), "failed readings must not be drawn as live metrics")

local unavailable = usageEntry("anthropic", 0)
unavailable.stale = true
unavailable.sections = {
    { type = "text", label = "HTTP 429", value = "Rate limited" },
}
local ordered = shared.entries({ entries = {
    unavailable,
    usageEntry("openai", 32),
    usageEntry("antigravity", 99),
} })
assert(#ordered == 2, "providers with their own refresh failure should be removed")
assert(ordered[1].id == "antigravity" and ordered[2].id == "openai",
       "working providers should be ordered by highest usage")

local bottleneckEntry = {
    id = "openai",
    status = "ready",
    stale = false,
    metrics = {
        { label = "Codex 5h", percent = 0, severity = "low" },
        { label = "Codex weekly", percent = 100, severity = "critical" },
    },
    sections = {},
}
local headlineMetric = shared.headline(bottleneckEntry)
assert(headlineMetric ~= nil and headlineMetric.label == "Codex weekly" and headlineMetric.percent == 100,
       "headline should select the bottleneck/highest severity metric across windows")

local tieSeverityEntry = {
    id = "openai",
    status = "ready",
    stale = false,
    metrics = {
        { label = "Session", percent = 15, severity = "low" },
        { label = "Weekly", percent = 45, severity = "low" },
    },
    sections = {},
}
local tieMetric = shared.headline(tieSeverityEntry)
assert(tieMetric ~= nil and tieMetric.label == "Session" and tieMetric.percent == 15,
       "headline should prioritize active session when broader windows are not critical")

local reordered = shared.entries({ entries = {
    usageEntry("antigravity", 50),
    bottleneckEntry,
} })
assert(reordered[1].id == "openai" and reordered[2].id == "antigravity",
       "a provider with critical 100% weekly limit should rank above a 50% low severity provider")

local antigravityEntry = {
    id = "antigravity",
    status = "ready",
    stale = false,
    metrics = {
        { label = "Gemini", percent = 0, severity = "low" },
        { label = "Claude & GPT OSS", percent = 0, severity = "low" },
        { label = "Gemini", percent = 24, severity = "low" },
        { label = "Claude & GPT OSS", percent = 100, severity = "critical" },
    },
    sections = {},
}
assert(#shared.modelHeadlines(bottleneckEntry) == 0,
       "single-model providers should have no sub-model headlines")
local agyModels = shared.modelHeadlines(antigravityEntry)
assert(#agyModels == 2, "antigravity should extract both model headlines")
assert(agyModels[1].model == "Gemini" and agyModels[1].glyph == "brand-google" and agyModels[1].metric.percent == 0,
       "gemini should resolve to its active session")
assert(agyModels[2].model == "Claude & GPT OSS" and agyModels[2].glyph == "robot" and agyModels[2].displayName == "Claude & GPT OSS" and agyModels[2].metric.percent == 0 and agyModels[2].blockingMetric.percent == 100,
       "claude/oss should preserve its identity, session and exhausted quota")

local normalAgy = {
    id = "antigravity",
    status = "ready",
    stale = false,
    metrics = {
        { label = "Gemini", percent = 11, severity = "low" },
        { label = "Claude & GPT OSS", percent = 0, severity = "low" },
        { label = "Gemini", percent = 43, severity = "low" },
        { label = "Claude & GPT OSS", percent = 78, severity = "high" },
    },
    sections = {},
}
local normalHeadline = shared.headline(normalAgy)
assert(normalHeadline ~= nil and normalHeadline.percent == 11,
       "antigravity headline should pick highest active session (11%) when no metric is critical")

local session = { label = "Gemini", percent = 100, severity = "critical", reset_at = "2030-01-01T02:00:00Z" }
local weekly = { label = "Gemini", percent = 100, severity = "critical", reset_at = "2030-01-06T02:00:00Z" }
assert(shared.headline({ id = "openai", metrics = { session, weekly } }) == weekly,
       "two exhausted windows must use the latest reset")
weekly.percent = 90
local oneModel = { id = "antigravity", metrics = { session, weekly } }
assert(shared.headline(oneModel) == session, "critical but usable weekly quota must not block the session")
local oneHeadline = shared.modelHeadlines(oneModel)
assert(#oneHeadline == 1 and oneHeadline[1].blockingMetric == session,
       "a single model must retain its actual exhausted window")
session.percent, weekly.percent = 0, 100
assert(shared.headline(oneModel) == weekly, "one model must show its exhausted weekly quota")

assert(shared.providerDashboard("anthropic") == "https://claude.ai/settings/usage", "Claude plan usage URL")
assert(shared.providerDashboard("anthropic_api") == "https://console.anthropic.com/", "API usage stays in the console")
assert(shared.providerDashboard("openai@work") == "https://chatgpt.com/codex/settings/usage", "account suffix keeps Codex usage URL")
assert(shared.providerDashboard("antigravity") == "https://antigravity.google/", "Antigravity opens its own service")
assert(shared.providerDashboard("grok") == "https://console.x.ai/", "Grok API stays in the xAI console")
assert(shared.providerDashboard("supergrok") == "https://grok.com/", "SuperGrok opens the consumer service")
assert(shared.providerDashboard("unknown") == nil, "unknown provider returns nil dashboard")

local mShort, mWeekly = shared.dualMetrics({
    { label = "Weekly", percent = 90, window_secs = 604800 },
    { label = "Session", percent = 20, window_secs = 18000 },
})
assert(mShort.percent == 20 and mWeekly.percent == 90, "dualMetrics should sort 5h/session first regardless of input order")

local labelShort, labelWeekly = shared.dualMetrics({
    { label = "Codex weekly", percent = 80 },
    { label = "Codex 5h", percent = 15 },
})
assert(labelShort.percent == 15 and labelWeekly.percent == 80, "dualMetrics should detect 5h vs weekly from labels")

local singleWeeklyShort, singleWeeklyWeekly = shared.dualMetrics({
    { label = "Weekly only", percent = 70, window_secs = 604800 },
})
assert(singleWeeklyShort == nil and singleWeeklyWeekly.percent == 70, "dualMetrics should identify single weekly metric")

local singleSessionShort, singleSessionWeekly = shared.dualMetrics({
    { label = "5h only", percent = 30, window_secs = 18000 },
})
assert(singleSessionShort.percent == 30 and singleSessionWeekly == nil, "dualMetrics should identify single session metric")

local malformedShort, malformedWeekly = shared.dualMetrics({ 42, { label = "Weekly", percent = 90, window_secs = 604800 } })
assert(malformedShort == nil and malformedWeekly.percent == 90,
    "dualMetrics should discard malformed entries before choosing a window")
local onlyMalformedShort, onlyMalformedWeekly = shared.dualMetrics({ 42 })
assert(onlyMalformedShort == nil and onlyMalformedWeekly == nil,
    "dualMetrics should not return a scalar metric")

local reorderedModels = shared.modelHeadlines({ id = "antigravity", metrics = {
    { label = "Gemini", percent = 90, window_secs = 604800 },
    { label = "Gemini", percent = 20, window_secs = 18000 },
} })
assert(#reorderedModels == 1 and reorderedModels[1].metric.percent == 20,
    "Antigravity headline should use the session window when weekly arrives first")

local balanceDeepseek = {
    id = "deepseek", status = "ready", stale = false, metrics = {},
    sections = {
        { type = "spacer" },
        { type = "text", label = "Balance", value = "$2.90" },
        { type = "block", label = "Breakdown", body = { "granted $0.00 · topped-up $2.90" } },
    },
}
assert(shared.balanceText(balanceDeepseek) == "$2.90",
    "a balance section should surface as the capsule reading")

local balanceNous = {
    id = "nous", status = "ready", stale = false, metrics = {},
    sections = {
        { type = "text", label = "Subscription credits", value = "0.00 remaining" },
        { type = "text", label = "Top-up credits", value = "8.19 remaining" },
        { type = "text", label = "Total usable credits", value = "8.19" },
        { type = "text", label = "Renews", value = "25d 20h" },
    },
}
assert(shared.balanceText(balanceNous) == "8.19",
    "total usable credits should win over the reset countdown")
assert(shared.balanceText({ id = "nous", metrics = {}, sections = {
    { type = "text", label = "Top-up credits", value = "8.19 remaining" },
} }) == "8.19 remaining", "a lone credit line is still a balance")
assert(shared.balanceText(usageEntry("openai", 12)) == nil,
    "a percentage provider must keep its metric and report no balance text")
assert(shared.balanceText({ id = "deepseek", metrics = {}, sections = {
    { type = "text", label = "Balance", value = "credentials error: no API key" },
} }) == nil, "an error line is not a balance")

-- ── Mathematical triage optimization tests ──────────────────────────────────
local function isoIn(secondsAhead)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + secondsAhead)
end

-- 1. Hard constraints / lockouts
local unavailItem = { entry = { status = "error" }, sessionMetric = { percent = 0 }, weeklyMetric = { percent = 0 } }
assert(shared.calculateModelTriageScore(unavailItem) == -1000, "unavailable model must receive -1000")

local weeklyExhaustedItem = {
    entry = { status = "ready" },
    sessionMetric = { percent = 10 },
    weeklyMetric = { percent = 100 },
}
assert(shared.calculateModelTriageScore(weeklyExhaustedItem) <= -500, "100% weekly exhausted must lockout <= -500")

local sessionExhaustedItem = {
    entry = { status = "ready" },
    sessionMetric = { percent = 100 },
    weeklyMetric = { percent = 50 },
}
assert(shared.calculateModelTriageScore(sessionExhaustedItem) <= -300, "100% session exhausted must lockout <= -300")

-- 2. Weekly reset imminence bonus (Double-quota opportunity)
-- An item with weekly reset in 12h vs 5 days, same 30% free weekly quota:
local weeklyImminent = {
    entry = { status = "ready" },
    sessionMetric = { percent = 0, window_secs = 18000, reset_at = nil },
    weeklyMetric = { percent = 70, window_secs = 604800, reset_at = isoIn(12 * 3600) },
}
local weeklyFar = {
    entry = { status = "ready" },
    sessionMetric = { percent = 0, window_secs = 18000, reset_at = nil },
    weeklyMetric = { percent = 70, window_secs = 604800, reset_at = isoIn(120 * 3600) },
}
local scoreImminent = shared.calculateModelTriageScore(weeklyImminent)
local scoreFar = shared.calculateModelTriageScore(weeklyFar)
assert(scoreImminent > scoreFar,
    string.format("imminent weekly reset (%f) must outrank far reset (%f) to enable double-quota consumption", scoreImminent, scoreFar))

-- 3. Session pacing: active session expiring soon with unused quota
local sessionExpiringSoon = {
    entry = { status = "ready" },
    sessionMetric = { percent = 5, window_secs = 18000, reset_at = isoIn(20 * 60) }, -- 20 min left, 95% free
    weeklyMetric = { percent = 30, window_secs = 604800, reset_at = isoIn(80 * 3600) },
}
local sessionJustStarted = {
    entry = { status = "ready" },
    sessionMetric = { percent = 5, window_secs = 18000, reset_at = isoIn(280 * 60) }, -- 4h 40m left, 95% free
    weeklyMetric = { percent = 30, window_secs = 604800, reset_at = isoIn(80 * 3600) },
}
local scoreExpiring = shared.calculateModelTriageScore(sessionExpiringSoon)
local scoreJustStarted = shared.calculateModelTriageScore(sessionJustStarted)
assert(scoreExpiring > scoreJustStarted,
    string.format("session about to expire with quota (%f) must be prioritized over freshly started (%f)", scoreExpiring, scoreJustStarted))

-- 4. Coupling between weekly health and session consumption:
-- Given two models with identical 5h session metrics, the one with ample weekly headroom
-- must heavily outrank the one at risk of weekly starvation.
local modelHealthyWeekly = {
    entry = { status = "ready" },
    sessionMetric = { percent = 20, window_secs = 18000, reset_at = isoIn(3 * 3600) },
    weeklyMetric = { percent = 20, window_secs = 604800, reset_at = isoIn(100 * 3600) }, -- 80% weekly free
}
local modelDepletedWeekly = {
    entry = { status = "ready" },
    sessionMetric = { percent = 20, window_secs = 18000, reset_at = isoIn(3 * 3600) },
    weeklyMetric = { percent = 92, window_secs = 604800, reset_at = isoIn(100 * 3600) }, -- only 8% weekly free with 4 days to go!
}
local scoreHealthy = shared.calculateModelTriageScore(modelHealthyWeekly)
local scoreDepleted = shared.calculateModelTriageScore(modelDepletedWeekly)
assert(scoreHealthy > scoreDepleted * 3,
    string.format("healthy weekly quota (%f) must dominate depleted weekly quota (%f)", scoreHealthy, scoreDepleted))

-- 5. Reset credit analysis, collision detection, and staggering plan
local mockCandidates = {
    {
        id = "anthropic",
        display_name = "Claude",
        metrics = {
            { label = "Session (5h)", percent = 0, reset_at = isoIn(3 * 3600), window_secs = 18000 },
            { label = "Weekly (7d)", percent = 74, reset_at = isoIn(50 * 3600), window_secs = 604800 },
        },
        reset_credits = {
            available = 1,
            credits = {
                { title = "Claude Opus 5.5 launch reset", expires_at = isoIn(11.7 * 86400) },
            },
        },
    },
    {
        id = "openai",
        display_name = "Codex",
        metrics = {
            { label = "Codex 5h", percent = 2, reset_at = isoIn(3 * 3600), window_secs = 18000 },
            { label = "Codex weekly", percent = 29, reset_at = isoIn(80 * 3600), window_secs = 604800 },
        },
        reset_credits = {
            available = 3,
            credits = {
                { title = "Full reset 1", expires_at = isoIn(11.8 * 86400) },
                { title = "Full reset 2", expires_at = isoIn(18.8 * 86400) },
                { title = "Full reset 3", expires_at = isoIn(26.8 * 86400) },
            },
        },
    },
}

local plan, stats = shared.analyzeResetCredits(mockCandidates)
assert(plan.hasCollision == true, "collision must be detected between Claude and Codex expiring in ~11.7d")
assert(plan.advanceProviderId == "anthropic", "claude must be chosen to advance due to higher weekly progress and single credit constraint")
assert(plan.deferProviderId == "openai", "codex must be chosen to defer")

-- Verify stagger bonus elevates advance provider score
local claudeItem = {
    providerId = "anthropic",
    entry = mockCandidates[1],
    sessionMetric = mockCandidates[1].metrics[1],
    weeklyMetric = mockCandidates[1].metrics[2],
}
local normalClaudeScore = shared.calculateModelTriageScore(claudeItem, nil)
local staggeredClaudeScore = shared.calculateModelTriageScore(claudeItem, plan)
assert(staggeredClaudeScore > normalClaudeScore,
    string.format("staggered score (%f) must exceed normal score (%f) to accelerate mid-cycle burn", staggeredClaudeScore, normalClaudeScore))

-- Verify canClaimNow triggers when weekly is >= 95%
local exhaustedClaudeCandidate = {
    id = "anthropic",
    display_name = "Claude",
    metrics = {
        { label = "Weekly (7d)", percent = 100, reset_at = isoIn(20 * 3600), window_secs = 604800 },
    },
    reset_credits = {
        available = 1,
        credits = { { title = "Launch reset", expires_at = isoIn(5 * 86400) } },
    },
}
local planClaim, statsClaim = shared.analyzeResetCredits({ exhaustedClaudeCandidate })
assert(statsClaim["anthropic"].canClaimNow == true, "provider at 100% weekly with available credit must flag canClaimNow")
assert(planClaim.optimalClaimProviders["anthropic"] == true, "plan must register anthropic in optimalClaimProviders")

-- 6. Schedule-aware active working hours calculation
local cfg = {
    scheduleAware = true,
    sleepStartHour = 0,
    sleepEndHour = 8,
    weekendSleepStartHour = 1,
    weekendSleepEndHour = 9,
    mealPauseHours = 1,
    burstDurationHours = 2.0,
}

-- Baseline: Monday 08:00 to Tuesday 08:00 (24 calendar hours)
local monMorning = os.time({ year = 2026, month = 10, day = 12, hour = 8, min = 0, sec = 0 })
local tueMorning = os.time({ year = 2026, month = 10, day = 13, hour = 8, min = 0, sec = 0 })
local active24h = shared.calculateActiveHours(monMorning, tueMorning, cfg, true)
assert(math.abs(active24h - 15.15) < 0.6,
    string.format("active hours in 24h should discount sleep and meal pause, got %f", active24h))

-- Out-of-schedule awake burst within weekend sleep window (01:00 to 09:00):
local sun2am = os.time({ year = 2026, month = 10, day = 11, hour = 2, min = 0, sec = 0 })
local sun8am = os.time({ year = 2026, month = 10, day = 11, hour = 8, min = 0, sec = 0 })
local burstActive = shared.calculateActiveHours(sun2am, sun8am, cfg, true)
local noBurstActive = shared.calculateActiveHours(sun2am, sun8am, cfg, false)
assert(burstActive >= 2.0, "user active out-of-schedule must receive the 2h awake burst")
assert(noBurstActive == 0.25, "user inactive during sleep hours must receive 0 active hours (clamped to 0.25)")

-- Disabled schedule fallback:
local disabledCfg = { scheduleAware = false }
local rawCalendar = shared.calculateActiveHours(monMorning, tueMorning, disabledCfg)
assert(rawCalendar == 24.0, "when scheduleAware is false, calculateActiveHours must return raw 24 calendar hours")

-- 7. Imminent weekly expiration triage prioritization (Gemini vs multi-day buffer)
-- Gemini: 84% used (16% free), reset in 16.7h calendar (~9.9h active working time)
-- Codex: 29% used (71% free), reset in 80h calendar (~47h active working time)
local geminiSunday = {
    providerId = "gemini",
    entry = { status = "ready" },
    sessionMetric = { percent = 45, window_secs = 18000, reset_at = isoIn(2.2 * 3600) },
    weeklyMetric = { percent = 84, window_secs = 604800, reset_at = isoIn(16.7 * 3600) },
}
local codexSunday = {
    providerId = "openai",
    entry = { status = "ready" },
    sessionMetric = { percent = 2, window_secs = 18000, reset_at = isoIn(2.8 * 3600) },
    weeklyMetric = { percent = 29, window_secs = 604800, reset_at = isoIn(80 * 3600) },
}
local geminiScore = shared.calculateModelTriageScore(geminiSunday, nil, os.time(), cfg, true)
local codexScore = shared.calculateModelTriageScore(codexSunday, nil, os.time(), cfg, true)
assert(geminiScore > codexScore,
    string.format("Gemini with imminent reset in ~9.9h active hours (%f) must outrank Codex with 4-day buffer (%f)", geminiScore, codexScore))

io.write("ok: shared timestamps, availability, provider order, mathematical triage score, and reset staggering\n")
