#!/bin/sh
# Headless smoke test. Starts Neovim with tests/minimal_init.lua and drives it over RPC.
#   sh tests/smoke.sh
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd -P) # resolved like getcwd() (e.g. /var -> /private/var on macOS)
# The checkout directory name and its path as shown in the winbar (~ for $HOME)
ROOT_NAME=$(basename "$ROOT")
case "$ROOT" in
"$HOME"/*) ROOT_DISPLAY="~${ROOT#"$HOME"}" ;;
*) ROOT_DISPLAY=$ROOT ;;
esac

TEST_OUT=$(mktemp -d)
export TEST_OUT
SOCK="$TEST_OUT/nvim.sock"
# Make notification behaviour deterministic (no frontmost-app check)
unset __CFBundleIdentifier
# The renderer tests check what the plugin passes, not what was inherited
unset CLAUDE_CODE_NO_FLICKER

nvim --headless --clean -u tests/minimal_init.lua --listen "$SOCK" >/dev/null 2>&1 &
NVIM_PID=$!
trap 'kill $NVIM_PID 2>/dev/null; rm -rf "$TEST_OUT"' EXIT

i=0
while [ ! -S "$SOCK" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done

failures=0
lua() {
    # Evaluate a Lua expression in the test Neovim and print the result
    printf 'return %s' "$1" >"$TEST_OUT/expr.lua"
    nvim --server "$SOCK" --remote-expr "v:lua.T_run('$TEST_OUT/expr.lua')"
}
check() { # name, actual, expected substring
    case "$2" in
    *"$3"*) echo "ok   - $1" ;;
    *)
        echo "FAIL - $1"
        echo "       expected to contain: $3"
        echo "       actual: $2"
        failures=$((failures + 1))
        ;;
    esac
}
hook() { # id, event, json
    printf '%s' "$3" | NVIM="$SOCK" CLAUDE_DECK_ID="$1" bin/claude-deck-hook "$2"
    sleep 0.3
}

# Opening in an empty buffer reuses the window
check "toggle opens in place" "$(lua '(function() require("claude-deck").toggle(); vim.cmd("stopinsert"); return #vim.api.nvim_list_wins() .. " " .. vim.b.claude_deck_id end)()')" "1 1"
sleep 0.5
check "claude gets --settings with hooks" "$(cat "$TEST_OUT/args.1")" "claude-deck-hook"
check "claude gets the system prompt" "$(cat "$TEST_OUT/args.1")" "ct list"
check "classic renderer by default" "$(cat "$TEST_OUT/env.1")" "CLAUDE_CODE_NO_FLICKER=0"
check "terminal scrollback is set" "$(lua '"[" .. vim.bo.buftype .. " " .. vim.bo.scrollback .. "]"')" "[terminal 100000]"

# Hook events update the winbar
hook 1 SessionStart '{"cwd":"'"$ROOT"'","session_id":"sess-1","transcript_path":"'"$ROOT"'/tests/fixtures/transcript.jsonl"}'
hook 1 UserPromptSubmit '{"prompt":"Refactor   the parser module and add tests for it"}'
check "running state in winbar" "$(lua 'T_winbar()')" "#1 Running │ Refactor the parser module and add tests for it"
check "statusline shows cwd and session" "$(lua 'T_statusline()')" "$ROOT_NAME"
check "statusline shows session id" "$(lua 'T_statusline()')" "session sess-1"
check "buffer is renamed" "$(lua 'vim.api.nvim_buf_get_name(0)')" "claude:#1 Refactor the parser"
check "no leftover term:// buffers" "$(lua '#vim.tbl_filter(function(b) return vim.api.nvim_buf_get_name(b):match("^term://") ~= nil end, vim.api.nvim_list_bufs())')" "0"
check "narrow window cuts the title" "$(lua '(function() vim.cmd("vsplit"); vim.api.nvim_win_set_width(0, 30); local s = T_winbar(); vim.cmd("close"); return s end)()')" "#1 Running │ Refactor the p…"
check "one-line mode right-aligns the cwd" "$(lua '(function() vim.o.columns = 200; vim.o.laststatus = 3; local s = T_winbar(); vim.o.laststatus = 2; vim.o.columns = 80; return s end)()')" "tests for it   "
check "one-line mode shows the full cwd" "$(lua '(function() vim.o.columns = 200; vim.o.laststatus = 3; local s = T_winbar(); vim.o.laststatus = 2; vim.o.columns = 80; return s end)()')" "$ROOT_DISPLAY"
check "one-line mode drops the cwd when narrow" "$(lua '(function() vim.o.laststatus = 3; local s = T_winbar(); vim.o.laststatus = 2; return s:find("repos", 1, true) and s or "no cwd" end)()')" "no cwd"
hook 1 Notification '{"notification_type":"permission_prompt","message":"Claude needs your permission"}'
check "attention state in winbar" "$(lua 'T_winbar()')" "Needs you"
check "no notification for the watched terminal" "$(lua '#_G.notifications')" "0"
hook 1 Notification '{"notification_type":"idle_prompt"}'
check "idle_prompt keeps the state" "$(lua 'T_winbar()')" "Needs you"

# A second terminal below; terminal #1 is no longer watched
lua '(function() require("claude-deck").new("below"); vim.cmd("stopinsert"); return "" end)()' >/dev/null
check "new below splits" "$(lua 'vim.json.encode(vim.fn.winlayout()[1])')" "col"
hook 1 Stop '{}'
check "notification for an unwatched terminal" "$(lua 'table.concat(_G.notifications, ";")')" "Claude: Waiting | Refactor the parser"

# ct list / ct read
check "ct list" "$(NVIM="$SOCK" CLAUDE_DECK_ID=2 bin/ct list)" "#2 (you)"
check "ct read" "$(NVIM="$SOCK" bin/ct read '#1' 2)" "## Claude"
check "ct read unknown id fails" "$(NVIM="$SOCK" bin/ct read 9; echo "exit=$?")" "exit=1"

# Fork opens to the right with --resume
lua '(function() vim.cmd("wincmd k"); require("claude-deck").fork(); vim.cmd("stopinsert"); return "" end)()' >/dev/null
sleep 0.5
check "fork resumes the session" "$(tr '\n' ' ' <"$TEST_OUT/args.3")" "--resume sess-1 --fork-session"
check "fork title" "$(lua 'T_winbar()')" "↳Refactor"

# Focus mode opens a tab and returns
check "focus opens a tab in the terminal cwd" "$(lua '(function() vim.cmd("wincmd h"); require("claude-deck").focus(); return #vim.api.nvim_list_tabpages() .. " " .. vim.fn.getcwd() end)()')" "2 $ROOT"
check "focus closes and returns" "$(lua '(function() require("claude-deck").focus(); return #vim.api.nvim_list_tabpages() .. " " .. vim.b.claude_deck_id end)()')" "1 1"

# :q hides a terminal; list can bring it back below
lua '(function() vim.cmd("q"); return "" end)()' >/dev/null
check "hidden terminal still listed" "$(NVIM="$SOCK" bin/ct list)" "#1"
check "list shows hidden terminal below" "$(lua '(function() require("claude-deck").list(); T_pick("ctrl-s", 1); return vim.b.claude_deck_id end)()')" "1"

# Directory picker
check "dir picker candidates" "$(lua '(function() require("claude-deck").pick_dir(); return table.concat(_G.last_picker.lines, ";") end)()')" "fixtures/roots/project-a"
check "dir picker opens in the chosen dir" "$(lua '(function() for i, l in ipairs(_G.last_picker.lines) do if l:find("project%-a") then T_pick("ctrl-v", i) end end; vim.cmd("stopinsert"); return require("claude-deck.state").current().cwd end)()')" "fixtures/roots/project-a"
check "dir picker lists the cwd and then its subdirectories" "$(lua '(function() require("claude-deck").pick_dir(); local l = _G.last_picker.lines; return l[1] .. ";" .. l[2] end)()')" "$(printf '1\t%s;2\t%s/bin' "$ROOT_DISPLAY" "$ROOT_DISPLAY")"
check "dir picker header has the browse keys" "$(lua '_G.last_picker.opts.fzf_opts["--header"]')" "tab: go into / shift-tab: go up"
# T_pick a line by pattern; browsing opens the next picker on vim.schedule
pick_line() { # action, Lua pattern
    lua '(function() for i, l in ipairs(_G.last_picker.lines) do if l:find("'"$2"'") then T_pick("'"$1"'", i); return "" end end; return "" end)()' >/dev/null
}
picker_state() {
    lua '_G.last_picker.opts.prompt .. "|" .. table.concat(_G.last_picker.lines, ";")'
}
FIXTURES="$ROOT_DISPLAY/tests/fixtures/roots"
pick_line tab "project%-a$"
check "tab browses into a directory" "$(picker_state)" "$(printf '%s/project-a> |1\t%s/project-a;2\t%s/project-a/sub-a' "$FIXTURES" "$FIXTURES" "$FIXTURES")"
pick_line btab "project%-a$"
check "shift-tab goes up" "$(picker_state)" "$(printf '%s> |1\t%s;2\t%s/project-a;3\t%s/project-b' "$FIXTURES" "$FIXTURES" "$FIXTURES" "$FIXTURES")"
pick_line tab "project%-a$"
pick_line tab "sub%-a$"
check "tab into an empty directory lists it alone" "$(picker_state)" "$(printf '%s/project-a/sub-a> |1\t%s/project-a/sub-a' "$FIXTURES" "$FIXTURES")"
check "enter after browsing opens there" "$(lua '(function() T_pick("default", 1); vim.cmd("stopinsert"); return require("claude-deck.state").current().cwd end)()')" "fixtures/roots/project-a/sub-a"
lua '(function() vim.cmd("close"); require("claude-deck").pick_dir(); T_pick("btab", 1); return "" end)()' >/dev/null
check "shift-tab from the first list shows the cwd parent" "$(picker_state)" "$(dirname "$ROOT_DISPLAY")> |"
lua '(function() require("claude-deck").pick_dir(); return "" end)()' >/dev/null
pick_line tab "project%-a$"
lua '(function() T_pick("tab"); return "" end)()' >/dev/null
check "tab without a selection reopens the browsed list" "$(picker_state)" "$(printf '%s/project-a> |1\t%s/project-a;2\t%s/project-a/sub-a' "$FIXTURES" "$FIXTURES" "$FIXTURES")"
lua '(function() require("claude-deck").pick_dir(); _G.T_first = table.concat(_G.last_picker.lines, ";"); T_pick("tab"); return "" end)()' >/dev/null
check "tab without a selection reopens the first list" "$(lua '_G.last_picker.opts.prompt .. "|" .. tostring(table.concat(_G.last_picker.lines, ";") == _G.T_first)')" "Directory> |true"
check "dir_roots skip hidden directories" "$(lua 'table.concat(_G.last_picker.lines, ";")')" "fixtures/roots/project-b"
case "$(lua 'table.concat(_G.last_picker.lines, ";")')" in
*roots/.hidden*) echo "FAIL - dir_roots skip hidden directories (listed)"; failures=$((failures + 1)) ;;
esac
mkdir -p "$TEST_OUT/browse/gone"
lua '(function() vim.cmd.cd(vim.fn.fnameescape(vim.env.TEST_OUT .. "/browse")); require("claude-deck").pick_dir(); vim.fn.delete(vim.env.TEST_OUT .. "/browse/gone", "d"); for i, l in ipairs(_G.last_picker.lines) do if l:find("/gone$") then T_pick("tab", i) end end; return "" end)()' >/dev/null
check "browsing into a removed directory is no error" "$(lua '(function() local p = _G.last_picker; vim.cmd.cd(vim.fn.fnameescape("'"$ROOT"'")); return p.opts.prompt .. "|" .. #p.lines end)()')" "/gone> |0"
check "terminal list has no browse keys" "$(lua '(function() require("claude-deck").list(); local o = _G.last_picker.opts; return tostring(o.actions.tab) .. " " .. tostring(o.actions.btab) .. " " .. tostring(o.fzf_opts["--header"]:find("tab:", 1, true)) end)()')" "nil nil nil"

# Terminal-mode keymaps and auto insert
check "normal_mode keymap in terminals" "$(lua '(function() local m = vim.fn.maparg("<C-q>", "t", false, true); return tostring(m.buffer) .. " " .. m.rhs end)()')" "1 <C-\\><C-n>"
check "send_esc keymap in terminals" "$(lua '(function() local m = vim.fn.maparg("<C-]>", "t", false, true); return tostring(m.buffer) .. " " .. m.rhs end)()')" "1 <Esc>"
lua '(function() vim.cmd("stopinsert"); vim.cmd("wincmd w"); vim.cmd("wincmd w"); return "" end)()' >/dev/null
sleep 0.2
check "auto insert when entering a terminal" "$(lua 'vim.api.nvim_get_mode().mode .. " " .. tostring(vim.b.claude_deck_id ~= nil)')" "t true"

# Splitting a terminal keeps the editor width (even with 'equalalways')
check "split keeps other windows" "$(lua '(function() vim.cmd("stopinsert | tabnew"); vim.o.columns = 200; vim.o.equalalways = true; vim.cmd("edit " .. vim.fn.tempname()); local editor = vim.api.nvim_get_current_win(); require("claude-deck").new(); vim.cmd("stopinsert"); local before = vim.api.nvim_win_get_width(editor); require("claude-deck").new("right"); vim.cmd("stopinsert"); return before .. " " .. vim.api.nvim_win_get_width(editor) .. " " .. tostring(vim.o.equalalways) end)()')" "119 119 true"
lua '(function() vim.cmd("tabclose!"); return "" end)()' >/dev/null

# Renderer and scrollback options (each case opens a terminal below and reads what it got)
renderer_env() { # setup options as a Lua table
    id=$(lua '(function() require("claude-deck").setup(vim.tbl_extend("force", T_opts, '"$1"')); require("claude-deck").new("below"); vim.cmd("stopinsert"); local id = vim.b.claude_deck_id; vim.cmd("close"); return id end)()')
    sleep 0.5
    cat "$TEST_OUT/env.$id"
}
check "renderer = fullscreen" "$(renderer_env '{ renderer = "fullscreen" }')" "CLAUDE_CODE_NO_FLICKER=1"
check "renderer = false sets nothing" "$(renderer_env '{ renderer = false }')" "CLAUDE_CODE_NO_FLICKER=unset"
check "invalid renderer sets nothing" "$(renderer_env '{ renderer = "nope" }')" "CLAUDE_CODE_NO_FLICKER=unset"
check "invalid renderer warns once" "$(lua '(function() require("claude-deck").new("below"); vim.cmd("stopinsert | close"); local _, n = vim.api.nvim_exec2("messages", { output = true }).output:gsub("claude%-deck: invalid renderer", ""); return "[" .. n .. "]" end)()')" "[1]"
check "invalid renderer is replaced with false" "$(lua 'tostring(require("claude-deck.config").options.renderer)')" "false"
check "scrollback = false keeps the default" "$(lua '(function() require("claude-deck").setup(vim.tbl_extend("force", T_opts, { scrollback = false })); require("claude-deck").new("below"); vim.cmd("stopinsert"); local s = "[" .. vim.bo.scrollback .. "]"; vim.cmd("close"); return s end)()')" "[10000]"
check "invalid scrollback values are replaced with false" "$(lua '(function() local c = require("claude-deck.config"); local r = {}; for _, v in ipairs({ "big", -5, 1.5, 0, 100001 }) do require("claude-deck").setup(vim.tbl_extend("force", T_opts, { scrollback = v })); table.insert(r, tostring(c.options.scrollback)) end; return "[" .. table.concat(r, " ") .. "]" end)()')" "[false false false false false]"
check "invalid scrollback still opens a terminal" "$(lua '(function() require("claude-deck").setup(vim.tbl_extend("force", T_opts, { scrollback = -5 })); require("claude-deck").new("below"); vim.cmd("stopinsert"); local s = "[" .. tostring(require("claude-deck.state").get(vim.b.claude_deck_id) ~= nil) .. " " .. vim.bo.scrollback .. "] " .. vim.trim(T_winbar()); vim.cmd("close"); return s end)()')" "[true 10000] #"
lua '(function() require("claude-deck").setup(T_opts); return "" end)()' >/dev/null

# Without --settings
lua '(function() require("claude-deck").setup(vim.tbl_extend("force", T_opts, { claude_settings = false })); require("claude-deck").new("below"); vim.cmd("stopinsert"); return "" end)()' >/dev/null
sleep 0.5
args=$(cat "$TEST_OUT/args.$(lua 'vim.b.claude_deck_id')")
case "$args" in
*--settings*) echo "FAIL - claude_settings = false omits --settings"; failures=$((failures + 1)) ;;
*) echo "ok   - claude_settings = false omits --settings" ;;
esac
check "claude_settings = false keeps the system prompt" "$args" "ct list"
check "settings command shows the hooks" "$(lua '(function() require("claude-deck").show_settings(); return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n") end)()')" "claude-deck-hook"

# Terminal window style is window-local; windows split from a terminal get the user's values back
check "terminal style keeps the global options" "$(lua '(function() local origin = vim.api.nvim_get_current_win(); vim.go.number = true; require("claude-deck").new("below"); vim.cmd("stopinsert"); local term, global = vim.wo.number, vim.go.number; vim.cmd("new"); local split = vim.wo.number; vim.cmd("close | close"); vim.api.nvim_set_current_win(origin); vim.go.number = false; return tostring(term) .. " " .. tostring(global) .. " " .. tostring(split) end)()')" "false true true"

# :q on the last window hides a running terminal instead of quitting Neovim
check ":q with other windows only closes the terminal window" "$(lua '(function() vim.cmd("only"); require("claude-deck").show(1); vim.cmd("stopinsert"); local before = #vim.api.nvim_list_wins(); vim.cmd("q"); return before .. " " .. #vim.api.nvim_list_wins() .. " " .. tostring(vim.b.claude_deck_id) end)()')" "2 1 nil"
check ":q on the last window keeps Neovim running" "$(lua '(function() require("claude-deck").show(1); vim.cmd("stopinsert | only"); vim.cmd("q"); local t = require("claude-deck.state").get(1); return #vim.api.nvim_list_wins() .. " [" .. vim.api.nvim_buf_get_name(0) .. "] [" .. vim.wo.winbar .. "] " .. vim.fn.jobwait({ t.job }, 0)[1] end)()')" "1 [] [] -1"
sleep 0.2
check ":q on the last window tells how many are running" "$(lua 'vim.api.nvim_exec2("messages", { output = true }).output')" "terminals still running (:qa to quit Neovim)"

check ":q next to a help window keeps Neovim running" "$(lua '(function() require("claude-deck").show(1); vim.cmd("stopinsert | only | help | wincmd p"); vim.cmd("q"); local s = #vim.api.nvim_list_wins() .. " [" .. vim.api.nvim_buf_get_name(0) .. "]"; vim.cmd("helpclose"); return s end)()')" "2 []"
check "empty buffers are reused" "$(lua '(function() local before = #vim.api.nvim_list_bufs(); require("claude-deck").show(1); vim.cmd("stopinsert | only"); vim.cmd("q"); return tostring(before == #vim.api.nvim_list_bufs()) end)()')" "true"
check "keep_alive_on_quit = false opens no window" "$(lua '(function() local o = require("claude-deck.config").options; require("claude-deck").show(1); vim.cmd("stopinsert | only"); o.keep_alive_on_quit = false; vim.api.nvim_exec_autocmds("QuitPre", {}); local off = #vim.api.nvim_list_wins(); o.keep_alive_on_quit = true; vim.api.nvim_exec_autocmds("QuitPre", {}); return off .. " " .. #vim.api.nvim_list_wins() end)()')" "1 2"
sleep 0.2
check "a failed quit removes the empty window" "$(lua '#vim.api.nvim_list_wins() .. " " .. tostring(vim.b.claude_deck_id)')" "1 1"

# send_location(): "path:line " typed into the prompt (stdin.<id> of the dummy), no <CR>
ESC=$(printf '\033')
sent() { # id: what the terminal received since the last call, in brackets (<paste>: bracketed paste)
    sleep 0.3
    printf '[%s]' "$(sed "s/$ESC\[200~/<paste>/g; s/$ESC\[201~/<\/paste>/g" "$TEST_OUT/stdin.$1" 2>/dev/null)"
    : >"$TEST_OUT/stdin.$1"
}
to_editor() { # leave terminal mode and go back to the editor window of focus mode
    nvim --server "$SOCK" --remote-send '<C-\><C-n>' >/dev/null 2>&1
    lua '(function() vim.api.nvim_set_current_win(_G.T_edit_win); return "" end)()' >/dev/null
}
keys() { # keys typed in the editor
    nvim --server "$SOCK" --remote-send "$1" >/dev/null 2>&1
}
lua '(function() require("claude-deck").setup(vim.tbl_extend("force", T_opts, { keymaps = { send_location = "<F5>" } })); return "" end)()' >/dev/null
check "send_location keymap in normal and visual mode" "$(lua '(function() local n, x = vim.fn.maparg("<F5>", "n", false, true), vim.fn.maparg("<F5>", "x", false, true); return n.desc .. " | " .. x.desc end)()')" "Claude: send file location | Claude: send file location"
sent 1 >/dev/null
lua '(function() vim.cmd("stopinsert"); require("claude-deck").focus(); _G.T_edit_win = vim.api.nvim_get_current_win(); vim.cmd("edit README.md"); vim.api.nvim_win_set_cursor(0, { 3, 0 }); return "" end)()' >/dev/null
check "send_location in focus mode switches to the terminal" "$(lua '(function() require("claude-deck").send_location(); return tostring(vim.b.claude_deck_id) end)()')" "1"
check "send_location sends the relative path and line" "$(sent 1)" "[<paste>README.md:3 </paste>]"
sleep 0.2
check "send_location leaves the terminal in terminal mode" "$(lua 'vim.api.nvim_get_mode().mode')" "t"
to_editor
keys '5GVjj<F5>'
check "visual line selection sends a range" "$(sent 1)" "[<paste>README.md:5-7 </paste>]"
sleep 0.2
check "visual mode is left after sending" "$(lua '(function() local b = vim.api.nvim_win_get_buf(_G.T_edit_win); return vim.api.nvim_get_mode().mode .. " " .. vim.api.nvim_buf_get_mark(b, "<")[1] .. "-" .. vim.api.nvim_buf_get_mark(b, ">")[1] end)()')" "t 5-7"
to_editor
keys '9G<C-v>kk<F5>'
check "upward blockwise selection sends start-end" "$(sent 1)" "[<paste>README.md:7-9 </paste>]"
to_editor
keys '6Gvl<F5>'
check "selection on one line sends one line" "$(sent 1)" "[<paste>README.md:6 </paste>]"
to_editor
keys "4GVj:ClaudeDeck location<CR>"
check ":'<,'>ClaudeDeck location sends the range" "$(sent 1)" "[<paste>README.md:4-5 </paste>]"
to_editor
lua '(function() vim.cmd("noswapfile edit ~/claude-deck-test-nonexistent/a.lua"); vim.api.nvim_buf_set_lines(0, 0, -1, false, { "x", "y" }); vim.api.nvim_win_set_cursor(0, { 2, 0 }); local b = vim.api.nvim_get_current_buf(); require("claude-deck").send_location(); vim.bo[b].modified = false; return "" end)()' >/dev/null
check "file outside the cwd is sent with ~ (unsaved is fine)" "$(sent 1)" "[<paste>~/claude-deck-test-nonexistent/a.lua:2 </paste>]"
to_editor
lua '(function() vim.cmd("edit " .. vim.fn.fnameescape(vim.env.TEST_OUT .. "/outside.txt")); require("claude-deck").send_location(); return "" end)()' >/dev/null
check "file outside the cwd and home is sent as absolute path" "$(sent 1)" "[<paste>$(cd "$TEST_OUT" && pwd -P)/outside.txt:1 </paste>]"
to_editor
check "unnamed buffer warns" "$(lua '(function() vim.cmd("enew!"); return T_notify(require("claude-deck").send_location) end)()')" "the current buffer is not a file"
check "unnamed buffer sends nothing and stays" "$(sent 1)$(lua 'tostring(vim.b.claude_deck_id)')" "[]nil"
check "inside the terminal warns" "$(lua '(function() vim.cmd("stopinsert"); require("claude-deck").show(1); return T_notify(require("claude-deck").send_location) end)()')" "the current buffer is not a file"
to_editor
check "focus mode terminal not shown warns" "$(lua '(function() vim.cmd("edit README.md"); local term_win = vim.fn.bufwinid(require("claude-deck.state").get(1).buf); vim.api.nvim_win_close(term_win, false); return T_notify(require("claude-deck").send_location) end)()')" "terminal #1 is not shown in this tab"
check "nothing sent when the terminal is not shown" "$(sent 1)" "[]"
lua '(function() require("claude-deck").focus(); return "" end)()' >/dev/null

# send_location() outside focus mode: the only terminal shown in the tab
lua '(function() vim.cmd("stopinsert | tabnew | edit README.md"); _G.T_edit_win = vim.api.nvim_get_current_win(); require("claude-deck").new(); vim.cmd("stopinsert"); _G.T_tab_term = vim.b.claude_deck_id; vim.api.nvim_set_current_win(_G.T_edit_win); return "" end)()' >/dev/null
TAB_TERM=$(lua '_G.T_tab_term')
sleep 0.3
lua '(function() vim.api.nvim_win_set_cursor(0, { 2, 0 }); require("claude-deck").send_location(); return "" end)()' >/dev/null
check "outside focus mode the only terminal in the tab gets it" "$(sent "$TAB_TERM")" "[<paste>README.md:2 </paste>]"
to_editor
check "two terminals in the tab warn" "$(lua '(function() local w = vim.api.nvim_get_current_win(); require("claude-deck").new("below"); vim.cmd("stopinsert"); _G.T_second = vim.api.nvim_get_current_win(); vim.api.nvim_set_current_win(w); return T_notify(require("claude-deck").send_location) end)()')" "more than one terminal is shown in this tab"
check "nothing sent with two terminals" "$(sent "$TAB_TERM")" "[]"
keys '3GVj<F5>'
check "visual mode is left also when only warning" "$(lua 'vim.api.nvim_get_mode().mode .. " " .. vim.fn.line("'"'"'<") .. "-" .. vim.fn.line("'"'"'>")')" "n 3-4"
check "exited terminal warns" "$(lua '(function() vim.api.nvim_win_close(_G.T_second, true); local t = require("claude-deck.state").get(_G.T_tab_term); vim.fn.jobstop(t.job); vim.fn.jobwait({ t.job }, 1000); vim.wait(1000, function() return t.state == "exited" end); return T_notify(require("claude-deck").send_location) end)()')" "terminal #$TAB_TERM has exited"
check "nothing sent to an exited terminal" "$(sent "$TAB_TERM")" "[]"
lua '(function() vim.cmd("tabclose!"); require("claude-deck").setup(T_opts); return "" end)()' >/dev/null
check "invalid keymaps.send_location warns" "$(lua 'T_notify(function() require("claude-deck").setup(vim.tbl_extend("force", T_opts, { keymaps = { send_location = true } })) end)')" "invalid keymaps.send_location true"
check "invalid keymaps.send_location is replaced with false" "$(lua 'tostring(require("claude-deck.config").options.keymaps.send_location) .. " [" .. vim.fn.maparg("<F5>", "n") .. "]"')" "false []"
lua '(function() require("claude-deck").setup(T_opts); return "" end)()' >/dev/null
check "send_location keymap is off by default" "$(lua '"[" .. vim.fn.maparg("<F5>", "n") .. vim.fn.maparg("<F5>", "x") .. "]"')" "[]"

# User command
check "user command completion" "$(lua 'table.concat(vim.fn.getcompletion("ClaudeDeck f", "cmdline"), ",")')" "focus,fork"
check "user command completion has location" "$(lua 'table.concat(vim.fn.getcompletion("ClaudeDeck l", "cmdline"), ",")')" "list,location"

messages=$(lua 'vim.api.nvim_exec2("messages", { output = true }).output')
case "$messages" in
*rror* | *E[0-9]*) echo "FAIL - no errors in :messages"; echo "$messages"; failures=$((failures + 1)) ;;
*) echo "ok   - no errors in :messages" ;;
esac

# :qa still quits Neovim (last: the test Neovim exits here)
nvim --server "$SOCK" --remote-send '<C-\><C-n>:qa<CR>' >/dev/null 2>&1
i=0
while kill -0 $NVIM_PID 2>/dev/null && [ $i -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
if kill -0 $NVIM_PID 2>/dev/null; then
    echo "FAIL - :qa quits Neovim"
    failures=$((failures + 1))
else
    echo "ok   - :qa quits Neovim"
fi

if [ "$failures" -gt 0 ]; then
    echo "$failures test(s) failed"
    exit 1
fi
echo "all tests passed"
