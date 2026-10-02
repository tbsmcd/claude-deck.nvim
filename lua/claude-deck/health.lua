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

    for _, name in ipairs({ "renderer", "scrollback" }) do
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

    if config.options.notify.notifier then
        health.ok("Using a custom notifier")
    elseif vim.fn.has("mac") == 1 then
        health.ok("Notifications via osascript")
        if vim.env.__CFBundleIdentifier and vim.fn.executable("lsappinfo") == 1 then
            health.ok("Frontmost app check enabled (" .. vim.env.__CFBundleIdentifier .. ")")
        else
            health.info("Frontmost app check disabled; relying on FocusLost only")
        end
    elseif vim.fn.executable("notify-send") == 1 then
        health.ok("Notifications via notify-send")
    else
        health.warn("No notifier found", "Install notify-send or set `notify.notifier`")
    end

    if pcall(require, "fzf-lua") then
        health.ok("fzf-lua found (pickers support ctrl-v / ctrl-s)")
    else
        health.info("fzf-lua not found; using vim.ui.select")
    end
end

return M
