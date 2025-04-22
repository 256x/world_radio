# 🌍 World Radio Script

A terminal-based script to browse and play live radio stations by country using `mplayer`, `fzf`, and `jq`.

---

## 📦 Requirements

Make sure the following tools are installed:

- `curl`
- `jq`
- `fzf`
- `mplayer`
- `tput` (usually part of `ncurses`)

You can install them via `apt`, `brew`, `pkg`, etc., depending on your system.

---

## 🔧 Setup

1. Clone this repository:

   ```bash
   git clone https://github.com/yourusername/world-radio
   cd world-radio
   chmod +x world_radio.txt
   ```

2. (Optional) Create a `.countries` file manually if you want to override or cache the country list.

---

## ▶️ Usage

### Basic Launch

```bash
./world_radio.sh
```

- First, select a **country**.
- Then, choose a **station**.
- Press `ESC` to go back to country or station list.
- Press `q` to quit.

### Show All Available Countries

```bash
./world_radio.txt -l
```

### Start with Preselected Country

```bash
./world_radio.txt -c "Japan"
```

---

## 🩼 Notes

- A cache of radio stations per country is stored in: `~/.cache/radio_script/`
- Temporary files used:
  - `/tmp/mplayer_radio_fifo`
  - `/tmp/mplayer_radio_info`
- Cursor and terminal settings are restored after exit.
- All activity is logged to `/tmp/radio_script.log`.

---

## 📃 License

MIT License (Feel free to modify or redistribute)

---

## 🙏 Thanks

- [radio-browser.info](https://www.radio-browser.info/) - Public Radio API

---

