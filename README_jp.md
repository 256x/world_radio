# 🌍 World Radio Script（ワールドラジオスクリプト）

`mplayer`、`fzf`、`jq` を利用して、国別にインターネットラジオを検索・再生できるターミナルスクリプトです。

---

## 📦 必要なパッケージ

以下のコマンドが使用可能であることを確認してください：

- `curl`
- `jq`
- `fzf`
- `mplayer`
- `tput`（通常 `ncurses` パッケージに含まれます）

お使いの環境に応じて `apt`、`brew`、`pkg` などでインストールしてください。

---

## 🔧 セットアップ

1. リポジトリをクローンします：

   ```bash
   git clone https://gitlab.com/_f_umi/world_radio.git
   cd world_radio
   chmod +x world_radio.sh
   ```

2. （任意）`.countries` ファイルを手動で作成すれば、国リストをキャッシュまたはカスタマイズできます。

---

## ▶️ 使い方

### 基本的な起動

```bash
./world_radio.sh
```

- 最初に **国** を選択します。
- 次に **局** を選びます。
- `ESC` キーで国または局のリストに戻れます。
- `q` キーで終了します。

### 国リストの表示

```bash
./world_radio.sh -l
```

### 国を指定して起動

```bash
./world_radio.sh -c "Japan"
```

---

## 🩼 補足

- 国ごとのラジオ局情報は `~/.cache/radio_script/` にキャッシュされます。
- 一時ファイルとして以下を使用します：
  - `/tmp/mplayer_radio_fifo`
  - `/tmp/mplayer_radio_info`
- スクリプト終了時にはカーソルと端末の設定が元に戻されます。
- すべての操作ログは `/tmp/radio_script.log` に記録されます。

---

## 📃 ライセンス

MITライセンス（自由に変更・再配布可能）

---

## 🙏 謝辞

- [radio-browser.info](https://www.radio-browser.info/) - 公共ラジオAPI




