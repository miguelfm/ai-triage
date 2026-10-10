--!nonstrict
-- What the capsule and the panel both need, in one copy, so the parsing and the
-- severity tiers cannot drift between two entries that agree on screen. Needs
-- plugin_api 22, where require() arrived.

local M = {}

-- Tabler has no Anthropic mark, so providers without a brand glyph use a
-- semantic one. The glyph is identity: it carries no colour of its own, so every
-- colour left in the panel means something.
local PROVIDER_GLYPHS = {
    anthropic = "asterisk-simple",
    anthropic_api = "asterisk-simple",
    openai = "brand-openai",
    zai = "bolt",
    openrouter = "route",
    deepseek = "fish",
    kimi = "moon",
    moonshot = "moon",
    kilo = "robot",
    novita = "cloud",
    grok = "brand-x",
    supergrok = "brand-x",
    antigravity = "sparkles",
    cursor = "cursor-text",
    minimax = "wave-square",
    kiro = "ghost",
    nous = "flask",
    ["opencode-go"] = "code",
    commandcode = "terminal-2",
    copilot = "brand-github-copilot",
    gemini = "brand-google",
    ["claude-oss"] = "robot",
    ["claude_oss"] = "robot",
}

local PROVIDER_DASHBOARDS = {
    anthropic = "https://claude.ai/settings/usage",
    anthropic_api = "https://console.anthropic.com/",
    openai = "https://chatgpt.com/codex/settings/usage",
    openrouter = "https://openrouter.ai/activity",
    cursor = "https://www.cursor.com/settings",
    deepseek = "https://platform.deepseek.com/",
    zai = "https://z.ai",
    kimi = "https://platform.moonshot.cn/",
    moonshot = "https://platform.moonshot.cn/",
    grok = "https://console.x.ai/",
    supergrok = "https://grok.com/",
    gemini = "https://aistudio.google.com/",
    copilot = "https://github.com/settings/copilot",
    minimax = "https://platform.minimaxi.com/",
    antigravity = "https://antigravity.google/",
    ["claude-oss"] = "https://antigravity.google/",
    ["claude_oss"] = "https://antigravity.google/",
    kilo = "https://app.kilo.ai/usage",
    novita = "https://novita.ai/console",
    kiro = "https://app.kiro.dev/",
    nous = "https://portal.nousresearch.com/",
    ["opencode-go"] = "https://opencode.ai/console/",
    commandcode = "https://commandcode.ai/signin",
}

function M.baseProvider(id)
    return (tostring(id or ""):match("^[^@]+") or "")
end

function M.providerGlyph(id)
    return PROVIDER_GLYPHS[M.baseProvider(id)] or "brain"
end

function M.providerDashboard(id)
    return PROVIDER_DASHBOARDS[M.baseProvider(id)]
end

-- Ask the poller for a read. `at` is never read: it is there so two requests in
-- a row differ, and nowMs is the only sub-second clock the API has.
function M.requestRefresh()
    noctalia.state.set("command", { action = "refresh", at = noctalia.nowMs() })
end

-- Free text the CLI wrote to complain rather than to report; it marks those by
-- writing `error:` into the line. Asked here and nowhere else, so the panel and
-- the capsule cannot disagree about which lines are data.
function M.saysError(value)
    return tostring(value or ""):lower():find("error:") ~= nil
end

function M.transportError(value)
    return tostring(value or ""):lower():match("http%s*:?%s*%d%d%d") ~= nil
end

local function terminalAuthText(value)
    local text = tostring(value or ""):lower()
    local status = text:match("http%s*:?%s*401") ~= nil
        or text:match("http%s*:?%s*403") ~= nil
    local rejected = text:find("reject", 1, true) ~= nil
        or text:find("invalid", 1, true) ~= nil
        or text:find("expired", 1, true) ~= nil
        or text:find("forbidden", 1, true) ~= nil
        or text:find("unauthorized", 1, true) ~= nil
    return status and text:find("auth", 1, true) ~= nil and rejected
end

function M.terminalAuth(entry)
    if type(entry) ~= "table" then return false end
    if terminalAuthText(entry.error) then return true end
    local sections = type(entry.sections) == "table" and entry.sections or {}
    for _, section in ipairs(sections) do
        if type(section) == "table" and section.type == "text"
            and terminalAuthText(tostring(section.label or "") .. " "
                .. tostring(section.value or "")) then
            return true
        end
    end
    return false
end

-- A provider the CLI is no longer reading: the entry either fails outright, or
-- keeps serving cached numbers with a warning saying why they stopped moving.
-- Both mean the readings are a record, not a gauge.
function M.warning(entry)
    if type(entry) ~= "table" then return "" end
    local direct = noctalia.string.trim(tostring(entry.error or ""))
    if direct ~= "" then return direct end
    local sections = type(entry.sections) == "table" and entry.sections or {}
    for _, section in ipairs(sections) do
        if type(section) == "table" and section.type == "text" then
            local value = tostring(section.value or "")
            if M.saysError(value) then
                return noctalia.string.trim(value)
            end
        end
    end
    return ""
end

function M.unavailable(entry)
    if type(entry) ~= "table" then return true end
    if entry.status == "error" or M.warning(entry) ~= "" then return true end
    if entry.stale ~= true then return false end
    local sections = type(entry.sections) == "table" and entry.sections or {}
    for _, section in ipairs(sections) do
        if type(section) == "table" and section.type == "text"
            and (M.transportError(section.label) or M.transportError(section.value)) then
            return true
        end
    end
    return false
end

-- A parser failure says nothing about the account's availability.
function M.readFailure(entry)
    return type(entry) == "table" and entry.status == "error"
        and tostring(entry.error or ""):find("^schema mismatch:") ~= nil
end

-- Anything else in the `error` slot means no failure.
M.NO_FAILURE = { code = "", detail = "" }

function M.asFailure(value)
    if type(value) ~= "table" then return M.NO_FAILURE end
    return {
        code = type(value.code) == "string" and value.code or "",
        detail = type(value.detail) == "string" and value.detail or "",
    }
end

-- "2026-08-15T11:29:59.872624Z" -> unix seconds. The stamps are UTC and
-- os.time() reads its table as local, so the offset is measured at that same
-- instant and added back.
function M.parseIso(value)
    if type(value) ~= "string" then return nil end
    local y, mo, d, h, mi, s = value:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
    if y == nil then return nil end
    local asLocal = os.time({
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
    })
    local utc = os.date("!*t", asLocal)
    -- Let os.time resolve DST for these wall-clock fields. os.date marks a UTC
    -- table as standard time, which is wrong when the same fields fall in the
    -- local timezone's daylight-saving season.
    utc.isdst = nil
    local utcAsLocal = os.time(utc)
    return asLocal + (asLocal - utcAsLocal)
end

local function formatDuration(seconds)
    if seconds <= 0 then return noctalia.tr("ui.now") end
    local minutes = math.floor(seconds / 60)
    local days = math.floor(minutes / 1440)
    local hours = math.floor((minutes % 1440) / 60)
    local rest = minutes % 60
    if days > 0 then return string.format("%dd %dh", days, hours) end
    if hours > 0 then return string.format("%dh %dm", hours, rest) end
    return string.format("%dm", rest)
end

local function formatFixedDuration(seconds)
    if seconds <= 0 then return noctalia.tr("ui.now") end
    local minutes = math.floor(seconds / 60)
    local days = math.floor(minutes / 1440)
    local hours = math.floor((minutes % 1440) / 60)
    local rest = minutes % 60
    if days > 0 then return string.format("%dd %dh", days, hours) end
    return string.format("%dh %02dm", hours, rest)
end

function M.countdown(section)
    local at = M.parseIso(section and section.reset_at)
    if at == nil then return "" end
    return formatDuration(at - os.time())
end

function M.fixedCountdown(section)
    local at = M.parseIso(section and section.reset_at)
    if at == nil then return "" end
    return formatFixedDuration(at - os.time())
end

-- Where the countdown lands: "14:20" today, "Sat 14:20" past midnight, a date
-- once a weekday stops naming one day.
function M.resetClock(section)
    local at = M.parseIso(section and section.reset_at)
    if at == nil then return "" end
    local clock = noctalia.formatTime(noctalia.timeFormat(), at)
    if os.date("%Y-%m-%d", at) == os.date("%Y-%m-%d") then return clock end
    -- Prepended rather than folded into the pattern: the host's format grammar
    -- passes unknown text through verbatim, so "ddd" would render as the word.
    if at - os.time() > 6 * 86400 then return os.date("%d %b", at) .. " " .. clock end
    return os.date("%a", at) .. " " .. clock
end

-- How much of the window is gone, out of "Resets in 1h 58m · 60% elapsed".
function M.elapsedPercent(detail)
    local value = tostring(detail or ""):match("(%d+)%%%s*elapsed")
    return value ~= nil and tonumber(value) or nil
end

-- The pace is the trailing segment of "Resets in 1h 58m · 60% elapsed · 30pts
-- ahead". `elapsed` sitting there means the reading carries no pace at all.
-- Returns that segment's text, then the points and the direction inside it.
function M.pace(detail)
    local text = tostring(detail or "")
    local points, word = text:match("(%d+)pts%s+(%a+)")
    points = tonumber(points)
    if not text:find("·") then return "", points, word end
    local last = ""
    for part in text:gmatch("[^·]+") do last = part end
    last = noctalia.string.trim(last)
    if last:find("elapsed") then return "", points, word end
    return last, points, word
end

-- Whether a 5h rolling session has actively started consumption/countdown.
function M.isSessionStarted(metric)
    if type(metric) ~= "table" then return false end
    local pct = tonumber(metric.percent)
    if pct == nil then
        pct = tonumber(tostring(metric.value or ""):match("(%d+)")) or 0
    end
    if pct > 0 then
        return true
    end

    local at = M.parseIso(metric.reset_at)
    local remaining = nil
    if at ~= nil and at > os.time() then
        remaining = at - os.time()
    end

    if remaining == nil and type(metric.detail) == "string" then
        local detail = metric.detail
        local d, dh = detail:match("Resets in%s+(%d+)d%s*(%d*)h?")
        if d then
            remaining = tonumber(d) * 86400 + (tonumber(dh) or 0) * 3600
        else
            local h, m = detail:match("Resets in%s+(%d+)h%s*(%d*)m?")
            if h then
                remaining = tonumber(h) * 3600 + (tonumber(m) or 0) * 60
            else
                local mOnly = detail:match("Resets in%s+(%d+)m")
                if mOnly then
                    remaining = tonumber(mOnly) * 60
                end
            end
        end
    end

    -- If no future reset time is present (expired or never scheduled), session is not started
    if remaining == nil or remaining <= 0 then
        return false
    end

    local window = tonumber(metric.window_secs) or 18000
    if window <= 0 then window = 18000 end

    local elapsed = M.elapsedPercent(metric.detail)
    if elapsed == nil then
        local elapsedSecs = math.max(0, window - remaining)
        elapsed = math.floor((elapsedSecs / window) * 100)
    end

    -- An active session has consumed quota (>0%), has elapsed significantly
    -- (>= 10% elapsed, e.g. >30m into a 5h window), or has less than 90% remaining (<4h 30m of 5h).
    local isCodex = type(metric.label) == "string" and metric.label:lower():find("codex") ~= nil
    if isCodex then
        -- Codex (OpenAI) does not use fixed slots; its window is strictly rolling from the prompt.
        -- Any session that has elapsed (> 0% elapsed) or has less than 4h 58m remaining is actively running.
        if (elapsed and elapsed > 0) or (remaining > 0 and remaining < 17880) then
            return true
        end
    else
        -- Anthropic / others with fixed slots (e.g. slot can be up to 15-20m in before use):
        if (elapsed and elapsed >= 10) or (remaining > 0 and remaining < (window * 0.90)) then
            return true
        end
    end

    return false
end

-- Kept next to the role both entries colour with, so the tiers cannot be edited
-- in one file and forgotten in the other. `low` falls through to 0, like
-- anything the CLI adds later.
M.SEVERITY_RANK = { critical = 3, high = 2, mid = 1 }

local function isCritical(metric)
    if type(metric) ~= "table" then return false end
    local sev = tostring(metric.severity or "")
    local pct = tonumber(metric.percent) or 0
    return sev == "critical" or pct >= 100
end
M.isCritical = isCritical

-- Severity is a warning, not proof of exhaustion. Only a full quota blocks use.
function M.blockingMetric(metrics)
    local blocking = nil
    for _, metric in ipairs(metrics or {}) do
        if type(metric) == "table" and (tonumber(metric.percent) or 0) >= 100 then
            local reset = M.parseIso(metric.reset_at) or -1
            local previous = M.parseIso(blocking and blocking.reset_at) or -1
            if blocking == nil or reset > previous then blocking = metric end
        end
    end
    return blocking
end

function M.headline(entry)
    if type(entry) ~= "table" or type(entry.metrics) ~= "table" then return nil end
    local metrics = entry.metrics
    if #metrics == 0 then return nil end

    local blocking = M.blockingMetric(metrics)
    if blocking ~= nil then return blocking end

    -- 1. For Antigravity: always follow active session usage across models
    if M.baseProvider(entry.id) == "antigravity" then
        local seen = {}
        local best = nil
        local bestPct = -1
        for _, metric in ipairs(metrics) do
            if type(metric) == "table" and metric.label ~= nil and metric.label ~= "" then
                local model = tostring(metric.label)
                if not seen[model] then
                    seen[model] = true
                    local pct = tonumber(metric.percent) or 0
                    if pct > bestPct then
                        best = metric
                        bestPct = pct
                    end
                end
            end
        end
        if best ~= nil then return best end
    end

    -- Otherwise keep the primary window selected by the CLI.
    for _, metric in ipairs(metrics) do
        if type(metric) == "table" then return metric end
    end
    return nil
end

-- A provider can report a balance instead of a quota. The CLI then sends no
-- percentage metrics and puts the figure in a `text` section (DeepSeek
-- `Balance: $2.90`, Nous `Total usable credits: 8.19`). Pick the one a reader
-- would want on the bar: a total or balance first, then a credit/remaining
-- line, and never a reset countdown. Returns nil for providers that already
-- carry a headline metric, so the percentage path is untouched.
function M.balanceText(entry)
    if type(entry) ~= "table" or M.headline(entry) ~= nil then return nil end
    local sections = type(entry.sections) == "table" and entry.sections or nil
    if sections == nil then return nil end

    local credit = nil
    for _, section in ipairs(sections) do
        if type(section) == "table" and section.type == "text" then
            local value = noctalia.string.trim(tostring(section.value or ""))
            if value ~= "" and not M.saysError(value) then
                local label = tostring(section.label or ""):lower()
                if label:find("total", 1, true) or label:find("balance", 1, true) then
                    return value
                end
                if credit == nil
                    and (label:find("credit", 1, true) or label:find("remaining", 1, true)) then
                    credit = value
                end
            end
        end
    end
    return credit
end

function M.modelGlyph(label)
    local lower = tostring(label or ""):lower()
    if lower:find("oss", 1, true) or lower:find("claude", 1, true) then return "robot" end
    if lower:find("gemini", 1, true) then return "brand-google" end
    if lower:find("gpt", 1, true) or lower:find("openai", 1, true) then return "brand-openai" end
    return "sparkles"
end

function M.modelDisplayName(label)
    local lower = tostring(label or ""):lower()
    if lower:find("oss", 1, true) or lower:find("claude", 1, true) then return tostring(label or "") end
    if lower:find("gemini", 1, true) then return "Gemini" end
    if lower:find("gpt", 1, true) or lower:find("openai", 1, true) then return "GPT" end
    return tostring(label or "")
end

function M.modelHeadlines(entry)
    if type(entry) ~= "table" or type(entry.metrics) ~= "table" then return {} end
    if M.baseProvider(entry.id) ~= "antigravity" then return {} end

    local order = {}
    local byModel = {}
    for _, metric in ipairs(entry.metrics) do
        if type(metric) == "table" and metric.label ~= nil and metric.label ~= "" then
            local model = tostring(metric.label)
            if byModel[model] == nil then
                byModel[model] = {}
                order[#order + 1] = model
            end
            byModel[model][#byModel[model] + 1] = metric
        end
    end

    local result = {}
    for _, model in ipairs(order) do
        local modelMetrics = byModel[model]
        local sessionMetric, weeklyMetric = M.dualMetrics(modelMetrics)
        sessionMetric = sessionMetric or weeklyMetric
        local blockingMetric = M.blockingMetric(modelMetrics)
        if sessionMetric ~= nil then
            result[#result + 1] = {
                model = model,
                displayName = M.modelDisplayName(model),
                glyph = M.modelGlyph(model),
                metric = sessionMetric,
                metrics = modelMetrics,
                blockingMetric = blockingMetric,
            }
        end
    end
    return result
end

-- Extracts (shortMetric, weeklyMetric) where shortMetric represents the 5-hour
-- session limit and weeklyMetric represents the 7-day rate limit.
function M.dualMetrics(metrics)
    if type(metrics) ~= "table" then return nil, nil end
    local valid = {}
    for _, metric in ipairs(metrics) do
        if type(metric) == "table" then valid[#valid + 1] = metric end
    end
    metrics = valid
    if #metrics == 0 then return nil, nil end
    if #metrics == 1 then
        local m = metrics[1]
        local isWeekly = false
        if type(m) == "table" then
            local w = tonumber(m.window_secs)
            local lbl = tostring(m.label or ""):lower()
            if (w ~= nil and w > 86400) or lbl:find("week", 1, true) or lbl:find("7d", 1, true) then
                isWeekly = true
            end
        end
        if isWeekly then
            return nil, m
        end
        return m, nil
    end

    local shortMetric = nil
    local weeklyMetric = nil

    for _, m in ipairs(metrics) do
        if type(m) == "table" then
            local w = tonumber(m.window_secs)
            local lbl = tostring(m.label or ""):lower()
            if w ~= nil then
                if w <= 86400 and shortMetric == nil then
                    shortMetric = m
                elseif w > 86400 and weeklyMetric == nil then
                    weeklyMetric = m
                end
            elseif lbl:find("5h", 1, true) or lbl:find("session", 1, true) or lbl:find("hour", 1, true) then
                if shortMetric == nil then shortMetric = m end
            elseif lbl:find("week", 1, true) or lbl:find("7d", 1, true) then
                if weeklyMetric == nil then weeklyMetric = m end
            end
        end
    end

    if shortMetric ~= nil and weeklyMetric ~= nil then
        return shortMetric, weeklyMetric
    end

    if shortMetric ~= nil and weeklyMetric == nil and #metrics >= 2 then
        for _, m in ipairs(metrics) do
            if m ~= shortMetric then return shortMetric, m end
        end
    end

    if weeklyMetric ~= nil and shortMetric == nil and #metrics >= 2 then
        for _, m in ipairs(metrics) do
            if m ~= weeklyMetric then return m, weeklyMetric end
        end
    end

    return metrics[1], metrics[2]
end

function M.entries(report)
    if type(report) ~= "table" or type(report.entries) ~= "table" then return {} end
    local visible, positions = {}, {}
    for _, entry in ipairs(report.entries) do
        if type(entry) == "table" and not M.terminalAuth(entry)
            and (not M.unavailable(entry) or M.readFailure(entry)) then
            visible[#visible + 1] = entry
            positions[entry] = #visible
        end
    end
    table.sort(visible, function(a, b)
        local aMetric = M.headline(a)
        local bMetric = M.headline(b)
        local aRank = M.SEVERITY_RANK[tostring(aMetric and aMetric.severity or "")] or 0
        local bRank = M.SEVERITY_RANK[tostring(bMetric and bMetric.severity or "")] or 0
        if aRank ~= bRank then return aRank > bRank end
        local aPercent = type(aMetric) == "table" and tonumber(aMetric.percent) or -1
        local bPercent = type(bMetric) == "table" and tonumber(bMetric.percent) or -1
        if aPercent ~= bPercent then return aPercent > bPercent end
        return positions[a] < positions[b]
    end)
    return visible
end

-- A provider can report more than it was given, so clamp before this becomes a
-- bar width.
function M.ratio(percent)
    local value = (tonumber(percent) or 0) / 100
    if value < 0 then return 0 end
    if value > 1 then return 1 end
    return value
end

-- The CLI tiers every percentage; copying its thresholds here would be a second
-- source of truth. `calm` is for when it raised nothing.
--
-- `high` is deliberately not `tertiary`: themes may make that role dark, and in
-- the stock dark theme it lands at 2.8:1 on a card, below the 3.9:1 of the muted
-- text it is supposed to outrank.
function M.severityRole(section, calm)
    local severity = tostring(section and section.severity or "")
    if severity == "critical" then return "error" end
    if severity == "high" then return "secondary" end
    return calm
end

-- ── Reset credit analysis and staggering plan ─────────────────────────────────
-- When two or more providers have weekly reset credits/promotions expiring
-- around the same date (e.g. within 7 days in the same ~16d horizon),
-- it is practically impossible to double quota consumption for both in the same final week.
-- The optimal strategy is staggering:
-- 1. One provider is advanced to burn its weekly quota in half the time (~3.5d)
--    and claim the reset mid-cycle, completing two full quotas that week.
-- 2. The other provider is deferred to the final expiration week.
-- 3. When a provider with reset credits reaches 100% weekly usage (or >=95%),
--    an "Optimal Reset Window" is flagged to claim immediately.
function M.analyzeResetCredits(entries, nowTime)
    nowTime = nowTime or os.time()
    local providerStats = {}
    local allExpiring = {}

    for _, entry in ipairs(entries or {}) do
        local id = entry.id
        local baseId = M.baseProvider(id)
        local displayName = tostring(entry.display_name or entry.name or id or "")
        local rawCredits = type(entry.reset_credits) == "table" and entry.reset_credits.credits or nil
        local availableCount = type(entry.reset_credits) == "table" and tonumber(entry.reset_credits.available) or 0
        local sections = type(entry.sections) == "table" and entry.sections or {}

        local _, wMetric = M.dualMetrics(entry.metrics)
        local wPct = wMetric and tonumber(wMetric.percent) or 0
        local wAt = wMetric and M.parseIso(wMetric.reset_at)
        local wRemainingSecs = (wAt and wAt > nowTime) and (wAt - nowTime) or 604800

        local list = {}
        if rawCredits and #rawCredits > 0 then
            for _, rc in ipairs(rawCredits) do
                local expAt = M.parseIso(rc.expires_at)
                if expAt and expAt > nowTime then
                    list[#list + 1] = {
                        title = rc.title or "Full reset",
                        expiresAt = expAt,
                        remainingSecs = expAt - nowTime,
                    }
                end
            end
        end

        if #list == 0 then
            for _, section in ipairs(sections) do
                if section.type == "block" and tostring(section.label or ""):lower():find("reset credit") then
                    for _, line in ipairs(section.body or {}) do
                        local text = noctalia.string.trim(tostring(line or ""))
                        local days = tonumber(text:match("(%d+)d")) or 0
                        local hours = tonumber(text:match("(%d+)h")) or 0
                        local expAt = nowTime + (days * 86400) + (hours * 3600)
                        if expAt > nowTime then
                            list[#list + 1] = {
                                title = text:match("^(.-)%s+·") or text,
                                expiresAt = expAt,
                                remainingSecs = expAt - nowTime,
                            }
                        end
                    end
                end
            end
        end

        table.sort(list, function(a, b) return a.expiresAt < b.expiresAt end)

        local count = math.max(availableCount, #list)
        if count > 0 then
            local earliest = list[1]
            local stats = {
                id = id,
                baseId = baseId,
                name = displayName,
                glyph = M.providerGlyph(baseId),
                available = count,
                credits = list,
                earliestExpiry = earliest and earliest.expiresAt or (nowTime + 604800 * 2),
                earliestRemainingSecs = earliest and earliest.remainingSecs or (604800 * 2),
                weeklyPercent = wPct,
                weeklyRemainingSecs = wRemainingSecs,
                canClaimNow = (wPct >= 95 and count > 0),
            }
            providerStats[baseId] = stats
            if earliest then
                allExpiring[#allExpiring + 1] = stats
            end
        end
    end

    local staggerPlan = {
        hasCollision = false,
        collidingProviders = {},
        advanceProviderId = nil,
        advanceName = nil,
        deferProviderId = nil,
        deferName = nil,
        daysUntilExpiry = nil,
        timeDiffHours = nil,
        optimalClaimProviders = {},
    }

    for baseId, stats in pairs(providerStats) do
        if stats.canClaimNow then
            staggerPlan.optimalClaimProviders[baseId] = true
        end
    end

    -- Collision detection: 2 or more providers with credits expiring in <= 16 days
    -- and with expiration dates separated by less than 7 days (same weekly window)
    if #allExpiring >= 2 then
        table.sort(allExpiring, function(a, b) return a.earliestExpiry < b.earliestExpiry end)
        for i = 1, #allExpiring - 1 do
            local p1 = allExpiring[i]
            local p2 = allExpiring[i + 1]
            local diffSecs = math.abs(p1.earliestExpiry - p2.earliestExpiry)
            local horizonSecs = 16 * 86400

            if p1.earliestRemainingSecs <= horizonSecs and p2.earliestRemainingSecs <= horizonSecs and diffSecs <= (7 * 86400) then
                staggerPlan.hasCollision = true
                staggerPlan.collidingProviders = { p1, p2 }
                staggerPlan.timeDiffHours = diffSecs / 3600
                staggerPlan.daysUntilExpiry = math.min(p1.earliestRemainingSecs, p2.earliestRemainingSecs) / 86400

                -- Advance fitness evaluation:
                -- Higher current weekly consumption (wPct) = closer to reaching 100% in a compressed timeframe (~3.5d).
                -- Single vs multiple credits: if p1 only has 1 credit while p2 has multiple consecutive credits (e.g. Codex with 3),
                -- p1 needs to secure its single cycle, whereas p2 has subsequent cycles.
                local p1Score = p1.weeklyPercent + (p1.available == 1 and 25 or 0)
                local p2Score = p2.weeklyPercent + (p2.available == 1 and 25 or 0)

                local advanceP = (p1Score >= p2Score) and p1 or p2
                local deferP = (p1Score >= p2Score) and p2 or p1

                staggerPlan.advanceProviderId = advanceP.baseId
                staggerPlan.advanceName = advanceP.name
                staggerPlan.deferProviderId = deferP.baseId
                staggerPlan.deferName = deferP.name
                break
            end
        end
    end

    return staggerPlan, providerStats
end

-- ── Schedule-aware Human Activity Model ──────────────────────────────────────
-- Models realistic human interaction patterns (workdays vs weekends, sleep/rest,
-- meal pauses). Calculates effective active working hours (H_active) rather than
-- raw calendar hours, reflecting that quotas expiring within off-hours must be
-- burned during remaining awake periods before they are permanently lost.

M.DEFAULT_SCHEDULE = {
    scheduleAware = true,
    sleepStartHour = 0,         -- 00:00 midnight on weekdays
    sleepEndHour = 8,           -- 08:00 AM on weekdays
    weekendSleepStartHour = 1,  -- 01:00 AM on weekends
    weekendSleepEndHour = 9,    -- 09:00 AM on weekends
    mealPauseHours = 1,         -- 1h pause for lunch/dinner
    burstDurationHours = 2.0,   -- 2h active awake burst when active out-of-schedule
}

function M.getScheduleConfig()
    local aware = true
    if type(noctalia) == "table" and type(noctalia.getConfig) == "function" then
        if noctalia.getConfig("schedule_aware_triage") == false then
            aware = false
        end
    end
    local function numConfig(key, default, minVal, maxVal)
        if type(noctalia) == "table" and type(noctalia.getConfig) == "function" then
            local val = tonumber(noctalia.getConfig(key))
            if val ~= nil then
                if minVal and val < minVal then val = minVal end
                if maxVal and val > maxVal then val = maxVal end
                return val
            end
        end
        return default
    end

    return {
        scheduleAware = aware,
        sleepStartHour = numConfig("sleep_start_hour", 0, 0, 23),
        sleepEndHour = numConfig("sleep_end_hour", 8, 0, 23),
        weekendSleepStartHour = numConfig("weekend_sleep_start_hour", 1, 0, 23),
        weekendSleepEndHour = numConfig("weekend_sleep_end_hour", 9, 0, 23),
        mealPauseHours = numConfig("meal_pause_hours", 1, 0, 3),
        burstDurationHours = 2.0,
    }
end

-- Calculates effective active working hours between tStart and tEnd.
-- Out-of-schedule adaptation: If the user is currently active during nominal sleep hours
-- (e.g. late-night coding burst), an immediate awake burst is credited as active time,
-- after which off-hours resume until the morning wake-up hour.
function M.calculateActiveHours(tStart, tEnd, config, isUserActiveNow)
    if tEnd == nil or tStart == nil or tEnd <= tStart then
        return 0.0
    end
    config = config or M.getScheduleConfig()
    if not config.scheduleAware then
        return (tEnd - tStart) / 3600.0
    end
    if isUserActiveNow == nil then
        isUserActiveNow = true
    end

    local burstUntil = tStart
    if isUserActiveNow then
        burstUntil = tStart + ((config.burstDurationHours or 2.0) * 3600)
    end

    local totalActiveHours = 0.0
    local cur = tStart
    local step = 1800 -- 30-minute integration step

    while cur < tEnd do
        local nextCur = math.min(tEnd, cur + step)
        local dtHours = (nextCur - cur) / 3600.0
        local mid = (cur + nextCur) * 0.5

        local weight = 1.0
        if mid < burstUntil then
            -- Active out-of-schedule or immediate awake burst
            weight = 1.0
        else
            local date = os.date("*t", math.floor(mid))
            local wday = date.wday -- 1 = Sunday, 7 = Saturday
            local isWeekend = (wday == 1 or wday == 7)
            local hour = date.hour + date.min / 60.0

            local sStart = isWeekend and config.weekendSleepStartHour or config.sleepStartHour
            local sEnd = isWeekend and config.weekendSleepEndHour or config.sleepEndHour

            local inSleep = false
            if sStart == sEnd then
                inSleep = false
            elseif sStart < sEnd then
                inSleep = (hour >= sStart and hour < sEnd)
            else
                inSleep = (hour >= sStart or hour < sEnd)
            end

            if inSleep then
                weight = 0.0
            else
                if config.mealPauseHours and config.mealPauseHours > 0 then
                    local lunchStart = 14.0
                    local lunchEnd = 14.0 + config.mealPauseHours
                    if hour >= lunchStart and hour < lunchEnd then
                        weight = 0.15
                    else
                        weight = 1.0
                    end
                else
                    weight = 1.0
                end
            end
        end

        totalActiveHours = totalActiveHours + (dtHours * weight)
        cur = nextCur
    end

    return math.max(0.25, totalActiveHours)
end

-- Model Quota Gearing Ratios (K_m = L_weekly / L_session):
-- Defines how many full 100% 5h sessions equal 100% weekly quota.
-- Low K (<= 3.5, e.g. Claude & GPT OSS ~2.5): weekly quota is the bottleneck; 1 session burns ~40% of the week.
-- High K (>= 12.0, e.g. Codex ~16.0, Claude Pro ~14.0): 5h session windows are the bottleneck; 1 session burns only 6-7%.
M.DEFAULT_GEARING = {
    ["claude-oss"] = 2.5,
    ["gemini"] = 8.0,
    ["anthropic"] = 14.0,
    ["openai"] = 16.0,
    ["default"] = 10.0,
}

function M.getModelGearing(providerId, modelName)
    local rawId = tostring(providerId or ""):lower()
    local rawName = tostring(modelName or ""):lower()

    if type(noctalia) == "table" and type(noctalia.getConfig) == "function" then
        if rawId:find("oss") or rawName:find("oss") then
            local v = tonumber(noctalia.getConfig("gearing_claude_oss"))
            if v and v > 0 then return v end
        elseif rawId:find("gemini") or rawName:find("gemini") then
            local v = tonumber(noctalia.getConfig("gearing_gemini"))
            if v and v > 0 then return v end
        elseif rawId:find("anthropic") or (rawName:find("claude") and not rawName:find("oss")) then
            local v = tonumber(noctalia.getConfig("gearing_anthropic"))
            if v and v > 0 then return v end
        elseif rawId:find("openai") or rawName:find("codex") or rawName:find("gpt") then
            local v = tonumber(noctalia.getConfig("gearing_openai"))
            if v and v > 0 then return v end
        end
        local def = tonumber(noctalia.getConfig("gearing_default"))
        if def and def > 0 then return def end
    end

    if rawId:find("oss") or rawName:find("oss") then
        return 2.5
    elseif rawId:find("gemini") or rawName:find("gemini") then
        return 8.0
    elseif rawId:find("anthropic") or (rawName:find("claude") and not rawName:find("oss")) then
        return 14.0
    elseif rawId:find("openai") or rawName:find("codex") or rawName:find("gpt") then
        return 16.0
    end
    return 10.0
end

-- Mathematical triage model for dynamic multi-provider resource optimization:
-- Goal: Maximize useful token throughput over time without premature exhaustion,
-- ensuring all provider quotas finish near 0% by the end of their weekly (7d) or session (5h) window.
-- Schedule-aware active pacing: Pacing and velocity are calculated over effective active working hours
-- (discounting sleep and off-hours), elevating providers whose remaining active time is critically scarce.
-- Model gearing (K_m): Couples weekly quotas with 5h session windows, factoring in how many sessions
-- fit in a weekly quota (e.g. ~2.5 for Claude & GPT OSS vs ~16 for Codex).
-- Time-arbitrage & perishability: When weekly reset is within active reach (<= 24 active hours),
-- unspent quota risks permanent loss and receives an urgency multiplier.
-- Collision staggering: When designated as the advance leader, the weekly target pace is
-- compressed to reach 100% in half the cycle (~3.5d / ~45 active hours) to trigger the mid-cycle reset.
function M.calculateModelTriageScore(item, staggerPlan, nowTime, scheduleConfig, isUserActiveNow)
    if item == nil or M.unavailable(item.entry) then
        return -1000
    end
    nowTime = nowTime or os.time()
    scheduleConfig = scheduleConfig or M.getScheduleConfig()
    if isUserActiveNow == nil then
        isUserActiveNow = true
    end

    local sMetric = item.sessionMetric
    local wMetric = item.weeklyMetric

    local sPct = sMetric and tonumber(sMetric.percent) or 0
    local wPct = wMetric and tonumber(wMetric.percent) or 0
    local sFree = math.max(0, 100 - sPct)
    local wFree = math.max(0, 100 - wPct)

    -- Hard constraints / lockouts
    -- If weekly quota is 100% exhausted, no traffic can be routed
    if wMetric ~= nil and wPct >= 100 then
        return -500 - sPct
    end
    -- If session quota is 100% exhausted, provider waits for the 5h reset
    if sMetric ~= nil and sPct >= 100 then
        return -300 - wPct
    end

    ----------------------------------------------------------------------
    -- 1. WEEKLY MATHEMATICAL MODEL (7d): Velocity, Capacity & Gearing
    ----------------------------------------------------------------------
    local gearing = M.getModelGearing(item.providerId or (item.entry and item.entry.id), item.name)

    local wFactor = 1.0
    local uResetWeekly = 0.0
    local uStaggerAdvance = 0.0
    local uBottleneck = 0.0
    local uLowKConserve = 0.0
    local dutyCycle = 0.0
    local H_w = 0.0

    if wMetric ~= nil then
        local wAt = M.parseIso(wMetric.reset_at)
        H_w = M.calculateActiveHours(nowTime, wAt, scheduleConfig, isUserActiveNow)
        if H_w < 0.5 then H_w = 0.5 end

        -- If this model belongs to the provider designated to ADVANCE reset (stagger leader):
        -- The objective is to burn 100% of the weekly quota in half the time (~3.5d / ~45 active hours)
        -- to claim the reset mid-cycle and double weekly throughput.
        local isStaggerLeader = false
        if staggerPlan and staggerPlan.hasCollision and staggerPlan.advanceProviderId then
            local baseId = M.baseProvider(item.providerId or (item.entry and item.entry.id))
            if baseId == staggerPlan.advanceProviderId then
                isStaggerLeader = true
            end
        end

        local targetH_w = H_w
        if isStaggerLeader then
            -- Compressed horizon at half the cycle (minimum 6 active hours)
            targetH_w = math.min(H_w, math.max(6.0, H_w * 0.50))
        end

        -- Capacity and session duty cycle:
        -- In targetH_w active hours, max sessions = targetH_w / 5.0, each session burns (100 / gearing)%
        local C_max = (targetH_w * 20.0) / gearing
        dutyCycle = wFree / math.max(1.0, C_max)

        -- Required weekly consumption velocity ratio Pi_w, geared by model capacity ratio:
        local Pi_w = (wFree / targetH_w) * 1.68
        local gearedPi_w = Pi_w * ((gearing / 10.0) ^ 0.60)

        -- Threshold for low headroom scales with gearing (1 session is 100/gearing %):
        local oneSessionPct = 100.0 / gearing
        local lowHeadroomPct = math.min(30.0, math.max(8.0, oneSessionPct * 0.80))

        if wFree <= lowHeadroomPct and H_w > 24.0 and not isStaggerLeader then
            wFactor = 0.08 + 0.15 * (wFree / lowHeadroomPct)
        else
            -- Continuous weighting function: smooth scaling
            local maxWeight = isStaggerLeader and 2.20 or 1.80
            wFactor = math.min(maxWeight, math.max(0.20, 0.40 + 0.60 * gearedPi_w))
        end

        -- Stagger leader acceleration bonus:
        if isStaggerLeader and wFree >= 5.0 then
            uStaggerAdvance = 25.0 * (wFree / 100.0) * math.min(1.0, (100.0 - targetH_w) / 100.0)
        end

        -- Time-arbitrage and perishability bonus for imminent weekly reset (<= 24 active hours):
        -- Reflects that quotas expire permanently if not consumed.
        -- When active hours <= 24h, remaining 5h sessions are scarce (e.g. <= 2 sessions left).
        if H_w <= 24.0 and wFree >= 5.0 then
            local ratio = math.min(4.0, (16.0 / math.max(1.0, H_w))^1.2)
            uResetWeekly = wFree * ratio * 4.2
        end

        -- Bottleneck urgency bonus for high-gearing models (K >= 8):
        -- When dutyCycle >= 0.70 and weekly reset is not yet in the final 24h:
        if dutyCycle >= 0.70 and wFree >= 5.0 and H_w > 24.0 then
            local excess = math.min(2.0, dutyCycle - 0.50)
            uBottleneck = 25.0 * (wFree / 100.0) * excess
        end

        -- Low-K conservation penalty: when K <= 3.5 (e.g. Claude & GPT OSS) with ample time (H_w >= 18h):
        if gearing <= 3.5 and H_w >= 18.0 and dutyCycle <= 0.65 then
            local scarcity = (3.5 - gearing) / 3.5
            local timeHorizon = math.min(1.0, (H_w - 18.0) / 36.0)
            uLowKConserve = -20.0 * scarcity * (1.0 - dutyCycle) * timeHorizon
        end
    end

    ----------------------------------------------------------------------
    -- 2. SESSION MATHEMATICAL MODEL (5h) AND WEEKLY COUPLING
    ----------------------------------------------------------------------
    local score = 0.0

    if sMetric ~= nil then
        local sAt = M.parseIso(sMetric.reset_at)
        local sStarted = M.isSessionStarted(sMetric)
        local sWindow = tonumber(sMetric.window_secs) or 18000
        local sRemainingSecs = (sStarted and sAt and sAt > nowTime)
            and math.max(1, sAt - nowTime)
            or (sStarted and 1 or sWindow)
        local H_s = M.calculateActiveHours(nowTime, nowTime + sRemainingSecs, scheduleConfig, isUserActiveNow)
        if H_s < 0.05 then H_s = 0.05 end

        if sStarted then
            -- Active session: 5h timer is running
            local sElapsedRatio = math.min(1.0, math.max(0.0, (sWindow - sRemainingSecs) / sWindow))
            local sUrgencyFactor = 1.0 + 1.80 * (sElapsedRatio * sElapsedRatio)
            local baseSession = sFree * sUrgencyFactor

            -- Critical session burn urgency if effective active time before sleep/reset <= 1.5h
            local uBurnSession = 0.0
            if H_s <= 1.50 and sFree >= 15.0 then
                local burnUrgency = (1.50 - H_s) / 1.50
                uBurnSession = 50.0 * (sFree / 100.0) * burnUrgency
            end

            -- Coupling: session velocity modulated by weekly pace factor and bonuses
            score = (baseSession * wFactor) + uBurnSession + uResetWeekly + uStaggerAdvance + uBottleneck + uLowKConserve
        else
            -- Uninitiated session (0% usage, timer not yet started):
            -- Discounted if available active time before sleep/off-hours is short
            local availabilityDiscount = math.min(1.0, math.max(0.35, H_s / 5.0))
            local baseSession = sFree * 0.75 * availabilityDiscount
            local uKickstart = 0.0
            if dutyCycle >= 0.75 and H_w > 24.0 then
                uKickstart = 12.0 * math.min(1.5, dutyCycle - 0.50)
            end
            score = (baseSession * wFactor) + uKickstart + uResetWeekly + uStaggerAdvance + uBottleneck + uLowKConserve
        end
    else
        -- No session metric: optimize directly on weekly quota
        score = (wFree * wFactor) + uResetWeekly + uStaggerAdvance + uBottleneck + uLowKConserve
    end

    return score
end

return M
