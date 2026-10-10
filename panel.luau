--!nonstrict
-- Expanded panel for one provider. It renders `sections[]`, the CLI's lossless
-- view, so the credit blocks and free text that `metrics[]` drops still show up.

local report = nil
local polling = false
local refreshQueued = false

-- Modo de visualización: "columns" (tres columnas lado a lado) ou "tabs" (pestanas orixinais)
local LAYOUT_MODE = "columns"

local shared = require("./shared.luau")
local providerGlyph, parseIso = shared.providerGlyph, shared.parseIso
local countdown, resetClock = shared.countdown, shared.resetClock
local ratio, headline, severityRole = shared.ratio, shared.headline, shared.severityRole
local modelHeadlines, isCritical, dualMetrics = shared.modelHeadlines, shared.isCritical, shared.dualMetrics
local isSessionStarted = shared.isSessionStarted
local calculateModelTriageScore = shared.calculateModelTriageScore
local modelGlyph = shared.modelGlyph
local modelDisplayName = shared.modelDisplayName
local elapsedPercent, pace = shared.elapsedPercent, shared.pace
local requestRefresh = shared.requestRefresh
local providerWarning, unavailable, readFailure = shared.warning, shared.unavailable, shared.readFailure
local saysError, transportError = shared.saysError, shared.transportError
local NO_FAILURE, asFailure = shared.NO_FAILURE, shared.asFailure

local failure = NO_FAILURE

-- The plan each provider last reported on. A plan carries the limits every
-- percentage is measured against, so a reading taken under the old one says
-- nothing about the new one.
local lastPlan = {}

-- A vendor the user never set up is not listed. The CLI prefixes every such
-- message with `credentials error:`, but that bucket also holds providers that
-- are set up and merely unreachable, so the row is dropped only when the CLI
-- says there is no key at all.
local function configured(entry)
    if entry.status ~= "error" then return true end
    local message = tostring(entry.error or ""):lower()
    return not (message:find("^credentials error:") and message:find("no api key", 1, true))
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

-- ── Entry selection ───────────────────────────────────────────────────────────

local function entries() return shared.entries(report) end

local function currentEntry()
    local wanted = noctalia.state.get("selected")
    local first = nil
    for _, entry in ipairs(entries()) do
        if configured(entry) then
            if entry.id == wanted then return entry end
            if (wanted == "gemini" or wanted == "claude-oss" or wanted == "claude_oss")
                and shared.baseProvider(entry.id) == "antigravity" then
                return entry
            end
            if first == nil then first = entry end
        end
    end
    return first
end

local function updatedText(entry)
    local at = parseIso(entry and entry.fetched_at)
    if at == nil then return "" end
    local minutes = math.floor((os.time() - at) / 60)
    if minutes < 1 then return noctalia.tr("ui.updated_now") end
    return noctalia.tr("ui.updated_ago", { minutes = minutes })
end

-- ── Cards ─────────────────────────────────────────────────────────────────────

-- One reading, without the card around it. `title` names it: the metric's own
-- label, or the window's name inside a card that stacks a model's readings.
-- `muted` is for the second case, where the card is already titled.
local function metricRows(section, title, muted)
    local percent = tonumber(section.percent) or 0
    local tint = severityRole(section, "on_surface")
    local fill = severityRole(section, "primary")
    local value = tostring(section.value or ""):gsub(" of ", " / ")
    local showValue = value ~= "" and value ~= string.format("%d%%", percent)

    local left = countdown(section)
    local clock = resetClock(section)
    local paceText, _, paceWord = pace(section.detail)

    local resetStr = ""
    if left ~= "" then
        resetStr = left
        if clock ~= "" then resetStr = resetStr .. " (" .. clock .. ")" end
    end

    local displayTitle = tostring(title or "")

    -- Title on the left; percentage on the right.
    local rightMeta = {}
    rightMeta[#rightMeta + 1] = ui.row({
        paddingH = 8, paddingV = 3, radius = 6, align = "center", justify = "center",
        fill = tint .. "/0.15",
    }, {
        ui.label({ text = string.format("%d%%", percent), fontSize = 16,
                   fontWeight = "bold", color = tint, textAlign = "center" }),
    })

    local topRow = ui.row({ gap = 8, align = "center" }, {
        ui.label({
            text = displayTitle,
            fontSize = muted and 15 or 16,
            fontWeight = "semibold",
            color = "on_surface",
            maxLines = 1,
        }),
        ui.spacer({ flexGrow = 1 }),
        ui.row({ gap = 6, align = "center", justify = "end" }, rightMeta),
    })

    -- Usage bar.
    local progressBar = ui.progress({
        progress = ratio(percent),
        fill = fill,
        track = "on_surface/0.10",
        radius = 4,
        height = 7,
    })

    -- Reset on the left, pace on the right.
    local bottomRowElements = {}
    if resetStr ~= "" then
        bottomRowElements[#bottomRowElements + 1] = ui.row({ gap = 5, align = "center",
            paddingH = 6, paddingV = 3, radius = 6, fill = "on_surface/0.08" }, {
            ui.glyph({ name = "clock", size = 13, color = "on_surface_variant" }),
            ui.label({ text = resetStr, fontSize = 14, color = "on_surface_variant",
                       maxLines = 2, maxWidth = paceText ~= "" and 280 or 440 }),
        })
    end

    local subRight = {}
    if paceText ~= "" then
        local paceColor = paceWord == "ahead" and "secondary"
            or paceWord == "behind" and "error"
            or "on_surface_variant"
        local paceIcon = paceWord == "ahead" and "trending-up"
            or paceWord == "behind" and "trending-down"
            or "check"
        subRight[#subRight + 1] = ui.row({ gap = 4, align = "center" }, {
            ui.glyph({ name = paceIcon, size = 13, color = paceColor }),
            ui.label({ text = paceText, fontSize = 13, fontWeight = "medium", color = paceColor, maxLines = 1 }),
        })
    end

    local body = { topRow, progressBar }

    if showValue then
        body[#body + 1] = ui.label({ text = value, fontSize = 14,
                                    color = "on_surface_variant", maxLines = 2 })
    end

    if #bottomRowElements > 0 or #subRight > 0 then
        body[#body + 1] = ui.row({ gap = 6, align = "center" }, {
            ui.row({ gap = 4, align = "center" }, bottomRowElements),
            ui.spacer({ flexGrow = 1 }),
            ui.row({ gap = 4, align = "center", justify = "end" }, subRight),
        })
    end

    local rest = plainDetail(section.detail)
    if rest ~= "" then
        body[#body + 1] = ui.label({ text = rest, fontSize = 13, color = "on_surface_variant" })
    end

    return body
end

local CARD = { gap = 8, padding = 12, radius = 11, fill = "surface_variant/0.88",
               border = "outline/0.20", borderWidth = 1 }

local function cardStyle(gap, fill, border)
    return { gap = gap, padding = CARD.padding, radius = CARD.radius,
             fill = fill or CARD.fill, border = border or CARD.border,
             borderWidth = CARD.borderWidth }
end

local function stackCard(name, readings, glyph)
    local titled = name ~= ""
    local body = {}
    if titled then
        body[#body + 1] = ui.row({ gap = 7, align = "center" }, {
            ui.row({
                width = 26, height = 26, radius = 6,
                fill = "primary/0.14", align = "center", justify = "center",
            }, {
                ui.glyph({ name = glyph or modelGlyph(name), size = 15, color = "primary" }),
            }),
            ui.label({ text = glyph and name or modelDisplayName(name), fontSize = 15, fontWeight = "bold",
                       color = "on_surface", maxLines = 1 }),
        })
    end
    for index, reading in ipairs(readings) do
        if index > 1 then
            body[#body + 1] = ui.box({ height = 1, fill = "outline/0.20" })
        end
        for _, node in ipairs(metricRows(reading.section, reading.title, titled)) do
            body[#body + 1] = node
        end
    end
    return ui.column(CARD, body)
end

local function blockCard(section)
    local label = tostring(section.label or "")
    local isResetCredits = label == "Reset credits"
    local isUnavailable = label == "Unavailable"
    local isCredits = label == "Credits"

    local iconName = isResetCredits and "ticket"
        or isUnavailable and "circle-off"
        or isCredits and "coin"
        or "info-circle"
    local iconColor = isResetCredits and "primary"
        or isUnavailable and "error"
        or isCredits and "secondary"
        or "on_surface_variant"

    local body = {
        ui.row({ gap = 7, align = "center" }, {
            ui.glyph({ name = iconName, size = 16, color = iconColor }),
            ui.label({ text = label, fontSize = 14, fontWeight = "bold",
                       color = isUnavailable and "error" or "on_surface", maxLines = 1 }),
        }),
    }
    local lines = type(section.body) == "table" and section.body or {}
    for _, line in ipairs(lines) do
        local text = noctalia.string.trim(tostring(line))
        -- A bare "balance:" would read as a row that failed to render.
        if text:find(":$") then text = text .. " —" end
        local kind, expiry = text:match("^(.-)%s+·%s+(.+)$")
        if isResetCredits and kind and expiry then
            body[#body + 1] = ui.column({ gap = 2 }, {
                ui.label({ text = kind, fontSize = 14, fontWeight = "medium", color = "on_surface", maxLines = 2 }),
                ui.label({ text = expiry, fontSize = 13, color = "on_surface_variant", maxLines = 2 }),
            })
        else
            body[#body + 1] = ui.label({
                text = text ~= "" and text or "—",
                fontSize = 13,
                color = "on_surface_variant",
                maxLines = isResetCredits and 3 or 1,
            })
        end
    end
    return ui.column(cardStyle(4,
        isUnavailable and "error/0.06" or nil,
        isUnavailable and "error/0.18" or nil), body)
end

-- A `text` section the CLI uses for a warning. The `credentials error:` prefix
-- and the repeated provider name are the CLI talking to a log, not to a panel
-- that already names the provider in its title.
local function noteCard(text, failureLabel)
    local clean = noctalia.string.trim(tostring(text or ""))
    clean = clean:gsub("^[Cc]redentials error:%s*", "")
    local content = {
        ui.label({ text = clean, fontSize = 13, color = "on_surface_variant",
                   flexGrow = 1, maxLines = 3 }),
    }
    if failureLabel ~= nil and failureLabel ~= "" then
        table.insert(content, 1, ui.label({
            text = failureLabel,
            fontSize = 15,
            fontWeight = "bold",
            color = "error",
        }))
    end
    return ui.row({ gap = 8, align = "start", padding = CARD.padding, radius = CARD.radius,
                    fill = failureLabel and "error/0.07" or "secondary/0.07",
                    border = failureLabel and "error/0.16" or "outline/0.06",
                    borderWidth = CARD.borderWidth }, {
        ui.glyph({ name = "alert-triangle", size = 18, color = failureLabel and "error" or "secondary" }),
        ui.column({ gap = 4, flexGrow = 1 }, content),
    })
end

-- `updatedText` heads a live report ("Updated 3 min ago"); a record is dated, not
-- updated, and reads wrong with that word in front of it.
local function recordAge(entry)
    local at = parseIso(entry and entry.fetched_at)
    if at == nil then return noctalia.tr("ui.last_reading_now") end
    local minutes = math.floor((os.time() - at) / 60)
    if minutes < 1 then return noctalia.tr("ui.last_reading_now") end
    return noctalia.tr("ui.last_reading", { minutes = minutes })
end

-- Every reading a provider sent, grouped into the subjects it is read by:
-- Windowed reports group by model; other reports keep their readings in one
-- provider card. The card and the record share this grouping.
local function groupReadings(items, windowed)
    local order, byName = {}, {}
    for _, item in ipairs(items) do
        if item.section.type == "metric" then
            local label = tostring(item.section.label or "")
            local name = windowed and label or ""
            if byName[name] == nil then
                byName[name] = {}
                order[#order + 1] = name
            end
            local readings = byName[name]
            readings[#readings + 1] = {
                section = item.section,
                title = windowed and item.window or label,
            }
        end
    end
    return order, byName
end

-- While a provider is down its numbers record when it was last read, so they
-- are set in text rather than drawn as bars a glance would read as live.
local function recordCard(entry, items, windowed)
    local order, byName = groupReadings(items, windowed)
    if #order == 0 then return nil end

    local body = {
        ui.label({ text = recordAge(entry), fontSize = 14, fontWeight = "semibold",
                   color = "on_surface", maxLines = 1 }),
    }
    for _, name in ipairs(order) do
        local parts = {}
        for _, reading in ipairs(byName[name]) do
            local value = tostring(reading.section.value or "")
            if value == "" then
                value = string.format("%d%%", tonumber(reading.section.percent) or 0)
            end
            parts[#parts + 1] = noctalia.string.trim(reading.title .. " " .. value)
        end
        local line = table.concat(parts, " · ")
        if name ~= "" then
            body[#body + 1] = ui.row({ gap = 6, align = "center" }, {
                ui.label({ text = modelDisplayName(name), fontSize = 14, color = "on_surface_variant", maxLines = 1 }),
                ui.spacer({ flexGrow = 1 }),
                ui.label({ text = line, fontSize = 14, color = "on_surface", maxLines = 1 }),
            })
        else
            body[#body + 1] = ui.label({ text = line, fontSize = 14, color = "on_surface",
                                        maxLines = 1 })
        end
    end
    return ui.column(cardStyle(4), body)
end

-- Everything in a report that is not a reading: credit blocks, headings,
-- warnings, free text. A provider that is down loses its gauges, not the rest of
-- what the CLI said, so both passes draw these the same way. `warned` says the
-- warning already stands at the top, so it is not said twice.
-- A credits block with zero balance and no usage is skipped: showing an empty
-- card for a user who does not purchase or use credits is noise.
local function isEmptyCredits(section)
    if section.type ~= "block" then return false end
    local label = tostring(section.label or ""):lower()
    if not label:find("credit", 1, true) then return false end

    local lines = type(section.body) == "table" and section.body or {}
    if #lines == 0 then return true end

    local hasPositive = false
    for _, line in ipairs(lines) do
        local text = tostring(line):lower()
        local balanceVal = text:match("balance:%s*(.*)")
        if balanceVal ~= nil then
            local num = tonumber(balanceVal:match("[%d%.]+"))
            if num ~= nil and num > 0 then
                hasPositive = true
                break
            end
        else
            for numStr in text:gmatch("[%d%.]+") do
                local n = tonumber(numStr)
                if n ~= nil and n > 0 then
                    hasPositive = true
                    break
                end
            end
        end
    end
    return not hasPositive
end

local function otherCard(section, warned)
    if section.type == "block" then
        if isEmptyCredits(section) then return nil end
        return blockCard(section)
    end

    if section.type == "text" then
        local label = tostring(section.label or "")
        local value = tostring(section.value or "")
        if transportError(label) or transportError(value) then return nil end
        if label:lower() == "warning" or saysError(value) then
            if warned then return nil end
            return noteCard(value)
        end
        if label:lower() == "source" then
            return nil
        end
        local props = cardStyle(6)
        props.align = "center"
        return ui.row(props, {
            ui.label({ text = label, fontSize = 13, color = "on_surface_variant" }),
            ui.spacer({ flexGrow = 1 }),
            ui.label({ text = value, fontSize = 13, fontWeight = "medium", color = "on_surface", maxLines = 1 }),
        })
    end

    if section.type == "title" then
        return ui.label({
            text = tostring(section.value or section.label or ""),
            fontSize = 15, fontWeight = "semibold", color = "on_surface",
        })
    end

    -- Keep schema additions visible instead of silently losing report data.
    return ui.label({
        text = tostring(section.value or section.label or section.type or "—"),
        fontSize = 13, color = "on_surface_variant",
    })
end

-- ── Provider list ─────────────────────────────────────────────────────────────

local function providerRow(entry, selected, compact)
    local displayName = tostring(entry.display_name or entry.name or entry.id or "")
    local broken = entry.status == "error" or unavailable(entry)

    local children = {
        ui.glyph({
            name = providerGlyph(entry.id),
            size = compact and 18 or 17,
            color = selected and "primary" or "on_surface",
        }),
    }

    if not compact then
        children[#children + 1] = ui.label({
            text = displayName,
            fontSize = 15,
            fontWeight = selected and "bold" or "medium",
            color = selected and "primary" or "on_surface",
            maxLines = 1,
        })
    end

    if broken then
        children[#children + 1] = ui.glyph({
            name = "alert-circle",
            size = 15,
            color = "error",
        })
    end

    return ui.row({
        key = "provider-" .. tostring(entry.id),
        gap = 7,
        align = "center",
        justify = "center",
        tooltip = compact and displayName or nil,
        paddingH = 12,
        minHeight = 36,
        paddingV = 7,
        radius = 8,
        flexGrow = 1,
        fill = selected and "primary/0.16" or "surface_variant/0.50",
        border = selected and "primary/0.45" or "outline/0.15",
        borderWidth = 1,
        onClick = function()
            noctalia.state.set("selected", tostring(entry.id))
            render()
        end,
    }, children)
end

-- ── Render ────────────────────────────────────────────────────────────────────

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


local function copySummary(entry)
    if entry == nil then return end
    local parts = { tostring(entry.display_name or entry.id) }
    local sub = tostring(entry.plan or "")
    if sub ~= "" and sub ~= parts[1] then
        parts[#parts + 1] = "(" .. sub .. ")"
    end
    local metricStrs = {}
    for _, m in ipairs(entry.metrics or {}) do
        if m.label and m.percent then
            metricStrs[#metricStrs + 1] = tostring(m.label) .. " " .. tostring(m.percent) .. "%"
        end
    end
    if #metricStrs > 0 then
        parts[#parts + 1] = "· " .. table.concat(metricStrs, " · ")
    end
    local text = table.concat(parts, " ")
    if type(noctalia.copyToClipboard) == "function" then
        noctalia.copyToClipboard(text, "text/plain")
    end
end

local function statusIndicator(entry)
    if failure.code ~= "" then
        return ui.row({ gap = 4, align = "center" }, {
            ui.glyph({ name = "clock-exclamation", size = 15, color = "secondary" }),
            ui.label({ text = noctalia.tr("ui.stale_hint"), fontSize = 13,
                color = "on_surface_variant", maxLines = 1 }),
            ui.button({ text = noctalia.tr("ui.retry"), glyph = "refresh",
                variant = "ghost", controlSize = "sm", enabled = not polling,
                onClick = requestRefresh }),
        })
    end
    if entry == nil then return nil end
    if entry.stale == true then
        return ui.row({ gap = 4, align = "center" }, {
            ui.glyph({ name = "clock-exclamation", size = 15, color = "secondary" }),
            ui.label({ text = noctalia.tr("ui.stale_hint"), fontSize = 13,
                color = "on_surface_variant", maxLines = 1 }),
        })
    end
    if unavailable(entry) then
        return ui.label({ text = noctalia.tr("ui.unavailable"), fontSize = 13,
            color = "error", maxLines = 1 })
    end

    if type(entry.metrics) ~= "table" or #entry.metrics == 0 then
        return ui.label({ text = noctalia.tr("ui.waiting"), fontSize = 13,
            color = "on_surface_variant", maxLines = 1 })
    end

    local models = modelHeadlines(entry)
    if #models == 0 then
        models = { { displayName = "", glyph = providerGlyph(entry.id), metrics = entry.metrics } }
    end
    local notices = {}
    for _, model in ipairs(models) do
        local short, weekly = dualMetrics(model.metrics)
        local affected = {}
        for index, metric in ipairs(model.metrics or {}) do
            local percent = type(metric) == "table" and tonumber(metric.percent) or nil
            if percent ~= nil and percent > 50 then
                local window = metric == short and "5h" or metric == weekly and "7d" or ""
                affected[#affected + 1] = { metric = metric, percent = percent,
                    window = window, index = index }
            end
        end
        table.sort(affected, function(a, b)
            local aBlocked, bBlocked = a.percent >= 100, b.percent >= 100
            if aBlocked ~= bBlocked then return aBlocked end
            if aBlocked and bBlocked then
                local aReset = parseIso(a.metric.reset_at) or 0
                local bReset = parseIso(b.metric.reset_at) or 0
                if aReset ~= bReset then return aReset > bReset end
            end
            if a.percent ~= b.percent then return a.percent > b.percent end
            if a.window ~= b.window then return a.window == "7d" end
            return a.index < b.index
        end)
        if affected[1] ~= nil then
            affected[1].model = model
            notices[#notices + 1] = affected[1]
        end
    end

    if #notices > 0 then
        local pills = {}
        for index = 1, math.min(#notices, 2) do
            local item = notices[index]
            local metric = item.metric
            local blocked = item.percent >= 100
            local role = blocked and "error" or severityRole(metric, "primary")
            local modelName = tostring(item.model.displayName or "")
            if modelName == "Claude & GPT OSS" then modelName = "OSS" end
            local text = (modelName ~= "" and modelName .. " " or "")
                .. (item.window ~= "" and item.window .. " " or "")
                .. tostring(item.percent) .. "%"
            local severity = tostring(metric.severity or "")
            local detail = blocked and noctalia.tr("ui.quota_exhausted")
                or (severity == "high" or severity == "critical")
                    and noctalia.tr("ui.severity." .. severity)
                or tostring(item.percent) .. "%"
            local left = blocked and shared.fixedCountdown(metric) or ""
            if left ~= "" then detail = detail .. " · " .. noctalia.tr("ui.quota_reset", { time = left }) end
            pills[#pills + 1] = ui.row({ gap = 4, align = "center", paddingH = 7,
                paddingV = 3, radius = 6, fill = role .. "/0.15",
                border = role .. "/0.25", borderWidth = 1, tooltip = detail }, {
                ui.glyph({ name = item.model.glyph, size = 13, color = role }),
                ui.label({ text = text, fontSize = 13,
                    fontWeight = "bold", color = role, maxLines = 1 }),
            })
        end
        return ui.row({ gap = 4, align = "center" }, pills)
    end
    return ui.glyph({ name = "circle-check", size = 16, color = "primary" })
end

local function detailPane(entry)
    local children = {}

    local cards = {}
    local sections = entry ~= nil and type(entry.sections) == "table" and entry.sections or {}

    -- Pass one: pair every reading with the heading over it, and drop the padding
    -- the CLI puts between sections -- the column sets its own gap, and a spacer
    -- left by a consumed heading would double it.
    local windowed = false
    local heading = ""
    local items = {}
    local metricCount = 0
    for _, section in ipairs(sections) do
        if type(section) == "table" then
            local text = section.type == "text"
            if text and noctalia.string.trim(tostring(section.value or "")) == "" then
                heading = tostring(section.label or "")
                windowed = windowed or heading ~= ""
            elseif section.type ~= "spacer" then
                items[#items + 1] = { section = section, window = heading }
                if section.type == "metric" then metricCount = metricCount + 1 end
            end
        end
    end

    -- A provider that is down draws no gauges: a bar reads as a live reading, and
    -- nothing is reading. The warning takes their place, and the last numbers
    -- follow as a record, unless a plan change made them meaningless.
    local warning = entry ~= nil and providerWarning(entry) or ""
    if warning ~= "" then
        local failureLabel = readFailure(entry) and noctalia.tr("ui.error.failed") or nil
        cards[#cards + 1] = noteCard(warning, failureLabel)
        local id = tostring(entry.id or "")
        local previous = lastPlan[id]
        local current = tostring(entry.plan or "")
        -- Only a plan the CLI names on both sides is evidence of a change: an
        -- entry that fell over and stopped naming one says nothing.
        if previous ~= nil and previous ~= "" and current ~= "" and previous ~= current then
            cards[#cards + 1] = ui.label({ text = noctalia.tr("ui.plan_changed"), fontSize = 11,
                                           color = "on_surface_variant", maxLines = 2 })
        else
            local record = recordCard(entry, items, windowed)
            if record ~= nil then cards[#cards + 1] = record end
        end
    else
        -- Pass two: every reading a provider sends, in the cards it is read by.
        local order, byName = groupReadings(items, windowed)
        for _, name in ipairs(order) do
            local cardName, glyph = name, nil
            local readings = byName[name]
            if not windowed and entry ~= nil then
                cardName = tostring(entry.display_name or entry.id)
                glyph = providerGlyph(entry.id)
                for _, reading in ipairs(readings) do
                    local label = tostring(reading.title):lower()
                    if label:match("5h$") then
                        reading.title = "Session"
                    elseif label:match("weekly$") then
                        reading.title = "Weekly"
                    end
                end
            end
            cards[#cards + 1] = stackCard(cardName, readings, glyph)
        end
    end

    -- The rest is the same either way: losing the gauges is no reason to lose
    -- what else the CLI said.
    for _, item in ipairs(items) do
        if item.section.type ~= "metric" then
            local card = otherCard(item.section, warning ~= "")
            if card ~= nil then cards[#cards + 1] = card end
        end
    end

    -- Keep the same card width in both modes. The scrollbar lives in the
    -- reserved right gutter, while the provider header remains fixed above.
    if #cards > 0 then
        local needsScroll = false
        if LAYOUT_MODE == "columns" then
            -- En modo columnas con panel alto (640px), 2-4 tarxetas entran sen scroll.
            needsScroll = #cards >= 5 or metricCount >= 8
            for _, item in ipairs(items) do
                if item.section.type == "block" and type(item.section.body) == "table"
                    and #item.section.body >= 8 then
                    needsScroll = true
                end
            end
        else
            needsScroll = #cards >= 3 or metricCount >= 3
                or (windowed and #cards >= 2)
            for _, item in ipairs(items) do
                if item.section.type == "block" and type(item.section.body) == "table"
                    and #item.section.body >= 4 then
                    needsScroll = true
                end
            end
        end
        local props = { gap = 8, paddingH = 6,
            paddingV = 4, align = "stretch" }
        if needsScroll then
            props.flexGrow = 1
            children[#children + 1] = ui.scroll(props, cards)
        else
            children[#children + 1] = ui.column(props, cards)
        end
    elseif entry ~= nil then
        children[#children + 1] = ui.row({ gap = 6, align = "center" }, {
            ui.glyph({ name = "info-circle", size = 14, color = "on_surface_variant" }),
            ui.label({ text = noctalia.tr("ui.no_usage"), fontSize = 12, color = "on_surface_variant" }),
        })
        children[#children + 1] = ui.spacer({ flexGrow = 1 })
    end

    return ui.column({ gap = 6, paddingH = 0, paddingV = 0, flexGrow = 1,
                       align = "stretch" }, children)
end

local function renderTabs(entry, candidates)
    local compactTabs = #candidates > 3

    local tabs = {}
    for _, candidate in ipairs(candidates) do
        tabs[#tabs + 1] = providerRow(candidate, entry ~= nil and candidate.id == entry.id, compactTabs)
    end

    local headerActions = {}
    local providerActions = {}
    local updatedRow = nil

    local fetched = parseIso(entry and entry.fetched_at)
    if fetched ~= nil then
        updatedRow = ui.row({ gap = 4, align = "center", paddingH = 7,
                              paddingV = 3, radius = 6, fill = "on_surface/0.08",
                              tooltip = updatedText(entry) }, {
            ui.glyph({ name = "clock", size = 13, color = "on_surface_variant" }),
            ui.label({
                text = noctalia.tr("ui.updated") .. " " .. noctalia.formatTime(noctalia.timeFormat(), fetched),
                fontSize = 13,
                color = "on_surface_variant",
            }),
        })
    end

    if entry ~= nil then
        providerActions[#providerActions + 1] = ui.button({
            glyph = "copy",
            variant = "outline",
            controlSize = "sm",
            tooltip = "Copy usage summary",
            onClick = function() copySummary(entry) end,
        })
        local dashUrl = shared.providerDashboard(entry.id)
        if dashUrl ~= nil then
            providerActions[#providerActions + 1] = ui.button({
                glyph = "external-link",
                variant = "outline",
                controlSize = "sm",
                tooltip = "Open dashboard",
                onClick = function()
                    if type(noctalia.runAsync) == "function" then
                        noctalia.runAsync("xdg-open '" .. dashUrl .. "'")
                    end
                end,
            })
        end
    end

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

    local topChildren = {
        ui.row({ gap = 8, align = "center" }, {
            ui.row({
                width = 30, height = 30, radius = 7,
                fill = "primary/0.14", align = "center", justify = "center",
            }, {
                ui.glyph({ name = "brain", size = 18, color = "primary" }),
            }),
            ui.label({ text = noctalia.tr("ui.title"), fontSize = 17, fontWeight = "bold", color = "on_surface" }),
            ui.spacer({ flexGrow = 1 }),
            ui.row({ gap = 4, align = "center" }, headerActions),
        }),
    }

    if #tabs > 0 then
        topChildren[#topChildren + 1] = ui.row({ key = "tabs-dock", gap = 6,
            align = "center", justify = "center" }, tabs)
    end

    local status = statusIndicator(entry)
    if updatedRow ~= nil or status ~= nil or #providerActions > 0 then
        local providerMeta = {}
        if updatedRow ~= nil then providerMeta[#providerMeta + 1] = updatedRow end
        if status ~= nil then providerMeta[#providerMeta + 1] = status end
        providerMeta[#providerMeta + 1] = ui.spacer({ flexGrow = 1 })
        if #providerActions > 0 then
            providerMeta[#providerMeta + 1] = ui.row({ gap = 4, align = "center" }, providerActions)
        end
        topChildren[#topChildren + 1] = ui.row({ key = "meta-row", gap = 4, align = "center" }, providerMeta)
    end

    panel.render(ui.column({
        gap = 6,
        paddingH = 14,
        paddingV = 10,
        flexGrow = 1,
        align = "stretch",
        fill = "surface/0.95",
        radius = 16,
        border = "outline/0.25",
        borderWidth = 1,
    }, {
        ui.column({ gap = 6 }, topChildren),
        ui.separator({ orientation = "horizontal", color = "outline", opacity = 0.20 }),
        detailPane(entry),
    }))
end

-- ── Modo 3 columnas: Sesión (5h), Semanal (7d) e Reset credits ──────────────

local function collectModelItems(candidates)
    local items = {}
    for _, entry in ipairs(candidates) do
        local id = entry.id
        local baseId = shared.baseProvider(id)
        local displayName = tostring(entry.display_name or entry.name or entry.id or "")
        local plan = tostring(entry.plan or "")

        if baseId == "antigravity" then
            local models = modelHeadlines(entry)
            if #models > 0 then
                for _, model in ipairs(models) do
                    local sMetric, wMetric = dualMetrics(model.metrics)
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
            else
                local sMetric, wMetric = dualMetrics(entry.metrics)
                items[#items + 1] = {
                    providerId = id,
                    providerName = displayName,
                    plan = plan,
                    providerGlyph = providerGlyph(id),
                    name = displayName,
                    glyph = providerGlyph(id),
                    badge = nil,
                    sessionMetric = sMetric,
                    weeklyMetric = wMetric,
                    entry = entry,
                }
            end
        else
            local sMetric, wMetric = dualMetrics(entry.metrics)
            items[#items + 1] = {
                providerId = id,
                providerName = displayName,
                plan = plan,
                providerGlyph = providerGlyph(id),
                name = displayName,
                glyph = providerGlyph(id),
                badge = nil,
                sessionMetric = sMetric,
                weeklyMetric = wMetric,
                entry = entry,
            }
        end
    end
    return items
end

local function collectResetCredits(candidates)
    local credits = {}
    for _, entry in ipairs(candidates) do
        local providerName = tostring(entry.display_name or entry.name or entry.id or "")
        local providerId = entry.id
        local sections = type(entry.sections) == "table" and entry.sections or {}
        local rawCredits = type(entry.reset_credits) == "table" and entry.reset_credits.credits or nil

        for _, section in ipairs(sections) do
            if section.type == "block" and tostring(section.label or ""):lower():find("reset credit") then
                local lines = type(section.body) == "table" and section.body or {}
                for lineIndex, line in ipairs(lines) do
                    local text = noctalia.string.trim(tostring(line))
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
                        expireTimestamp = parseIso(rawCredits[lineIndex].expires_at)
                    end
                    if expireTimestamp == nil and rawCredits then
                        for _, rc in ipairs(rawCredits) do
                            if kind and rc.title and rc.title == kind then
                                expireTimestamp = parseIso(rc.expires_at)
                                break
                            end
                        end
                    end
                    if expireTimestamp == nil then
                        local days = tonumber(expiryText:match("(%d+)d")) or 0
                        local hours = tonumber(expiryText:match("(%d+)h")) or 0
                        expireTimestamp = os.time() + (days * 86400) + (hours * 3600)
                    end

                    credits[#credits + 1] = {
                        providerId = providerId,
                        providerName = providerName,
                        glyph = providerGlyph(providerId),
                        expiry = expiryText,
                        fullTitle = kind or text,
                        expiresAt = expireTimestamp or math.huge,
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

    return credits
end

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
        return string.format("%s, %s %s %s", weekday, month, day, clock)
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
    local ratio = remaining / window

    if ratio > 0.60 then
        return "#4ade80" -- Verde (>60%)
    elseif ratio > 0.30 then
        return "#38bdf8" -- Azul (30%-60%)
    elseif ratio > 0.12 then
        return "#facc15" -- Amarelo (12%-30%)
    elseif ratio > 0.04 then
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

local function assessTriage(metric, percent, elapsedPct, windowLabel, item)
    if metric == nil or percent == nil then return nil end
    local isWeekly = windowLabel == "7d"
    local remainingQuota = 100 - percent
    local at = parseIso(metric.reset_at)
    local remainingSecs = (at and at > os.time()) and (at - os.time()) or 0
    local paceDiff = (elapsedPct or 0) - percent

    local wMetric = item and item.weeklyMetric
    local wPct = wMetric and tonumber(wMetric.percent) or 0
    local isWeeklyExhausted = (wMetric ~= nil and wPct >= 100)

    if percent >= 100 or isWeeklyExhausted then
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

    local shouldThrottle = false
    if percent >= 75 and remainingSecs > (isWeekly and 172800 or 3600) then
        shouldThrottle = true
    elseif paceDiff <= -15 and percent >= 60 then
        shouldThrottle = true
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
            summary = string.format("Heavy use · %d%% free remaining", remainingQuota),
        }
    end

    local shouldBurn = false
    if not isWeekly then
        if remainingSecs <= 5400 and remainingQuota >= 25 and remainingSecs > 0 then
            shouldBurn = true
        elseif remainingSecs <= 9000 and remainingQuota >= 45 and remainingSecs > 0 then
            shouldBurn = true
        elseif paceDiff >= 20 and remainingQuota >= 40 and isSessionStarted(metric) then
            shouldBurn = true
        end
    else
        if remainingSecs <= 86400 and remainingQuota >= 15 and remainingSecs > 0 then
            shouldBurn = true
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
            summary = string.format("%d%% free to use · %dpts under", remainingQuota, paceDiff),
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


local kickstarting = {}
local kickstartedAt = {}

local function kickstartTarget(item)
    if item == nil then return nil end
    local id = tostring(item.providerId or "")
    local name = tostring(item.name or ""):lower()
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
        end)
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

local function renderMetricCard(item, metric, windowLabel)
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
        return ui.column(CARD, {
            ui.row({ gap = 6, align = "center" }, {
                ui.row({ gap = 5, align = "center" }, titleChildren),
                ui.spacer({ flexGrow = 1 }),
                unavail and ui.row({ gap = 4, align = "center" }, {
                    ui.glyph({ name = "alert-circle", size = 14, color = "error" }),
                    ui.label({ text = noctalia.tr("ui.unavailable"), fontSize = 13, color = "error" }),
                }) or ui.label({ text = "—", fontSize = 14, color = "on_surface_variant" }),
            }),
        })
    end

    local percent = tonumber(metric.percent) or 0
    local tint = severityRole(metric, "on_surface")
    local fill = severityRole(metric, "primary")
    local value = tostring(metric.value or ""):gsub(" of ", " / ")
    local showValue = value ~= "" and value ~= string.format("%d%%", percent)

    local resetTimeText = formatResetTime(metric, windowLabel)
    local leftDuration = ""
    if windowLabel == "7d" or isSessionStarted(metric) then
        leftDuration = countdown(metric)
        if (leftDuration == "now" or leftDuration == noctalia.tr("ui.now"))
            and windowLabel ~= "7d" and not isSessionStarted(metric) then
            leftDuration = ""
        end
    end
    local resetTooltip = leftDuration ~= "" and ("Renews in " .. leftDuration) or nil

    local elapsedPct = calculateElapsed(metric, windowLabel)
    local triage = assessTriage(metric, percent, elapsedPct, windowLabel, item)

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

    local topRow = ui.row({ gap = 4, align = "center" }, {
        ui.row({ gap = 4, align = "center" }, titleChildren),
        ui.spacer({ flexGrow = 1 }),
        ui.row({ gap = 5, align = "center", justify = "end" }, rightMeta),
    })

    local progressBar = ui.progress({
        progress = ratio(percent),
        fill = fill,
        track = "on_surface/0.10",
        radius = 4,
        height = 8,
    })

    local progressElement = progressBar
    if elapsedPct ~= nil then
        local leftFlex = math.max(1, elapsedPct)
        local rightFlex = math.max(1, 100 - elapsedPct)
        local paceDiff = elapsedPct - percent
        local paceStatus = paceDiff >= 0
            and string.format("+%d%% quota free", paceDiff)
            or string.format("%d%% over pace", -paceDiff)
        local markerTip = string.format("Time: %d%% elapsed · Quota: %d%% used (%s)",
            elapsedPct, percent, paceStatus)

        local markerColor = paceDiff >= 0 and "#38bdf8" or "#fb923c"

        local markerChildren = {}
        if elapsedPct > 1 then
            markerChildren[#markerChildren + 1] = ui.spacer({ flexGrow = leftFlex })
        end
        markerChildren[#markerChildren + 1] = ui.box({
            width = 4,
            height = 5,
            radius = 1.5,
            fill = markerColor,
        })
        if elapsedPct < 99 then
            markerChildren[#markerChildren + 1] = ui.spacer({ flexGrow = rightFlex })
        end

        local markerRow = ui.row({
            height = 5,
            align = "center",
            paddingH = 0,
            tooltip = markerTip,
        }, markerChildren)

        progressElement = ui.column({ gap = 1, align = "stretch" }, {
            progressBar,
            markerRow,
        })
    end

    local body = { topRow, progressElement }

    local bottomRowElements = {}
    if resetTimeText ~= "" then
        bottomRowElements[#bottomRowElements + 1] = ui.row({
            gap = 5, align = "center", justify = "center",
            paddingH = 8,
            paddingV = 2,
            radius = 5,
            fill = "on_surface/0.08",
        }, {
            ui.glyph({ name = "clock", size = 13, color = "on_surface_variant" }),
            ui.label({
                text = resetTimeText,
                fontSize = 13,
                fontWeight = "medium",
                color = "on_surface",
                textAlign = "center",
                maxLines = 1,
            }),
        })
    end

    local ksTarget = kickstartTarget(item)
    local justKickstarted = ksTarget ~= nil and kickstartedAt[ksTarget] ~= nil
        and (os.time() - kickstartedAt[ksTarget]) < 18000
    local isWeeklyExhausted = (item and item.weeklyMetric ~= nil and (tonumber(item.weeklyMetric.percent) or 0) >= 100)
    local canKickstart = not isWeekly and ksTarget ~= nil and not justKickstarted
        and not isSessionStarted(metric) and percent == 0
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
    end

    if #bottomRowElements > 0 then
        body[#body + 1] = ui.row({ gap = 8, align = "center", justify = "center" }, bottomRowElements)
    end

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
    local ratio = remaining / window

    if ratio > 0.60 then
        return "#4ade80"
    elseif ratio > 0.30 then
        return "#38bdf8"
    elseif ratio > 0.12 then
        return "#facc15"
    elseif ratio > 0.04 then
        return "#fb923c"
    else
        return "#f87171"
    end
end

local function renderCreditCard(credit)
    local fgColor = creditCountdownColor(credit)
    return ui.column(cardStyle(6), {
        ui.row({ gap = 8, align = "center", tooltip = credit.fullTitle }, {
            ui.row({
                width = 30, height = 30, radius = 7,
                fill = "primary/0.14", align = "center", justify = "center",
            }, {
                ui.glyph({ name = credit.glyph, size = 18, color = "primary" }),
            }),
            ui.label({
                text = credit.providerName,
                fontSize = 17,
                fontWeight = "bold",
                color = "on_surface",
                maxLines = 1,
            }),
            ui.spacer({ flexGrow = 1 }),
            ui.row({
                gap = 6, align = "center",
                paddingH = 6, paddingV = 2,
            }, {
                ui.glyph({ name = "clock", size = 16, color = fgColor }),
                ui.label({
                    text = credit.expiry,
                    fontSize = 16,
                    fontWeight = "semibold",
                    color = fgColor,
                    maxLines = 1,
                }),
            }),
        }),
    })
end

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

    local notices = {}
    for _, candidate in ipairs(candidates) do
        local status = statusIndicator(candidate)
        if status ~= nil then
            notices[#notices + 1] = status
        end
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
    if #notices > 0 then
        for _, n in ipairs(notices) do
            topRowChildren[#topRowChildren + 1] = n
        end
    end
    topRowChildren[#topRowChildren + 1] = ui.row({ gap = 4, align = "center" }, headerActions)

    local modelItems = collectModelItems(candidates)
    local resetCredits = collectResetCredits(candidates)

    -- Ordenar os modelos por triaxe (tendo en conta consumo e tempo horario e semanal)
    table.sort(modelItems, function(a, b)
        local aScore = calculateModelTriageScore(a)
        local bScore = calculateModelTriageScore(b)
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

    -- Ambas columnas seguen a mesma orde de triaxe:
    -- ao lado da tarxeta horaria vai sempre a semanal do mesmo provedor/modelo
    local sessionCards = {}
    local weeklyCards = {}
    for _, item in ipairs(modelItems) do
        local sCard = renderMetricCard(item, item.sessionMetric, "5h")
        if sCard ~= nil then
            sessionCards[#sessionCards + 1] = sCard
        end
        local wCard = renderMetricCard(item, item.weeklyMetric, "7d")
        if wCard ~= nil then
            weeklyCards[#weeklyCards + 1] = wCard
        end
    end

    local creditCards = {}
    for _, credit in ipairs(resetCredits) do
        creditCards[#creditCards + 1] = renderCreditCard(credit)
    end
    if #creditCards == 0 then
        creditCards[#creditCards + 1] = ui.column(CARD, {
            ui.row({ gap = 8, align = "center" }, {
                ui.glyph({ name = "info-circle", size = 18, color = "on_surface_variant" }),
                ui.label({ text = "No pending reset credits", fontSize = 16, color = "on_surface_variant" }),
            }),
        })
    end

    local col1 = ui.column({
        key = "col-session",
        gap = 6,
        flexGrow = 1.20,
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
        ui.column({ gap = 6, align = "stretch" }, sessionCards),
    })

    local col2 = ui.column({
        key = "col-weekly",
        gap = 6,
        flexGrow = 1.20,
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
        ui.column({ gap = 6, align = "stretch" }, weeklyCards),
    })

    local col3 = ui.column({
        key = "col-credits",
        gap = 6,
        flexGrow = 0.75,
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
            ui.label({ text = "Reset credits", fontSize = 18, fontWeight = "bold", color = "on_surface" }),
        }),
        ui.separator({ orientation = "horizontal", color = "outline", opacity = 0.16 }),
        ui.column({ gap = 6, align = "stretch" }, creditCards),
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
    local entry = currentEntry()
    -- A failure with nothing behind it is the whole panel; with a report behind
    -- it, a banner over readings that are still the best answer available. A
    -- report whose every row was dropped still counts as one: the panel it draws
    -- is empty, not absent.
    if failure.code ~= "" and report == nil then
        -- The panel keeps its manifest size, and a failure has nowhere near
        -- 720x400 to say. Bounded and centred, the empty surround reads as
        -- composition rather than a half-drawn frame.
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

    if LAYOUT_MODE == "columns" and #candidates > 1 then
        renderColumns(candidates)
    else
        renderTabs(entry, candidates)
    end
end

-- ── Wiring ────────────────────────────────────────────────────────────────────

-- Rebuilt from the report rather than added to, so the map holds one key per
-- provider on screen instead of every id the panel has seen since it opened.
local function rememberPlans()
    local seen = {}
    for _, entry in ipairs(entries()) do
        if type(entry) == "table" then
            local id = tostring(entry.id or "")
            -- A provider that is down is serving what it cached, so the plan to
            -- keep is the one it last reported for real.
            if unavailable(entry) then
                seen[id] = lastPlan[id]
            else
                seen[id] = tostring(entry.plan or "")
            end
        end
    end
    lastPlan = seen
end

noctalia.state.watch("report", function(value)
    if type(value) == "table" then
        report = value
        failure = NO_FAILURE
        rememberPlans()
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
    -- Every open asks for fresh numbers. The CLI answers from its cache when it
    -- has one, and the poller drops requests that arrive too close together.
    requestRefresh()
    report = noctalia.state.get("report")
    rememberPlans()
    failure = asFailure(noctalia.state.get("error"))
    polling = noctalia.state.get("polling") == true
    refreshQueued = noctalia.state.get("refresh_queued") == true
    -- Countdowns tick locally; the CLI is only woken by the poller's interval.
    panel.setWantsSecondTicks(true)
    render()
end

-- Panel second tick, for the countdowns.
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
    elseif lower == "up" or lower == "down" or lower == "left" or lower == "right" then
        if LAYOUT_MODE == "tabs" then
            local list = {}
            local currentIndex = 1
            local current = currentEntry()
            for _, candidate in ipairs(entries()) do
                if configured(candidate) then
                    list[#list + 1] = candidate
                    if current ~= nil and candidate.id == current.id then
                        currentIndex = #list
                    end
                end
            end
            if #list > 1 then
                local nextIndex = (lower == "up" or lower == "left") and ((currentIndex - 2 + #list) % #list + 1)
                                                                     or ((currentIndex % #list) + 1)
                noctalia.state.set("selected", list[nextIndex].id)
                render()
            end
        end
    end
end

render()

