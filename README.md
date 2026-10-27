# Linux Neural Read-Aloud (`setup-linux-tts.sh`)
    
    Tired of Linux screen readers sounding like a 1980s robot (`espeak-ng`) or having to download a **7.6 GB** Flatpak just to have your PC read study
    material aloud?
    
    **`setup-linux-tts.sh`** is a single, self-contained installer script that sets up **100% offline, natural-sounding Neural Text-to-Speech** on Linux
    using [Piper TTS](https://github.com/rhasspy/piper) and `speech-dispatcher` in **~190 MB total**.
    
    Once installed, simply **highlight any text with your mouse** and press **`Super + Alt + S`** (`Meta + Alt + S`) to have it read aloud. Press
    **`Super + Alt + S`** again anytime to stop speaking.
    
    ---

    ## ✨ Features

    - **Natural Neural Voices (100% Offline):** Uses official standalone Piper ONNX voice models running fast on your CPU (~0.2s latency, no GPU or
    ￹internet required).
    - **Tiny Footprint (~190 MB total):**
      - Piper engine + ONNX runtime: `52 MB`
      - High-quality English voice (`en_US-lessac-high`): `109 MB` (or Norwegian `no_NO-talesyntese-medium`: `~60 MB`)
      - System packages (`speech-dispatcher`, `wl-clipboard` / `xclip`): `~28 MB`
    - **Works System-Wide:**
      - Includes a toggleable **`speak-selection`** script bound to **`Super + Alt + S`**.
      - Also hooks Piper into **Speech Dispatcher**, so built-in *"Speak Text"* features in **Okular**, **Kate**, **Orca**, and browsers automatically
      ￹use the neural voice.
    - **Universal Distro Support (Official Repos Only — No AUR):**
      - Automatically detects and uses `pacman` (Arch / CachyOS / Manjaro), `apt` (Debian / Ubuntu / Linux Mint / Pop!_OS), `dnf` (Fedora / RHEL),
      ￹`zypper` (openSUSE), `xbps` (Void), `apk` (Alpine), `eopkg` (Solus), `emerge` (Gentoo), or `slackpkg` (Slackware).
    - **Wayland & X11 Native:**
      - Reads highlighted text directly from the primary selection (`wl-paste --primary` on Wayland, `xclip`/`xsel` on X11) without needing to press
      ￹`Ctrl+C`, with automatic fallback to your clipboard.
    - **Multi-Desktop Hotkey Auto-Configuration:**
      - Automatically configures `Super + Alt + S` on **KDE Plasma (5 & 6)**, **GNOME**, **Cinnamon**, **MATE**, **XFCE**, **Hyprland**, **Sway**, and
      ￹**i3wm**.
    - **Safe, Atomic & Reversible:**
      - Verifies **SHA-256 checksums** for all downloaded binaries and models.
      - Uses atomic downloads (`mktemp` + `mv`) and `flock` concurrency locking.
      - Preserves and backs up existing `speechd.conf` settings using idempotent managed blocks.
      - Includes a one-command `--uninstall` that cleanly rolls back all files, configs, and hotkeys.

    ---

    ## 🚀 Quick Start

    Clone the repository and run the installer as your normal desktop user:

    ```bash
    chmod +x setup-linux-tts.sh
    ./setup-linux-tts.sh

  (The script will only prompt for sudo / doas / pkexec if system packages like speech-dispatcher or wl-clipboard are missing).
  ──────
  ## ⚙ Command-Line Options

    Usage: ./setup-linux-tts.sh [OPTIONS]

    Options:
      --lang <en|no|both>                 Install English ('en'), Norwegian ('no'), or 'both' (default: en)
      --source <auto|primary|clipboard>   Text source priority:
                                            auto      - Primary selection first, then clipboard (default)
                                            primary   - Highlighted text (primary selection) only
                                            clipboard - Copied text (Ctrl+C clipboard) first
      --max-chars <N>                     Max characters to read at once (default: 8000)
      --force, --update, -f               Re-download & overwrite binaries/models and update packages
      --uninstall                         Remove installed files and restore previous config/hotkeys
      --help, -h                          Show this help message

  ### Examples

  Install with Norwegian voice model (no_NO-talesyntese-medium):

    ./setup-linux-tts.sh --lang no

  Install both English and Norwegian models:

    ./setup-linux-tts.sh --lang both

  Prefer Ctrl+C clipboard over mouse highlight:

    ./setup-linux-tts.sh --source clipboard

  Cleanly uninstall everything and restore original settings:

    ./setup-linux-tts.sh --uninstall
  ──────
  ## 🛠 How It Works Under the Hood

  1. ~/.local/share/piper-tts/ — Stores the standalone Piper binary (x86_64, aarch64, or armv7l), the .onnx voice model, and a safe stdin wrapper
  (piper-spd-synth) that dynamically reads the model's sample rate from its .onnx.json metadata.
  2. ~/.local/bin/speak-selection — Grabs your currently highlighted text (or clipboard), pipes it directly via stdin to Piper (preventing any shell-
  injection risks), and tracks playback with a dedicated process group + PID file ($XDG_RUNTIME_DIR/speak-selection-$UID.pid) so pressing Super + Alt +
  ￹S a second time immediately stops playback.
  3. ~/.config/speech-dispatcher/ — Adds a piper-generic.conf module and appends a non-destructive managed block to speechd.conf so applications using
  speech-dispatcher (spd-say, Okular, Orca) use Piper automatically.
