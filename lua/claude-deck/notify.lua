-- Desktop notifications.
local config = require("claude-deck.config")
local state = require("claude-deck.state")

local M = {}

-- Bundle id of the terminal app running Neovim (set by macOS for apps launched from the GUI)
M.bundle_id = vim.env.__CFBundleIdentifier

-- The method "auto" picks: terminal-notifier, then osascript on macOS; notify-send elsewhere.
-- nil when none is available.
function M.auto_method()
    if vim.fn.has("mac") == 1 then
        if vim.fn.executable("terminal-notifier") == 1 then
            return "terminal-notifier"
        end
        return vim.fn.executable("osascript") == 1 and "osascript" or nil
    end
    return vim.fn.executable("notify-send") == 1 and "notify-send" or nil
end

-- The built-in method in use (notify.method with "auto" resolved), or nil.
function M.method()
    local method = config.options.notify.method
    if method == nil or method == "auto" then
        return M.auto_method()
    end
    return method
end

-- Whether clicking a notification of this method brings back the terminal app.
function M.returns_to_terminal(method)
    return method == "terminal-notifier" or method == "osc"
end

-- True when Neovim runs in a terminal (a TUI is attached), not in a GUI or --headless.
local function has_tty_ui()
    for _, ui in ipairs(vim.api.nvim_list_uis()) do
        if ui.stdout_tty then
            return true
        end
    end
    return false
end

-- Writes an escape sequence to the terminal running Neovim.
local function send_to_terminal(seq)
    if vim.api.nvim_ui_send then
        -- Neovim 0.12+: the TUI may run in another process than the one running this code
        vim.api.nvim_ui_send(seq)
    else
        -- Neovim 0.11: stdout is the RPC channel to the TUI process; stderr is the terminal
        vim.api.nvim_chan_send(vim.v.stderr, seq)
    end
end

-- terminal-notifier reads its arguments as NSUserDefaults, so a value starting with
-- "-", "[", "(" or "{" is not taken as a string unless it starts with a backslash.
local function tn_value(value)
    if value:match("^[%-%[%(%{]") then
        return "\\" .. value
    end
    return value
end

-- Bytes kept of an OSC notification text
local OSC_MAX_BYTES = 500

local senders = {
    ["terminal-notifier"] = function(title, subtitle, body, id)
        local cmd = { "terminal-notifier", "-title", tn_value(title) }
        if subtitle ~= "" then
            vim.list_extend(cmd, { "-subtitle", tn_value(subtitle) })
        end
        if body ~= "" then
            vim.list_extend(cmd, { "-message", tn_value(body) })
        end
        if M.bundle_id then
            vim.list_extend(cmd, { "-activate", M.bundle_id })
        end
        -- Replaces the previous notification of the same terminal
        vim.list_extend(cmd, { "-group", "claude-deck-" .. tostring(id or 0) })
        vim.system(cmd)
    end,
    osc = function(title, subtitle, body)
        if not has_tty_ui() then
            return
        end
        -- Control characters (ESC, BEL, newlines, C1 such as ST) would end or break the sequence
        local text = (title .. ": " .. subtitle .. " — " .. body)
            :gsub("%s+", " ")
            :gsub("%c", "")
            :gsub("\194[\128-\159]", "")
        text = vim.trim(text)
        if #text > OSC_MAX_BYTES then
            -- Cut at a character boundary
            text = text:sub(1, OSC_MAX_BYTES + vim.str_utf_start(text, OSC_MAX_BYTES + 1))
        end
        send_to_terminal("\27]9;" .. text .. "\7")
    end,
    osascript = function(title, subtitle, body)
        vim.system({
            "osascript",
            "-e",
            "on run argv",
            "-e",
            "display notification (item 1 of argv) with title (item 2 of argv) subtitle (item 3 of argv)",
            "-e",
            "end run",
            body,
            title,
            subtitle,
        })
    end,
    ["notify-send"] = function(title, subtitle, body)
        vim.system({ "notify-send", title .. ": " .. subtitle, body })
    end,
}

-- id: claude-deck terminal id, used to group notifications of the same terminal.
function M.desktop_notify(title, subtitle, body, id)
    local sender = senders[M.method() or ""]
    if sender then
        sender(title, subtitle, body, id)
    end
end

-- callback(true) when the terminal app running Neovim is the frontmost app.
-- Backs up FocusLost, which some terminals do not report. Assumes true when unknown.
local function terminal_is_frontmost(callback)
    if vim.fn.has("mac") == 0 or not M.bundle_id or vim.fn.executable("lsappinfo") == 0 then
        callback(true)
        return
    end

    vim.system({ "lsappinfo", "front" }, { text = true }, function(front)
        local asn = vim.trim(front.stdout or "")
        if front.code ~= 0 or asn == "" then
            callback(true)
            return
        end
        vim.system({ "lsappinfo", "info", "-only", "bundleid", asn }, { text = true }, function(info)
            local bundle_id = (info.stdout or ""):match('"CFBundleIdentifier"="([^"]+)"')
            callback(bundle_id == nil or bundle_id == M.bundle_id)
        end)
    end)
end

local function is_watching(term, callback)
    if not state.nvim_focused or vim.api.nvim_get_current_buf() ~= term.buf then
        callback(false)
        return
    end
    terminal_is_frontmost(vim.schedule_wrap(callback))
end

function M.on_state(term, new_state, message)
    local opts = config.options.notify
    if not opts.enabled or not vim.tbl_contains(opts.states, new_state) then
        return
    end

    local payload = {
        title = "Claude: " .. state.label(new_state),
        subtitle = state.title(term),
        body = message or vim.fn.fnamemodify(term.cwd, ":~"),
        state = new_state,
        terminal = term,
    }
    local function send()
        if opts.notifier then
            opts.notifier(payload)
        else
            M.desktop_notify(payload.title, payload.subtitle, payload.body, term.id)
        end
    end

    if not opts.skip_when_watching then
        send()
        return
    end
    is_watching(term, function(watching)
        if not watching then
            send()
        end
    end)
end

return M
