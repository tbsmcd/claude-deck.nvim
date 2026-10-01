-- Desktop notifications.
local config = require("claude-terminals.config")
local state = require("claude-terminals.state")

local M = {}

-- Bundle id of the terminal app running Neovim (set by macOS for apps launched from the GUI)
local TERMINAL_BUNDLE_ID = vim.env.__CFBundleIdentifier

function M.desktop_notify(title, subtitle, body)
    if vim.fn.has("mac") == 1 then
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
    elseif vim.fn.executable("notify-send") == 1 then
        vim.system({ "notify-send", title .. ": " .. subtitle, body })
    end
end

-- callback(true) when the terminal app running Neovim is the frontmost app.
-- Backs up FocusLost, which some terminals do not report. Assumes true when unknown.
local function terminal_is_frontmost(callback)
    if vim.fn.has("mac") == 0 or not TERMINAL_BUNDLE_ID or vim.fn.executable("lsappinfo") == 0 then
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
            callback(bundle_id == nil or bundle_id == TERMINAL_BUNDLE_ID)
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
            M.desktop_notify(payload.title, payload.subtitle, payload.body)
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
