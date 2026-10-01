if vim.g.loaded_claude_terminals then
    return
end
vim.g.loaded_claude_terminals = true

vim.api.nvim_create_user_command("ClaudeTerminals", function(opts)
    require("claude-terminals").command(opts.fargs)
end, {
    nargs = "*",
    desc = "claude-terminals: toggle / new / list / dir / fork / rename / focus / show",
    complete = function(arg_lead, cmdline)
        local args = vim.split(cmdline, "%s+", { trimempty = true })
        local completing_sub = #args == 1 or (#args == 2 and arg_lead ~= "")
        local candidates = completing_sub and require("claude-terminals").subcommands or { "right", "below" }
        return vim.tbl_filter(function(c)
            return vim.startswith(c, arg_lead)
        end, candidates)
    end,
})
