local M = {}

function M.check()
    local health = vim.health
    local config = require("claude-deck.config")

    health.start("claude-deck")

    if vim.fn.has("nvim-0.11") == 1 then
        health.ok("Neovim >= 0.11")
    else
        health.error("Neovim 0.11 or later is required")
    end

    local cmd = config.options.cmd[1]
    if vim.fn.executable(cmd) == 1 then
        health.ok("`" .. cmd .. "` is executable")
    else
        health.error("`" .. cmd .. "` was not found", "Install Claude Code or set `cmd`")
    end

    if config.options.claude_settings then
        health.ok("Hooks are passed with `claude --settings`")
    else
        health.info(
            "`claude_settings` is false: status, notifications, task titles and fork need the hooks "
                .. "in your own Claude Code settings (`:ClaudeDeck settings`)"
        )
    end

    for _, name in ipairs({ "renderer", "scrollback", "keymaps.send_location" }) do
        if config.invalid[name] ~= nil then
            health.warn("`" .. name .. "`: invalid value " .. vim.inspect(config.invalid[name]) .. ", using false")
        end
    end
    local renderer = config.options.renderer
    if renderer then
        health.info("renderer: " .. renderer .. " (CLAUDE_CODE_NO_FLICKER is set for terminals)")
    elseif vim.env.CLAUDE_CODE_NO_FLICKER then
        health.info(
            "renderer: false (CLAUDE_CODE_NO_FLICKER=" .. vim.env.CLAUDE_CODE_NO_FLICKER .. " is inherited from Neovim)"
        )
    else
        health.info("renderer: false (CLAUDE_CODE_NO_FLICKER is unset in Neovim; Claude Code's `tui` setting decides)")
    end

    for _, script in ipairs({ "claude-deck-hook", "ct" }) do
        if vim.fn.executable(config.bin_dir .. "/" .. script) == 1 then
            health.ok("bin/" .. script .. " is executable")
        else
            health.error("bin/" .. script .. " is not executable", "chmod +x " .. config.bin_dir .. "/" .. script)
        end
    end

    if config.invalid["notify.method"] ~= nil then
        health.warn(
            "`notify.method`: cannot use " .. vim.inspect(config.invalid["notify.method"]) .. ", using \"auto\""
        )
    end
    local notify = require("claude-deck.notify")
    local method = notify.method()
    local is_mac = vim.fn.has("mac") == 1
    if config.options.notify.notifier then
        health.ok("Using a custom notifier")
    elseif method then
        local how = config.options.notify.method == "auto" and " (auto)" or ""
        if notify.returns_to_terminal(method) then
            health.ok("Notifications via " .. method .. how .. "; clicking one brings back the terminal app")
        else
            health.ok("Notifications via " .. method .. how)
            if is_mac then
                health.info("Clicking a notification does not bring back the terminal app")
            end
        end
        if method == "osc" then
            health.info("The terminal sends the notification (OSC 9); allow notifications in its settings")
        end
    elseif is_mac then
        health.warn(
            "No notifier found",
            "Install terminal-notifier (`brew install terminal-notifier`), set `notify.method = \"osc\"` "
                .. "or set `notify.notifier`"
        )
    else
        health.warn("No notifier found", "Install notify-send, set `notify.method = \"osc\"` or set `notify.notifier`")
    end
    if
        is_mac
        and not config.options.notify.notifier
        and config.options.notify.method == "auto"
        and vim.fn.executable("terminal-notifier") == 0
    then
        health.info(
            "terminal-notifier not found. Install it (`brew install terminal-notifier`) so that "
                .. "clicking a notification brings back the terminal app"
        )
    end
    if is_mac then
        if notify.bundle_id and vim.fn.executable("lsappinfo") == 1 then
            health.ok("Frontmost app check enabled (" .. notify.bundle_id .. ")")
        else
            health.info("Frontmost app check disabled; relying on FocusLost only")
        end
    end

    if pcall(require, "fzf-lua") then
        health.ok("fzf-lua found (pickers support ctrl-v / ctrl-s)")
    else
        health.info("fzf-lua not found; using vim.ui.select")
    end
end

return M
