--!nonstrict
-- What the capsule and the panel both need, in one copy, so the parsing and the
-- severity tiers cannot drift between two entries that agree on screen. Needs
-- plugin_api 22, where require() arrived.

local M = {}

M.WINDOW_5H = 18000
M.WINDOW_7D = 604800
M.WEEKLY_HOURS = 168.0
M.NOMINAL_WEEKLY_PACE_RATIO = 1.68

local function trim(s)
    if noctalia and noctalia.string and type(noctalia.string.trim) == "function" then
        return noctalia.string.trim(s)
    end
    return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

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
    return PROVIDER_GLYPHS[M.baseProvider(id)] or "scale"
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

    -- At 0% quota usage, rolling providers (Codex, Antigravity) report a synthetic
    -- future reset timestamp floating around the full window (e.g. 4h 59m, 4h 58m,
    -- with 0% elapsed). These are unstarted sessions awaiting their first prompt.
    -- A 5h session is only considered started if:
    -- 1) Quota has been consumed (pct > 0, handled above),
    -- 2) Time has elapsed significantly (>= 10% elapsed, e.g. > 30m into a 5h window),
    -- 3) Or less than 90% of the window remains (< 4h 30m of 5h: remaining < window * 0.90).
    if (elapsed and elapsed >= 10) or (remaining > 0 and remaining < (window * 0.90)) then
        return true
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

function M.isModelHidden(providerId, modelName)
    local hideOss = false
    local hiddenList = ""
    if noctalia and type(noctalia.getConfig) == "function" then
        hideOss = noctalia.getConfig("hide_claude_oss") == true
        hiddenList = tostring(noctalia.getConfig("hidden_services") or "")
    end
    local pid = tostring(providerId or ""):lower()
    local name = tostring(modelName or ""):lower()
    local basePid = M.baseProvider(pid):lower()

    if hideOss then
        if pid == "claude-oss" or pid == "claude_oss"
            or basePid == "claude-oss" or basePid == "claude_oss"
            or name:find("oss", 1, true)
            or (name:find("claude", 1, true) and not pid:find("anthropic")) then
            return true
        end
    end

    if hiddenList ~= "" then
        for item in hiddenList:gmatch("[^,]+") do
            local lowerItem = item:match("^%s*(.-)%s*$"):lower()
            if lowerItem ~= "" then
                if pid == lowerItem or basePid == lowerItem or name == lowerItem
                    or (name ~= "" and name:find(lowerItem, 1, true))
                    or (pid ~= "" and pid:find(lowerItem, 1, true)) then
                    return true
                end
                if (lowerItem == "claude-oss" or lowerItem == "claude_oss" or lowerItem == "claudeoss")
                    and (name:find("claude", 1, true) and name:find("oss", 1, true)) then
                    return true
                end
            end
        end
    end

    return false
end

-- Severity is a warning, not proof of exhaustion. Only a full quota blocks use.
function M.blockingMetric(metrics, providerId)
    local blocking = nil
    for _, metric in ipairs(metrics or {}) do
        if type(metric) == "table" and (tonumber(metric.percent) or 0) >= 100 then
            local lbl = tostring(metric.label or "")
            if not M.isModelHidden(providerId or lbl, lbl) then
                local reset = M.parseIso(metric.reset_at) or -1
                local previous = M.parseIso(blocking and blocking.reset_at) or -1
                if blocking == nil or reset > previous then blocking = metric end
            end
        end
    end
    return blocking
end

function M.headline(entry)
    if type(entry) ~= "table" or type(entry.metrics) ~= "table" then return nil end
    local metrics = entry.metrics
    if #metrics == 0 then return nil end

    local visibleMetrics = {}
    for _, m in ipairs(metrics) do
        if type(m) == "table" then
            local lbl = tostring(m.label or "")
            if not M.isModelHidden(entry.id, lbl) then
                visibleMetrics[#visibleMetrics + 1] = m
            end
        end
    end
    if #visibleMetrics == 0 then visibleMetrics = metrics end

    -- Per-model quota pools (ai-usagebar 1.40+ model_pool) should not block the headline
    -- if shared provider windows still have capacity
    local nonPoolMetrics = {}
    for _, m in ipairs(visibleMetrics) do
        if type(m) == "table" and not m.model_pool then nonPoolMetrics[#nonPoolMetrics + 1] = m end
    end
    local candidateMetrics = #nonPoolMetrics > 0 and nonPoolMetrics or visibleMetrics

    local blocking = M.blockingMetric(candidateMetrics, entry.id)
    if blocking ~= nil then return blocking end

    -- 1. For Antigravity: always follow active session usage across visible models
    if M.baseProvider(entry.id) == "antigravity" then
        local seen = {}
        local best = nil
        local bestPct = -1
        for _, metric in ipairs(candidateMetrics) do
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
    for _, metric in ipairs(visibleMetrics) do
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
    if lower:find("argon", 1, true) then return "Gemini 4 Argon" end
    if lower == "gemini" then return "Gemini" end
    if lower:find("gemini", 1, true) then return tostring(label or "") end
    if lower:find("gpt", 1, true) or lower:find("openai", 1, true) then return "GPT" end
    return tostring(label or "")
end

-- Parse quota from agy statusline observation JSON (e.g. agy-statusline.observation.json)
function M.parseAgyStatuslineObservation(data)
    if type(data) ~= "table" then return nil end
    local quota = {}

    local q = (type(data.payload) == "table" and type(data.payload.quota) == "table") and data.payload.quota or nil
    if q then
        if type(q["gemini-5h"]) == "table" then
            local rem = tonumber(q["gemini-5h"].remaining_fraction) or 1
            local used = math.max(0, math.min(100, math.floor((1 - rem) * 100 + 0.5)))
            quota.gemini_5h = {
                percent = used,
                reset_at = q["gemini-5h"].reset_time,
                remaining_secs = tonumber(q["gemini-5h"].reset_in_seconds),
            }
        end
        if type(q["gemini-weekly"]) == "table" then
            local rem = tonumber(q["gemini-weekly"].remaining_fraction) or 1
            local used = math.max(0, math.min(100, math.floor((1 - rem) * 100 + 0.5)))
            quota.gemini_weekly = {
                percent = used,
                reset_at = q["gemini-weekly"].reset_time,
                remaining_secs = tonumber(q["gemini-weekly"].reset_in_seconds),
            }
        end
        if type(q["3p-5h"]) == "table" then
            local rem = tonumber(q["3p-5h"].remaining_fraction) or 1
            local used = math.max(0, math.min(100, math.floor((1 - rem) * 100 + 0.5)))
            quota.third_party_5h = {
                percent = used,
                reset_at = q["3p-5h"].reset_time,
                remaining_secs = tonumber(q["3p-5h"].reset_in_seconds),
            }
        end
        if type(q["3p-weekly"]) == "table" then
            local rem = tonumber(q["3p-weekly"].remaining_fraction) or 1
            local used = math.max(0, math.min(100, math.floor((1 - rem) * 100 + 0.5)))
            quota.third_party_weekly = {
                percent = used,
                reset_at = q["3p-weekly"].reset_time,
                remaining_secs = tonumber(q["3p-weekly"].reset_in_seconds),
            }
        end
    end

    if not quota.gemini_5h and type(data.snapshot) == "table" and type(data.snapshot.windows) == "table" then
        for _, w in ipairs(data.snapshot.windows) do
            if type(w) == "table" then
                local kind = w.kind
                local used = tonumber(w.used_percent)
                if used == nil and w.remaining_percent ~= nil then
                    used = 100 - tonumber(w.remaining_percent)
                end
                used = math.max(0, math.min(100, math.floor((used or 0) + 0.5)))
                local resetIso = nil
                local remSecs = nil
                if w.resets_at then
                    local ts = tonumber(w.resets_at)
                    if ts then
                        resetIso = os.date("!%Y-%m-%dT%H:%M:%SZ", ts)
                        remSecs = math.max(0, ts - os.time())
                    end
                end
                if kind == "five_hour" then
                    quota.gemini_5h = {
                        percent = used,
                        reset_at = resetIso,
                        remaining_secs = remSecs,
                    }
                elseif kind == "weekly" then
                    quota.gemini_weekly = {
                        percent = used,
                        reset_at = resetIso,
                        remaining_secs = remSecs,
                    }
                end
            end
        end
    end

    if quota.gemini_5h or quota.gemini_weekly then
        return quota
    end
    return nil
end

-- Parse quota output from `agy -p /quota`
function M.parseAgyCliQuota(text)
    if type(text) ~= "string" or text == "" then return nil end
    local quota = {}

    for line in text:gmatch("[^\r\n]+") do
        local isGemini = line:find("Gemini", 1, true) ~= nil
        local is3p = line:find("Claude", 1, true) ~= nil or line:find("GPT", 1, true) ~= nil
        local is5h = line:find("Five Hour", 1, true) ~= nil
        local isWeekly = line:find("Weekly", 1, true) ~= nil
        local remPct, y, mo, d, h, mi = line:match("(%d+)%%%s+(%d%d%d%d)%-(%d%d)%-(%d%d)%s+(%d%d):(%d%d)")
        if (isGemini or is3p) and (is5h or isWeekly) and remPct then
            local remaining = tonumber(remPct) or 100
            local used = math.max(0, math.min(100, 100 - remaining))
            local localTs = os.time({
                year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                hour = tonumber(h), min = tonumber(mi), sec = 0,
            })
            local iso = os.date("!%Y-%m-%dT%H:%M:%SZ", localTs)
            local item = {
                percent = used,
                reset_at = iso,
                remaining_secs = math.max(0, localTs - os.time()),
            }
            if isGemini and is5h then
                quota.gemini_5h = item
            elseif isGemini and isWeekly then
                quota.gemini_weekly = item
            elseif is3p and is5h then
                quota.third_party_5h = item
            elseif is3p and isWeekly then
                quota.third_party_weekly = item
            end
        end
    end

    if quota.gemini_5h or quota.gemini_weekly then
        return quota
    end
    return nil
end

-- Enrich Antigravity entry with real local session quota
function M.enrichAntigravityEntry(entry, quotaData)
    if type(entry) ~= "table" or type(quotaData) ~= "table" then return end
    if type(entry.metrics) ~= "table" then return end

    local function applyUpdate(m, qd)
        if not qd then return end
        if qd.percent ~= nil then
            m.percent = qd.percent
            m.value = string.format("%d%%", qd.percent)
            if qd.percent >= 90 then
                m.severity = "critical"
            elseif qd.percent >= 75 then
                m.severity = "high"
            elseif qd.percent >= 50 then
                m.severity = "mid"
            else
                m.severity = "low"
            end
        end
        if qd.reset_at then
            m.reset_at = qd.reset_at
            local remainingText = M.countdown({ reset_at = qd.reset_at })
            if remainingText ~= "" then
                m.detail = "Resets in " .. remainingText
            else
                m.detail = "Resets now"
            end
        end
    end

    for _, m in ipairs(entry.metrics) do
        if type(m) == "table" and type(m.label) == "string" then
            local label = m.label:lower()
            local window = tonumber(m.window_secs) or 0
            if label:find("gemini") then
                if window <= 43200 then
                    applyUpdate(m, quotaData.gemini_5h)
                else
                    applyUpdate(m, quotaData.gemini_weekly)
                end
            elseif label:find("claude") or label:find("gpt") or label:find("oss") then
                if window <= 43200 then
                    applyUpdate(m, quotaData.third_party_5h)
                else
                    applyUpdate(m, quotaData.third_party_weekly)
                end
            end
        end
    end

    if type(entry.sections) == "table" then
        for _, s in ipairs(entry.sections) do
            if type(s) == "table" and s.type == "metric" and type(s.label) == "string" then
                local label = s.label:lower()
                local window = tonumber(s.window_secs) or 0
                if label:find("gemini") then
                    if window <= 43200 then
                        applyUpdate(s, quotaData.gemini_5h)
                    else
                        applyUpdate(s, quotaData.gemini_weekly)
                    end
                elseif label:find("claude") or label:find("gpt") or label:find("oss") then
                    if window <= 43200 then
                        applyUpdate(s, quotaData.third_party_5h)
                    else
                        applyUpdate(s, quotaData.third_party_weekly)
                    end
                end
            elseif type(s) == "table" and s.label == "Source" and type(s.value) == "string" then
                s.value = "Local agy session"
            end
        end
    end
end

function M.modelHeadlines(entry)
    if type(entry) ~= "table" or type(entry.metrics) ~= "table" then return {} end
    if M.baseProvider(entry.id) ~= "antigravity" then return {} end

    local order = {}
    local byModel = {}
    for _, metric in ipairs(entry.metrics) do
        if type(metric) == "table" and metric.label ~= nil and metric.label ~= "" then
            local model = tostring(metric.label)
            if not M.isModelHidden(entry.id, model) then
                if byModel[model] == nil then
                    byModel[model] = {}
                    order[#order + 1] = model
                end
                byModel[model][#byModel[model] + 1] = metric
            end
        end
    end

    local result = {}
    for _, model in ipairs(order) do
        local modelMetrics = byModel[model]
        local sessionMetric, weeklyMetric = M.dualMetrics(modelMetrics)
        sessionMetric = sessionMetric or weeklyMetric
        local blockingMetric = M.blockingMetric(modelMetrics, entry.id)
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
            if w ~= nil and w > 0 then
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
            local id = entry.id
            local name = entry.display_name or entry.name or entry.id
            if not M.isModelHidden(id, name) then
                visible[#visible + 1] = entry
                positions[entry] = #visible
            end
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
-- A weekly reset credit is worth the quota it lets you burn before the natural
-- renewal would have refilled the week anyway, minus the unused quota it throws
-- away. That holds whether a claim zeroes the counter under the same renewal or
-- opens a fresh 7d window (which then stands in for the natural renewal), so a
-- claim is bounded by the active hours left in the cycle: claiming a few hours
-- before the renewal buys back one session at most and wastes the credit.
--
-- Capacity runs at full 5h-session pace, each session spending 100/gearing % of
-- the week, the same C_max the weekly triage uses.
M.CLAIM_MIN_WEEKLY_PCT = 95 -- the week is effectively spent
M.CLAIM_VALUE_RATIO = 0.5   -- spend it now only for at least half of what it is worth later

local function sessionCapacity(activeHours, gearing)
    return math.max(0.0, activeHours) * 20.0 / gearing
end

-- Best gain from spending a credit inside one cycle: burn `wFree` at full pace,
-- claim as soon as it runs out (or right before the credit expires), then burn
-- the refill until the renewal. Hours are active hours from the start of the cycle.
local function cycleClaimGain(cycleHours, expiryHours, wFree, gearing)
    if expiryHours <= 0 then return 0.0 end
    local burnHours = math.min(wFree * gearing / 20.0, expiryHours, cycleHours)
    local leftover = wFree - math.min(wFree, sessionCapacity(burnHours, gearing))
    local refill = math.min(100.0, sessionCapacity(cycleHours - burnHours, gearing))
    return math.max(0.0, refill - leftover)
end

-- When to spend a provider's earliest-expiring credit: "claim" now, "advance"
-- (worth spending this cycle once the week runs out), or "hold" for a later cycle.
local function adviseResetCredit(stats, gearing, nowTime, config)
    local renewAt = stats.weeklyResetAt
    local window = stats.weeklyWindowSecs
    local expiresAt = stats.earliestExpiry
    local wFree = math.max(0.0, 100.0 - stats.weeklyPercent)

    local cycleHours = M.calculateActiveHours(nowTime, renewAt, config, true)
    local expiryHours = expiresAt >= renewAt and math.huge
        or M.calculateActiveHours(nowTime, expiresAt, config, true)
    local nowGain = math.max(0.0, math.min(100.0, sessionCapacity(cycleHours, gearing)) - wFree)
    local cycleGain = cycleClaimGain(cycleHours, expiryHours, wFree, gearing)

    -- The next cycle starts at 0%: the whole week has to be burnt before a claim pays.
    -- To meaningfully defer to the next cycle, the credit must survive deep enough
    -- into the next cycle (at least 3.0 days / 72h) and allow burning at least ~40%
    -- of the fresh week naturally. Credits expiring on the same day as renewal or
    -- within 72h cannot be deferred — this cycle is their last viable chance.
    local laterGain = 0.0
    local minDeferRunwaySecs = 3 * 86400
    if expiresAt > (renewAt + minDeferRunwaySecs) then
        local nextEnd = renewAt + window
        local nextHours = M.calculateActiveHours(renewAt, nextEnd, config, false)
        local nextExpiry = expiresAt >= nextEnd and math.huge
            or M.calculateActiveHours(renewAt, expiresAt, config, false)
        local minBurnHours = 40.0 * gearing / 20.0
        if nextExpiry >= minBurnHours then
            laterGain = cycleClaimGain(nextHours, nextExpiry, 100.0, gearing)
        end
    end

    local oneSession = 100.0 / gearing
    local lastChance = (expiresAt <= renewAt + minDeferRunwaySecs)
        or (laterGain < math.max(40.0, oneSession))
        or (cycleGain >= 50.0 and laterGain < cycleGain * 0.65)

    local worthIt = cycleGain >= oneSession and (laterGain == 0.0 or cycleGain >= M.CLAIM_VALUE_RATIO * laterGain)
    local spent = stats.weeklyPercent >= M.CLAIM_MIN_WEEKLY_PCT
    local expiryFirst = expiryHours < wFree * gearing / 20.0
    local renewIn = formatDuration(renewAt - nowTime)
    local expiresIn = formatDuration(expiresAt - nowTime)

    local perilExpiry = expiryHours <= 4.0 or (expiresAt - nowTime) <= (6 * 3600)
    local canClaimPeril = perilExpiry and (stats.weeklyPercent >= 80 or nowGain >= oneSession)

    local advice = {
        nowGain = nowGain,
        cycleGain = cycleGain,
        laterGain = laterGain,
        lastChance = lastChance,
        sessionsToSpend = wFree / oneSession,
    }
    if worthIt and (spent or canClaimPeril or (expiryFirst and expiryHours <= 2.0)) then
        advice.status = "claim"
        advice.summary = spent
            and string.format("Weekly quota spent · claim now: ~%d%% of a week back before the renewal in %s",
                math.floor(nowGain + 0.5), renewIn)
            or string.format("Reset credit expires in %s · claim now: ~%d%% of a week back",
                expiresIn, math.floor(nowGain + 0.5))
    elseif worthIt then
        advice.status = "advance"
        if lastChance and (renewAt - nowTime) <= (7 * 86400) and not expiryFirst then
            advice.summary = string.format("Claim before renewal in %s · burn remaining %d%% early · worth ~%d%% of a week",
                renewIn, math.floor(wFree + 0.5), math.floor(cycleGain + 0.5))
        elseif expiryFirst then
            advice.summary = string.format("Claim before the credit expires in %s · worth ~%d%% of a week",
                expiresIn, math.floor(cycleGain + 0.5))
        else
            advice.summary = string.format("Claim once this week runs out · worth ~%d%% of a week",
                math.floor(cycleGain + 0.5))
        end
    else
        advice.status = "hold"
        advice.summary = laterGain > cycleGain
            and string.format("Keep the reset: renews in %s, a claim now adds ~%d%% of a week vs ~%d%% next cycle",
                renewIn, math.floor(cycleGain + 0.5), math.floor(laterGain + 0.5))
            or string.format("Keep the reset: a claim this cycle adds only ~%d%% of a week",
                math.floor(cycleGain + 0.5))
    end
    return advice
end

-- When two or more providers have weekly reset credits/promotions expiring
-- around the same date (e.g. within 7 days in the same ~16d horizon),
-- it is practically impossible to double quota consumption for both in the same final week.
-- The optimal strategy is staggering:
-- 1. One provider is advanced to burn its weekly quota early and claim the reset
--    mid-cycle, completing two full quotas that week. When its current cycle is
--    too short for that, the advance starts from its next renewal.
-- 2. The other provider is deferred to the final expiration week.
-- 3. A claim is flagged only once the week is spent (or the credit is about to
--    expire) and the cycle has enough active hours left to make it pay.
function M.analyzeResetCredits(entries, nowTime, scheduleConfig)
    nowTime = nowTime or os.time()
    scheduleConfig = scheduleConfig or M.getScheduleConfig()
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
        local wWindow = wMetric and tonumber(wMetric.window_secs) or 604800
        local wAt = wMetric and M.parseIso(wMetric.reset_at)
        if wAt == nil or wAt <= nowTime then wAt = nowTime + wWindow end
        local wRemainingSecs = wAt - nowTime

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
                if type(section) == "table" and section.type == "block" and tostring(section.label or ""):lower():find("reset credit") then
                    local lines = type(section.body) == "table" and section.body or {}
                    for _, line in ipairs(lines) do
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
                weeklyResetAt = wAt,
                weeklyWindowSecs = wWindow,
                weeklyRemainingSecs = wRemainingSecs,
            }
            stats.advice = adviseResetCredit(stats, M.getModelGearing(id, displayName), nowTime, scheduleConfig)
            stats.canClaimNow = stats.advice.status == "claim"
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
        expiresAt = nil,
        timeDiffHours = nil,
        advanceNow = false,
        optimalClaimProviders = {},
        -- Providers whose weekly quota should be burnt early so the credit is claimed this cycle
        fastTrack = {},
        creditAdvice = {},
    }

    for baseId, stats in pairs(providerStats) do
        staggerPlan.creditAdvice[baseId] = stats.advice
        if stats.canClaimNow then
            staggerPlan.optimalClaimProviders[baseId] = true
        end
        -- Last cycle in which the credit can pay off: burn the week early to reach it.
        if stats.advice.status == "advance" and stats.advice.lastChance then
            staggerPlan.fastTrack[baseId] = true
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
                staggerPlan.expiresAt = math.min(p1.earliestExpiry, p2.earliestExpiry)

                -- Advance fitness evaluation:
                -- 1. Reserve scarcity: a provider with 1 credit must secure its single window,
                --    whereas providers with multiple credits have subsequent renewal cycles.
                -- 2. Progress / Cycle proximity: higher weekly progress (or imminent renewal
                --    starting a fresh week in a few hours) minimizes burn friction.
                local function advanceScore(p)
                    local reserveScarcity = (1.0 / math.max(1, p.available)) * 50.0
                    local progress = p.weeklyPercent
                    if p.advice.status == "hold" and not p.advice.lastChance then
                        -- For providers held pending imminent renewal: proximity to the fresh cycle
                        progress = (1.0 - math.min(1.0, p.weeklyRemainingSecs / p.weeklyWindowSecs)) * 30.0
                    elseif p.advice.lastChance then
                        progress = progress + 100.0
                    end
                    return reserveScarcity + progress
                end
                local p1Score = advanceScore(p1)
                local p2Score = advanceScore(p2)

                local advanceP = (p1Score >= p2Score) and p1 or p2
                local deferP = (p1Score >= p2Score) and p2 or p1

                staggerPlan.advanceProviderId = advanceP.baseId
                staggerPlan.advanceName = advanceP.name
                staggerPlan.deferProviderId = deferP.baseId
                staggerPlan.deferName = deferP.name
                staggerPlan.advanceNow = advanceP.advice.status == "advance"
                if staggerPlan.advanceNow then
                    staggerPlan.fastTrack[advanceP.baseId] = true
                end
                -- The deferred credit waits for a later cycle while that one can still pay it back.
                if deferP.advice.status == "advance" and not deferP.advice.lastChance then
                    deferP.advice.status = "hold"
                    deferP.advice.summary = string.format("Deferred: keep it for the cycle after the renewal in %s · worth ~%d%% of a week",
                        formatDuration(deferP.weeklyRemainingSecs), math.floor(deferP.advice.laterGain + 0.5))
                end
                break
            end
        end
    end

    return staggerPlan, providerStats
end

-- Check whether a candidate provider is configured (excludes unconfigured "no api key" errors)
function M.isConfigured(entry)
    if type(entry) ~= "table" then return false end
    if entry.status ~= "error" then return true end
    local message = tostring(entry.error or ""):lower()
    return not (message:find("^credentials error:") and message:find("no api key", 1, true))
end

-- Map a provider/model entry to its CLI kickstart target name ("claude", "codex", "gemini", "claude-oss")
function M.kickstartTarget(itemOrId, optionalName)
    if itemOrId == nil then return nil end
    local id = ""
    local name = ""
    if type(itemOrId) == "table" then
        id = tostring(itemOrId.providerId or itemOrId.id or "")
        name = tostring(itemOrId.name or itemOrId.displayName or ""):lower()
    else
        id = tostring(itemOrId)
        name = tostring(optionalName or ""):lower()
    end
    if id == "anthropic" or name:find("^claude$") then
        return "claude"
    elseif id == "openai" or name:find("^codex") then
        return "codex"
    elseif id == "gemini" or name:find("gemini") then
        return "gemini"
    elseif id == "claude-oss" or id == "claude_oss" or name:find("oss") then
        return "claude-oss"
    elseif id == "antigravity" then
        if name:find("gemini") then
            return "gemini"
        elseif name:find("claude") or name:find("oss") then
            return "claude-oss"
        end
    end
    return nil
end

-- Normalize candidate provider entries and unpack multi-model providers (Antigravity) into distinct model items
function M.collectModelItems(candidates)
    local items = {}
    if type(candidates) ~= "table" then return items end
    for _, entry in ipairs(candidates) do
        local id = entry.id
        local baseId = M.baseProvider(id)
        local displayName = tostring(entry.display_name or entry.name or entry.id or "")
        local plan = tostring(entry.plan or "")

        if baseId == "antigravity" then
            local models = M.modelHeadlines(entry)
            if #models > 0 then
                for _, model in ipairs(models) do
                    local sMetric, wMetric = M.dualMetrics(model.metrics)
                    local subId = (model.displayName == "Gemini" or tostring(model.name or ""):lower():find("gemini"))
                        and "gemini"
                        or "claude-oss"
                    items[#items + 1] = {
                        providerId = subId,
                        providerName = model.displayName,
                        plan = plan,
                        providerGlyph = model.glyph,
                        name = model.displayName,
                        glyph = model.glyph,
                        badge = nil,
                        sessionMetric = sMetric,
                        weeklyMetric = wMetric,
                        entry = entry,
                    }
                end
            elseif not M.isModelHidden(id, displayName) then
                local sMetric, wMetric = M.dualMetrics(entry.metrics)
                items[#items + 1] = {
                    providerId = id,
                    providerName = displayName,
                    plan = plan,
                    providerGlyph = M.providerGlyph(id),
                    name = displayName,
                    glyph = M.providerGlyph(id),
                    badge = nil,
                    sessionMetric = sMetric,
                    weeklyMetric = wMetric,
                    entry = entry,
                }
            end
        else
            if not M.isModelHidden(id, displayName) then
                local sMetric, wMetric = M.dualMetrics(entry.metrics)
                items[#items + 1] = {
                    providerId = id,
                    providerName = displayName,
                    plan = plan,
                    providerGlyph = M.providerGlyph(id),
                    name = displayName,
                    glyph = M.providerGlyph(id),
                    badge = nil,
                    sessionMetric = sMetric,
                    weeklyMetric = wMetric,
                    entry = entry,
                }
            end
        end
    end
    for _, item in ipairs(items) do
        M.recordTelemetrySample(item)
    end
    return items
end

-- Collect, parse, and sort pending reset credits from provider sections and stagger plans
function M.collectResetCredits(candidates, staggerPlan)
    local credits = {}
    if type(candidates) ~= "table" then return credits end
    for _, entry in ipairs(candidates) do
        local providerName = tostring(entry.display_name or entry.name or entry.id or "")
        local providerId = entry.id
        local baseId = M.baseProvider(providerId)
        local sections = type(entry.sections) == "table" and entry.sections or {}
        local rawCredits = type(entry.reset_credits) == "table" and entry.reset_credits.credits or nil

        for _, section in ipairs(sections) do
            if type(section) == "table" and section.type == "block" and tostring(section.label or ""):lower():find("reset credit") then
                local lines = type(section.body) == "table" and section.body or {}
                for lineIndex, line in ipairs(lines) do
                    local text = trim(tostring(line))
                    local kind, expiry = text:match("^(.-)%s+·%s+(.+)$")
                    local expiryText = ""
                    if expiry then
                        expiryText = expiry:gsub("^[Ee]xpires%s*", "")
                    elseif text:find("[Ee]xpires") then
                        expiryText = text:gsub("^[Ee]xpires%s*", "")
                    else
                        expiryText = text
                    end

                    local expireTimestamp = nil
                    if rawCredits and rawCredits[lineIndex] and rawCredits[lineIndex].expires_at then
                        expireTimestamp = M.parseIso(rawCredits[lineIndex].expires_at)
                    end
                    if expireTimestamp == nil and rawCredits then
                        for _, rc in ipairs(rawCredits) do
                            if kind and rc.title and rc.title == kind then
                                expireTimestamp = M.parseIso(rc.expires_at)
                                break
                            end
                        end
                    end
                    if expireTimestamp == nil then
                        local days = tonumber(expiryText:match("(%d+)d")) or 0
                        local hours = tonumber(expiryText:match("(%d+)h")) or 0
                        expireTimestamp = os.time() + (days * 86400) + (hours * 3600)
                    end

                    local role = nil
                    if staggerPlan and staggerPlan.hasCollision then
                        if baseId == staggerPlan.advanceProviderId then
                            role = "advance"
                        elseif baseId == staggerPlan.deferProviderId then
                            role = "defer"
                        end
                    end

                    credits[#credits + 1] = {
                        baseId = baseId,
                        providerId = providerId,
                        providerName = providerName,
                        glyph = M.providerGlyph(providerId),
                        expiry = expiryText,
                        fullTitle = kind or text,
                        expiresAt = expireTimestamp or math.huge,
                        role = role,
                    }
                end
            end
        end
    end

    table.sort(credits, function(a, b)
        if a.expiresAt ~= b.expiresAt then
            return a.expiresAt < b.expiresAt
        end
        return (a.providerName or "") < (b.providerName or "")
    end)

    -- Only the earliest-expiring credit of a provider is the next one to spend.
    local seen = {}
    for _, credit in ipairs(credits) do
        if not seen[credit.baseId] then
            seen[credit.baseId] = true
            local advice = staggerPlan and staggerPlan.creditAdvice and staggerPlan.creditAdvice[credit.baseId]
            credit.advice = advice and advice.summary or nil
            if staggerPlan and staggerPlan.optimalClaimProviders and staggerPlan.optimalClaimProviders[credit.baseId] then
                credit.role = "claim"
            end
        end
    end

    return credits
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
    local step = 3600 -- 1-hour integration step

    while cur < tEnd do
        -- Fast-path for far time horizons beyond 48 hours:
        -- Beyond 2 days, exact circadian boundaries have zero differential effect on triage;
        -- add nominal active working ratio (0.65 ~= 15.6 active hours / 24h) and break.
        if (cur - tStart) >= 172800 then
            local farHours = (tEnd - cur) / 3600.0
            totalActiveHours = totalActiveHours + (farHours * 0.65)
            break
        end

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

-- Nominal weekly active waking hours: 7 days * ~15 active hours/day (discounting sleep and meal breaks)
M.NOMINAL_WEEKLY_ACTIVE_HOURS = 105.0

-- Model Quota Gearing Ratios (K_m = L_weekly / L_session):
-- Defines how many full 100% 5h sessions equal 100% weekly quota.
-- Low K (<= 3.5, e.g. Claude & GPT OSS ~2.5): weekly quota is the bottleneck; 1 session burns ~40% of the week.
-- Moderate K (e.g. Codex ~6.3, Claude Pro ~7.0): 1 session burns ~15.9% / ~14.3% of the week.
-- High K (>= 12.0): session capacity can become the bottleneck before the weekly reset.
M.DEFAULT_GEARING = {
    ["claude-oss"] = 2.5,
    ["gemini"] = 8.0,
    ["anthropic"] = 7.0,
    ["openai"] = 6.3, -- Observed Oct 1–12, 2026: 512 session points / 81 weekly points.
    ["default"] = 10.0,
}

-- In-memory empirical telemetry store for tracking session delta vs weekly delta (K_obs = Delta S / Delta W)
M.telemetryBaselines = {}

function M.modelTelemetryKey(providerId, modelName)
    local pid = tostring(providerId or ""):lower()
    local mname = tostring(modelName or ""):lower()
    if pid:find("oss") or mname:find("oss") then
        return "claude-oss"
    elseif pid:find("gemini") or mname:find("gemini") then
        return "gemini"
    elseif pid:find("anthropic") or (mname:find("claude") and not mname:find("oss")) then
        return "anthropic"
    elseif pid:find("openai") or mname:find("codex") or mname:find("gpt") then
        return "openai"
    end
    return pid ~= "" and pid or "default"
end

-- Record a telemetry sample from an item with both 5h session and 7d weekly metrics.
-- When quota is consumed during an active session, computes empirical gearing:
-- K_obs = Delta Session % / Delta Weekly %
function M.recordTelemetrySample(item)
    if type(item) ~= "table" then return end
    local sMetric = item.sessionMetric
    local wMetric = item.weeklyMetric
    if type(sMetric) ~= "table" or type(wMetric) ~= "table" then return end

    local sPct = tonumber(sMetric.percent)
    local wPct = tonumber(wMetric.percent)
    if sPct == nil or wPct == nil then return end

    local key = M.modelTelemetryKey(item.providerId or (item.entry and item.entry.id), item.name)
    local sReset = tostring(sMetric.reset_at or "")
    local wReset = tostring(wMetric.reset_at or "")

    local telemetry = M.telemetryBaselines
    if type(noctalia) == "table" and type(noctalia.state) == "table" and type(noctalia.state.get) == "function" then
        local st = noctalia.state.get("gearing_telemetry")
        if type(st) == "table" then telemetry = st end
    end

    local rec = telemetry[key]
    if rec == nil then
        rec = {
            s_base = sPct,
            w_base = wPct,
            s_reset = sReset,
            w_reset = wReset,
            k_calibrated = nil,
            obs_samples = 0,
        }
        telemetry[key] = rec
    else
        -- Detect session or weekly cycle reset
        local resetChanged = (sReset ~= "" and rec.s_reset ~= "" and sReset ~= rec.s_reset)
        local sessionDropped = (rec.s_base > 25 and sPct <= 5)
        local weekReset = (wReset ~= "" and rec.w_reset ~= "" and wReset ~= rec.w_reset)

        if resetChanged or sessionDropped or weekReset then
            rec.s_base = sPct
            rec.w_base = wPct
            rec.s_reset = sReset
            rec.w_reset = wReset
        else
            if sPct < rec.s_base then
                rec.s_base = sPct
                rec.w_base = wPct
            else
                local dS = sPct - rec.s_base
                local dW = wPct - rec.w_base
                -- When session usage delta is significant (>= 15%) and weekly delta >= 1%:
                if dS >= 15.0 and dW >= 1.0 then
                    local k_sample = dS / dW
                    if k_sample >= 1.5 and k_sample <= 30.0 then
                        rec.obs_samples = (rec.obs_samples or 0) + 1
                        if rec.k_calibrated == nil then
                            rec.k_calibrated = math.floor(k_sample * 10 + 0.5) / 10
                        else
                            local blended = 0.35 * k_sample + 0.65 * rec.k_calibrated
                            rec.k_calibrated = math.floor(blended * 10 + 0.5) / 10
                        end
                    end
                end
            end
        end
    end

    M.telemetryBaselines = telemetry
    if type(noctalia) == "table" and type(noctalia.state) == "table" and type(noctalia.state.set) == "function" then
        noctalia.state.set("gearing_telemetry", telemetry)
    end
end

function M.getModelGearing(providerId, modelName, item)
    local rawId = tostring(providerId or ""):lower()
    local rawName = tostring(modelName or ""):lower()
    local key = M.modelTelemetryKey(providerId, modelName)

    -- 1. Check user manual override in configuration
    if type(noctalia) == "table" and type(noctalia.getConfig) == "function" then
        local configKey = "gearing_" .. (key:gsub("%-", "_"))
        local v = tonumber(noctalia.getConfig(configKey))
        if v and v > 0 then
            local defVal = M.DEFAULT_GEARING[key] or 10.0
            if math.abs(v - defVal) > 0.05 then
                return v, false
            end
        end
    end

    -- 2. Check dynamic empirical telemetry calibration
    local telemetry = M.telemetryBaselines
    if type(noctalia) == "table" and type(noctalia.state) == "table" and type(noctalia.state.get) == "function" then
        local st = noctalia.state.get("gearing_telemetry")
        if type(st) == "table" then telemetry = st end
    end
    local rec = telemetry and telemetry[key]
    if rec and rec.k_calibrated and rec.k_calibrated > 0 then
        return rec.k_calibrated, true
    end

    -- 3. Default empirical baseline
    local def = M.DEFAULT_GEARING[key] or M.DEFAULT_GEARING["default"]
    return def, false
end

-- Upstream dynamic weekly cycle passthrough (the upstream reset_at is authoritative)
function M.reconcileReportCycles(report, _nowTime)
    return report
end

-- Mathematical triage model for dynamic multi-provider resource optimization:
-- Goal: Maximize useful token throughput over time without premature exhaustion,
-- ensuring all provider quotas finish near 0% by the end of their weekly (7d) or session (5h) window.
-- Schedule-aware active pacing: Pacing and velocity are calculated over effective active working hours
-- (discounting sleep and off-hours), elevating providers whose remaining active time is critically scarce.
-- Model gearing (K_m): Couples weekly quotas with 5h session windows, factoring in how many sessions
-- fit in a weekly quota (e.g. ~2.5 for Claude & GPT OSS vs ~6.3 for Codex).
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
        local sAt = M.parseIso(sMetric.reset_at)
        local sRem = (sAt and sAt > nowTime) and (sAt - nowTime) or 18000
        return -300 - math.min(99.0, (sRem / 3600.0) * 10.0) - (wPct * 0.05)
    end

    ----------------------------------------------------------------------
    -- 1. WEEKLY MATHEMATICAL MODEL (7d): Velocity, Capacity & Gearing
    ----------------------------------------------------------------------
    local gearing = M.getModelGearing(item.providerId or (item.entry and item.entry.id), item.name)

    local wFactor = 1.0
    local uResetWeekly = 0.0
    local uBottleneck = 0.0
    local dutyCycle = 0.0
    local H_w = 0.0

    if wMetric ~= nil then
        local wAt = wMetric and M.parseIso(wMetric.reset_at)
        H_w = M.calculateActiveHours(nowTime, wAt, scheduleConfig, isUserActiveNow)
        if H_w < 0.5 then H_w = 0.5 end

        -- If this model belongs to a provider fast-tracking its reset credit (stagger leader,
        -- or the last cycle in which the credit pays off): burn 100% of the weekly quota in
        -- half the time (~3.5d / ~45 active hours) to claim the reset mid-cycle and double
        -- weekly throughput. A cycle too short for the claim to pay is never fast-tracked.
        local isStaggerLeader = false
        if staggerPlan and staggerPlan.fastTrack then
            local baseId = M.baseProvider(item.providerId or (item.entry and item.entry.id))
            isStaggerLeader = staggerPlan.fastTrack[baseId] == true
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

        -- Required weekly consumption velocity ratio Pi_w relative to nominal active pace:
        local Pi_w = (wFree / targetH_w) * (M.NOMINAL_WEEKLY_ACTIVE_HOURS / 100.0)
        local defaultGearing = M.DEFAULT_GEARING["default"] or 10.0
        local gearedPi_w = Pi_w * ((gearing / defaultGearing) ^ 0.60)

        -- Threshold for low headroom scales with gearing (1 session is 100/gearing %):
        local oneSessionPct = 100.0 / gearing
        local lowHeadroomPct = math.min(30.0, math.max(8.0, oneSessionPct * 0.80))

        -- Temporal distribution & anti-burst smoothing (prevents concentration of usage followed by voids):
        -- When there are still many active hours left in the week (H_w > 24.0) and not fast-tracking:
        -- Evaluate pacing relative to elapsed time in the 7-day cycle.
        local paceSmooth = 1.0
        if H_w > 24.0 and not isStaggerLeader and wMetric.window_secs then
            local wWindow = tonumber(wMetric.window_secs) or 604800
            local wRemSecs = (wAt and wAt > nowTime) and (wAt - nowTime) or 0
            local wElapsedRatio = math.min(1.0, math.max(0.0, (wWindow - wRemSecs) / wWindow))
            local expectedBurn = wElapsedRatio * 100.0
            local overPace = wPct - expectedBurn
            if overPace > 15.0 then
                -- Ahead of pace: smoothly dampen to avoid exhausting quota days before renewal
                paceSmooth = math.max(0.35, 1.0 - 0.02 * (overPace - 15.0))
            elseif overPace < -15.0 then
                -- Behind pace: gently favor to ensure smooth utilization of available quota
                paceSmooth = math.min(1.35, 1.0 + 0.015 * (-overPace - 15.0))
            end
        end

        if wFree <= lowHeadroomPct and H_w > 24.0 and not isStaggerLeader then
            wFactor = (0.08 + 0.15 * (wFree / lowHeadroomPct)) * paceSmooth
        else
            -- Continuous weighting function: smooth scaling modulated by temporal pacing
            local maxWeight = isStaggerLeader and 2.20 or 1.80
            wFactor = math.min(maxWeight, math.max(0.20, (0.40 + 0.60 * gearedPi_w) * paceSmooth))
        end

        -- Time-arbitrage and perishability urgency for imminent weekly reset (<= 24 active hours):
        -- Reflects that quotas expire permanently if not consumed.
        -- When active hours <= 24h (or targetH_w <= 24h for fast-track leaders), remaining 5h sessions are scarce.
        local sprintH = isStaggerLeader and targetH_w or H_w
        if sprintH <= 24.0 and wFree > 0.5 then
            local ratio = math.min(8.0, (24.0 / math.max(0.5, sprintH)) ^ 1.25)
            local sprintBonus = sprintH <= 3.0 and (220.0 * (3.0 - sprintH) / 3.0) or 0.0
            uResetWeekly = 50.0 + sprintBonus + (wFree * 4.0 * ratio)
        end

        -- Unified capacity bottleneck urgency when session slots are scarce:
        if dutyCycle >= 0.70 and wFree >= 5.0 and H_w > 24.0 then
            local excess = math.min(1.5, dutyCycle - 0.50)
            uBottleneck = 20.0 * (wFree / 100.0) * excess
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
            score = (baseSession * wFactor) + uBurnSession + uResetWeekly + uBottleneck
        else
            -- Uninitiated session (0% usage, timer not yet started):
            -- Discounted if available active time before sleep/off-hours is short
            local availabilityDiscount = math.min(1.0, math.max(0.35, H_s / 5.0))
            local baseSession = sFree * 0.75 * availabilityDiscount
            score = (baseSession * wFactor) + uResetWeekly + uBottleneck
        end
    else
        -- No session metric: optimize directly on weekly quota
        score = (wFree * wFactor) + uResetWeekly + uBottleneck
    end

    return score
end

-- ── Typographic scaling & presets ─────────────────────────────────────────────
local PRESET_FACTORS = {
    compact = 0.85,
    small = 0.85,
    normal = 1.00,
    medium = 1.00,
    large = 1.15,
    huge = 1.30,
    xlarge = 1.30,
    ["extra-large"] = 1.30,
    ["extra_large"] = 1.30,
}

function M.getTypography(customPreset)
    local preset = customPreset
    if preset == nil or preset == "" or preset == "inherit" then
        if noctalia and type(noctalia.getConfig) == "function" then
            preset = noctalia.getConfig("font_scale")
        end
    end
    preset = tostring(preset or "normal"):lower()
    local num = tonumber(preset)
    local factor = num or PRESET_FACTORS[preset] or 1.00
    if factor < 0.50 then factor = 0.50 end
    if factor > 2.00 then factor = 2.00 end

    return {
        preset = preset,
        factor = factor,
        fontSize = function(base)
            return math.max(7, math.floor((base or 11) * factor + 0.5))
        end,
        glyphSize = function(base)
            return math.max(8, math.floor((base or 14) * factor + 0.5))
        end,
    }
end

return M
