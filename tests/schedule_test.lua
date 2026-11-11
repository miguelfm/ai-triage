-- Real daily availability budgets, half-hour boundaries, and weekly/DST horizons.
local settings = {
    schedule_aware_triage = true, sleep_start_hour = 22, sleep_end_hour = 8.5,
    weekend_sleep_start_hour = 22, weekend_sleep_end_hour = 8.5, meal_pause_hours = 5,
}
noctalia = { getConfig = function(key) return settings[key] end }
local shared = dofile("shared.luau")
local cfg = shared.getScheduleConfig()
local function at(day, hour, month)
    return os.time({ year = 2026, month = month or 10, day = day,
        hour = math.floor(hour), min = (hour % 1) * 60, sec = 0 })
end
local function close(actual, expected, message)
    assert(math.abs(actual - expected) < 0.000001,
        string.format("%s: expected %.6f, got %.6f", message, expected, actual))
end
assert(cfg.sleepEndHour == 8.5 and cfg.weekendSleepEndHour == 8.5 and cfg.mealPauseHours == 5)
close(shared.nominalWeeklyActiveHours(cfg), 59.5, "nominal weekly budget")
for day = 12, 18 do
    close(shared.calculateActiveHours(at(day, 0), at(day + 1, 0), cfg, false), 8.5,
        "weekday/weekend daily budget")
end
close(shared.calculateActiveHours(at(12, 8.5), at(12, 22), cfg, true), 8.5,
    "daytime activity must not bypass the five-hour allowance")
close(shared.calculateActiveHours(at(12, 8), at(12, 8.5), cfg, false), 0.25,
    "08:00–08:30 remains off-hours (numerical floor)")
close(shared.calculateActiveHours(at(12, 8.5), at(12, 9), cfg, false), 0.5 * 8.5 / 13.5,
    "08:30 boundary is exact")
close(shared.calculateActiveHours(at(12, 21.5), at(12, 22.5), cfg, true), 0.5 * 8.5 / 13.5,
    "daytime activity must not extend the normal 22:00 cutoff")
close(shared.calculateActiveHours(at(12, 9), at(12, 10), cfg, false),
    shared.calculateActiveHours(at(12, 14), at(12, 15), cfg, false),
    "unscheduled breaks have no invented lunch window")
close(shared.calculateActiveHours(at(12, 0), at(19, 0), cfg, false), 59.5,
    "weekly horizon must honor the full schedule after 48h")
close(shared.calculateActiveHours(at(12, 0), at(26, 0), cfg, false), 119,
    "two-week horizon must honor the full schedule")
close(shared.calculateActiveHours(at(12, 23), at(13, 8.5), cfg, true), 2,
    "exceptional nighttime use credits only the immediate two-hour burst")
close(shared.calculateActiveHours(at(12, 23), at(13, 8.5), cfg, false), 0.25,
    "inactive nights must not receive an awake burst")
local timezone = os.getenv("TZ")
-- Render-local caching must preserve the numerical floor, availability flags
-- and independent configurations, then release everything at frame end.
local start, finish = at(12, 23), at(13, 8.5)
local active = shared.calculateActiveHours(start, finish, cfg, true)
local asleep = shared.calculateActiveHours(start, finish, cfg, false)
shared.beginCalculationFrame()
for _ = 1, 3 do
    close(shared.calculateActiveHours(start, finish, cfg, true), active, "cached awake burst")
    close(shared.calculateActiveHours(start, finish, cfg, false), asleep, "cached sleep floor")
end
local changed = {}
for k, v in pairs(cfg) do changed[k] = v end
changed.sleepStartHour, changed.weekendSleepStartHour = 23.5, 23.5
assert(shared.calculateActiveHours(start, finish, changed, false) > asleep,
    "a different schedule must not reuse another configuration's cached result")
shared.endCalculationFrame()
close(shared.calculateActiveHours(start, finish, cfg, false), asleep, "frame cleanup")

local transitions = timezone == "Europe/Brussels" and { {29, 3}, {25, 10} }
    or timezone == "America/New_York" and { {8, 3}, {1, 11} } or {}
for _, transition in ipairs(transitions) do
    local day, month = transition[1], transition[2]
    close(shared.calculateActiveHours(at(day, 0, month), at(day + 1, 0, month), cfg, false), 8.5,
        "DST changes sleep length, not the daytime budget")
    shared.beginCalculationFrame()
    for _ = 1, 2 do
        close(shared.calculateActiveHours(at(day, 0, month), at(day + 1, 0, month), cfg, false), 8.5,
            "cached DST day preserves the daytime budget")
    end
    shared.endCalculationFrame()
end
settings.meal_pause_hours = 24
local noTime = shared.getScheduleConfig()
close(shared.nominalWeeklyActiveHours(noTime), 0, "unavailable hours cannot produce negative capacity")
close(shared.calculateActiveHours(at(12, 0), at(13, 0), noTime, false), 0.25,
    "zero capacity retains only the existing numerical floor")
settings.schedule_aware_triage = false
close(shared.calculateActiveHours(at(12, 0), at(13, 0), shared.getScheduleConfig(), false), 24,
    "disabled schedule preserves calendar time")
print("ok: half-hour schedule, five-hour daily allowance, weekly horizons, nighttime exceptions and DST")
