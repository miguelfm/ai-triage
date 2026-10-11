--!nonstrict
-- AI Triage dashboard: Side-by-side 3-column view of Rolling 5h Sessions,
-- Weekly 7d Quotas, and Reset Credits / Stagger Strategy.

local report = nil
local polling = false
local refreshQueued = false

local shared = require("./shared.luau")
local parseIso = shared.parseIso
local countdown = shared.countdown
local ratio = shared.ratio
local severityRole = shared.severityRole
local isSessionStarted = shared.isSessionStarted
local calculateModelTriageScore = shared.calculateModelTriageScore
local calculateActiveHours = shared.calculateActiveHours
local getScheduleConfig = shared.getScheduleConfig
local getModelGearing = shared.getModelGearing
local elapsedPercent = shared.elapsedPercent
local requestRefresh = shared.requestRefresh
local unavailable = shared.unavailable
local NO_FAILURE, asFailure = shared.NO_FAILURE, shared.asFailure
local isConfigured = shared.isConfigured
local kickstartTarget = shared.kickstartTarget
local collectModelItems = shared.collectModelItems
local collectResetCredits = shared.collectResetCredits
local providerDashboard = shared.providerDashboard

local failure = NO_FAILURE

local CARD = {
    gap = 8,
    padding = 12,
    radius = 11,
    fill = "surface_variant/0.88",
    border = "outline/0.20",
    borderWidth = 1,
}

local function cardStyle(gap, fill, border, padding)
    return {
        gap = gap or CARD.gap,
        padding = padding or CARD.padding,
        radius = CARD.radius,
        fill = fill or CARD.fill,
        border = border or CARD.border,
        borderWidth = CARD.borderWidth,
    }
end

local function configured(entry)
    return isConfigured(entry)
end

local function entries()
    return shared.entries(report)
end

-- ── Detail line parsing ───────────────────────────────────────────────────────
-- "Resets in 1h 58m · 60% elapsed · 30pts ahead". The reset half is already in
-- `reset_at`; what is left is the pace, and some details carry no reset at all.
local function plainDetail(detail)
    local head = tostring(detail or ""):match("^[^·]*") or ""
    head = noctalia.string.trim(head)
    if head:lower():find("^resets?%s+in") then return "" end
    return head
end

-- ── Error Block ───────────────────────────────────────────────────────────────
-- The CLI's own words come last and smallest, where a bug report can quote them.
local function errorBlock()
    local key = "ui.error." .. failure.code
    local children = {
        ui.row({ gap = 6, align = "center" }, {
            ui.glyph({ name = "alert-circle", size = 18, color = "error" }),
            ui.label({ text = noctalia.tr(key), fontSize = 12, fontWeight = "bold", color = "error" }),
        }),
        ui.label({ text = noctalia.tr(key .. "_hint"), fontSize = 11, color = "on_surface_variant" }),
    }

    if failure.detail ~= "" then
        children[#children + 1] = ui.label({
            text = failure.detail, fontSize = 11, color = "on_surface_variant", maxLines = 3,
        })
    end

    local actions = {
        ui.button({
            text = noctalia.tr("ui.retry"), glyph = "refresh",
            variant = "outline", controlSize = "sm",
            enabled = not polling,
            onClick = requestRefresh,
        }),
    }

    if failure.code == "not_installed" then
        children[#children + 1] = ui.label({
            text = "https://github.com/akitaonrails/ai-usagebar",
            fontSize = 11, color = "on_surface", maxLines = 2,
        })
        actions[#actions + 1] = ui.button({
            text = noctalia.tr("ui.install"), glyph = "brand-github",
            variant = "outline", controlSize = "sm",
            onClick = function()
                if type(noctalia.runAsync) == "function" then
                    noctalia.runAsync("xdg-open 'https://github.com/akitaonrails/ai-usagebar'")
                end
            end,
        })
    end
    children[#children + 1] = ui.row({ gap = 6, align = "center" }, actions)

    return ui.column({ gap = 8, padding = 12, radius = 14,
                       fill = "error/0.06", border = "error/0.12", borderWidth = 1 }, children)
end

-- ── Presentation & Triage Formatting ──────────────────────────────────────────

local function formatResetTime(metric, windowLabel)
    local isWeekly = windowLabel == "7d"
    if not isWeekly and not isSessionStarted(metric) then
        return ""
    end
    local at = parseIso(metric and metric.reset_at)
    if at == nil then
        return countdown(metric)
    end
    if not isWeekly and at <= os.time() then
        return ""
    end
    local clock = noctalia.formatTime(noctalia.timeFormat(), at)
    if isWeekly then
        local weekday = os.date("%a", at)
        local day = os.date("%d", at)
        local month = os.date("%b", at)
        local activeHours = calculateActiveHours(os.time(), at)
        local activeStr = ""
        if activeHours and activeHours > 0 and activeHours <= 24.0 and (at - os.time()) <= 86400 * 2 then
            activeStr = string.format(" (~%.1fh active)", activeHours)
        end
        return string.format("%s, %s %s %s%s", weekday, month, day, clock, activeStr)
    else
        if os.date("%Y-%m-%d", at) == os.date("%Y-%m-%d") then
            return clock
        else
            local weekday = os.date("%a", at)
            return string.format("%s %s", weekday, clock)
        end
    end
end

local function countdownColor(metric)
    if not isSessionStarted(metric) then
        return "on_surface_variant"
    end
    local at = parseIso(metric and metric.reset_at)
    local window = tonumber(metric and metric.window_secs) or 18000
    if at == nil or at <= os.time() then
        return "on_surface_variant"
    end

    local remaining = math.max(0, at - os.time())
    local r = remaining / window

    if r > 0.60 then
        return "#4ade80" -- Verde (>60%)
    elseif r > 0.30 then
        return "#38bdf8" -- Azul (30%-60%)
    elseif r > 0.12 then
        return "#facc15" -- Amarelo (12%-30%)
    elseif r > 0.04 then
        return "#fb923c" -- Laranxa (4%-12%)
    else
        return "#f87171" -- Vermello (<4%)
    end
end

local function calculateElapsed(metric, windowLabel)
    if metric == nil then return nil end
    local isWeekly = windowLabel == "7d"
    if not isWeekly and not isSessionStarted(metric) then
        return nil
    end
    local fromDetail = elapsedPercent(metric.detail)
    if fromDetail ~= nil then
        return math.min(100, math.max(0, fromDetail))
    end
    local at = parseIso(metric.reset_at)
    local window = tonumber(metric.window_secs)
        or (isWeekly and 604800 or 18000)
    if at ~= nil and window > 0 and at > os.time() then
        local remaining = math.max(0, at - os.time())
        local elapsed = math.max(0, window - remaining)
        return math.min(100, math.max(0, math.floor((elapsed / window) * 100)))
    end
    return nil
end

local function formatSeconds(seconds)
    if seconds <= 0 then return "now" end
    local minutes = math.floor(seconds / 60)
    local days = math.floor(minutes / 1440)
    local hours = math.floor((minutes % 1440) / 60)
    local rest = minutes % 60
    if days > 0 then return string.format("%dd %dh", days, hours) end
    if hours > 0 then return string.format("%dh %dm", hours, rest) end
    return string.format("%dm", rest)
end

local function assessTriage(metric, percent, elapsedPct, windowLabel, item, staggerPlan)
    if metric == nil or percent == nil then return nil end
    local isWeekly = windowLabel == "7d"
    local remainingQuota = 100 - percent
    local at = parseIso(metric.reset_at)
    local remainingSecs = (at and at > os.time()) and (at - os.time()) or 0
    local paceDiff = (elapsedPct or 0) - percent

    local wMetric = item and item.weeklyMetric
    local wPct = wMetric and tonumber(wMetric.percent) or 0
    local isWeeklyExhausted = (wMetric ~= nil and wPct >= 100)
    local baseId = item and shared.baseProvider(item.providerId or (item.entry and item.entry.id))

    local hasCredit = false
    if item and item.entry and type(item.entry.reset_credits) == "table" then
        hasCredit = (tonumber(item.entry.reset_credits.available) or 0) > 0
    end
    if not hasCredit and staggerPlan and staggerPlan.optimalClaimProviders and baseId then
        hasCredit = staggerPlan.optimalClaimProviders[baseId] == true
    end

    if percent >= 100 or isWeeklyExhausted then
        if isWeekly and hasCredit then
            return {
                status = "claim_reset",
                label = "Claim Reset",
                glyph = "ticket",
                color = "#c084fc",
                bg = "tertiary/0.22",
                border = "tertiary/0.55",
                cardBorder = "tertiary/0.55",
                summary = "Weekly quota at 100% · Optimal moment to claim reset and double quota!",
            }
        end
        return {
            status = "exhausted",
            label = "Exhausted",
            glyph = "circle-x",
            color = "#f87171",
            bg = "error/0.18",
            border = "error/0.45",
            cardBorder = "error/0.45",
            summary = isWeeklyExhausted and "Weekly quota depleted" or "Quota depleted",
        }
    end

    if isWeekly and staggerPlan and staggerPlan.hasCollision and staggerPlan.advanceProviderId == baseId and percent < 100 then
        return {
            status = "fast_track",
            label = "Fast-track",
            glyph = "flame",
            color = "#38bdf8",
            bg = "primary/0.20",
            border = "primary/0.50",
            cardBorder = "primary/0.50",
            summary = string.format("Advance reset: burn remaining %d%% in ~3.5d to double quota and stagger expirations", remainingQuota),
        }
    end

    local gearing = getModelGearing(item and (item.providerId or (item.entry and item.entry.id)), item and item.name) or 10.0
    local oneSessionPct = 100.0 / gearing
    local sessionsNeeded = remainingQuota / oneSessionPct

    local shouldThrottle = false
    local throttleSummary = nil
    if percent >= 75 and remainingSecs > (isWeekly and 172800 or 3600) then
        shouldThrottle = true
    elseif paceDiff <= -15 and percent >= 60 then
        shouldThrottle = true
    elseif isWeekly and gearing <= 3.5 and percent >= 45 and remainingSecs > 172800 then
        shouldThrottle = true
        throttleSummary = string.format("Conserve · High weekly impact (~%.1f sess/wk, 1 session = ~%d%% week)", gearing, math.floor(oneSessionPct + 0.5))
    end

    if shouldThrottle then
        return {
            status = "conserve",
            label = "Conserve",
            glyph = "alert-triangle",
            color = "#f87171",
            bg = "error/0.18",
            border = "error/0.45",
            cardBorder = "error/0.45",
            summary = throttleSummary or string.format("Heavy use · %d%% free remaining", remainingQuota),
        }
    end

    local shouldBurn = false
    local burnSummary = nil
    if not isWeekly then
        local H_s_active = calculateActiveHours(os.time(), os.time() + remainingSecs)
        if (H_s_active <= 1.50 or remainingSecs <= 5400) and remainingQuota >= 25 and remainingSecs > 0 then
            shouldBurn = true
            burnSummary = string.format("Session expires soon (~%.1fh active) · %d%% free to use", H_s_active, remainingQuota)
        elseif remainingSecs <= 9000 and remainingQuota >= 45 and remainingSecs > 0 then
            shouldBurn = true
        elseif paceDiff >= 20 and remainingQuota >= 40 and isSessionStarted(metric) then
            shouldBurn = true
        end
    else
        local H_w_active = calculateActiveHours(os.time(), at)
        local C_max = (H_w_active * 20.0) / gearing
        local dutyCycle = remainingQuota / math.max(1.0, C_max)

        if (H_w_active <= 14.0 or remainingSecs <= 86400) and remainingQuota >= 10 and remainingSecs > 0 then
            shouldBurn = true
            burnSummary = string.format("Weekly reset soon (~%.1fh active left) · %d%% quota will expire", H_w_active, remainingQuota)
        elseif dutyCycle >= 0.85 and remainingQuota >= 20 and remainingSecs > 0 then
            shouldBurn = true
            burnSummary = string.format("Session bottleneck: need ~%.1f sessions for %d%% weekly quota (~%.1fs/w)", sessionsNeeded, remainingQuota, gearing)
        elseif remainingSecs <= 172800 and remainingQuota >= 25 and remainingSecs > 0 then
            shouldBurn = true
        elseif remainingSecs <= 259200 and remainingQuota >= 35 and remainingSecs > 0 then
            shouldBurn = true
        elseif paceDiff >= 20 and remainingQuota >= 40 then
            shouldBurn = true
        end
    end

    if shouldBurn then
        return {
            status = "use_now",
            label = "Use now",
            glyph = "flame",
            color = "#fb923c",
            bg = "primary/0.18",
            border = "primary/0.45",
            cardBorder = "primary/0.45",
            summary = burnSummary or string.format("%d%% free to use · %dpts under", remainingQuota, paceDiff),
        }
    end

    if not isWeekly and not isSessionStarted(metric) and percent == 0 then
        return {
            status = "fresh",
            label = "Fresh",
            glyph = "star",
            color = "#38bdf8",
            bg = "tertiary/0.14",
            border = "tertiary/0.35",
            cardBorder = nil,
            summary = "100% free · session not started",
        }
    end

    return {
        status = "balanced",
        label = "Balanced",
        glyph = "circle-check",
        color = "#4ade80",
        bg = "secondary/0.14",
        border = "secondary/0.35",
        cardBorder = nil,
        summary = string.format("%d%% free · %s", remainingQuota,
            paceDiff >= 0 and string.format("%dpts under", paceDiff) or string.format("%dpts ahead", -paceDiff)),
    }
end

-- ── Kickstart Controller ──────────────────────────────────────────────────────

local kickstarting = {}
local kickstartedAt = {}

local function kickstartWindow(target)
    if target == nil or kickstarting[target] then return end
    kickstarting[target] = true
    if type(render) == "function" then
        render()
    end
    if type(noctalia.runAsync) == "function" then
        local cmd = string.format('export PATH="$HOME/.local/bin:$PATH"; if [ -x "$HOME/.local/bin/ai-kickstart" ]; then exec "$HOME/.local/bin/ai-kickstart" %s; else exec ai-kickstart %s; fi', target, target)
        local launched = noctalia.runAsync(cmd, function(result)
            kickstarting[target] = nil
            local ok = result == nil or result == true or result.exitCode == 0
            if ok then
                kickstartedAt[target] = os.time()
                requestRefresh()
            else
                local err = (type(result) == "table" and type(result.stderr) == "string" and result.stderr ~= "")
                    and result.stderr
                    or ("Failed to start 5h session for " .. tostring(target) .. ". Check backend CLI.")
                if type(noctalia.notifyError) == "function" then
                    noctalia.notifyError("AI Kickstart", err)
                end
            end
            if type(render) == "function" then
                render()
            end
        end, 30000)
        if launched == false then
            kickstarting[target] = nil
            if type(noctalia.notifyError) == "function" then
                noctalia.notifyError("AI Kickstart", "Host refused to execute ai-kickstart.")
            end
            if type(render) == "function" then
                render()
            end
        end
    else
        kickstarting[target] = nil
    end
end

-- ── Card Renderers ────────────────────────────────────────────────────────────

local function renderMetricCard(item, metric, windowLabel, staggerPlan)
    local isWeekly = windowLabel == "7d"
    local isLongName = #item.name > 12

    local titleChildren = {
        ui.row({
            width = 24, height = 24, radius = 6,
            fill = "primary/0.14", align = "center", justify = "center",
        }, {
            ui.glyph({ name = item.glyph, size = 14, color = "primary" }),
        }),
        ui.label({
            text = item.name,
            fontSize = isLongName and 14 or 15,
            fontWeight = "bold",
            color = "on_surface",
            maxLines = 1,
            maxWidth = 165,
        }),
    }
    if item.badge then
        titleChildren[#titleChildren + 1] = ui.row({
            paddingH = 4, paddingV = 1, radius = 4, fill = "primary/0.10",
        }, {
            ui.label({ text = item.badge, fontSize = 10, fontWeight = "medium", color = "primary" }),
        })
    end

    if metric == nil or unavailable(item.entry) then
        local unavail = unavailable(item.entry)
        return ui.column({
            gap = 6,
            paddingH = 10,
            paddingV = 8,
            radius = CARD.radius,
            fill = CARD.fill,
            border = CARD.border,
            borderWidth = CARD.borderWidth,
        }, {
            ui.row({ gap = 4, align = "center" }, {
                ui.row({ gap = 4, align = "center" }, titleChildren),
                ui.spacer({ flexGrow = 1 }),
                unavail and ui.row({ gap = 4, align = "center", paddingH = 6, paddingV = 2, radius = 5, fill = "error/0.12" }, {
                    ui.glyph({ name = "alert-circle", size = 12, color = "error" }),
                    ui.label({ text = noctalia.tr("ui.unavailable"), fontSize = 12, fontWeight = "medium", color = "error" }),
                }) or ui.label({ text = "—", fontSize = 14, color = "on_surface_variant" }),
            }),
            ui.column({ gap = 1, align = "stretch" }, {
                ui.progress({ progress = 0, fill = "on_surface/0.10", track = "on_surface/0.05", radius = 4, height = 8 }),
                ui.row({ height = 5 }),
            }),
            ui.row({ gap = 8, align = "center", justify = "center" }, {
                ui.row({ gap = 5, align = "center", paddingH = 8, paddingV = 2, radius = 5, fill = "on_surface/0.06" }, {
                    ui.glyph({ name = "slash", size = 12, color = "on_surface_variant" }),
                    ui.label({ text = "Offline", fontSize = 12, color = "on_surface_variant" }),
                }),
            }),
        })
    end

    local percent = tonumber(metric.percent) or 0
    local tint = severityRole(metric, "on_surface")
    local fill = severityRole(metric, "primary")
    local value = tostring(metric.value or ""):gsub(" of ", " / ")
    local showValue = value ~= "" and value ~= string.format("%d%%", percent)

    local resetTimeText = formatResetTime(metric, windowLabel)
    local isStarted = isWeekly or isSessionStarted(metric)
    local leftDuration = ""
    if isStarted then
        leftDuration = countdown(metric)
        if (leftDuration == "now" or leftDuration == noctalia.tr("ui.now"))
            and not isWeekly and not isSessionStarted(metric) then
            leftDuration = ""
        end
    end
    local resetTooltip = leftDuration ~= "" and ("Renews in " .. leftDuration) or nil

    local elapsedPct = calculateElapsed(metric, windowLabel)
    local triage = assessTriage(metric, percent, elapsedPct, windowLabel, item, staggerPlan)

    if triage ~= nil then
        titleChildren[#titleChildren + 1] = ui.row({
            gap = 2, align = "center",
            paddingH = 4, paddingV = 1, radius = 4,
            fill = triage.bg, border = triage.border, borderWidth = 1,
            tooltip = triage.summary,
        }, {
            ui.glyph({ name = triage.glyph, size = 10, color = triage.color }),
            ui.label({ text = triage.label, fontSize = 10, fontWeight = "bold", color = triage.color }),
        })
    end

    local rightMeta = {}
    if leftDuration ~= "" then
        local fgColor = countdownColor(metric)
        rightMeta[#rightMeta + 1] = ui.row({
            gap = 3, align = "center",
            paddingH = 3, paddingV = 1,
        }, {
            ui.glyph({ name = "clock", size = 12, color = fgColor }),
            ui.label({
                text = leftDuration,
                fontSize = 13,
                fontWeight = "medium",
                color = fgColor,
                maxLines = 1,
            }),
        })
    end

    rightMeta[#rightMeta + 1] = ui.row({
        paddingH = 6, paddingV = 2, radius = 5, align = "center", justify = "center",
        fill = tint .. "/0.15",
    }, {
        ui.label({ text = string.format("%d%%", percent), fontSize = 15,
                   fontWeight = "bold", color = tint, textAlign = "center" }),
    })

    local cardPaddingH = 10
    local cardPaddingV = 8
    local cardGap = 6

    local actionBtn = nil
    if isWeekly and triage and triage.status == "claim_reset" then
        local dashUrl = providerDashboard(item.providerId or (item.entry and item.entry.id))
        if dashUrl then
            actionBtn = ui.button({
                text = "Claim",
                glyph = "external-link",
                variant = "primary",
                controlSize = "sm",
                tooltip = "Open dashboard to claim weekly reset",
                onClick = function()
                    if type(noctalia.runAsync) == "function" then
                        noctalia.runAsync("xdg-open '" .. dashUrl .. "'")
                    end
                end,
            })
        end
    end

    local topRowChildren = {
        ui.row({ gap = 4, align = "center" }, titleChildren),
        ui.spacer({ flexGrow = 1 }),
    }
    if actionBtn ~= nil then
        topRowChildren[#topRowChildren + 1] = actionBtn
    end
    topRowChildren[#topRowChildren + 1] = ui.row({ gap = 5, align = "center", justify = "end" }, rightMeta)

    local topRow = ui.row({ gap = 4, align = "center" }, topRowChildren)

    local progressBar = ui.progress({
        progress = ratio(percent),
        fill = fill,
        track = "on_surface/0.10",
        radius = 4,
        height = 8,
    })

    local effectiveElapsed = elapsedPct
    if not isWeekly and not isStarted then
        effectiveElapsed = 0
    end

    local markerChildren = {}
    local markerTip = "Session not started · 0% elapsed · 0% quota used"
    local markerColor = "#38bdf8"

    if effectiveElapsed ~= nil then
        local leftFlex = math.max(1, effectiveElapsed)
        local rightFlex = math.max(1, 100 - effectiveElapsed)
        local paceDiff = effectiveElapsed - percent
        local paceStatus = paceDiff >= 0
            and string.format("+%d%% quota free", paceDiff)
            or string.format("%d%% over pace", -paceDiff)
        markerTip = string.format("Time: %d%% elapsed · Quota: %d%% used (%s)",
            effectiveElapsed, percent, paceStatus)
        markerColor = paceDiff >= 0 and "#38bdf8" or "#fb923c"

        if effectiveElapsed > 1 then
            markerChildren[#markerChildren + 1] = ui.spacer({ flexGrow = leftFlex })
        end
        markerChildren[#markerChildren + 1] = ui.box({
            width = 4,
            height = 5,
            radius = 1.5,
            fill = markerColor,
        })
        if effectiveElapsed < 99 then
            markerChildren[#markerChildren + 1] = ui.spacer({ flexGrow = rightFlex })
        end
    else
        markerChildren[#markerChildren + 1] = ui.spacer({ flexGrow = 1 })
    end

    local markerRow = ui.row({
        height = 5,
        align = "center",
        paddingH = 0,
        tooltip = markerTip,
    }, markerChildren)

    local progressElement = ui.column({ gap = 1, align = "stretch" }, {
        progressBar,
        markerRow,
    })

    local body = { topRow, progressElement }

    local bottomRowElements = {}

    -- Element 1: Clock pill (Always rendered to guarantee vertical symmetry)
    if isWeekly or isStarted then
        bottomRowElements[#bottomRowElements + 1] = ui.row({
            gap = 5, align = "center", justify = "center",
            paddingH = 8,
            paddingV = 2,
            radius = 5,
            fill = "on_surface/0.08",
            tooltip = resetTooltip or (isWeekly and "Weekly quota reset schedule" or "5h rolling window reset time"),
        }, {
            ui.glyph({ name = "clock", size = 13, color = "on_surface_variant" }),
            ui.label({
                text = resetTimeText ~= "" and resetTimeText or "--:--",
                fontSize = 13,
                fontWeight = "medium",
                color = "on_surface",
                textAlign = "center",
                maxLines = 1,
            }),
        })
    else
        -- Unstarted 5h session: Red indicator with "--:--"
        bottomRowElements[#bottomRowElements + 1] = ui.row({
            gap = 5, align = "center", justify = "center",
            paddingH = 8,
            paddingV = 2,
            radius = 5,
            fill = "error/0.10",
            border = "error/0.25",
            borderWidth = 1,
            tooltip = "Session not started · Rolling 5h timer begins on first prompt",
        }, {
            ui.glyph({ name = "clock", size = 13, color = "error" }),
            ui.label({
                text = "--:--",
                fontSize = 13,
                fontWeight = "bold",
                color = "error",
                textAlign = "center",
                maxLines = 1,
            }),
        })
    end

    -- Element 2: Complementary status or action element (Always rendered)
    if isWeekly then
        local gearing = getModelGearing(item and (item.providerId or (item.entry and item.entry.id)), item and item.name)
        if gearing then
            local oneSessionPct = math.floor((100.0 / gearing) + 0.5)
            bottomRowElements[#bottomRowElements + 1] = ui.row({
                gap = 4, align = "center", justify = "center",
                paddingH = 7,
                paddingV = 2,
                radius = 5,
                fill = "secondary/0.10",
                tooltip = string.format("Gearing: ~%.1f 5h sessions per week (1 session burns ~%d%% weekly quota)", gearing, oneSessionPct),
            }, {
                ui.glyph({ name = "gauge", size = 12, color = "secondary" }),
                ui.label({
                    text = string.format("~%.1fs/w", gearing),
                    fontSize = 12,
                    fontWeight = "medium",
                    color = "secondary",
                }),
            })
        end
    else
        -- 5h Session card complementary action / status
        local ksTarget = kickstartTarget(item)
        local justKickstarted = ksTarget ~= nil and kickstartedAt[ksTarget] ~= nil
            and (os.time() - kickstartedAt[ksTarget]) < 18000
        local isWeeklyExhausted = (item and item.weeklyMetric ~= nil and (tonumber(item.weeklyMetric.percent) or 0) >= 100)
        local canKickstart = ksTarget ~= nil and not justKickstarted
            and not isStarted and percent == 0
            and not isWeeklyExhausted
            and not unavailable(item and item.entry)

        if canKickstart then
            local isBusy = kickstarting[ksTarget] == true
            bottomRowElements[#bottomRowElements + 1] = ui.button({
                glyph = isBusy and "loader-2" or "bolt",
                text = isBusy and "Starting..." or "Start 5h",
                variant = "outline",
                controlSize = "sm",
                enabled = not isBusy,
                tooltip = "Send 1-token prompt to trigger 5h rolling window now",
                onClick = function()
                    kickstartWindow(ksTarget)
                end,
            })
        elseif isWeeklyExhausted then
            bottomRowElements[#bottomRowElements + 1] = ui.row({
                gap = 4, align = "center", justify = "center",
                paddingH = 7,
                paddingV = 2,
                radius = 5,
                fill = "error/0.12",
                border = "error/0.25",
                borderWidth = 1,
                tooltip = "Weekly quota is 100% exhausted. Sessions cannot be started until weekly reset.",
            }, {
                ui.glyph({ name = "alert-circle", size = 12, color = "error" }),
                ui.label({
                    text = "7d exhausted",
                    fontSize = 12,
                    fontWeight = "medium",
                    color = "error",
                }),
            })
        elseif isStarted then
            bottomRowElements[#bottomRowElements + 1] = ui.row({
                gap = 4, align = "center", justify = "center",
                paddingH = 7,
                paddingV = 2,
                radius = 5,
                fill = "primary/0.10",
                tooltip = "5-hour rolling session window currently active",
            }, {
                ui.glyph({ name = "bolt", size = 12, color = "primary" }),
                ui.label({
                    text = "5h rolling",
                    fontSize = 12,
                    fontWeight = "medium",
                    color = "primary",
                }),
            })
        else
            bottomRowElements[#bottomRowElements + 1] = ui.row({
                gap = 4, align = "center", justify = "center",
                paddingH = 7,
                paddingV = 2,
                radius = 5,
                fill = "on_surface/0.08",
                tooltip = "Session window not currently active",
            }, {
                ui.glyph({ name = "clock-pause", size = 12, color = "on_surface_variant" }),
                ui.label({
                    text = "Unstarted",
                    fontSize = 12,
                    fontWeight = "medium",
                    color = "on_surface_variant",
                }),
            })
        end
    end

    body[#body + 1] = ui.row({ gap = 8, align = "center", justify = "center" }, bottomRowElements)

    if showValue then
        body[#body + 1] = ui.row({ align = "center", justify = "center" }, {
            ui.label({ text = value, fontSize = 14, color = "on_surface_variant", maxLines = 1 }),
        })
    end

    local rest = plainDetail(metric.detail)
    if rest ~= "" then
        body[#body + 1] = ui.label({ text = rest, fontSize = 13, color = "on_surface_variant" })
    end

    return ui.column({
        gap = cardGap,
        paddingH = cardPaddingH,
        paddingV = cardPaddingV,
        radius = CARD.radius,
        fill = CARD.fill,
        border = (triage and triage.cardBorder) or CARD.border,
        borderWidth = (triage and triage.cardBorder) and 1 or CARD.borderWidth,
    }, body)
end

local function creditCountdownColor(credit)
    local expiresAt = credit and credit.expiresAt
    if expiresAt == nil or expiresAt == math.huge then
        return "on_surface_variant"
    end
    local remaining = math.max(0, expiresAt - os.time())
    local window = 30 * 86400
    local r = remaining / window

    if r > 0.60 then
        return "#4ade80"
    elseif r > 0.30 then
        return "#38bdf8"
    elseif r > 0.12 then
        return "#facc15"
    elseif r > 0.04 then
        return "#fb923c"
    else
        return "#f87171"
    end
end

local function renderCreditCard(credit)
    local fgColor = creditCountdownColor(credit)
    local roleBadge = nil
    if credit.role == "claim" then
        roleBadge = ui.row({
            paddingH = 5, paddingV = 1.5, radius = 4,
            fill = "tertiary/0.20", border = "tertiary/0.50", borderWidth = 1,
        }, {
            ui.label({ text = "CLAIM NOW", fontSize = 9, fontWeight = "bold", color = "#c084fc" }),
        })
    elseif credit.role == "advance" then
        roleBadge = ui.row({
            paddingH = 5, paddingV = 1.5, radius = 4,
            fill = "primary/0.20", border = "primary/0.50", borderWidth = 1,
        }, {
            ui.label({ text = "ADVANCE", fontSize = 9, fontWeight = "bold", color = "#38bdf8" }),
        })
    elseif credit.role == "defer" then
        roleBadge = ui.row({
            paddingH = 5, paddingV = 1.5, radius = 4,
            fill = "outline/0.15", border = "outline/0.30", borderWidth = 1,
        }, {
            ui.label({ text = "DEFER", fontSize = 9, fontWeight = "medium", color = "on_surface_variant" }),
        })
    end

    local dashUrl = providerDashboard(credit.providerId)
    local openBtn = dashUrl and ui.button({
        glyph = "external-link",
        variant = "ghost",
        controlSize = "sm",
        tooltip = "Open dashboard to manage reset",
        onClick = function()
            if type(noctalia.runAsync) == "function" then
                noctalia.runAsync("xdg-open '" .. dashUrl .. "'")
            end
        end,
    }) or nil

    local creditRow = {
        ui.row({
            width = 24, height = 24, radius = 6,
            fill = "primary/0.14", align = "center", justify = "center",
        }, {
            ui.glyph({ name = credit.glyph, size = 14, color = "primary" }),
        }),
        ui.label({
            text = credit.providerName,
            fontSize = 14,
            fontWeight = "bold",
            color = "on_surface",
            maxLines = 1,
        }),
    }
    if roleBadge ~= nil then
        creditRow[#creditRow + 1] = roleBadge
    end
    creditRow[#creditRow + 1] = ui.spacer({ flexGrow = 1 })
    if openBtn ~= nil then
        creditRow[#creditRow + 1] = openBtn
    end

    return ui.column(cardStyle(4, nil, nil, 8), {
        ui.row({ gap = 6, align = "center", tooltip = credit.fullTitle }, creditRow),
        ui.row({
            gap = 5, align = "center",
            paddingH = 2,
        }, {
            ui.glyph({ name = "clock", size = 13, color = fgColor }),
            ui.label({
                text = credit.expiry,
                fontSize = 13,
                fontWeight = "medium",
                color = fgColor,
                maxLines = 1,
            }),
        })
    })
end

-- ── 3-Column Layout ───────────────────────────────────────────────────────────

local function renderColumns(candidates)
    local headerActions = {}
    headerActions[#headerActions + 1] = ui.button({
        glyph = polling and "loader-2" or refreshQueued and "clock" or "refresh",
        variant = "outline", controlSize = "sm",
        tooltip = noctalia.tr(polling and "ui.refreshing"
            or refreshQueued and "ui.refresh_queued" or "ui.refresh"),
        enabled = not polling,
        onClick = requestRefresh,
    })
    headerActions[#headerActions + 1] = ui.button({
        glyph = "settings",
        variant = "outline", controlSize = "sm",
        tooltip = noctalia.tr("ui.settings"),
        onClick = function() noctalia.openSettings() end,
    })
    headerActions[#headerActions + 1] = ui.button({
        glyph = "x",
        variant = "outline", controlSize = "sm",
        tooltip = "Close",
        onClick = function()
            if type(panel.close) == "function" then panel.close() end
        end,
    })

    local latestFetched = nil
    for _, candidate in ipairs(candidates) do
        local at = parseIso(candidate and candidate.fetched_at)
        if at ~= nil and (latestFetched == nil or at > latestFetched) then
            latestFetched = at
        end
    end

    local updatedRow = nil
    if latestFetched ~= nil then
        local minutes = math.floor((os.time() - latestFetched) / 60)
        local timeTip = minutes < 1 and noctalia.tr("ui.updated_now") or noctalia.tr("ui.updated_ago", { minutes = minutes })
        updatedRow = ui.row({ gap = 4, align = "center", paddingH = 7,
                              paddingV = 3, radius = 6, fill = "on_surface/0.08",
                              tooltip = timeTip }, {
            ui.glyph({ name = "clock", size = 14, color = "on_surface_variant" }),
            ui.label({
                text = noctalia.tr("ui.updated") .. " " .. noctalia.formatTime(noctalia.timeFormat(), latestFetched),
                fontSize = 14,
                color = "on_surface_variant",
            }),
        })
    end

    local topRowChildren = {
        ui.row({
            width = 32, height = 32, radius = 8,
            fill = "primary/0.14", align = "center", justify = "center",
        }, {
            ui.glyph({ name = "brain", size = 20, color = "primary" }),
        }),
        ui.label({ text = noctalia.tr("ui.title"), fontSize = 19, fontWeight = "bold", color = "on_surface" }),
    }
    if updatedRow ~= nil then
        topRowChildren[#topRowChildren + 1] = updatedRow
    end
    topRowChildren[#topRowChildren + 1] = ui.spacer({ flexGrow = 1 })
    topRowChildren[#topRowChildren + 1] = ui.row({ gap = 4, align = "center" }, headerActions)

    local modelItems = collectModelItems(candidates)
    local staggerPlan, providerStats = shared.analyzeResetCredits(candidates)
    local resetCredits = collectResetCredits(candidates, staggerPlan)

    local scheduleConfig = getScheduleConfig()

    -- Sort models by triage score (considering session & weekly pacing, schedule-aware active hours, and staggering)
    table.sort(modelItems, function(a, b)
        local aScore = calculateModelTriageScore(a, staggerPlan, os.time(), scheduleConfig, true)
        local bScore = calculateModelTriageScore(b, staggerPlan, os.time(), scheduleConfig, true)
        if math.abs(aScore - bScore) > 0.01 then
            return aScore > bScore
        end
        local aSPct = a.sessionMetric and tonumber(a.sessionMetric.percent) or 0
        local bSPct = b.sessionMetric and tonumber(b.sessionMetric.percent) or 0
        if aSPct ~= bSPct then
            return aSPct < bSPct
        end
        local aWPct = a.weeklyMetric and tonumber(a.weeklyMetric.percent) or 0
        local bWPct = b.weeklyMetric and tonumber(b.weeklyMetric.percent) or 0
        if aWPct ~= bWPct then
            return aWPct < bWPct
        end
        return (a.name or "") < (b.name or "")
    end)

    -- Both columns follow the same triage order:
    -- the session card sits next to the weekly card for the same provider/model
    local sessionCards = {}
    local weeklyCards = {}
    for _, item in ipairs(modelItems) do
        local sCard = renderMetricCard(item, item.sessionMetric, "5h", staggerPlan)
        if sCard ~= nil then
            sessionCards[#sessionCards + 1] = sCard
        end
        local wCard = renderMetricCard(item, item.weeklyMetric, "7d", staggerPlan)
        if wCard ~= nil then
            weeklyCards[#weeklyCards + 1] = wCard
        end
    end

    local creditCards = {}
    for _, credit in ipairs(resetCredits) do
        creditCards[#creditCards + 1] = renderCreditCard(credit)
    end

    if staggerPlan and staggerPlan.hasCollision then
        local stratCard = ui.column(cardStyle(4, nil, nil, 8), {
            ui.row({ gap = 6, align = "center" }, {
                ui.glyph({ name = "calendar-clock", size = 15, color = "primary" }),
                ui.label({
                    text = string.format("Reset Plan (Collision in %.0fd)", staggerPlan.daysUntilExpiry or 12),
                    fontSize = 13, fontWeight = "bold", color = "primary",
                }),
            }),
            ui.label({
                text = string.format("%s & %s expire together (~Oct 22). Staggering strategy:", staggerPlan.advanceName or "Claude", staggerPlan.deferName or "Codex"),
                fontSize = 11, color = "on_surface_variant",
            }),
            ui.row({ gap = 6, align = "start" }, {
                ui.glyph({ name = "arrow-right", size = 12, color = "#38bdf8" }),
                ui.label({
                    text = string.format("1. Advance %s: burn remaining quota to 100%% in ~3.5d and claim reset.", staggerPlan.advanceName or "Claude"),
                    fontSize = 11, fontWeight = "semibold", color = "on_surface", flexGrow = 1,
                }),
            }),
            ui.row({ gap = 6, align = "start" }, {
                ui.glyph({ name = "arrow-right", size = 12, color = "outline" }),
                ui.label({
                    text = string.format("2. Defer %s: reserve reset credit for the following week.", staggerPlan.deferName or "Codex"),
                    fontSize = 11, color = "on_surface_variant", flexGrow = 1,
                }),
            }),
        })
        table.insert(creditCards, 1, stratCard)
    end

    for baseId, isClaim in pairs(staggerPlan and staggerPlan.optimalClaimProviders or {}) do
        if isClaim then
            local stats = providerStats and providerStats[baseId]
            local pName = stats and stats.name or baseId
            local dashUrl = providerDashboard(baseId)
            local claimCardChildren = {
                ui.row({ gap = 6, align = "center" }, {
                    ui.glyph({ name = "sparkles", size = 16, color = "#c084fc" }),
                    ui.label({
                        text = "Optimal Reset Window!",
                        fontSize = 13, fontWeight = "bold", color = "#c084fc",
                    }),
                }),
                ui.label({
                    text = string.format("%s reached 100%% weekly quota. Claim reset now to double quota!", pName),
                    fontSize = 11, color = "on_surface",
                }),
            }
            if dashUrl ~= nil then
                claimCardChildren[#claimCardChildren + 1] = ui.button({
                    text = "Open Dashboard",
                    glyph = "external-link",
                    variant = "primary",
                    controlSize = "sm",
                    onClick = function()
                        if type(noctalia.runAsync) == "function" then
                            noctalia.runAsync("xdg-open '" .. dashUrl .. "'")
                        end
                    end,
                })
            end
            local claimCard = ui.column(cardStyle(4, nil, nil, 8), claimCardChildren)
            table.insert(creditCards, 1, claimCard)
        end
    end
    if #creditCards == 0 then
        creditCards[#creditCards + 1] = ui.column(cardStyle(6, nil, nil, 10), {
            ui.row({ gap = 8, align = "center" }, {
                ui.glyph({ name = "info-circle", size = 18, color = "on_surface_variant" }),
                ui.label({ text = "No pending reset credits", fontSize = 16, color = "on_surface_variant" }),
            }),
        })
    end
    if #sessionCards == 0 then
        sessionCards[#sessionCards + 1] = ui.column(cardStyle(6, nil, nil, 10), {
            ui.row({ gap = 8, align = "center" }, {
                ui.glyph({ name = "info-circle", size = 18, color = "on_surface_variant" }),
                ui.label({ text = "No active session metrics", fontSize = 15, color = "on_surface_variant" }),
            }),
        })
    end
    if #weeklyCards == 0 then
        weeklyCards[#weeklyCards + 1] = ui.column(cardStyle(6, nil, nil, 10), {
            ui.row({ gap = 8, align = "center" }, {
                ui.glyph({ name = "info-circle", size = 18, color = "on_surface_variant" }),
                ui.label({ text = "No active weekly metrics", fontSize = 15, color = "on_surface_variant" }),
            }),
        })
    end

    local col1 = ui.column({
        key = "col-session",
        gap = 6,
        flexGrow = 1.15,
        align = "stretch",
        paddingH = 4,
        paddingV = 2,
    }, {
        ui.row({ gap = 8, align = "center", paddingH = 4, paddingV = 2 }, {
            ui.row({
                width = 30, height = 30, radius = 7,
                fill = "primary/0.14", align = "center", justify = "center",
            }, {
                ui.glyph({ name = "clock", size = 18, color = "primary" }),
            }),
            ui.label({ text = "Session (5h)", fontSize = 18, fontWeight = "bold", color = "on_surface" }),
        }),
        ui.separator({ orientation = "horizontal", color = "outline", opacity = 0.16 }),
        ui.scroll({ flexGrow = 1, gap = 6, align = "stretch" }, sessionCards),
    })

    local col2 = ui.column({
        key = "col-weekly",
        gap = 6,
        flexGrow = 1.15,
        align = "stretch",
        paddingH = 4,
        paddingV = 2,
    }, {
        ui.row({ gap = 8, align = "center", paddingH = 4, paddingV = 2 }, {
            ui.row({
                width = 30, height = 30, radius = 7,
                fill = "secondary/0.14", align = "center", justify = "center",
            }, {
                ui.glyph({ name = "calendar", size = 18, color = "secondary" }),
            }),
            ui.label({ text = "Weekly (7d)", fontSize = 18, fontWeight = "bold", color = "on_surface" }),
        }),
        ui.separator({ orientation = "horizontal", color = "outline", opacity = 0.16 }),
        ui.scroll({ flexGrow = 1, gap = 6, align = "stretch" }, weeklyCards),
    })

    local col3 = ui.column({
        key = "col-credits",
        gap = 6,
        flexGrow = 0.90,
        align = "stretch",
        paddingH = 4,
        paddingV = 2,
    }, {
        ui.row({ gap = 8, align = "center", paddingH = 4, paddingV = 2 }, {
            ui.row({
                width = 30, height = 30, radius = 7,
                fill = "primary/0.14", align = "center", justify = "center",
            }, {
                ui.glyph({ name = "ticket", size = 18, color = "primary" }),
            }),
            ui.label({ text = "Reset Credits", fontSize = 18, fontWeight = "bold", color = "on_surface" }),
        }),
        ui.separator({ orientation = "horizontal", color = "outline", opacity = 0.16 }),
        ui.scroll({ flexGrow = 1, gap = 6, align = "stretch" }, creditCards),
    })

    local columns = {
        col1,
        ui.box({ width = 1, fill = "outline/0.20" }),
        col2,
        ui.box({ width = 1, fill = "outline/0.20" }),
        col3,
    }

    local mainChildren = {
        ui.row({ gap = 8, align = "center" }, topRowChildren),
        ui.separator({ orientation = "horizontal", color = "outline", opacity = 0.20 }),
        ui.row({ gap = 12, flexGrow = 1, align = "stretch" }, columns),
    }

    panel.render(ui.column({
        gap = 8,
        paddingH = 16,
        paddingV = 10,
        flexGrow = 1,
        align = "stretch",
        fill = "surface/0.95",
        radius = 16,
        border = "outline/0.25",
        borderWidth = 1,
    }, mainChildren))
end

function render()
    if failure.code ~= "" and report == nil then
        panel.render(ui.column({ flexGrow = 1, padding = 14, align = "center", justify = "center" }, {
            ui.column({ gap = 10, width = 320 }, {
                ui.row({ gap = 8, align = "center" }, {
                    ui.glyph({ name = "brain", size = 18, color = "primary" }),
                    ui.label({ text = noctalia.tr("ui.title"), fontSize = 15,
                               fontWeight = "bold", color = "on_surface" }),
                }),
                errorBlock(),
            }),
        }))
        return
    end

    local candidates = {}
    for _, candidate in ipairs(entries()) do
        if configured(candidate) then
            candidates[#candidates + 1] = candidate
        end
    end

    if #candidates > 0 then
        renderColumns(candidates)
    else
        panel.render(ui.column({ flexGrow = 1, padding = 14, align = "center", justify = "center" }, {
            ui.column({ gap = 10, width = 320 }, {
                ui.row({ gap = 8, align = "center" }, {
                    ui.glyph({ name = "brain", size = 18, color = "primary" }),
                    ui.label({ text = noctalia.tr("ui.title"), fontSize = 15,
                               fontWeight = "bold", color = "on_surface" }),
                }),
                ui.label({
                    text = noctalia.tr("ui.no_providers") or "No providers configured or reachable.",
                    fontSize = 13,
                    color = "on_surface_variant",
                }),
            }),
        }))
    end
end

-- ── Lifecycle & Event Wiring ──────────────────────────────────────────────────

noctalia.state.watch("report", function(value)
    if type(value) == "table" then
        report = value
        failure = NO_FAILURE
        render()
    end
end)

noctalia.state.watch("error", function(value)
    failure = asFailure(value)
    render()
end)

noctalia.state.watch("polling", function(value)
    polling = value == true
    render()
end)

noctalia.state.watch("refresh_queued", function(value)
    refreshQueued = value == true
    render()
end)

function onOpen(context)
    if type(context) == "string" and context ~= "" then
        noctalia.state.set("selected", context)
    end
    requestRefresh()
    report = noctalia.state.get("report")
    failure = asFailure(noctalia.state.get("error"))
    polling = noctalia.state.get("polling") == true
    refreshQueued = noctalia.state.get("refresh_queued") == true
    panel.setWantsSecondTicks(true)
    render()
end

function update()
    render()
end

function onClose()
    panel.setWantsSecondTicks(false)
end

function onKey(chord, pressed)
    if not pressed then return end
    local lower = tostring(chord or ""):lower()
    if lower == "escape" then
        if type(panel.close) == "function" then panel.close() end
    elseif lower == "r" then
        requestRefresh()
    end
end

render()
