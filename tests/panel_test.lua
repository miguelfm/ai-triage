-- Host harness for malformed collection handling in panel.luau.

local function read(path)
    local file = assert(io.open(path, "r"))
    local source = file:read("*a")
    file:close()
    return source
end

local function loadPanel(entry, failure)
    local watchers = {}
    local isReport = type(entry) == "table" and type(entry.entries) == "table"
    local report = isReport and entry or entry ~= nil and { entries = { entry } } or nil
    local first = report ~= nil and report.entries[1] or nil
    local opened, copied, notifications = {}, {}, {}
    local values = {
        report = report,
        error = failure or { code = "", detail = "" },
        selected = isReport and entry.selected or first ~= nil and first.id or nil,
    }
    local noctalia = {
        state = {
            get = function(key) return values[key] end,
            set = function(key, value) values[key] = value end,
            watch = function(key, fn) watchers[key] = fn end,
        },
        commandExists = function() return false end,
        nowMs = function() return 1000 end,
        tr = function(key, args)
            if key == "ui.quota_reset" and args then return key .. ": " .. args.time end
            return key
        end,
        string = {
            trim = function(value) return tostring(value):match("^%s*(.-)%s*$") end,
        },
        formatTime = function() return "12:00" end,
        timeFormat = function() return "%H:%M" end,
        runAsync = function(command)
            opened[#opened + 1] = command
            return true
        end,
        copyToClipboard = function(text, mime)
            copied[#copied + 1] = { text = text, mime = mime }
        end,
        notify = function() notifications[#notifications + 1] = true end,
    }
    local ui = setmetatable({}, {
        __index = function(_, kind)
            return function(props, children)
                return { kind = kind, props = props or {}, children = children or {} }
            end
        end,
    })
    local drawn = nil
    local panel = {
        render = function(tree) drawn = tree end,
        setWantsSecondTicks = function() end,
    }
    local sharedEnv = setmetatable({ noctalia = noctalia }, { __index = _G })
    local shared = assert(load(read("shared.luau"), "shared", "t", sharedEnv))()
    local env = setmetatable({
        noctalia = noctalia,
        ui = ui,
        panel = panel,
        require = function(path)
            assert(path == "./shared.luau")
            return shared
        end,
    }, { __index = _G })
    assert(load(read("panel.luau"), "panel", "t", env))()
    env.onOpen()
    local function publish(nextEntry)
        values.report = { entries = { nextEntry } }
        values.selected = nextEntry.id
        watchers.report(values.report)
        return drawn
    end
    return drawn, publish, env, opened, copied, notifications
end

local function collect(node, kind, found)
    found = found or {}
    if type(node) ~= "table" then return found end
    if node.kind == kind then found[#found + 1] = node end
    for _, child in ipairs(node.children or {}) do collect(child, kind, found) end
    for _, child in ipairs(node) do collect(child, kind, found) end
    return found
end

local function labels(node)
    local out = {}
    for _, label in ipairs(collect(node, "label")) do out[#out + 1] = tostring(label.props.text or "") end
    return out
end

local function has(list, wanted)
    for _, value in ipairs(list) do if value == wanted then return true end end
    return false
end

local malformedSections = {
    id = "openai",
    display_name = "Codex",
    plan = "Plan",
    status = "ready",
    metrics = {},
    sections = 42,
}
local sectionsOk = pcall(loadPanel, malformedSections)
assert(sectionsOk, "malformed sections should render as no usage")

local malformedSectionEntry = {
    id = "openai",
    display_name = "Codex",
    plan = "Plan",
    status = "ready",
    metrics = {},
    sections = { 42 },
}
local sectionEntryOk = pcall(loadPanel, malformedSectionEntry)
assert(sectionEntryOk, "malformed section entries should be ignored")

local malformedBody = {
    id = "openai",
    display_name = "Codex",
    plan = "Plan",
    status = "ready",
    metrics = {},
    sections = { { type = "block", label = "Credits", body = 42 } },
}
local bodyOk = pcall(loadPanel, malformedBody)
assert(bodyOk, "malformed block body should render as an empty block")

local malformedMetricsOk = pcall(loadPanel, {
    id = "openai", display_name = "Codex", status = "ready",
    metrics = { 42, { label = "Weekly", percent = 70, window_secs = 604800 } },
    sections = {},
})
assert(malformedMetricsOk, "status pills should ignore non-table metrics")

local rejectedProvider = {
    id = "anthropic",
    display_name = "Claude",
    plan = "Claude Pro",
    status = "ready",
    metrics = {},
    sections = {
        { type = "text", label = "HTTP 403", value = "authentication rejected" },
    },
}
local rejectedLabels = labels(loadPanel(rejectedProvider))
assert(not has(rejectedLabels, "Claude"),
       "a terminal provider should leave the panel immediately")

local normalReport = {
    entries = {
        {
            id = "google",
            display_name = "Gemini",
            plan = "Advanced",
            status = "ready",
            metrics = {
                { label = "Session", percent = 20, window_secs = 18000 },
                { label = "Weekly", percent = 50, window_secs = 604800 },
            },
            sections = {
                { type = "text", label = "Reset", value = "Reset in 5d" },
            },
        },
    },
}
local renderedTree = loadPanel(normalReport)
local scrollElements = collect(renderedTree, "scroll")
assert(#scrollElements >= 3, "expected at least 3 ui.scroll elements for the 3 columns, found " .. tostring(#scrollElements))

io.write("ok: malformed collections, authentication errors, and scroll containers verified in panel\n")
