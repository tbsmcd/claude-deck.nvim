# claude-deck.nvim User Guide

English | [日本語](guide.ja.md)

This guide walks through using claude-deck.nvim after you install it, following a typical session. For the full list of options, see the [README](../README.md) and the help (`:help claude-deck`).

## 0. Assumptions in this guide

**claude-deck.nvim does not create a single keymap.** Keys such as `<leader>cc` in this guide are the ones the author maps in their own `init.lua`. Without the same settings, pressing them does nothing: to use them, you have to add the mappings to your own `init.lua`.

This guide assumes the settings below. If your own `init.lua` differs, read the guide accordingly.

| Item | Assumed in this guide | Where it is set |
|---|---|---|
| `<leader>` | Space (`vim.g.mapleader = " "`) | Your own `init.lua` |
| Keys such as `<leader>cc` | As in the README installation example (lazy.nvim `keys`) | Your own `init.lua` |
| `<leader>cp` | `send_location()` is mapped with `mode = { "n", "x" }` | Your own `init.lua` |
| `<Esc>` in terminal mode | A mapping leaves terminal mode with `<Esc>` (the README's example) | Your own `init.lua` |
| `<C-h>` / `<C-j>` / `<C-k>` / `<C-l>` | Mappings move between windows in normal and terminal mode (the README's example) | Your own `init.lua` |
| fzf-lua, nvim-tree.lua | Installed (used for the split keys in the lists, directory browsing, and the focus mode tree) | Your own plugin setup |
| `laststatus` | `2` (a statusline per window; with `3`, the second line moves into the winbar) | Your own `init.lua` |
| `dir_roots` | `{ "~/repos" }` (the place offered by `<leader>cd`) | The plugin's `opts` |
| `terminal-notifier` | Installed (so that clicking a notification on macOS brings back the terminal app) | `brew install terminal-notifier` |

Everything else (the renderer, the notification delay, `<C-q>` and `<C-]>`, and so on) is left at the plugin's defaults.

### Example configuration

The relevant part of the author's `init.lua`, which this guide assumes. Copy it into your own `init.lua` and change the keys as you like.

```lua
-- Settings in your own init.lua (taken from the author's init.lua)

vim.g.mapleader = " "
vim.opt.laststatus = 2

-- lazy.nvim plugin spec
{
    "tbsmcd/claude-deck.nvim",
    opts = {
        dir_roots = { "~/repos" },
    },
},

-- Keys for claude-deck.nvim
local ct = require("claude-deck")
vim.keymap.set("n", "<leader>cc", ct.toggle, { desc = "open/focus/grow claude terminal" })
vim.keymap.set("n", "<leader>cv", function() ct.new("right") end, { desc = "claude terminal split right" })
vim.keymap.set("n", "<leader>cs", function() ct.new("below") end, { desc = "claude terminal split below" })
vim.keymap.set("n", "<leader>cl", ct.list, { desc = "list claude terminals" })
vim.keymap.set("n", "<leader>cd", ct.pick_dir, { desc = "open claude terminal in directory" })
vim.keymap.set("n", "<leader>cf", ct.fork, { desc = "fork claude terminal session" })
vim.keymap.set("n", "<leader>cr", ct.rename, { desc = "rename claude terminal task" })
vim.keymap.set("n", "<leader>co", ct.focus, { desc = "toggle tree/editor mode for claude terminal" })
vim.keymap.set({ "n", "x" }, "<leader>cp", ct.send_location, { desc = "send file:line to claude terminal" })
vim.keymap.set("n", "<leader>cR", ct.redraw, { desc = "redraw claude terminal (resume session)" })

-- <Esc> leaves terminal mode (send Esc to Claude with <C-]> instead)
vim.keymap.set("t", "<Esc>", [[<C-\><C-n>]])

-- <C-h/j/k/l> move between windows in normal and terminal mode
for _, key in ipairs({ "h", "j", "k", "l" }) do
    vim.keymap.set("n", "<C-" .. key .. ">", "<C-w>" .. key)
    vim.keymap.set("t", "<C-" .. key .. ">", [[<C-\><C-n><C-w>]] .. key)
end
```

## 1. What this plugin does

claude-deck.nvim runs several Claude Code sessions at once in Neovim terminals and lets you see the state of each one at a glance.

- Each terminal shows its number, status and task title, colored by status
- You get a desktop notification when Claude is waiting for input or for your answer
- Closing a terminal does not stop Claude: it keeps running in the background, and you can bring it back later
- Focus mode lets you talk to Claude while looking at your code
- Claude in one terminal can read the conversations in the other terminals

"Deck" means a place where several sessions are laid out so you can see them all.

## 2. Reading the screen

Each terminal has two lines of information, one above and one below (with `laststatus` set to `3`, the lower line moves to the right side of the winbar).

```
 #2 Running │ Split the parser                 ← winbar (number, status, task title)
 (Claude Code screen)
 ~/repos/app                 session 1a2b3c4d  ← statusline (cwd, session id)
```

There are five statuses, told apart by color.

| Status | Color | Meaning |
|---|---|---|
| New | Gray | Just started. No prompt sent yet |
| Running | Sky blue | Claude is working |
| Waiting | Yellow | Claude finished its turn and is waiting for your next prompt |
| Needs you | Vermillion | Claude is stopped, waiting for your answer to a permission prompt or a question |
| Exited | Dark gray | The Claude process has exited |

Waiting means "Claude says it is your turn". Nothing moves forward until you send something.

![Waiting status. The winbar shows the task title Claude set, with the statusline below](images/guide/en/waiting.webp)

Claude names the task itself once it understands the task (about 20 characters). Until then, the beginning of the first prompt is shown as a temporary title.

![Right after sending a prompt. Running, with the beginning of the prompt as the temporary title](images/guide/en/running.webp)
To name it yourself, run `:ClaudeDeck rename` (in the author's setup, `<leader>cr`). Claude never changes a title you set yourself (it will if you ask it to rename the terminal).

## 3. The basic flow

### Open

Run `:ClaudeDeck` (in the author's setup, `<leader>cc` in normal mode) to open a Claude Code terminal.

- On an empty screen, it opens in place (full screen)
- When you have a file open, it opens at the far right
- When you are already inside a terminal, it opens another one to the right

The terminal opens in Neovim's current directory. To open it somewhere else, use `:ClaudeDeck dir` (in the author's setup, `<leader>cd`; chapter 4).

### Give it a task

The terminal is ready for input right away (terminal mode). Type your task in Claude Code's prompt input and send it.

Once you send it, the status becomes Running, and after a while it becomes Waiting or Needs you.

![Needs you status. Claude has stopped to ask a question with choices](images/guide/en/needs-you.webp)

### Get notified

If Claude stops while you are doing something else, you get a desktop notification. Clicking it brings the terminal app (iTerm2, for example) to the front.

No notification is sent while you are looking at that terminal. You get one only when you are looking at another window or another app.

![A macOS notification banner: Claude: Waiting, the task title and the directory](images/guide/en/notification.webp)

### Move to other windows

Inside a terminal, every key you press goes to Claude. To get back to Neovim commands, leave terminal mode first.

| Key | Action |
|---|---|
| `<C-q>` | Leave terminal mode (only in claude-deck terminals) |
| `<C-\><C-n>` | Same (built into Neovim) |
| `<Esc>` | Same. This comes from the assumed setup in chapter 0 (a mapping in your own `init.lua`), not from the plugin |
| `<C-]>` | Send Esc to Claude (interrupt, close a dialog; press twice for the rewind menu) |

After leaving terminal mode, you can move between windows as usual with `<C-w>h` and so on. With the setup in chapter 0, you can also move with `<C-h>` / `<C-j>` / `<C-k>` / `<C-l>` without leaving terminal mode. When you move back into the terminal window, it returns to terminal mode automatically.

If you mapped `<Esc>` in Neovim to leave terminal mode, `<Esc>` does not reach Claude. Use `<C-]>` to send Esc to Claude. Without that mapping, `<Esc>` reaches Claude as it is.

### Close and bring back

You can close a terminal window with `:q`. Claude keeps running in the background, and status updates and notifications continue.

To bring it back, open the list with `:ClaudeDeck list` (in the author's setup, `<leader>cl`) and pick a terminal.

| Key in the list | Action |
|---|---|
| `Enter` | Open (in place on an empty screen, to the right inside a terminal, at the far right otherwise) |
| `Ctrl-v` | Open in a split to the right |
| `Ctrl-s` | Open in a split below |

If you run `:q` when there is only one window, Neovim does not quit. The terminal is hidden and an empty window is left (a message tells you how many terminals are running in the background). To quit Neovim itself, use `:qa`. This also ends the Claude sessions running in the background.

![The message shown after running :q in the last window](images/guide/en/last-window-q.webp)

To end Claude, run `/exit` in Claude's prompt input.

## 4. Working with several terminals

### Split to add more

| Command (key in the author's setup) | Action |
|---|---|
| `:ClaudeDeck new right` (`<leader>cv`) | Open a new terminal to the right of the current window |
| `:ClaudeDeck new below` (`<leader>cs`) | Open a new terminal below the current window |

A new terminal opens in the same directory as the terminal you are in. The size of your other windows does not change.

### Open in another directory

Run `:ClaudeDeck dir` (in the author's setup, `<leader>cd`) to open a directory list. The candidates come in this order:

1. The current directory
2. The directories directly under the current directory
3. The directories of open terminals
4. The directories directly under the places you configured (`dir_roots`). With the setup in chapter 0, this is the directories directly under `~/repos`
5. zoxide history

| Key in the list | Action |
|---|---|
| `Enter` / `Ctrl-v` / `Ctrl-s` | Open in that directory |
| `Tab` | Go into that directory |
| `Shift-Tab` | Go back up one level |

You can go down as many levels as you like with `Tab`. Press `Enter` at any level to open there.

![Go up with Shift-Tab, enter project-b and press Enter to open it](images/guide/en/dir-browse.gif)

### Fork a conversation

Run `:ClaudeDeck fork` inside a terminal (in the author's setup, `<leader>cf`) to continue the same conversation in another terminal. Use it when you want to try a different approach from this point. The original terminal stays as it is.

## 5. Discussing code while looking at it (focus mode)

Run `:ClaudeDeck focus` inside a terminal (in the author's setup, `<leader>co`), and a new tab opens with file tree | editor | that terminal. The tab's current directory is the terminal's directory.

Run `:ClaudeDeck focus` again, and the tab closes and your previous layout comes back.

### Send the file and line to Claude

In the editor of focus mode, run `:ClaudeDeck location` (in the author's setup, `<leader>cp`; in visual mode, `:'<,'>ClaudeDeck location`) to insert the current file and line into Claude's prompt input.

- Normal mode: the cursor line, e.g. `app/services/example.rb:24`
- Visual mode (select lines with `V`): the selected lines, e.g. `app/services/example.rb:24-58`

Only the path and line go into the prompt input, and focus moves to the terminal. Go on typing something like "I want to share this logic" and send it. Nothing is sent automatically.

It also works in tabs other than focus mode, as long as exactly one terminal is visible.

![In focus mode, select lines, run `:ClaudeDeck location` (in the author's setup, `<leader>cp`), then type the instruction](images/guide/en/focus-send-location.gif)

![The focus mode screen after Claude carried out the instruction](images/guide/en/focus-result.webp)

## 6. Scrolling back through the conversation

You can reread a conversation that has scrolled off the Claude Code screen with the usual Neovim buffer operations.

1. Leave terminal mode with `<C-q>`
2. Scroll back with `k`, `Ctrl-u`, `gg` and so on. You can also search with `/` and copy with `v` and `y`
3. Press `i` to return to terminal mode (you go back to the latest position)

![Leave terminal mode, scroll back, search, then return](images/guide/en/scroll-back.gif)

This works because the terminal starts Claude Code with the classic renderer. With this renderer, the prompt input sits near the top while the conversation is short, and settles at the bottom once the conversation fills the screen.

If you want the prompt input always fixed at the bottom, set `renderer = "fullscreen"`. In that case, you scroll back with Claude Code's own keys (`PageUp` / `PageDown`, and `Ctrl+O` for the transcript view).

## 7. Claude working with Claude (the `ct` command)

Claude in a terminal can check on the other terminals with the `ct` command. Claude is told about this command when it starts, so you just ask in plain words, for example:

- "Check how #1 is going"
- "Check that this doesn't conflict with the work in the other terminals"

| Command | Description |
|---|---|
| `ct list` | Number, status, task title, directory and session id of every terminal |
| `ct read 2` | Recent conversation of terminal #2 (20 messages by default) |
| `ct title "name"` | Set the title of its own terminal |

All of them run without a permission prompt. `ct read` only reads the conversation that has been recorded, so you cannot see what the other side is in the middle of writing until that message is finished.

![Claude in #2 reporting on the work in #1 with ct list and ct read](images/guide/en/ct.webp)

## 8. How notifications work

A notification is sent when the status becomes Waiting or Needs you. It is not sent in these cases:

- You are looking at that terminal (Neovim has focus, you are in that terminal's window, and the terminal app is frontmost)
- The status went back to Running within 2 seconds (for example, Claude resumed by itself when a background process finished)

On macOS, if `terminal-notifier` is installed, clicking a notification brings you back to the terminal app (`brew install terminal-notifier`). The first time, you need to allow `terminal-notifier` under "Notifications" in System Settings. When no notification appears, Neovim shows the reason in a message.

## 9. Troubleshooting

| Symptom | What to check |
|---|---|
| No notifications | Check the notification method with `:checkhealth claude-deck`. On macOS, allow `terminal-notifier` under "Notifications" in System Settings |
| The status stays Running | After you interrupt Claude, it stays Running until you send the next prompt (by design) |
| Claude does not stop when I press `<Esc>` | You mapped `<Esc>` to something else in Neovim. Use `<C-]>` |
| The task title disappeared | `/clear` in Claude removes the title Claude set. A title you set yourself stays |
| `:q` does not quit Neovim | This is the behavior when you close a terminal in the only window. Use `:qa` to quit |
| `Tab` and other keys do not work in the lists or the directory picker | fzf-lua is not installed. Install it to get the split keys and directory browsing |

## 10. Key reference

**All of these come from the example configuration in chapter 0 (the author's `init.lua`).** The plugin does not provide them: unless you add the same mappings to your own `init.lua`, they do not work. The same goes for `<Esc>`, `<C-h>` and so on.

| Key | Command | Action |
|---|---|---|
| `<leader>cc` | `:ClaudeDeck` | Open / move to / add to the right |
| `<leader>cv` | `:ClaudeDeck new right` | Open in a split to the right |
| `<leader>cs` | `:ClaudeDeck new below` | Open in a split below |
| `<leader>cl` | `:ClaudeDeck list` | List terminals |
| `<leader>cd` | `:ClaudeDeck dir` | Pick a directory and open there |
| `<leader>cf` | `:ClaudeDeck fork` | Fork the conversation |
| `<leader>cr` | `:ClaudeDeck rename` | Rename the task |
| `<leader>co` | `:ClaudeDeck focus` | Toggle focus mode |
| `<leader>cp` | `:ClaudeDeck location` (in visual mode, `:'<,'>ClaudeDeck location`) | Send the file and line to Claude |
| `<leader>cR` | `:ClaudeDeck redraw` | Redraw the terminal (resume the session) |
| `<C-q>` (in a terminal) | none (a plugin key) | Leave terminal mode |
| `<C-]>` (in a terminal) | none (a plugin key) | Send Esc to Claude |

To run them as commands, use `:ClaudeDeck` followed by a subcommand (`new`, `list`, `dir`, `fork`, `rename`, `focus`, `location`, `redraw`, `show`, `settings`).
