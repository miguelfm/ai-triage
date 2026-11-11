--!nonstrict
-- Pure schema-2 -> AI Triage report adapter. No credentials or network access.
local shared = require("./shared.luau")
local M = {}
local PROVIDERS = {
    codex = { "openai", "Codex" }, claude = { "anthropic", "Claude" },
    antigravity = { "antigravity", "Antigravity" },
}

local function number(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge and value or nil
end
local function count(value)
    if type(value) ~= "number" and type(value) ~= "string" then return nil end
    local n = tonumber(value)
    return n and n == math.floor(n) and n >= 0 and n <= 50 and n or nil
end
local function text(value, limit)
    return type(value) == "string" and value:gsub("[%c]", " "):sub(1, limit or 160) or ""
end
local function date(value)
    return type(value) == "string" and shared.parseIso(value) and value or nil
end

-- This API has no authentication. Deliberately keep configuration on loopback.
function M.endpoint(value)
    local base = tostring(value or "http://127.0.0.1:4789"):match("^%s*(.-)%s*$"):gsub("/+$", "")
    local host, port = base:match("^http://(127%.0%.0%.1):(%d+)$")
    if not host then host, port = base:match("^http://(localhost):(%d+)$") end
    if not host then host, port = base:match("^http://(%[::1%]):(%d+)$") end
    if base == "http://127.0.0.1" or base == "http://localhost" or base == "http://[::1]" then
        host, port = base:sub(8), "80"
    end
    if not host or not tonumber(port) or tonumber(port) < 1 or tonumber(port) > 65535 then return nil end
    port = tostring(tonumber(port))
    local canonical = "http://" .. host .. ":" .. port
    return canonical .. "/api/quota", "shuvquota-" .. host:gsub("[^%w]", "-") .. "-" .. port
end

local function metric(provider, window)
    if type(window) ~= "table" then return nil, "invalid quota window" end
    local id, label = text(window.id), text(window.label)
    local remaining, used = number(window.percentRemaining), number(window.percentUsed)
    if remaining then
        if remaining < 0 or remaining > 100 then return nil, "invalid remaining percentage" end
        if used and math.abs(used - (100 - remaining)) > 0.01 then return nil, "conflicting percentages" end
        used = 100 - remaining
    end
    if used == nil then return nil end -- unavailable, never zero
    if used < 0 or used > 100 then return nil, "invalid used percentage" end
    local duration = number(window.windowSeconds)
    if duration and (duration <= 0 or duration > 31622400) then return nil, "invalid quota duration" end
    local group = nil
    if provider == "antigravity" then
        if id == "gemini-gemini-5h" or id == "gemini-gemini-weekly" then label = "Gemini"
        elseif id == "3p-3p-5h" or id == "3p-3p-weekly" then label = "Claude & GPT OSS"
        else group = "Additional limits" end
    elseif provider == "codex" then
        if id == "session" then label = "Codex session"
        elseif id == "weekly" then label = "Codex weekly"
        else group = "Additional limits" end
    elseif provider == "claude" then
        if id == "session" then label = "Session (5h)"
        elseif id == "weekly" then label = "Weekly (7d)"
        elseif id == "fable-weekly" then label = "Fable (7d)"
        else group = "Additional limits" end
    end
    -- Missing cadence must not let a weekly-only response become a session.
    if not duration then group = "Additional limits" end
    if duration and not group then
        local weekly = id:find("weekly", 1, true) ~= nil
        if (weekly and duration <= 86400) or (not weekly and duration > 86400) then
            return nil, "quota identity and duration disagree"
        end
    end
    return { label = label ~= "" and label or id, percent = used,
        value = string.format("%.0f%%", used), window_secs = duration,
        reset_at = date(window.resetsAt), group = group,
        headline = "percent",
        severity = used >= 90 and "critical" or used >= 75 and "high" or used >= 50 and "mid" or "low" }
end

local RESET_TITLES = { fable = "Fable reset", full = "Full reset", weekly = "Weekly reset",
    session = "Session reset", ["new-model"] = "New-model reset", other = "Reset scope not reported" }

local function resetCredits(entry, provider, extras, now)
    local total, groups, nextExpiry = nil, {}, nil
    for _, extra in ipairs(extras) do
        if type(extra) == "table" then
            if extra.id == "banked-resets" or extra.id == "limit-resets" then total = count(extra.value) end
            if extra.id == "banked-expires" then nextExpiry = date(extra.value) end
            if type(extra.reset) == "table" then groups[#groups + 1] = extra.reset end
        end
    end
    if provider == "codex" and total then
        -- This summary cannot reconstruct individual grants or their expiries.
        entry.reset_credits = { available = total, credits = {}, partial = true, next_expires_at = nextExpiry }
    elseif provider == "claude" and (#groups > 0 or total ~= nil) then
        local credits, available, represented, malformed = {}, 0, 0, false
        for _, grant in ipairs(groups) do
            local n, starts, expires = count(grant.count), date(grant.startsAt), date(grant.expiresAt)
            represented = represented + (n or 0)
            local title = RESET_TITLES[grant.type] or RESET_TITLES.other
            if not n or (grant.startsAt ~= nil and not starts) or (grant.expiresAt ~= nil and not expires) then
                malformed = true
            elseif starts and shared.parseIso(starts) > now then
                entry.sections[#entry.sections + 1] = { type = "text", label = "Scheduled resets",
                    value = tostring(n) .. " " .. title .. " · from " .. starts }
            elseif not expires or shared.parseIso(expires) > now then
                available = available + n
                if available > 50 then malformed = true break end
                for _ = 1, n do
                    credits[#credits + 1] = { title = title, expires_at = expires,
                        weekly = grant.type == "full" or grant.type == "weekly" or grant.type == "fable" }
                end
            end
        end
        if malformed or (total and #groups > 0 and represented ~= total) then
            if total then entry.reset_credits = { available = total, credits = {}, partial = true } end
        else
            entry.reset_credits = { available = #groups > 0 and available or total, credits = credits }
        end
    end
end

function M.normalize(document, scope, now, maxAge)
    now, maxAge = now or os.time(), maxAge or 900
    if type(document) ~= "table" or document.schemaVersion ~= 2 or document.complete ~= true
        or type(document.providers) ~= "table" then return nil, "Expected a completed Shuvquota schema-2 snapshot" end
    local generated = date(document.generatedAt)
    local at = generated and shared.parseIso(generated)
    if not at or at > now + 60 then return nil, "Invalid or future snapshot timestamp" end
    if #document.providers > 64 or (#document.providers == 0 and next(document.providers) ~= nil) then
        return nil, "Invalid provider array"
    end
    local report = { schema_version = 1, collector_scope = scope, entries = {} }
    local seen = {}
    for _, provider in ipairs(document.providers) do
        if type(provider) ~= "table" or type(provider.id) ~= "string"
            or type(provider.accounts) ~= "table" or #provider.accounts > 64
            or (#provider.accounts == 0 and next(provider.accounts) ~= nil) then
            return nil, "Invalid provider or account array"
        end
        local meta = PROVIDERS[provider.id]
        if meta then
            local accounts = provider.accounts
            if #accounts == 0 then
                accounts = { { label = "unconfigured", status = "error", windows = {},
                    error = provider.error or "Authentication required; no Shuvquota account configured" } }
            end
            for _, account in ipairs(accounts) do
                if type(account) ~= "table" or type(account.label) ~= "string" or account.label == ""
                    or #account.label > 120 or account.label:find("[%c]") then return nil, "Invalid account label" end
                local id = meta[1] .. "@" .. account.label
                if seen[id] then return nil, "Duplicate provider/account identity" end
                seen[id] = true
                local entry = { id = id, name = meta[2], display_name = meta[2] .. " · " .. account.label,
                    short_name = meta[2], plan = text(account.plan), metrics = {},
                    fetched_at = generated, stale = now - at > maxAge,
                    collector_backend = "shuvquota", collector_provider = provider.id, collector_scope = scope,
                    sections = { { type = "text", label = "Source", value = "Shuvquota" },
                        { type = "text", label = "Observation", value = "Snapshot completed: " .. generated } } }
                local problem = text(account.error) ~= "" and text(account.error) or nil
                if account.status ~= "ok" then problem = problem or "Authentication required; quota unavailable" end
                if entry.stale then problem = problem or "Quota snapshot is stale; refresh Shuvquota" end
                if type(account.windows) ~= "table" or #account.windows > 128 then
                    problem = "schema mismatch: invalid quota windows"
                else
                    for _, window in ipairs(account.windows) do
                        local converted, err = metric(provider.id, window)
                        if err then problem = "schema mismatch: " .. err
                        elseif converted then entry.metrics[#entry.metrics + 1] = converted end
                    end
                end
                if #entry.metrics == 0 then problem = problem or "schema mismatch: no measured quota windows" end
                entry.status, entry.error = problem and "error" or "ready", problem
                if not problem then
                    local extras = type(account.extras) == "table" and account.extras or {}
                    if #extras <= 256 then resetCredits(entry, provider.id, extras, now) end
                end
                report.entries[#report.entries + 1] = entry
            end
        end
    end
    if #document.providers > 0 and #report.entries == 0 then return nil, "No supported Shuvquota providers" end
    return report
end

return M
