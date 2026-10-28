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

    -- PreToolUse is handled apart from the state machine: it answers `ct spawn` / `ct send` for terminals
    -- with orchestration on (see allow_orchestration_call())
    hooks.PreToolUse = {
        { matcher = "Bash", hooks = { { type = "command", command = script .. " PreToolUse", timeout = 5 } } },
    }

    local settings = { hooks = hooks }
    if config.options.cli.enabled then
        -- `ct list` / `ct read` / `ct wait` only read state, `ct title` only names the terminal it runs in
        -- and `ct open` / `ct diff` only show things in the editor, so allow them without a prompt
        settings.permissions = {
            allow = {
                "Bash(ct list)",
                "Bash(ct list:*)",
                "Bash(ct read:*)",
                "Bash(ct title:*)",
                "Bash(ct open:*)",
                "Bash(ct diff)",
                "Bash(ct diff:*)",
                "Bash(ct wait:*)",
            },
        }
        if config.options.cli.allow_orchestration then
            -- opt-in: an orchestrator may create and drive worker sessions without a prompt
            table.insert(settings.permissions.allow, "Bash(ct spawn:*)")
            table.insert(settings.permissions.allow, "Bash(ct send:*)")
        end
    end
    return vim.json.encode(settings)
end

local function handle(term, event, data)
    for _, key in ipairs({ "cwd", "session_id", "transcript_path" }) do
        if type(data[key]) == "string" and data[key] ~= "" then
            term[key] = data[key]
        end
    end
    state.changed()

    if event == "SessionStart" then
        -- A title set by the user is kept
        if data.source == "clear" and term.title_source ~= "user" then
            state.set_title(term, "")
        end
        state.set_state(term, "idle")
    elseif event == "UserPromptSubmit" then
        local prompt = type(data.prompt) == "string" and state.normalize_prompt(data.prompt) or ""
        if term.title == "" and prompt ~= "" and not prompt:match("^%s*/") then
            state.set_title(term, state.make_title(prompt), "auto")
        end
        -- The task sent with `ct send` (or the first prompt of `ct spawn`) has arrived when the
        -- submitted prompt is its text, or contains it (a draft was in the input). A request
        -- marked lost is revived when its prompt turns up after all.
        local request = term.last_request
        if request and not request.received then
            local text = state.normalize_prompt(request.text)
            if text ~= "" and (prompt == text or prompt:find(text, 1, true)) then
                request.received = true
                request.lost = false
            end
        end
        state.set_state(term, "running")
    elseif event == "PostToolUse" then
        -- Work resumed after a permission prompt
        if term.state ~= "running" then
            state.set_state(term, "running")
        end
    elseif event == "Stop" then
        local request = term.last_request
        if request and request.received and not request.completed then
            request.completed = true
        elseif request and not request.received and not request.completed then
            -- The turn ended without our prompt: it will not be received any more
            request.lost = true
        end
        state.set_state(term, "waiting")
    elseif event == "Notification" then
        -- idle_prompt is a reminder after Stop; stay in "waiting"
        if data.notification_type == "idle_prompt" then
            return
        end
        state.set_state(term, "attention", data.message)
    end
end

local ALLOW_DECISION = vim.json.encode({
    hookSpecificOutput = {
        hookEventName = "PreToolUse",
        permissionDecision = "allow",
        permissionDecisionReason = "claude-deck: orchestration is on for this terminal",
    },
})

-- Whether a PreToolUse input is a plain `ct spawn` / `ct send` Bash call
local function is_orchestration_call(data)
    if data.tool_name ~= "Bash" or type(data.tool_input) ~= "table" then
        return false
    end
    local command = data.tool_input.command
    if type(command) ~= "string" then
        return false
    end
    command = vim.trim(command)
    command = command:gsub("^command%s+", "")
    return command:match("^ct%s+spawn%f[%W]") ~= nil or command:match("^ct%s+send%f[%W]") ~= nil
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

    if event == "PreToolUse" then
        -- Answered at once (bin/claude-deck-hook prints the result); never changes the state
        local term = state.get(id)
        if term and term.orchestration and is_orchestration_call(data) then
            return ALLOW_DECISION
        end
        return ""
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
