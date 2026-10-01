# claude-terminals.nvim

Run multiple [Claude Code](https://docs.claude.com/en/docs/claude-code) sessions side by side in Neovim terminals, and always know which one needs you.

- **Status at a glance**: each terminal's winbar shows its id, status, task title and cwd, with a color per status
- **Desktop notifications** when a session finishes or asks for permission (skipped for the terminal you are looking at)
- **Many sessions**: split right / below, hide with `:q` (the session keeps running), bring back from a picker
- **Open in any directory** from a directory picker
- **Fork** a session into a new terminal (`--resume <id> --fork-session`)
- **Focus mode**: a new tab with file tree | editor | terminal in the terminal's cwd; toggle back to your previous layout
- **Cross-session awareness**: Claude inside a terminal can run `ct list` / `ct read <id>` to see what the other sessions are doing

```
 #1 Running │ Refactor the parser modu…  ~/src/app
 #2 Waiting │ Fix flaky login test       ~/src/app
 #3 Needs you │ Upgrade to React 19      ~/src/web
```

## Requirements

- Neovim >= 0.11
- [Claude Code](https://docs.claude.com/en/docs/claude-code) (`claude` on `PATH`)
- Optional: [fzf-lua](https://github.com/ibhagwan/fzf-lua) (pickers with split keys; falls back to `vim.ui.select`)
- Optional: [nvim-tree.lua](https://github.com/nvim-tree/nvim-tree.lua) (focus mode tree; falls back to netrw)
- Notifications: `osascript` on macOS, `notify-send` on Linux

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "tbsmcd/claude-terminals.nvim",
    cmd = "ClaudeTerminals",
    opts = {},
    keys = {
        { "<leader>cc", function() require("claude-terminals").toggle() end, desc = "Claude: open / focus / add" },
        { "<leader>cv", function() require("claude-terminals").new("right") end, desc = "Claude: new to the right" },
        { "<leader>cs", function() require("claude-terminals").new("below") end, desc = "Claude: new below" },
        { "<leader>cl", function() require("claude-terminals").list() end, desc = "Claude: list terminals" },
        { "<leader>cd", function() require("claude-terminals").pick_dir() end, desc = "Claude: new in directory" },
        { "<leader>cf", function() require("claude-terminals").fork() end, desc = "Claude: fork session" },
        { "<leader>cr", function() require("claude-terminals").rename() end, desc = "Claude: rename task" },
        { "<leader>co", function() require("claude-terminals").focus() end, desc = "Claude: focus mode" },
    },
}
```

No keymaps are created by default.

## Usage

| Lua API | Command | Description |
| --- | --- | --- |
| `toggle()` | `:ClaudeTerminals` | Outside a terminal: focus a visible one, or open a new one. Inside: add one to the right |
| `new(where?)` | `:ClaudeTerminals new [right\|below]` | Open a new terminal by splitting the current window |
| `list(opts?)` | `:ClaudeTerminals list` | Pick a terminal (including hidden ones) to show |
| `pick_dir(opts?)` | `:ClaudeTerminals dir` | Pick a directory and open a new terminal there |
| `fork(where?)` | `:ClaudeTerminals fork` | Fork the current session into a new terminal |
| `rename()` | `:ClaudeTerminals rename` | Rename the current task |
| `show_settings()` | `:ClaudeTerminals settings` | Show the Claude Code settings JSON (hooks, permissions) |
| `focus()` | `:ClaudeTerminals focus` | Toggle focus mode |
| `show(id, where?)` | `:ClaudeTerminals show <id>` | Show a terminal by id |

Where a new terminal opens (without `where`):

- inside a terminal: split to the right
- in an empty, unnamed buffer (e.g. right after starting Neovim): in place
- otherwise: at the far right (`width_ratio` of the editor width)

In the fzf-lua pickers, `enter` opens with the rule above, `ctrl-v` splits right and `ctrl-s` splits below.

Closing a terminal window (`:q`) only hides it. The Claude session keeps running and still updates its status and sends notifications. Exit Claude (`/exit`) to end it.

> [!NOTE]
> Neovim's terminal sends `<Esc>` to the running program. If you map `<Esc>` in terminal mode to leave terminal mode, use `<C-c>` to interrupt Claude.

### Status

| Status | Trigger | Notification |
| --- | --- | --- |
| New | started / `SessionStart` | |
| Running | `UserPromptSubmit`, `PostToolUse` | |
| Waiting | `Stop` | yes |
| Needs you | `Notification` (permission prompt etc.) | yes |
| Exited | process exited | |

The task title is the beginning of the first prompt (slash commands are ignored). `/clear` resets it.

### Notifications

A notification is skipped only when all of these hold:

1. Neovim has focus (`FocusGained` / `FocusLost`)
2. the current window shows that terminal
3. on macOS, the terminal app running Neovim is the frontmost app (checked with `lsappinfo`, as a backup for terminals that do not report focus)

### `ct` command for Claude

Inside a terminal, `ct` is on `PATH` and Claude is told about it with `--append-system-prompt`:

```sh
ct list            # id, status, title, cwd, session_id and transcript path of every terminal
ct read 2 [count]  # recent messages of terminal #2 (default 20)
```

Both are allowed without a permission prompt. So you can ask, for example, "check that this doesn't conflict with what #1 is doing".

> [!WARNING]
> `ct read` parses Claude Code's transcript files, whose format is internal and may change.

## Configuration

Defaults:

```lua
require("claude-terminals").setup({
    cmd = { "claude" },
    claude_settings = true, -- pass hooks and `ct` permissions with `claude --settings`
    title_width = 24,
    width_ratio = 0.4,
    dir_roots = {}, -- e.g. { "~/src" }: direct children are offered by pick_dir()
    zoxide = true, -- also offer `zoxide query --list` in pick_dir()
    labels = {
        idle = "New",
        running = "Running",
        waiting = "Waiting",
        attention = "Needs you",
        exited = "Exited",
        untitled = "(new task)",
    },
    notify = {
        enabled = true,
        states = { "waiting", "attention" },
        skip_when_watching = true,
        notifier = nil, -- function({ title, subtitle, body, state, terminal })
    },
    picker = "auto", -- "auto" | "fzf-lua" | "select"
    focus = {
        tree = "auto", -- "auto" | false | function(cwd)
    },
    cli = {
        enabled = true, -- `ct` on PATH and allowed without a prompt
        system_prompt = true, -- tell Claude about `ct`
    },
})
```

### Highlights

| Group | Default |
| --- | --- |
| `ClaudeTerminalsIdle` | gray |
| `ClaudeTerminalsRunning` | blue |
| `ClaudeTerminalsWaiting` | green |
| `ClaudeTerminalsAttention` | orange |
| `ClaudeTerminalsExited` | dark |
| `ClaudeTerminalsCwd` | links to `Directory` |

## How it works

- Each terminal runs `claude --settings <json>`. The JSON registers [hooks](https://docs.claude.com/en/docs/claude-code/hooks) that call `bin/claude-terminals-hook`, which forwards the event to Neovim over `$NVIM` (`nvim --server $NVIM --remote-expr`). Your `~/.claude/settings.json` is not modified, and `claude` started elsewhere is unaffected.
- Terminals are identified by `$CLAUDE_TERMINALS_ID`.

### Without `--settings`

Set `claude_settings = false` to start `claude` without `--settings`. Without the hooks, status, notifications, task titles and `fork()` do not work, and `ct` asks for permission.

To keep them, add the hooks to your own Claude Code settings (e.g. `~/.claude/settings.json`). `:ClaudeTerminals settings` shows the JSON. The hook script does nothing outside claude-terminals, so registering it globally is safe.

## Limitations

- Interrupting Claude does not fire the `Stop` hook, so the status stays "Running" until the next prompt.
- On macOS, switching tabs or panes inside the terminal app is not detected as losing focus.
- Terminals live in one Neovim instance and are lost when Neovim exits (sessions can be resumed with `claude --resume`).

## Health check

```vim
:checkhealth claude-terminals
```

## Development

```sh
sh tests/smoke.sh
```

## License

MIT
