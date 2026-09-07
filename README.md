# awake-mode

Mac を「起きたまま」にしておく方法を、モードひとつ選ぶだけにする。
選んだあとは常駐の見張りが 10 秒ごとに実状態を見て、ずれていれば直す。
メニューバーのアイコンの色は、**望んだ状態ではなく実際に効いている状態**で決まる。

*(English below / 英語版は下)*

---

## これで解ける場面

AI エージェント (Claude Code、Cursor など) を長時間走らせていると、こうなる。

- **通勤中も走らせたい** — 蓋を閉じて鞄に入れる。macOS は蓋を閉じると寝るので、途中で止まる
- **スマホから様子を見たい** — Tailscale や ssh で入るには、本体が起きている必要がある
- **カフェで席を外す** — 画面はロックしたいが、処理は止めたくない
- **止まっていたことに、あとで気づく** — 「ON にしたはずなのに効いていなかった」が一番痛い

蓋を閉じても寝ないようにできるのは `pmset disablesleep` だけで、これは root 権限が要る。
awake-mode はその 1 点のためだけにパスワード不要の許可を 4 コマンド分だけ作り、あとは
モードの選択に合わせて機械が状態を保つ。

## 3 つのモード

| モード | どうなるか | 蓋を閉じたら | 画面 |
|---|---|---|---|
| `normal` | スリープは macOS 任せ | 寝る | 通常 |
| `lid` | 蓋を閉じても本体は動き続ける | 起きたまま | 消えてよい |
| `lock` | 画面をロックして本体は動き続ける | 寝る | 選んだ瞬間に消えてロック |

`lock` は選んだ瞬間に 1 回だけ画面を消す。AC 接続だと `displaysleep=0` の Mac が多く、
画面が消えないとロックも走らないため。`lock` のままでも画面を触れば作業に戻れる。

## インストール

Xcode Command Line Tools が要る (`xcode-select --install`)。macOS 13 以降。

```sh
git clone https://github.com/sson-s2/awake-mode.git
cd awake-mode
./install.sh
```

インストール中に **ログインパスワードを 1 回聞かれる**。`/etc/sudoers.d/awake-mode` を書くためで、
許可する範囲は次の 4 行だけ。ワイルドカードは使っていない。

```
/usr/bin/pmset disablesleep 0
/usr/bin/pmset disablesleep 1
/usr/bin/pmset -b lowpowermode 0
/usr/bin/pmset -b lowpowermode 1
```

数秒でメニューバーにアイコンが出る。初期モードは `normal` なので、入れただけでは
Mac の寝かたは変わらない。何度実行しても同じ状態になる。

`~/.local/bin` が PATH に無ければ、install.sh がそう言うので `~/.zshrc` に 1 行足す。

### 端末から / スマホから

```sh
awake-mode lid       # 蓋を閉じても動かし続ける
awake-mode lock      # 画面をロックして動かし続ける
awake-mode normal    # macOS 任せに戻す
awake-mode status    # 今 何が効いているか
```

ssh で入って `awake-mode lid` と打つだけなので、スマホの端末アプリからでも切り替えられる。
`status` は効いていれば終了コード 0、効いていなければ 1 を返す。

## 仕組み

正は `~/Library/Application Support/awake-mode/mode` に書かれた 1 語だけ。メニューバーアプリも
CLI も、この 1 語を書く以外のことをしない。常駐の見張り (launchd の LaunchAgent) が 10 秒ごとに
その語を読み、`pmset disablesleep` と `caffeinate` の実際の値を見て、違えば合わせ、結果を
`status.json` に書く。アイコンと `awake-mode status` はその実状態を読む。だから「選んだのに
効いていない」があれば赤くなって見える。見張りが kill されても launchd が上げ直す。

## 電源につないでいない時

| モード | バッテリ駆動中 | 10% を切ったら | 電源を挿したら |
|---|---|---|---|
| `lid` | 蓋を閉じても起きたまま。画面は消え、低電力モードが自動で入る | 蓋の設定も `caffeinate` も外して普通に寝る。モードの選択は残る | 自動で戻る。低電力モードは切れる |
| `lock` | 蓋を開けたまま起きたまま。低電力モードが自動で入る | 同上 | 同上 |
| `normal` | いつもの Mac | 変化なし | 変化なし |

## 安全のための作り

- **電池が減ったら普通に寝る** — バッテリ駆動で 10% を切ると、蓋の設定も `caffeinate` も
  外して macOS の通常設定で寝かせる。モードの選択は消さないので、電源を挿すか 15% まで回復すれば
  自動で戻る。切り替わるたびに通知が 1 回出る。しきい値は設定で変えられる
- **低電力モード** — `lid` / `lock` でバッテリ駆動のあいだ、macOS の低電力モード
  (バッテリ側のプロファイル) を入れる。`normal` に戻すか電源を挿せば切る
- **止まる時は必ず戻す** — 見張りが正規に停止すると `disablesleep` を 0 に、低電力モードを
  切ってから終わる。**蓋を閉じたまま防止だけが残った Mac は、鞄の中で熱を持つ**。
  `caffeinate` は見張りの PID を見張る形で起動するので、見張りが強制終了されても道連れで消える
- **sudo の範囲** — 上記 4 コマンドのみ。awake-mode は他に root を使わない

## 設定

`~/Library/Application Support/awake-mode/config` を編集すると、次の周期から効く (再起動不要)。

| キー | 既定 | 意味 |
|---|---|---|
| `BATTERY_SLEEP_PERCENT` | `10` | バッテリ駆動でこれを下回ったら防止を解除する |
| `BATTERY_RESUME_PERCENT` | `15` | ここまで回復したら (または電源接続で) 再開する |
| `LOW_POWER_ON_BATTERY` | `1` | `0` にすると低電力モードに一切触らない |
| `INTERVAL_SEC` | `10` | 見張りが実状態を確かめる間隔 (秒) |

ログは `~/Library/Logs/awake-mode.log`。状態が変わった時だけ 1 行増える。

## アンインストール

```sh
./uninstall.sh                # 設定・ログ・選択したモードも消す
./uninstall.sh --keep-state   # 設定とログは残す
```

`disablesleep` と低電力モードを 0 に戻してから sudoers を消す。sudoers の削除で
**ログインパスワードをもう 1 回聞かれる**。

## よくある質問

**Amphetamine や KeepingYouAwake と何が違う?**
あの 2 つは `caffeinate` 相当のアサーションを立てるもので、**蓋を閉じたスリープは止められない**
(macOS がアサーションより優先する)。蓋閉じを止められるのは root で叩く `pmset disablesleep` だけ。
awake-mode はそこだけに絞って sudo を使い、残りは同じ仕組みを使っている。

**メニューバーのトグルを 1 個置くのと何が違う?**
トグルは「押したかどうか」しか見せない。awake-mode は 10 秒ごとに実際の値を読み直して、
食い違っていれば直し、直せなければアイコンを赤くする。**効いていないことに気づける**のが違い。
主スイッチは 1 つで、あとは全部その 1 つに従う。

**蓋を閉じたまま鞄に入れて熱くならない?**
処理が走っている限り発熱はする。だからモードを選ぶこと自体が判断で、awake-mode は
「知らないうちに防止が残っている」状態を作らない (停止時に必ず 0 に戻す) 側だけを引き受ける。

**Apple Silicon / Intel は?**
どちらも `pmset` の同じインターフェースを使う。低電力モードは対応している機種でだけ効く。

## ライセンス

MIT

---

# awake-mode (English)

Keeping a Mac awake should be one choice, not a checklist. Pick a mode; a small
watchdog compares the machine with that choice every ten seconds and fixes the
difference. The menu bar icon is coloured by **what is actually true**, not by
what you asked for.

## What it is for

Running an AI agent (Claude Code, Cursor) for hours runs into all of this:

- **Keep working on the commute.** Close the lid, put it in a bag. macOS sleeps on lid close, and the run dies.
- **Check in from a phone.** Tailscale or ssh only reach a machine that is awake.
- **Step away in a café.** Lock the screen without stopping the work.
- **Find out afterwards that it stopped.** "I turned it on and it wasn't on" is the expensive one.

Only `pmset disablesleep` stops lid-close sleep, and it needs root. awake-mode
buys exactly that with a password-free rule for four commands, and does the rest
in user space.

## Three modes

| Mode | Effect | Lid closed | Display |
|---|---|---|---|
| `normal` | sleep is left to macOS | sleeps | normal |
| `lid` | the machine keeps running with the lid shut | stays awake | may sleep |
| `lock` | the screen locks, the machine keeps running | sleeps | blanks and locks once |

`lock` blanks the display once, on entry: many Macs ship `displaysleep=0` on AC,
and a display that never sleeps never reaches the lock screen. Touch the machine
and you are back at work with the mode still set.

## Install

Needs the Xcode Command Line Tools (`xcode-select --install`) and macOS 13 or newer.

```sh
git clone https://github.com/sson-s2/awake-mode.git
cd awake-mode
./install.sh
```

It asks for your login password **once**, to write `/etc/sudoers.d/awake-mode`.
That file grants these four exact command lines and nothing else. No wildcards.

```
/usr/bin/pmset disablesleep 0
/usr/bin/pmset disablesleep 1
/usr/bin/pmset -b lowpowermode 0
/usr/bin/pmset -b lowpowermode 1
```

The icon appears in the menu bar within a few seconds. The starting mode is
`normal`, so installing it does not change how your Mac sleeps. Running it again
converges on the same state.

If `~/.local/bin` is not on your PATH, the installer prints the line to add.

### From a terminal, or from a phone

```sh
awake-mode lid       # keep running with the lid closed
awake-mode lock      # lock the screen, keep running
awake-mode normal    # back to macOS defaults
awake-mode status    # what is actually in effect
```

ssh in and type `awake-mode lid`; that is the whole phone story. `status` exits 0
when the mode is in effect and 1 when it is not.

## How it works

The source of truth is one word in `~/Library/Application Support/awake-mode/mode`.
The menu bar app and the CLI do nothing but write that word. A LaunchAgent reads it
every ten seconds, reads the real `pmset disablesleep` value and its own
`caffeinate` child, corrects any difference, and writes what it found to
`status.json`. The icon and `awake-mode status` read that file, which is why a
mode that is not taking effect shows up red instead of silently doing nothing.
If the watchdog is killed, launchd starts it again.

## On battery

| Mode | While on battery | Below 10% | When plugged in again |
|---|---|---|---|
| `lid` | Stays awake with the lid closed; the display goes dark and Low Power Mode turns on | Releases both the lid setting and `caffeinate` and sleeps normally; the mode selection is kept | Resumes automatically; Low Power Mode turns off |
| `lock` | Stays awake with the lid open; Low Power Mode turns on | Same | Same |
| `normal` | An ordinary Mac | No change | No change |

## Built to fail safe

- **A low battery sleeps normally.** Under 10% on battery, both the lid setting
  and `caffeinate` are released so the machine sleeps on your own macOS settings.
  The mode is kept, so plugging in or charging back to 15% resumes it by itself.
  One notification each way. Both thresholds are configurable.
- **Low Power Mode.** While `lid` or `lock` runs on battery, macOS Low Power Mode
  is turned on for the battery profile, and off again on AC or in `normal`.
- **Stopping always puts it back.** A clean stop sets `disablesleep` back to 0 and
  turns Low Power Mode off before exiting. **A Mac left with sleep prevention on and
  the lid shut cooks in a bag.** The `caffeinate` child watches the watchdog's own
  pid, so it dies with it even after a SIGKILL.
- **The sudo grant** is those four commands. awake-mode uses root for nothing else.

## Settings

Edit `~/Library/Application Support/awake-mode/config`; changes take effect on the
next cycle, no restart.

| Key | Default | Meaning |
|---|---|---|
| `BATTERY_SLEEP_PERCENT` | `10` | release everything below this, on battery |
| `BATTERY_RESUME_PERCENT` | `15` | resume at or above this, or on AC |
| `LOW_POWER_ON_BATTERY` | `1` | `0` leaves Low Power Mode entirely alone |
| `INTERVAL_SEC` | `10` | seconds between checks |

The log is `~/Library/Logs/awake-mode.log`, one line per change of state.

## Uninstall

```sh
./uninstall.sh                # removes the settings, the log and the saved mode
./uninstall.sh --keep-state   # keeps them
```

It resets `disablesleep` and Low Power Mode before removing the sudoers file, and
asks for your password once more to remove it.

## FAQ

**How is this different from Amphetamine or KeepingYouAwake?**
Those raise `caffeinate`-style power assertions, which **cannot stop lid-close
sleep**: macOS overrides assertions when the lid shuts. Only `pmset disablesleep`,
as root, stops that. awake-mode uses sudo for exactly that one thing and the same
assertions for everything else.

**How is this different from a menu bar toggle?**
A toggle shows whether you pressed it. awake-mode re-reads the machine every ten
seconds, corrects a drift, and turns the icon red when it cannot. **Noticing that it
is not working** is the difference. One switch, and everything follows it.

**Will it cook in a bag with the lid closed?**
Work generates heat, so choosing `lid` is a real decision. What awake-mode removes
is the other failure: prevention left on without you knowing. A clean stop always
returns the setting to 0.

**Apple silicon or Intel?**
Both, through the same `pmset` interface. Low Power Mode applies on machines that
support it.

## License

MIT
