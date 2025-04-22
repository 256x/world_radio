#!/bin/bash

# 一時ファイルとキャッシュのパス設定
FIFO_PATH="/tmp/mplayer_radio_fifo"
INFO_FILE="/tmp/mplayer_radio_info"
CACHE_DIR="$HOME/.cache/radio_script"
CACHE_TTL=3600  # キャッシュ有効期間（秒）
LOG_FILE="/tmp/radio_script.log"
CLEANUP_CALLED=0  # cleanupの重複防止フラグ
STREAM_TIMEOUT=60  # ストリーム接続のタイムアウト（秒）
STREAM_RETRIES=3  # ストリーム接続再試行回数
NOW_PLAYING=""  # 現在再生中の曲情報
NOW_PLAYING_CHECKED=0  # 曲情報チェックフラグ
mplayer_pid=""  # グローバル変数としてmplayerのPIDを保持

# シグナルの定義
SIG_COUNTRY=40  # ユーザー定義シグナル40
SIG_EXIT=41  # ユーザー定義シグナル41

# 定数
BACK_TO_COUNTRY="back"
QUIT_MPLAYER="quit"

# 端末の元の状態を保存
save_terminal_state() {
  original_stty_settings=$(stty -g)
  log "Saved terminal settings"
}

# 端末の状態を復元
restore_terminal_state() {
  if [ -n "$original_stty_settings" ]; then
    stty "$original_stty_settings"
    log "Restored terminal settings"
  fi
}

# 依存コマンドのチェック
check_dependencies() {
  local deps=("curl" "jq" "fzf" "mplayer" "tput")
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" &>/dev/null; then
      echo "Error: '$dep' not found. Please install it." >&2
      log "Dependency '$dep' not found."
      exit 1
    fi
  done
}

# ログ出力関数
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOG_FILE"
}

# mplayerプロセスを終了する関数
stop_mplayer() {
  if [ -n "$mplayer_pid" ] && kill -0 "$mplayer_pid" 2>/dev/null; then
    echo "quit" > "$FIFO_PATH" 2>/dev/null
    kill -s TERM "$mplayer_pid" 2>/dev/null
    wait "$mplayer_pid" 2>/dev/null
    log "Terminated mplayer process: $mplayer_pid"
    mplayer_pid=""
  fi
}

# クリーンアップ関数
cleanup() {
  if [ "$CLEANUP_CALLED" -eq 0 ]; then
    CLEANUP_CALLED=1
    stop_mplayer
    rm -f "$FIFO_PATH" "$INFO_FILE"
    tput cnorm 2>/dev/null  # カーソルを表示に戻す
    restore_terminal_state  # 端末設定を復元
    echo "Terminated."
    log "Script terminated."
  fi
}

# 文字列をトリミング（ターミナル幅に合わせる）
trim_string() {
  local text="$1"
  local max_width="$2"
  echo "$text" | cut -c 1-"$max_width"
}

# 表示を更新（clear引数で画面クリアを制御）
update_display() {
  local do_clear="$1"
  local term_width=$(tput cols)
  local content_width=$((term_width - 2))
  local header_text=$(trim_string "$display_text" "$content_width")

  [ "$do_clear" = "clear" ] && clear

  printf "\x1b[48;5;69m\x1b[30m%s\x1b[0m\n" "$header_text"
  echo "--------------------------------------------------"

  echo "[ Station Information ]"
  local station_info
  station_info=$(curl -s --max-time 3 -X GET -H "Icy-MetaData: 1" --range 0-0 "$url" -o /dev/null -D - 2>/dev/null | grep -i "icy-name\|icy-genre\|icy-url\|icy-description" | sed 's/^[iI][cC][yY]-//')
  if [ -n "$station_info" ]; then
    echo "$station_info" | while read -r line; do
      echo "  $(trim_string "$line" "$content_width")"
    done
    if [ -n "$tags" ]; then
      echo "  tags: $(trim_string "$tags" "$content_width")"
    fi
  else
    echo "  No station information available"
  fi
  
  # Now Playing情報を追加
  echo "--------------------------------------------------"
  echo "[ Now Playing ]"
  if [ -n "$NOW_PLAYING" ]; then
    echo "  $(trim_string "$NOW_PLAYING" "$content_width")"
  else
    echo "  No track information available"
  fi
  echo "--------------------------------------------------"

  echo ""
  echo "Updated: $(date '+%H:%M:%S') | Press ESC to return to station list | Press 'q' to exit"
  log "Updated display: station information displayed"
}

# 国のリストを取得し、fzfで選択する
select_country() {
  local countries
  local country_list_file=".countries"

  if [ -f "$country_list_file" ]; then
    log "Loading country list from file: $country_list_file"
    countries=$(cat "$country_list_file")
  else
    log "Fetching country list from network (file not found: $country_list_file)"
    countries=$(curl -s -f --max-time 10 "https://de1.api.radio-browser.info/json/countries" 2>/dev/null | jq -r '.[] | .name')
    if [ $? -eq 0 ] && [ -n "$countries" ]; then
      echo "$countries" > "$country_list_file"  # 国名のみを保存
      log "Fetched and saved country list to file: $country_list_file"
    else
      echo "Error: Failed to fetch countries list. Check network." >&2
      log "Failed to fetch countries list"
      cleanup
      exit 1
    fi
  fi

  if [ -n "$countries" ]; then
    country=$(echo "$countries" | sort | fzf --reverse --prompt="Select Country > " --border --height=20 --bind "ctrl-x:execute(kill -s ${SIG_EXIT} $$)+abort")
    if [ -z "$country" ]; then
      log "Country selection aborted."
      return 1  # 関数を抜ける
    fi
    log "Country selected: $country"
    return 0
  else
    echo "Error: No countries found." >&2
    log "No countries found."
    cleanup
    exit 1
  fi
}

# 選局処理
select_station() {
  local stations
  CACHE_FILE="$CACHE_DIR/stations_${country}.json"

  clear  # 画面をクリア

  echo ""
  echo "--- Loading [ $country ] Radio Stations ---"
  echo ""

  # ラジオ局データの取得（キャッシュ利用）
  log "Using option: country=$country"
  if [ -f "$CACHE_FILE" ] && [ $(( $(date +%s) - $(stat -c %Y "$CACHE_FILE") )) -lt "$CACHE_TTL" ]; then
    stations=$(cat "$CACHE_FILE")
    log "Loaded cached data for $country"
  else
    stations=$(curl -s -f --max-time 10 "https://de1.api.radio-browser.info/json/stations/bycountry/$country" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$stations" ]; then
      mkdir -p "$CACHE_DIR" 2>/dev/null
      echo "$stations" > "$CACHE_FILE"
      log "Fetched and cached station data for $country"
    else
      echo "Error: Failed to fetch station data. Invalid country or network issue." >&2
      log "Failed to fetch station data for $country"
      return 1
    fi
  fi

  # ラジオ局をパース
  stations=$(echo "$stations" | jq -r "[.[] | select(.url_resolved != null)] | sort_by(-.votes) | .[] | \"\(.name)|\(.url_resolved)|\(.tags)\"")

  if [ -z "$stations" ]; then
    echo "Error: No radio stations found for country '$country'." >&2
    log "No stations found for $country"
    return 1
  fi

  selection=$(echo "$stations" | fzf --reverse --prompt="  Popular $country Radio > " --border --height=20 --bind "ctrl-b:execute(print $BACK_TO_COUNTRY)+abort" --bind "q:execute(print $QUIT_MPLAYER)+abort")

  if [ -z "$selection" ]; then
    log "Station selection aborted."
    return 1  # 選局をキャンセル
  fi

  # 選択した局の情報
  name=$(echo "$selection" | cut -d'|' -f1 | xargs)
  url=$(echo "$selection" | cut -d'|' -f2 | xargs)
  tags=$(echo "$selection" | cut -d'|' -f3 | xargs)
  display_text=" [$country] - $name | $url"

  # 曲情報リセット
  NOW_PLAYING=""
  NOW_PLAYING_CHECKED=0

  log "Selected station: $name ($url)"
  return 0  # 正常終了
}

# 再生処理
play_station() {
  local retries=0
  while [ "$retries" -lt "$STREAM_RETRIES" ]; do
    # 前回のmplayerプロセスが残っていれば確実に終了させる
    stop_mplayer
    
    # FIFOファイルとINFO_FILEの準備
    rm -f "$FIFO_PATH" "$INFO_FILE" 2>/dev/null
    mkfifo "$FIFO_PATH" 2>/dev/null || {
      echo "Error: Failed to create FIFO file." >&2
      log "FIFO creation failed"
      return 1
    }
    touch "$INFO_FILE"

    # 画面表示の更新
    update_display clear

    # 接続試行中のメッセージを表示
    echo ""
    echo "Connecting to stream... (Press ESC to cancel, q to quit) (Attempt $((retries + 1))/$STREAM_RETRIES)"
    log "Attempting to connect to stream: $url (Attempt $((retries + 1))/$STREAM_RETRIES)"

    # MPlayerの実行（バックグラウンド）- 曲情報取得オプション追加
    mplayer -volume 20 -slave -really-quiet -input file="$FIFO_PATH" -idle -title "${name} - \${track}" "$url" > "$INFO_FILE" 2>&1 &
    mplayer_pid=$!
    log "Started mplayer with PID: $mplayer_pid"

    # 標準入力の設定を変更（非カノニカルモード）
    # -echo: エコーをオフ、-icanon: キーがすぐに渡されるように、-isig: Ctrl+Cなどのシグナルをブロック
    stty -echo -icanon min 0 time 0
    log "Terminal set to raw mode for key input"

    local timeout_counter=0
    local connect_success=0

    # メインループ
    while true; do
      # キー入力を最優先で確認する（接続状態に関わらず）
      if read -r -n 1 -t 0.1 char; then  # 0.1秒だけ待つ
        # ESCキーの検出
        if [ "$char" = $'\033' ]; then
          log "ESC key detected - returning to station selection"
          echo "quit" > "$FIFO_PATH" 2>/dev/null
          kill -s TERM "$mplayer_pid" 2>/dev/null
          wait "$mplayer_pid" 2>/dev/null
          mplayer_pid=""
          # ここで関数をreturnして、select_stationに戻る
          restore_terminal_state
          rm -f "$FIFO_PATH" "$INFO_FILE" 2>/dev/null
          return 0
        fi

        # qキーの検出
        if [ "$char" = "q" ]; then
          log "Quit key detected - exiting program"
          echo "quit" > "$FIFO_PATH" 2>/dev/null
          kill -s TERM "$mplayer_pid" 2>/dev/null
          wait "$mplayer_pid" 2>/dev/null
          mplayer_pid=""
          cleanup
          exit 0
        fi
      fi

      # MPlayerプロセスが生きているか確認
      if ! kill -0 "$mplayer_pid" 2>/dev/null; then
        log "MPlayer process terminated unexpectedly"
        break
      fi

      # タイムアウトカウンターを増やす
      timeout_counter=$((timeout_counter + 1))
      if [ "$timeout_counter" -ge "$((STREAM_TIMEOUT * 10))" ]; then  # sleep 0.1 なので10倍
        echo "Stream connection timed out. Press ESC to return or q to quit."
        log "Connection timeout reached"
        # タイムアウト後もキー入力を受け付ける
        stop_mplayer
        break  # タイムアウトしたら、内側のwhileループを抜けてリトライ
      fi

      # 曲情報の取得（10秒ごと）
      if [ "$((timeout_counter % 100))" -eq 0 ] || [ "$NOW_PLAYING_CHECKED" -eq 0 ]; then
        echo "get_meta_title" > "$FIFO_PATH" 2>/dev/null
        sleep 0.2  # MPlayerが応答するのを少し待つ
        new_track=$(grep -a "ANS_META_TITLE=" "$INFO_FILE" | tail -n 1 | sed 's/ANS_META_TITLE=//')
        if [ -n "$new_track" ] && [ "$new_track" != "$NOW_PLAYING" ]; then
          NOW_PLAYING="$new_track"
          update_display  # 曲が変わったら表示を更新
          log "Track changed: $NOW_PLAYING"
        fi
        NOW_PLAYING_CHECKED=1
      fi

      # ストリーム接続状態を確認
      if grep -q "Starting playback" "$INFO_FILE" 2>/dev/null; then
        update_display  # 接続成功時に表示を更新
        log "Stream playback started"
        connect_success=1
        # 接続に成功したら、内側のループを維持
      elif grep -q "Failed to open" "$INFO_FILE" 2>/dev/null || grep -q "Error opening" "$INFO_FILE" 2>/dev/null; then
        echo "Stream connection failed. Press ESC to return or q to quit."
        log "Stream connection failed"
        # エラー後もすぐには終了せず、ESCやqキーによる終了の機会を与える
        sleep 1  # ユーザーがメッセージを読む時間を与える
        stop_mplayer
        break  # 接続失敗したら、内側のwhileループを抜けてリトライ
      fi

      # 接続に成功した場合は、タイムアウトカウンターをリセット
      if [ "$connect_success" -eq 1 ]; then
        timeout_counter=0
        connect_success=2  # 一度だけリセットするためのフラグ
      fi

      sleep 0.1
    done

    # 標準入力の設定を元に戻す
    restore_terminal_state

    # 一時ファイルのクリーンアップ
    rm -f "$FIFO_PATH" "$INFO_FILE" 2>/dev/null

    # 接続に成功したか確認
    if [ "$connect_success" -ge 1 ]; then
      break  # 接続に成功したら、リトライループを抜ける
    fi

    retries=$((retries + 1))
    log "Stream connection failed, retrying (Attempt $retries/$STREAM_RETRIES)"
  done

  if [ "$retries" -eq "$STREAM_RETRIES" ] && [ "$connect_success" -eq 0 ]; then
    log "Stream connection failed after $STREAM_RETRIES retries"
    # 全てのリトライが失敗した場合も、ESCキーによる終了を可能にする待機時間を設ける
    echo "All connection attempts failed. Press ESC to return or q to quit."
    stty -echo -icanon min 0 time 0
    local wait_key=0
    while [ "$wait_key" -lt 50 ]; do  # 5秒間待機
      if read -r -n 1 -t 0.1 char; then
        if [ "$char" = $'\033' ]; then
          restore_terminal_state
          return 0
        elif [ "$char" = "q" ]; then
          restore_terminal_state
          cleanup
          exit 0
        fi
      fi
      wait_key=$((wait_key + 1))
      sleep 0.1
    done
    restore_terminal_state
    return 1  # 全てのリトライが失敗したら、エラーを返す
  fi

  return 0  # 正常終了
}

# シグナルハンドラ
handle_sigterm() {
  log "SIGTERM/SIGINT received. Exiting..."
  stop_mplayer
  cleanup
  exit 0
}

handle_sigcountry() {
  log "SIG_COUNTRY received. Returning to country selection..."
  stop_mplayer
  country=""
  return
}

handle_sigexit() {
  log "SIG_EXIT received. Exiting..."
  cleanup
  exit 0
}

# メイン処理

# 依存コマンドのチェック
check_dependencies

# 端末の状態を保存
save_terminal_state

# コマンドライン引数の処理
while getopts "c:l" opt; do
  case $opt in
    c) country="$OPTARG" ;;
    l)
      # 国リストの表示
      local countries
      countries=$(curl -s -f --max-time 10 "https://de1.api.radio-browser.info/json/countries" 2>/dev/null | jq -r '.[] | .name' | sort)
      echo "$countries"
      exit 0
      ;;
    *) echo "Usage: $0 [-c <country>] [-l]"; exit 1 ;;
  esac
done

# 初期化
country=""

# シグナルハンドラの設定 - SIGINTも必ず処理する
trap handle_sigterm SIGTERM SIGINT
trap handle_sigcountry "$SIG_COUNTRY"
trap handle_sigexit "$SIG_EXIT"

# キャッシュディレクトリの作成
mkdir -p "$CACHE_DIR" 2>/dev/null || {
  echo "Error: Failed to create cache directory." >&2
  log "Cache directory creation failed"
  exit 1
}

# カーソルを非表示
tput civis

# 終了時のトラップ
trap cleanup EXIT

# メインループ
while true; do
  # 国が選択されていなければ選択を促す
  if [ -z "$country" ]; then
    select_country || {
      # 国選択がキャンセルされた場合
      cleanup
      exit 0
    }
  fi

  # 局を選択
  while true; do  # 局選択ループを追加
    if select_station; then
      # 正常に局が選択されたら再生処理へ
      if play_station; then
        # 再生が終了または中断されたら局選択に戻る
        continue  # 局選択ループの先頭に戻る
      else
        # play_stationがエラーで終了した場合
        break  # 局選択ループから抜ける
      fi
    else
      # 曲選択がキャンセルされた場合、国選択からやり直す
      break  # 局選択ループから抜ける
    fi
  done
  # 局選択ループから抜けたら、国選択に戻る
  country=""
done
