-- Adapter and real poller regressions; no network, credentials, or live writes.
local function read(path)
    local f = assert(io.open(path)); local s = f:read("*a"); f:close(); return s
end
local function clone(value)
    if type(value) ~= "table" then return value end
    local out = {}; for k, v in pairs(value) do out[k] = clone(v) end; return out
end
local fixture = assert(loadfile("tests/fixtures/shuvquota_2.lua"))()
local values = {}
local env = setmetatable({ noctalia = {
    getConfig = function(key) return key == "show_claude_fable" and true or nil end,
    string = { trim = function(v) return tostring(v):match("^%s*(.-)%s*$") end },
    state = { get = function(k) return values[k] end, set = function(k, v) values[k] = v end },
} }, { __index = _G })
local shared = assert(load(read("shared.luau"), "shared", "t", env))()
env.require = function(name) assert(name == "./shared.luau"); return shared end
local adapter = assert(load(read("shuvquota.luau"), "shuvquota", "t", env))()
local now = assert(shared.parseIso(fixture.generatedAt))
env.os = setmetatable({ time = function(t) return t and os.time(t) or now end }, { __index = os })
local function normalize(doc)
    return adapter.normalize(doc or clone(fixture), "shuvquota-127-0-0-1-4789", now)
end

for _, url in ipairs({ "http://127.0.0.1:4789", "http://localhost:4789/", "http://[::1]:4789", "http://localhost" }) do
    assert(adapter.endpoint(url), url)
end
for _, url in ipairs({ "https://example.com", "http://127.0.0.1.evil:4789", "http://user@localhost:4789",
    "http://localhost:0", "http://localhost:65536", "http://localhost:4789/api/quota", "file:///tmp/report" }) do
    assert(not adapter.endpoint(url), url)
end
local report = assert(normalize())
assert(#report.entries == 3)
local codex, claude, agy = table.unpack(report.entries)
assert(codex.id == "openai@personal" and claude.id == "anthropic@personal")
assert(codex.metrics[1].percent == 25 and codex.metrics[2].percent == 50)
assert(codex.fetched_at == fixture.generatedAt and codex.collector_backend == "shuvquota")
assert(shared.kickstartTarget(codex.id) == nil, "owned collector login cannot prime a possibly different CLI account")
local models = shared.collectModelItems({ agy })
assert(#models == 2 and models[1].entry.id == "antigravity@personal")
local byId = {}; for _, item in ipairs(models) do byId[item.providerId] = item end
assert(byId["gemini@personal"].sessionMetric.percent == 25.125, "fractional percentages remain available to scoring")
assert(shared.metricText(byId["gemini@personal"].sessionMetric) == "25%", "round only presentation")
assert(byId["gemini@personal"].weeklyMetric.percent == 50)
assert(byId["claude-oss@personal"].weeklyMetric.percent == 0)
local fable = shared.claudeFableDetail(shared.collectModelItems({ claude })[1])
assert(fable.weeklyMetric.percent == 100 and fable.sessionMetric.percent == 20 and fable.informational)
assert(shared.headline(claude).percent == 20, "Shuvquota's exhausted Fable must not exhaust the Claude capsule")
do
    local reordered = clone(claude)
    reordered.metrics = { reordered.metrics[3], reordered.metrics[2], reordered.metrics[1] }
    local item = shared.collectModelItems({ reordered })[1]
    assert(item.weeklyMetric.percent == 55 and item.sessionMetric.percent == 20,
        "Shuvquota window order must not replace overall weekly usage with Fable")
    assert(shared.claudeFableDetail(item).weeklyMetric.percent == 100)
end
assert(#shared.collectModelItems(report.entries) == 4, "Fable must not become an independent routing/calibration target")
assert(codex.reset_credits.available == 2 and #codex.reset_credits.credits == 0 and codex.reset_credits.partial)
local _, stats = shared.analyzeResetCredits({ codex }, now)
assert(stats[codex.id].earliestExpiry == nil and stats[codex.id].canClaimNow == false,
    "the next Codex expiry does not reconstruct a complete reset inventory")
local cards = shared.collectResetCredits({ codex })
assert(cards[1].fullTitle:find("next expiry", 1, true) and cards[1].expiresAt < math.huge)
assert(#claude.reset_credits.credits == 2 and claude.reset_credits.credits[1].title == "Fable reset")
local incomplete = clone(fixture)
table.remove(incomplete.providers[2].accounts[1].extras)
assert(normalize(incomplete).entries[2].reset_credits.available == 2)
assert(#normalize(incomplete).entries[2].reset_credits.credits == 0,
    "a truncated grant list preserves the authoritative count without invented detail")

for _, mutate in ipairs({
    function(d) d.schemaVersion = 1 end,
    function(d) d.complete = false end,
    function(d) d.generatedAt = "2030-01-01T00:00:00Z" end,
    function(d) d.generatedAt = nil end,
    function(d) d.providers[1].accounts[2] = clone(d.providers[1].accounts[1]) end,
}) do local d = clone(fixture); mutate(d); assert(normalize(d) == nil) end
local bad = clone(fixture)
bad.providers[1].accounts[1].windows[1].percentRemaining = true
bad.providers[1].accounts[1].windows[1].percentUsed = nil
local partial = assert(normalize(bad))
assert(#partial.entries[1].metrics == 1 and shared.dualMetrics(partial.entries[1].metrics) == nil,
    "an unavailable session cannot be fabricated from the weekly window")
bad = clone(fixture); bad.providers[1].accounts[1].windows[1].percentUsed = 99
assert(normalize(bad).entries[1].status == "error", "inconsistent percentages cannot become live quota")
bad = clone(fixture); bad.providers[1].accounts[1].windows[2].windowSeconds = 18000
assert(normalize(bad).entries[1].status == "error", "contradictory cadence cannot be routed")
bad = clone(fixture); bad.providers[2].accounts[1].status = "error"
bad.providers[2].accounts[1].error = "Authentication required"
partial = assert(normalize(bad))
assert(partial.entries[1].status == "ready" and partial.entries[2].status == "error")
assert(shared.diagnostic(partial.entries[2]).actionKey == "ui.diagnostic.action.shuvquota")
bad = clone(fixture); bad.providers[3].accounts = {}
assert(normalize(bad).entries[3].status == "error", "an unconfigured provider remains diagnosable")
bad = clone(fixture)
local extras = bad.providers[2].accounts[1].extras
extras[2].reset.count = 3
extras[3].reset.type = "session"
extras[1].value = "4"
assert(#normalize(bad).entries[2].reset_credits.credits == 4, "group counts must be preserved")
extras[2].reset.startsAt = "2026-11-15T00:00:00Z"
local future = normalize(bad).entries[2]
assert(future.reset_credits.available == 1 and #future.reset_credits.credits == 1)
local _, futureStats = shared.analyzeResetCredits({ future }, now)
assert(futureStats[future.id].earliestExpiry == nil, "future and session-only grants cannot drive weekly reset advice")
assert(adapter.normalize(clone(fixture), "scope", now + 1800).entries[1].stale == true)
assert(shared.unavailable(adapter.normalize(clone(fixture), "scope", now + 1800).entries[1]))

-- Equivalent native quota facts must produce the same routing scores.
local expected = { entries = {
    { id = "openai@personal", display_name = "Codex · personal", status = "ready", metrics = {
        { label = "Codex session", percent = 25, window_secs = 18000, reset_at = "2026-11-11T15:00:00Z" },
        { label = "Codex weekly", percent = 50, window_secs = 604800, reset_at = "2026-11-14T12:00:00Z" },
    } },
    { id = "anthropic@personal", display_name = "Claude · personal", status = "ready", metrics = {
        { label = "Session (5h)", percent = 20, window_secs = 18000, reset_at = "2026-11-11T15:00:00Z" },
        { label = "Weekly (7d)", percent = 55, window_secs = 604800, reset_at = "2026-11-17T01:00:00Z" },
        { label = "Fable (7d)", percent = 100, window_secs = 604800, reset_at = "2026-11-17T01:00:00Z" },
    } },
} }
local normalizedItems = shared.collectModelItems({ codex, claude })
local nativeItems = shared.collectModelItems(expected.entries)
for i, item in ipairs(normalizedItems) do
    assert(math.abs(shared.calculateModelTriageScore(item, nil, now)
        - shared.calculateModelTriageScore(nativeItems[i], nil, now)) < 0.0001, "quota-source routing parity")
end
local sample = normalizedItems[1]
values.gearing_telemetry, shared.telemetryBaselines = {}, {}
shared.recordTelemetrySample(sample)
local telemetry = values.gearing_telemetry
assert(telemetry["openai@personal/shuvquota-127-0-0-1-4789"])
assert(not telemetry["openai@personal"], "collector calibration must not share an AIUsageBar baseline")

-- Exercise actual service state changes, cache paths, watchdog and late replies.
local function host()
    local h = { config = { quota_backend = "shuvquota" }, state = {}, callbacks = {}, runs = {},
        files = {}, encoded = {}, clock = 5000, httpAccepted = true, doc = clone(fixture), intervals = {} }
    local n = {
        getConfig = function(key) return h.config[key] end,
        nowMs = function() return h.clock end,
        setUpdateInterval = function(ms) h.intervals[#h.intervals + 1] = ms end,
        string = env.noctalia.string,
        pluginDataDir = function() return "/test" end,
        state = {
            get = function(key) return h.state[key] end,
            set = function(key, value) h.state[key] = value end,
            watch = function() end,
        },
        json = {
            decode = function(raw)
                if raw == "snapshot" then return clone(h.doc) end
                if raw == "native" then return clone(expected) end
                return clone(h.encoded[raw])
            end,
            encode = function(value)
                local key = "encoded-" .. tostring(#h.encoded + 1)
                h.encoded[#h.encoded + 1] = key; h.encoded[key] = clone(value); return key
            end,
        },
        http = function(request, callback)
            h.callbacks[#h.callbacks + 1] = { request = request, callback = callback }
            return h.httpAccepted
        end,
        runAsync = function(command, callback)
            h.runs[#h.runs + 1] = { command = command, callback = callback }; return true
        end,
        readFile = function(path) return h.files[path] end,
        writeFile = function(path, data) h.files[path] = data; return true end,
        renameFile = function(from, to) h.files[to], h.files[from] = h.files[from], nil; return true end,
    }
    h.env = setmetatable({ noctalia = n, os = env.os }, { __index = _G })
    local modules = {}
    h.env.require = function(path)
        if not modules[path] then modules[path] = assert(load(read(path:sub(3)), path, "t", h.env))() end
        return modules[path]
    end
    h.load = function() assert(load(read("service.luau"), "service", "t", h.env))() end
    h.respond = function(index, response)
        h.callbacks[index or #h.callbacks].callback(response or { ok = true, status = 200, body = "snapshot" })
    end
    h.load()
    return h
end
local h = host()
assert(#h.callbacks == 1 and #h.runs == 0, "Shuvquota uses native HTTP and never spawns a collector")
assert(h.callbacks[1].request.url == "http://127.0.0.1:4789/api/quota")
h.respond()
assert(#h.state.report.entries == 3 and not h.state.polling)
local cachedPath = "/test/last-report.shuvquota-127-0-0-1-4789.json"
assert(h.files[cachedPath] and not h.files["/test/last-report.json"], "backend report caches stay separate")
assert(h.files["/test/weekly-resets.shuvquota-127-0-0-1-4789.json"])
h.clock = h.clock + 2000; h.env.onIpc("refresh")
local oldReading = h.state.report
h.respond(nil, { ok = false })
assert(h.state.error.code == "collector_unavailable" and h.state.report == oldReading)
h.clock = h.clock + 2000; h.env.onIpc("refresh")
h.respond(nil, { ok = true, status = 503, body = "native" })
assert(h.state.error.code == "collector_http" and h.state.report == oldReading)
h.clock = h.clock + 2000; h.env.onIpc("refresh")
h.doc.complete = false; h.respond()
assert(h.state.error.code == "collector_schema" and h.state.report == oldReading)
h.doc.complete = true
h.clock = h.clock + 2000; h.env.onIpc("refresh")
local late = #h.callbacks
h.config.quota_backend = "ai-usagebar"; h.env.onConfigChanged()
assert(#h.runs == 1 and h.state.report == nil, "changing source cannot expose the other backend's cached report")
h.respond(late)
assert(h.state.report == nil and h.state.polling, "an old HTTP reply must not overwrite an AIUsageBar read")
h.runs[1].callback({ exitCode = 0, stdout = "native" })
assert(h.state.report.collector_scope == "ai-usagebar")
local delayedNative = h.runs[1].callback
h.config.quota_backend = "shuvquota"; h.env.onConfigChanged()
assert(h.state.report.entries[1].stale, "restored Shuvquota snapshots remain historical until confirmed")
h.respond()
assert(not h.state.report.entries[1].stale and h.state.error.code == "")
delayedNative({ exitCode = 0, stdout = "native" })
assert(h.state.report.collector_scope ~= "ai-usagebar", "late CLI replies are isolated too")
h.clock = h.clock + 2000; h.env.onIpc("refresh")
h.doc.providers[2].accounts[1].status = "error"
h.doc.providers[2].accounts[1].error = "Authentication required"
h.respond()
assert(h.state.report.entries[2].stale and h.state.report.entries[2].fetched_at == fixture.generatedAt)
assert(h.state.report.entries[2].metrics[3].percent == 100, "partial failures retain dated same-source metrics")
h.clock = h.clock + 2000; h.env.onIpc("refresh")
late = #h.callbacks; h.clock = h.clock + 30000; h.env.update()
assert(not h.state.polling and h.state.error.code == "collector_timeout")
h.respond(late)
assert(h.state.error.code == "collector_timeout", "watchdog deadlines invalidate late callbacks")
h.config.shuvquota_url = "http://localhost:4790"; h.env.onConfigChanged()
assert(h.state.report == nil, "changing collector URL cannot reuse the previous collector's state")
assert(h.callbacks[#h.callbacks].request.url == "http://localhost:4790/api/quota")
h.config.shuvquota_url = "https://remote.invalid"; h.env.onConfigChanged()
assert(h.state.error.code == "collector_url" and not h.state.polling)
h.config.shuvquota_url = "http://127.0.0.1:4791"; h.httpAccepted = false; h.env.onConfigChanged()
assert(h.state.error.code == "collector_unavailable" and not h.state.polling)
local archives = host()
archives.respond()
archives.doc.generatedAt = "2026-11-11T12:00:10Z"
archives.doc.providers[1].accounts[1].windows[2].resetsAt = "2026-11-14T15:00:00Z"
archives.doc.providers[1].accounts[1].windows[2].percentRemaining = 100
archives.doc.providers[1].accounts[1].windows[2].percentUsed = 0
archives.clock = archives.clock + 2000; archives.env.onIpc("refresh"); archives.respond()
local foundArchive = false
for path in pairs(archives.files) do
    if path:find("weekly-reset-event-shuvquota-127-0-0-1-4789-", 1, true) then foundArchive = true end
end
assert(foundArchive, "reset archives from different collectors must not overwrite each other")
print("ok: Shuvquota adapter, credits, routing parity, source isolation, partial failures and HTTP lifecycle")
