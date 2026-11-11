-- Sanitized schema-2 contract fixture: no real accounts or provider responses.
return {
    schemaVersion = 2, complete = true, generatedAt = "2026-11-11T12:00:00Z",
    providers = {
        { id = "codex", accounts = { { label = "personal", status = "ok", windows = {
            { id = "session", label = "Session", percentRemaining = 75, percentUsed = 25,
                windowSeconds = 18000, resetsAt = "2026-11-11T15:00:00Z" },
            { id = "weekly", label = "Weekly", percentRemaining = 50, percentUsed = 50,
                windowSeconds = 604800, resetsAt = "2026-11-14T12:00:00Z" },
        }, extras = {
            { id = "banked-resets", value = "2" },
            { id = "banked-expires", value = "2026-11-17T08:00:00Z" },
        } } } },
        { id = "claude", accounts = { { label = "personal", status = "ok", windows = {
            { id = "session", label = "Session", percentRemaining = 80,
                windowSeconds = 18000, resetsAt = "2026-11-11T15:00:00Z" },
            { id = "weekly", label = "Weekly", percentRemaining = 45,
                windowSeconds = 604800, resetsAt = "2026-11-17T01:00:00Z" },
            { id = "fable-weekly", label = "Fable weekly", percentRemaining = 0,
                windowSeconds = 604800, resetsAt = "2026-11-17T01:00:00Z" },
        }, extras = {
            { id = "limit-resets", value = "2" },
            { id = "limit-reset-fable-1", reset = { type = "fable", count = 1, expiresAt = "2026-11-17T08:00:00Z" } },
            { id = "limit-reset-full-2", reset = { type = "full", count = 1, expiresAt = "2026-12-10T22:00:00Z" } },
        } } } },
        { id = "antigravity", accounts = { { label = "personal", status = "ok", windows = {
            -- Weekly deliberately precedes session; array order is not cadence.
            { id = "gemini-gemini-weekly", label = "Weekly", percentRemaining = 50,
                windowSeconds = 604800, resetsAt = "2026-11-14T12:00:00Z" },
            { id = "gemini-gemini-5h", label = "5h", percentRemaining = 74.875,
                windowSeconds = 18000, resetsAt = "2026-11-11T15:00:00Z" },
            { id = "3p-3p-weekly", label = "Claude And GPT Models Weekly", percentRemaining = 100,
                windowSeconds = 604800, resetsAt = "2026-11-18T12:00:00Z" },
            { id = "3p-3p-5h", label = "Claude And GPT Models 5h", percentRemaining = 100,
                windowSeconds = 18000, resetsAt = "2026-11-11T17:00:00Z" },
        }, extras = {} } } },
    },
}
