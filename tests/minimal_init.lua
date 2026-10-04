-- Minimal config for tests/smoke.sh. Replaces `claude` with a dummy process that records its
-- arguments (args.<id>), CLAUDE_CODE_NO_FLICKER (env.<id>, "unset" when not set) and what is
-- typed into it (stdin.<id>, appended as it arrives: raw mode, no echo).
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local out = assert(vim.env.TEST_OUT, "TEST_OUT is not set")
_G.notifications = {}

_G.T_opts = {
    cmd = {
        "sh",
        "-c",
        'printf "%s\\n" "$@" > "' .. out .. '/args.$CLAUDE_DECK_ID"; '
            .. 'echo "CLAUDE_CODE_NO_FLICKER=${CLAUDE_CODE_NO_FLICKER-unset}" > "' .. out .. '/env.$CLAUDE_DECK_ID"; '
            .. "stty raw -echo 2>/dev/null; "
            .. 'exec cat >> "' .. out .. '/stdin.$CLAUDE_DECK_ID"',
        "dummy",
    },
    dir_roots = { root .. "/tests/fixtures/roots" },
    zoxide = false,
    picker = "fzf-lua",
    notify = {
        notifier = function(payload)
            table.insert(_G.notifications, payload.title .. " | " .. payload.subtitle)
        end,
    },
}
require("claude-deck").setup(_G.T_opts)

-- Stub fzf-lua so tests can trigger picker actions directly
package.loaded["fzf-lua"] = {
    fzf_exec = function(lines, opts)
        _G.last_picker = { lines = lines, opts = opts }
    end,
}

-- Helpers called from the test script
function _G.T_run(path)
    return tostring(assert(loadfile(path))())
end

function _G.T_winbar()
    return vim.api.nvim_eval_statusline(vim.wo.winbar, { winid = 0, use_winbar = true }).str
end

function _G.T_statusline()
    return vim.api.nvim_eval_statusline(vim.wo.statusline, { winid = 0 }).str
end

-- Runs fn and returns the last message given to vim.notify ("none" without one)
function _G.T_notify(fn)
    local message = "none"
    local notify = vim.notify
    vim.notify = function(msg)
        message = msg
    end
    local ok, err = pcall(fn)
    vim.notify = notify
    assert(ok, err)
    return message
end

-- index nil: no selection (nothing matches the query)
function _G.T_pick(action, index)
    local p = _G.last_picker
    p.opts.actions[action](index and { p.lines[index] } or {})
end
