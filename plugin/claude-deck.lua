if vim.g.loaded_claude_deck then
    return
end
vim.g.loaded_claude_deck = true

vim.api.nvim_create_user_command("ClaudeDeck", function(opts)
    require("claude-deck").command(opts.fargs, opts.range > 0 and { opts.line1, opts.line2 } or nil)
end, {
    nargs = "*",
    range = true,
    desc = "claude-deck: toggle / new / list / dir / fork / rename / focus / location / settings / show",
    complete = function(arg_lead, cmdline)
        local args = vim.split(cmdline, "%s+", { trimempty = true })
        local completing_sub = #args == 1 or (#args == 2 and arg_lead ~= "")
        local candidates = completing_sub and require("claude-deck").subcommands or { "right", "below" }
        return vim.tbl_filter(function(c)
            return vim.startswith(c, arg_lead)
        end, candidates)
    end,
})
