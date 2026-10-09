-- Tests for 5h rolling session initiation identification and ai-kickstart button.

local function read(path)
    local file = assert(io.open(path, "r"))
    local source = file:read("*a")
    file:close()
    return source
end

local mockState = {}
local mockNoctalia = {
    state = {
        get = function(key) return mockState[key] end,
        set = function(key, val) mockState[key] = val end,
        watch = function() end,
    },
    tr = function(key, args)
        if key == "ui.quota_reset" and args then return key .. ": " .. args.time end
        if key == "ui.now" then return "now" end
        return key
    end,
    string = {
        trim = function(value) return tostring(value):match("^%s*(.-)%s*$") end,
    },
    formatTime = function(fmt, timestamp)
        return os.date(fmt or "%H:%M", timestamp)
    end,
    timeFormat = function() return "%H:%M" end,
    nowMs = function() return 1000 end,
    commandExists = function() return false end,
    runAsync = function() return true end,
    openSettings = function() end,
}

local sharedEnv = setmetatable({ noctalia = mockNoctalia }, { __index = _G })
local shared = assert(load(read("shared.luau"), "shared", "t", sharedEnv))()

-- 1. Unit tests for shared.isSessionStarted
local now = os.time()
local futureIso = os.date("!%Y-%m-%dT%H:%M:%SZ", now + 7200)
local pastIso = os.date("!%Y-%m-%dT%H:%M:%SZ", now - 3600)

assert(shared.isSessionStarted({ percent = 5 }) == true,
    "percent > 0 must mean session is started")

assert(shared.isSessionStarted({ percent = 0, reset_at = futureIso }) == true,
    "percent == 0 with future reset_at must mean session is started")

assert(shared.isSessionStarted({ percent = 0, reset_at = pastIso }) == false,
    "percent == 0 with past reset_at must mean session is not started")

assert(shared.isSessionStarted({ percent = 0, reset_at = nil }) == false,
    "percent == 0 without reset_at must mean session is not started")

assert(shared.isSessionStarted({ percent = 0, detail = "Resets in 2h 17m · 54% elapsed" }) == true,
    "detail with active countdown must mean session is started")

assert(shared.isSessionStarted(nil) == false,
    "nil metric must return false")

-- 2. Panel component tests for Start 5h button visibility
local function collect(node, kind, found)
    found = found or {}
    if type(node) ~= "table" then return found end
    if node.kind == kind then found[#found + 1] = node end
    for _, child in ipairs(node.children or {}) do collect(child, kind, found) end
    for _, child in ipairs(node) do collect(child, kind, found) end
    return found
end

local function buttonsWithText(tree, text)
    local out = {}
    for _, btn in ipairs(collect(tree, "button")) do
        if btn.props and btn.props.text == text then
            out[#out + 1] = btn
        end
    end
    return out
end

local function hasLabel(tree, text)
    for _, lbl in ipairs(collect(tree, "label")) do
        if lbl.props and lbl.props.text == text then
            return true
        end
    end
    return false
end

local function loadPanelWithReport(report)
    mockState = {
        report = report,
        error = { code = "", detail = "" },
        selected = report.entries and report.entries[1] and report.entries[1].id or nil,
    }
    local panelDrawn = nil
    local panelObj = {
        render = function(tree) panelDrawn = tree end,
        setWantsSecondTicks = function() end,
    }
    local ui = setmetatable({}, {
        __index = function(_, kind)
            return function(props, children)
                return { kind = kind, props = props or {}, children = children or {} }
            end
        end,
    })
    local env = setmetatable({
        noctalia = mockNoctalia,
        ui = ui,
        panel = panelObj,
        require = function(path)
            assert(path == "./shared.luau")
            return shared
        end,
    }, { __index = _G })
    assert(load(read("panel.luau"), "panel", "t", env))()
    env.onOpen()
    return panelDrawn
end

-- Test scenario: 2 providers in 3-column layout:
-- Codex: 0% usage, but 5h period has ALREADY started (future reset_at, e.g. resets in 2h 17m).
-- Claude: 0% usage, 5h period NOT started (no reset_at).
local testReport = {
    entries = {
        {
            id = "openai",
            display_name = "Codex",
            status = "ready",
            metrics = {
                {
                    label = "Codex 5h",
                    percent = 0,
                    value = "0%",
                    reset_at = futureIso,
                    detail = "Resets in 2h 17m · 54% elapsed",
                    window_secs = 18000,
                },
                {
                    label = "Codex weekly",
                    percent = 28,
                    value = "28%",
                    reset_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now + 400000),
                    window_secs = 604800,
                },
            },
        },
        {
            id = "anthropic",
            display_name = "Claude",
            status = "ready",
            metrics = {
                {
                    label = "Session (5h)",
                    percent = 0,
                    value = "0%",
                    reset_at = nil,
                    detail = "",
                    window_secs = 18000,
                },
                {
                    label = "Weekly (7d)",
                    percent = 10,
                    value = "10%",
                    reset_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now + 400000),
                    window_secs = 604800,
                },
            },
        },
    },
}

local panelTree = loadPanelWithReport(testReport)
local startButtons = buttonsWithText(panelTree, "Start 5h")

assert(#startButtons == 1,
    "Expected exactly 1 'Start 5h' button (only for unstarted Claude, NOT for active Codex). Got: " .. #startButtons)

-- Verify Codex (started) has NO kickstart button and its triage badge is NOT 'Fresh'
assert(not hasLabel(panelTree, "unused session"),
    "Codex must not be labeled as unused session")

-- Test scenario 2: Claude has now started (future reset_at)
testReport.entries[2].metrics[1].reset_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now + 17500)
testReport.entries[2].metrics[1].detail = "Resets in 4h 51m · 2% elapsed · on track"
local panelTree2 = loadPanelWithReport(testReport)
local startButtons2 = buttonsWithText(panelTree2, "Start 5h")
assert(#startButtons2 == 0,
    "When both Codex and Claude 5h windows are started, 0 'Start 5h' buttons should appear. Got: " .. #startButtons2)

-- Test scenario 3: Claude's session expired in the past (e.g. yesterday) and is waiting for new prompt
testReport.entries[2].metrics[1].reset_at = pastIso
testReport.entries[2].metrics[1].detail = ""
local panelTree3 = loadPanelWithReport(testReport)
local startButtons3 = buttonsWithText(panelTree3, "Start 5h")
assert(#startButtons3 == 1,
    "When Claude's session expired in the past with 0% usage, 'Start 5h' button must appear. Got: " .. #startButtons3)

-- Test scenario 4: Provider without kickstart target (e.g. openrouter) at 0%
local nonKickstartReport = {
    entries = {
        {
            id = "openrouter",
            display_name = "OpenRouter",
            status = "ready",
            metrics = {
                { label = "Session", percent = 0, value = "0%", reset_at = nil, window_secs = 18000 },
            },
        },
        {
            id = "openai",
            display_name = "Codex",
            status = "ready",
            metrics = {
                { label = "Session", percent = 0, value = "0%", reset_at = futureIso, window_secs = 18000 },
            },
        },
    },
}
local panelTree4 = loadPanelWithReport(nonKickstartReport)
local startButtons4 = buttonsWithText(panelTree4, "Start 5h")
assert(#startButtons4 == 0,
    "Non-kickstart provider (openrouter) must not display Start 5h button. Got: " .. #startButtons4)

-- Test scenario 5: Host refuses launch (runAsync returns false)
-- Verifies that kickstarting[target] is cleared and a second click is permitted
local runAsyncCalls = 0
mockNoctalia.runAsync = function(cmd, cb)
    runAsyncCalls = runAsyncCalls + 1
    return false
end
local panelTree5 = loadPanelWithReport(testReport)
local startBtns5 = buttonsWithText(panelTree5, "Start 5h")
assert(#startBtns5 == 1, "Expected 1 'Start 5h' button initially")
startBtns5[1].props.onClick()
assert(runAsyncCalls == 1, "runAsync should have been called once on first click")
startBtns5[1].props.onClick()
assert(runAsyncCalls == 2, "Second click must produce a second launch attempt when runAsync returned false")

io.write("ok: all 5h session initiation scenarios and kickstart button tests passed!\n")
