# 仕様: 複数セッションの協調（オーケストレーション）

状態: 第 2 段まで実装済み。

## 実装済み（第 1 段）

- ターミナルごとのモデル
  - `new(where, opts)` / `fork(where, opts)` の `opts.model` を、`--model <model>` として別々の argv 要素で Claude Code に渡す。`cmd` に `--model X`（2 要素）または `--model=X` があるときは、明示したモデルがあれば取り除く。明示しなければ `cmd` はそのまま。
  - 要求したモデルを `term.model` に保存する（Claude Code が実際に使うモデルを確認するものではない）。`fork()` は `opts.model` がなければ元のターミナルのモデルを引き継ぎ、`new()` は何も引き継がない。`redraw()` は同じモデルで再起動する。
  - `:ClaudeDeck new|fork [right|below] [--model <model>]`（引数の順序は自由）。UI（winbar・statusline）は変えず、`ct list` に `\tmodel: <model または (default)>` の行を足した。
- `ct list --json`
  - `{"self": <id または null>, "terminals": [{"id", "state", "title", "title_source", "cwd", "session_id", "transcript_path", "model", "spawned_by"}]}` を 1 行で出力する。番号順。`state` は内部名（`idle|running|waiting|attention|exited`）。値がないものは JSON の null。`title_source` は `"claude"|"user"|"auto"|null`。
  - 許可リストに `Bash(ct list:*)` を追加した。
- `ct spawn`
  - `ct spawn [--title <名前>] [--cwd <dir>] [--model <model>] (--prompt <text> | --prompt-file <path>) [--show]`
  - プロンプトは Claude Code の位置引数として渡す（`-` で始まるときは `--` を前に置く）。入力欄には打ち込まない。`--prompt-file` は Neovim が読み、相対パスと相対 `--cwd` は Claude のシェルの `$PWD` からの相対。`--cwd` の既定は呼び出し元の cwd で、存在するディレクトリであること。
  - 既定ではフローティング window で起動してすぐ閉じる。タブ・window・カーソル・モードは変わらず、バッファは非表示のまま残る。`--show` では呼び出し元のターミナルの右に開き、フォーカスは動かさない。
  - 成功時: `{"id": <新しい番号>, "cwd": "…", "model": <文字列|null>, "title": <文字列|null>}`（終了コード 0）。
  - エラー（`ct: …`、終了コード 1）: プロンプトなし、両方指定、プロンプトファイルを読めない、`--cwd` が不正、名前が 40 セル超（何も作る前に拒否）、claude-deck のターミナルの外、`ct: spawn limit reached (N)`。
  - 上限は `cli.spawn_limit`（既定 3）。`term.spawned = true` で終了していないものを数える。`term.spawned_by` に呼び出し元の番号を記録する。
  - `Bash(ct spawn:*)` は許可リストに入れない（そのつど Claude Code があなたに確認する）。システムプロンプトには、作業を任せるよう頼まれたときだけ使うよう書いた。
  - Lua API: `require("claude-deck").spawn({ prompt, cwd, model, title, show })` が新しい番号（失敗時は nil とメッセージ）を返す。

## 実装済み（第 2 段）

- `ct send <id> (--prompt <text> | --prompt-file <path>)`
  - 既存のターミナルに作業を渡す。`--prompt-file` の相対パスは Claude のシェルの `$PWD` からの相対（`ct spawn` と同じ）。
  - 配送: プロンプト全体を 1 回のブラケットペースト（`\27[200~` … `\27[201~`）で `nvim_chan_send` し、約 50 ms 後（`vim.defer_fn`）に `\r` で送信する。複数行でも 1 回のペーストに収まる。表示中のターミナルには先に `fit_pty(win)` を呼ぶ。非表示でもそのまま送る。ペースト終端の列がテキストに含まれていれば取り除く。
  - 成功時: `{"id": 3, "request": "r1"}` を 1 行で出力する（終了コード 0）。成功は「入力を書き込んだ」ことだけを意味する。
  - エラー（`ct: …`、終了コード 1）: 自分自身（`ct: cannot send to yourself`）、存在しない番号、状態が `idle`/`waiting` 以外（`ct: terminal #3 is running (send only to idle or waiting terminals)`。attention・exited も同じ形）、ジョブが死んでいる、プロンプトなし、両方指定、読めないファイル、空（trim 後）、NUL バイトを含む。
  - `Bash(ct send:*)` は許可リストに入れない。
- リクエストの追跡
  - リクエスト番号 `r<N>` は `state.next_request` の通し番号。対象に `term.requests`（履歴）と `term.last_request`（`{id, from, text, sent_at, received, completed}`、終了時は `exited = true` も）を持つ。
  - `UserPromptSubmit` で、`last_request` が未受信かつ hook の `prompt` を trim したものが `text` を trim したものと等しければ `received = true`。`Stop` で `received` かつ未完了なら `completed = true`。ターミナルが終了したときも `completed = true`、`exited = true`。
  - `ct list --json` の各ターミナルに `"last_request": {"id", "from", "received", "completed", "sent_at"}`（なければ null）を足した。キーの順序は固定（`id` が先頭）。
- `ct wait <id>... [--timeout <seconds>]`
  - 既定のタイムアウトは 600 秒。待つループは `bin/ct`（POSIX sh）にあり、1 秒ごとに `cli.wait_status([ids])` を呼ぶので Neovim は止まらない。`pending` の行がなくなるか、タイムアウトで終わる。
  - `wait_status` の行: `3 done r1` / `3 pending r1 running` / `3 attention r1` / `3 exited`（リクエストがあれば `3 exited r1`）/ `3 missing` / `3 none`。判定の順序は、存在しない → `missing`、終了 → `exited`、最新のリクエストが完了 → `done`、状態が attention → `attention`、リクエストなし → `none`、それ以外 → `pending`。`none` は終了扱い（待ちが止まらないようにするため）。`waiting` だけでは完了にならない（受信してから `Stop` が必要）。
  - 最終出力（`cli.wait_result([ids], timed_out)`）: `{"timed_out": false, "terminals": {"3": {"status": "done", "request": "r1", "state": "waiting"}}}`。`status` は `done|attention|exited|missing|none|pending`。リクエストや状態がなければ null。
  - 終了コード: 完了で 0、タイムアウトで 2、使い方の誤り（番号なし、数字でない番号、不正なタイムアウト）で 1。
  - `Bash(ct wait:*)` を許可リストに入れた（読み取りのみ）。
- システムプロンプト: `ct send` と `ct wait` を `ct spawn` の段落に足した。終了はターンの終わりであって成功ではないので、作業者が書いた結果を読むよう書いた。
- Lua API: `require("claude-deck").send(id, prompt)` がリクエスト番号（失敗時は nil とメッセージ）を返す。`wait` は呼び出しをブロックするため、Lua API にはない。
