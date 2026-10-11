# 仕様: 複数セッションの協調（オーケストレーション）

状態: 第 1 段を実装済み。

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
