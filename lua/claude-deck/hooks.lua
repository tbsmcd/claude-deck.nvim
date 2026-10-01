-- Receives Claude Code hook events from bin/claude-deck-hook.
local state = require("claude-deck.state")

local M = {}

M.EVENTS = { "SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "Notification" }

-- Claude Code settings passed with `claude --settings`, so hooks apply only to these terminals
function M.settings_json()
    local config = require("claude-deck.config")
    local script = vim.fn.shellescape(config.bin_dir .. "/claude-deck-hook")
    local hooks = {}
    for _, event in ipairs(M.EVENTS) do
        hooks[event] = {
            { hooks = { { type = "command", command = script .. " " .. event, timeout = 5 } } },
        }
    end

    local settings = { hooks = hooks }
    if config.options.cli.enabled then
        -- `ct list` / `ct read` only read state, so allow them without a prompt
        settings.permissions = { allow = { "Bash(ct list)", "Bash(ct read:*)" } }
    end
    return vim.json.encode(settings)
end

local function handle(term, event, data)
    for _, key in ipairs({ "cwd", "session_id", "transcript_path" }) do
        if type(data[key]) == "string" and data[key] ~= "" then
            term[key] = data[key]
        end
    end

    if event == "SessionStart" then
        if data.source == "clear" then
            state.set_title(term, "")
        end
        state.set_state(term, "idle")
    elseif event == "UserPromptSubmit" then
        local prompt = type(data.prompt) == "string" and data.prompt or ""
        if term.title == "" and prompt ~= "" and not prompt:match("^%s*/") then
            state.set_title(term, state.make_title(prompt))
        end
        state.set_state(term, "running")
    elseif event == "PostToolUse" then
        -- Work resumed after a permission prompt
        if term.state ~= "running" then
            state.set_state(term, "running")
        end
    elseif event == "Stop" then
        state.set_state(term, "waiting")
    elseif event == "Notification" then
        -- idle_prompt is a reminder after Stop; stay in "waiting"
        if data.notification_type == "idle_prompt" then
            return
        end
        state.set_state(term, "attention", data.message)
    end
end

-- Called via `nvim --remote-expr`. `path` is a temp file with the hook's JSON input.
function M.on_hook(id, event, path)
    local ok, data = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    end)
    os.remove(path)
    if not ok or type(data) ~= "table" then
        data = {}
    end

    vim.schedule(function()
        local term = state.get(id)
        if term then
            handle(term, event, data)
        end
    end)
    return ""
end

return M
