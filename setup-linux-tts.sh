#!/usr/bin/env bash
# ==============================================================================
# setup-linux-tts.sh
# Universal Linux Neural Text-to-Speech (Piper TTS + Speech Dispatcher) Installer
#
# Usage:
#   ./setup-linux-tts.sh [OPTIONS]
#
# Options:
#   --lang <en|no|both>      Voice language to install & set as default (default: en)
#   --source <auto|primary|clipboard>
#                            Selection source priority for speak-selection (default: auto)
#   --max-chars <N>          Maximum characters to read per invocation (default: 8000)
#   --force, --update, -f    Re-download/override binaries, models, and update packages
#   --uninstall              Cleanly remove installed files, restore backups & hotkeys
#   --help, -h               Show this help message
# ==============================================================================

set -euo pipefail

# --- Colors & Logging ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { printf '%b[INFO]%b %b\n' "${BLUE}" "${NC}" "$*"; }
success() { printf '%b[OK]%b %b\n' "${GREEN}" "${NC}" "$*"; }
warn()    { printf '%b[WARN]%b %b\n' "${YELLOW}" "${NC}" "$*" >&2; }
error()   { printf '%b[ERROR]%b %b\n' "${RED}" "${NC}" "$*" >&2; }

# --- Paths & Defaults ---
PIPER_VERSION="${PIPER_VERSION:-2023.11.14-2}"
INSTALL_DIR="${HOME}/.local/share/piper-tts"
STATE_DIR="${INSTALL_DIR}/state"
BIN_DIR="${HOME}/.local/bin"
SPEAK_SCRIPT="${BIN_DIR}/speak-selection"
SYNTH_WRAPPER="${INSTALL_DIR}/piper-spd-synth"
SPD_CONFIG_DIR="${HOME}/.config/speech-dispatcher"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/setup-linux-tts-${UID}.lock"

LANG_CHOICE="${LANG_CHOICE:-en}"
SELECTION_SOURCE="${SELECTION_SOURCE:-auto}"
MAX_CHARS="${MAX_CHARS:-8000}"
FORCE_UPDATE=false
UNINSTALL=false

# Known SHA-256 checksums for official Piper 2023.11.14-2 binaries & models
declare -A PIPER_SHA256=(
    ["piper_linux_x86_64.tar.gz"]="a50cb45f355b7af1f6d758c1b360717877ba0a398cc8cbe6d2a7a3a26e225992"
    ["piper_linux_aarch64.tar.gz"]="fea0fd2d87c54dbc7078d0f878289f404bd4d6eea6e7444a77835d1537ab88eb"
    ["piper_linux_armv7l.tar.gz"]="c6946fcd57c705ed1d4666ea880f80ba0bbbd14de62ecbdd13460baf3bac8e37"
)

declare -A MODEL_URLS=(
    ["en_US-lessac-high"]="https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/high"
    ["no_NO-talesyntese-medium"]="https://huggingface.co/rhasspy/piper-voices/resolve/main/no/no_NO/talesyntese/medium"
)

declare -A MODEL_ONNX_SHA256=(
    ["en_US-lessac-high"]="4cabf7c3a638017137f34a1516522032d4fe3f38228a843cc9b764ddcbcd9e09"
    ["no_NO-talesyntese-medium"]="b763aebe02e72c4628c4074c4b8b448f05ffe523b975bfcd58e2c5d531270c13"
)

declare -A MODEL_JSON_SHA256=(
    ["en_US-lessac-high"]="db42b97d9859f257bc1561b8ed980e7fb2398402050a74ddd6cbec931a92412f"
    ["no_NO-talesyntese-medium"]="b0eb0491fc8bf9843d2beac8acf8773b6cf59274316406b36ff579ae8a1909d5"
)

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

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
EOF
}

# ==============================================================================
# Argument Parsing & Validation
# ==============================================================================
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --lang)
                if [ "$#" -lt 2 ]; then
                    error "Missing argument for --lang (expected: en, no, or both)"
                    usage
                    exit 1
                fi
                LANG_CHOICE="$2"
                shift 2
                ;;
            --source)
                if [ "$#" -lt 2 ]; then
                    error "Missing argument for --source (expected: auto, primary, or clipboard)"
                    usage
                    exit 1
                fi
                SELECTION_SOURCE="$2"
                shift 2
                ;;
            --max-chars)
                if [ "$#" -lt 2 ]; then
                    error "Missing argument for --max-chars (expected positive integer)"
                    usage
                    exit 1
                fi
                MAX_CHARS="$2"
                shift 2
                ;;
            --force|--update|-f)
                FORCE_UPDATE=true
                shift
                ;;
            --uninstall)
                UNINSTALL=true
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                error "Unknown argument: '$1'"
                usage
                exit 1
                ;;
        esac
    done

    case "$LANG_CHOICE" in
        en|no|both) ;;
        *)
            error "Invalid --lang value '${LANG_CHOICE}'. Allowed values: en, no, both."
            exit 1
            ;;
    esac

    case "$SELECTION_SOURCE" in
        auto|primary|clipboard) ;;
        *)
            error "Invalid --source value '${SELECTION_SOURCE}'. Allowed values: auto, primary, clipboard."
            exit 1
            ;;
    esac

    if ! [[ "$MAX_CHARS" =~ ^[0-9]+$ ]] || [ "$MAX_CHARS" -lt 100 ] || [ "$MAX_CHARS" -gt 100000 ]; then
        error "Invalid --max-chars '${MAX_CHARS}'. Must be an integer between 100 and 100000."
        exit 1
    fi

    if ! [[ "$PIPER_VERSION" =~ ^[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}(-[0-9]+)?$ ]]; then
        error "Invalid PIPER_VERSION format: '${PIPER_VERSION}'."
        exit 1
    fi
}

# ==============================================================================
# Concurrency Lock & Cleanup Trap
# ==============================================================================
TMP_WORK_DIR=""
cleanup_tmp() {
    if [ -n "$TMP_WORK_DIR" ] && [ -d "$TMP_WORK_DIR" ]; then
        rm -rf "$TMP_WORK_DIR"
    fi
}
trap cleanup_tmp EXIT INT TERM

acquire_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK_FILE"
        if ! flock -n 9; then
            error "Another instance of setup-linux-tts.sh is already running (lock: ${LOCK_FILE})."
            exit 1
        fi
    fi
}

# --- Argument-Safe Privilege Escalation ---
run_priv() {
    if command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    elif command -v doas >/dev/null 2>&1; then
        doas "$@"
    elif command -v pkexec >/dev/null 2>&1; then
        pkexec "$@"
    else
        error "No supported privilege escalation tool found (sudo, doas, or pkexec)."
        error "Please install 'sudo' or 'doas', or install the required system packages manually."
        exit 1
    fi
}

# ==============================================================================
# Managed Config Block Helper (Idempotent Updates & Removal for WM configs)
# ==============================================================================
MARKER_BEGIN="# >>> setup-linux-tts managed block >>>"
MARKER_END="# <<< setup-linux-tts managed block <<<"

remove_managed_block() {
    local target_file="$1"
    if [ ! -f "$target_file" ]; then
        return 0
    fi
    if grep -qF "$MARKER_BEGIN" "$target_file" 2>/dev/null; then
        local tmp_f="${target_file}.tts-tmp.$$"
        awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
            $0 == b { skip=1; next }
            $0 == e { skip=0; next }
            !skip { print }
        ' "$target_file" > "$tmp_f"
        mv "$tmp_f" "$target_file"
    fi
}

upsert_managed_block() {
    local target_file="$1"
    local content="$2"
    remove_managed_block "$target_file"
    # Also remove legacy unmanaged comment/line if present from older script versions
    if grep -qF "speak-selection" "$target_file" 2>/dev/null; then
        local tmp_f="${target_file}.tts-legacy.$$"
        grep -vF "speak-selection" "$target_file" | grep -vF "# Read selected text aloud (Piper TTS)" > "$tmp_f" || true
        mv "$tmp_f" "$target_file"
    fi
    printf '\n%s\n%s\n%s\n' "$MARKER_BEGIN" "$content" "$MARKER_END" >> "$target_file"
}

# ==============================================================================
# 1. Detect OS Base & Package Manager
# ==============================================================================
DISTRO_ID="unknown"
DISTRO_LIKE=""
PM="unknown"

detect_distro_and_pm() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_LIKE="${ID_LIKE:-}"
    fi

    if command -v pacman >/dev/null 2>&1; then
        PM="pacman"
    elif command -v apt-get >/dev/null 2>&1; then
        PM="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PM="dnf"
    elif command -v zypper >/dev/null 2>&1; then
        PM="zypper"
    elif command -v xbps-install >/dev/null 2>&1; then
        PM="xbps"
    elif command -v apk >/dev/null 2>&1; then
        PM="apk"
    elif command -v eopkg >/dev/null 2>&1; then
        PM="eopkg"
    elif command -v emerge >/dev/null 2>&1; then
        PM="emerge"
    elif command -v slackpkg >/dev/null 2>&1 || [ -f /etc/slackware-version ]; then
        PM="slackpkg"
    else
        PM="unknown"
    fi

    info "Detected OS: ${BOLD}${DISTRO_ID}${NC} ${DISTRO_LIKE:+(base: ${DISTRO_LIKE})} | Package Manager: ${BOLD}${PM}${NC}"
}

# ==============================================================================
# 2. Package Mapping & Verification Per Distribution
# ==============================================================================
get_distro_packages() {
    case "$PM" in
        pacman)
            echo "speech-dispatcher wl-clipboard xclip libpulse alsa-utils curl tar"
            ;;
        apt)
            echo "speech-dispatcher speech-dispatcher-utils wl-clipboard xclip pulseaudio-utils alsa-utils curl tar"
            ;;
        dnf)
            echo "speech-dispatcher speech-dispatcher-utils wl-clipboard xclip pulseaudio-utils alsa-utils curl tar"
            ;;
        zypper)
            echo "speech-dispatcher wl-clipboard xclip pulseaudio-utils alsa-utils curl tar"
            ;;
        xbps)
            echo "speech-dispatcher wl-clipboard xclip pulseaudio-utils alsa-utils curl tar"
            ;;
        apk)
            echo "speech-dispatcher wl-clipboard xclip pulseaudio-utils alsa-utils curl tar"
            ;;
        eopkg)
            echo "speech-dispatcher wl-clipboard xclip pulseaudio alsa-utils curl tar"
            ;;
        emerge)
            echo "app-accessibility/speech-dispatcher gui-apps/wl-clipboard x11-misc/xclip media-sound/alsa-utils net-misc/curl app-arch/tar"
            ;;
        slackpkg)
            echo "speech-dispatcher xclip alsa-utils curl tar"
            ;;
        *)
            echo ""
            ;;
    esac
}

check_required_commands() {
    local missing=()
    for cmd in spd-say speech-dispatcher curl tar sha256sum; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    # Require at least one audio player
    if ! command -v paplay >/dev/null 2>&1 && ! command -v pw-play >/dev/null 2>&1 && ! command -v aplay >/dev/null 2>&1; then
        missing+=("paplay/pw-play/aplay")
    fi

    # Require clipboard tool matching current session
    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
        if ! command -v wl-paste >/dev/null 2>&1; then
            missing+=("wl-paste")
        fi
    else
        if ! command -v xclip >/dev/null 2>&1 && ! command -v xsel >/dev/null 2>&1; then
            missing+=("xclip")
        fi
    fi

    if [ "${#missing[@]}" -gt 0 ]; then
        printf '%s\n' "${missing[@]}"
        return 1
    fi
    return 0
}

install_dependencies() {
    info "Checking required system commands..."

    local missing_cmds=""
    if missing_cmds="$(check_required_commands)" && [ "$FORCE_UPDATE" = false ]; then
        success "All required system utilities are present."
        return 0
    fi

    if [ -n "$missing_cmds" ]; then
        info "Missing commands detected: $(echo "$missing_cmds" | tr '\n' ' ')"
    fi

    local pkg_str
    pkg_str="$(get_distro_packages)"
    if [ -z "$pkg_str" ]; then
        error "Unsupported package manager (${PM}) and required commands are missing: $(echo "$missing_cmds" | tr '\n' ' ')"
        exit 1
    fi

    # Convert space-separated string to array
    local pkgs=()
    read -r -a pkgs <<< "$pkg_str"

    info "Installing packages via ${BOLD}${PM}${NC}: ${pkgs[*]}"

    case "$PM" in
        pacman)
            if [ "$FORCE_UPDATE" = true ]; then
                run_priv pacman -Syu --needed "${pkgs[@]}"
            else
                run_priv pacman -S --needed "${pkgs[@]}"
            fi
            ;;
        apt)
            run_priv apt-get update
            run_priv apt-get install -y "${pkgs[@]}"
            ;;
        dnf)
            if [ "$FORCE_UPDATE" = true ]; then
                run_priv dnf upgrade --refresh -y "${pkgs[@]}" || run_priv dnf install -y "${pkgs[@]}"
            else
                run_priv dnf install -y "${pkgs[@]}"
            fi
            ;;
        zypper)
            run_priv zypper install -y "${pkgs[@]}"
            ;;
        xbps)
            run_priv xbps-install -Sy "${pkgs[@]}"
            ;;
        apk)
            run_priv apk add "${pkgs[@]}"
            ;;
        eopkg)
            run_priv eopkg install -y "${pkgs[@]}"
            ;;
        emerge)
            run_priv emerge --ask=n --noreplace "${pkgs[@]}"
            ;;
        slackpkg)
            for spkg in "${pkgs[@]}"; do
                if ! compgen -G "/var/log/packages/${spkg}-*" >/dev/null 2>&1; then
                    run_priv slackpkg install "$spkg"
                fi
            done
            ;;
    esac

    # Post-install strict verification
    if ! missing_cmds="$(check_required_commands)"; then
        error "Package installation finished, but required commands are still missing: $(echo "$missing_cmds" | tr '\n' ' ')"
        exit 1
    fi

    success "All required dependencies verified."
}

# ==============================================================================
# 3. Atomic Download, Checksum Verification & Sample Rate Extraction
# ==============================================================================
verify_sha256() {
    local file="$1"
    local expected="$2"
    if [ -z "$expected" ]; then
        return 0
    fi
    local actual
    actual="$(sha256sum "$file" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        error "SHA-256 mismatch for $(basename "$file")!"
        error "  Expected: ${expected}"
        error "  Actual:   ${actual}"
        return 1
    fi
    return 0
}

download_model_atomically() {
    local model_name="$1"
    local base_url="${MODEL_URLS[$model_name]:-}"
    if [ -z "$base_url" ]; then
        error "Unknown model '${model_name}'."
        exit 1
    fi

    local onnx_dest="${INSTALL_DIR}/${model_name}.onnx"
    local json_dest="${INSTALL_DIR}/${model_name}.onnx.json"
    local expected_onnx_sha="${MODEL_ONNX_SHA256[$model_name]:-}"
    local expected_json_sha="${MODEL_JSON_SHA256[$model_name]:-}"

    if [ "$FORCE_UPDATE" = false ] && [ -s "$onnx_dest" ] && [ -s "$json_dest" ]; then
        if verify_sha256 "$onnx_dest" "$expected_onnx_sha" && verify_sha256 "$json_dest" "$expected_json_sha"; then
            success "Model '${model_name}' is already installed and verified."
            return 0
        else
            warn "Existing model '${model_name}' failed checksum check; re-downloading..."
        fi
    fi

    local tmp_onnx="${TMP_WORK_DIR}/${model_name}.onnx.part"
    local tmp_json="${TMP_WORK_DIR}/${model_name}.onnx.json.part"

    info "Downloading voice model '${model_name}'..."
    curl --fail --location --show-error --progress-bar \
        "${base_url}/${model_name}.onnx" -o "$tmp_onnx"
    curl --fail --location --show-error \
        "${base_url}/${model_name}.onnx.json" -o "$tmp_json"

    if [ ! -s "$tmp_onnx" ] || [ ! -s "$tmp_json" ]; then
        error "Downloaded model files for '${model_name}' are empty or incomplete."
        exit 1
    fi

    verify_sha256 "$tmp_onnx" "$expected_onnx_sha"
    verify_sha256 "$tmp_json" "$expected_json_sha"

    # Validate JSON structure and sample_rate field before moving into place
    local sr
    sr="$(extract_sample_rate "$tmp_json")"
    if ! [[ "$sr" =~ ^[0-9]+$ ]] || [ "$sr" -lt 8000 ] || [ "$sr" -gt 96000 ]; then
        error "Model metadata JSON for '${model_name}' does not contain a valid audio.sample_rate (got: '${sr}')."
        exit 1
    fi

    mv -f "$tmp_onnx" "$onnx_dest"
    mv -f "$tmp_json" "$json_dest"
    success "Installed and verified voice model '${model_name}' (sample rate: ${sr} Hz)."
}

extract_sample_rate() {
    local json_file="$1"
    local sr=""
    if command -v jq >/dev/null 2>&1; then
        sr="$(jq -r '.audio.sample_rate // empty' "$json_file" 2>/dev/null || true)"
    elif command -v python3 >/dev/null 2>&1; then
        sr="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("audio",{}).get("sample_rate",""))' "$json_file" 2>/dev/null || true)"
    else
        sr="$(grep -oE '"sample_rate"[[:space:]]*:[[:space:]]*[0-9]+' "$json_file" | head -n1 | grep -oE '[0-9]+' || true)"
    fi
    echo "${sr:-22050}"
}

install_piper() {
    mkdir -p "$INSTALL_DIR" "$STATE_DIR"
    TMP_WORK_DIR="$(mktemp -d "${INSTALL_DIR}/.tmp-install.XXXXXX")"

    local arch
    arch="$(uname -m)"
    local piper_archive=""
    case "$arch" in
        x86_64|amd64)   piper_archive="piper_linux_x86_64.tar.gz" ;;
        aarch64|arm64)  piper_archive="piper_linux_aarch64.tar.gz" ;;
        armv7l|armv7*)  piper_archive="piper_linux_armv7l.tar.gz" ;;
        *)
            error "Unsupported CPU architecture for prebuilt Piper binary: ${arch}"
            exit 1
            ;;
    esac

    local expected_tar_sha=""
    if [ "$PIPER_VERSION" = "2023.11.14-2" ]; then
        expected_tar_sha="${PIPER_SHA256[$piper_archive]:-}"
    fi

    if [ ! -x "${INSTALL_DIR}/piper/piper" ] || [ "$FORCE_UPDATE" = true ]; then
        local tmp_tar="${TMP_WORK_DIR}/${piper_archive}"
        local tmp_extract="${TMP_WORK_DIR}/extracted"
        mkdir -p "$tmp_extract"

        info "Downloading Piper Neural TTS (${arch}, version ${PIPER_VERSION})..."
        curl --fail --location --show-error --progress-bar \
            "https://github.com/rhasspy/piper/releases/download/${PIPER_VERSION}/${piper_archive}" \
            -o "$tmp_tar"

        verify_sha256 "$tmp_tar" "$expected_tar_sha"

        # Verify archive integrity before extracting
        tar -tzf "$tmp_tar" >/dev/null
        tar -xzf "$tmp_tar" -C "$tmp_extract"

        if [ ! -x "${tmp_extract}/piper/piper" ]; then
            error "Archive extracted, but piper binary was not found inside."
            exit 1
        fi

        rm -rf "${INSTALL_DIR}/piper"
        mv "${tmp_extract}/piper" "${INSTALL_DIR}/piper"
        success "Piper engine atomically installed to ${INSTALL_DIR}/piper/piper"
    else
        success "Piper binary already installed at ${INSTALL_DIR}/piper/piper"
    fi

    case "$LANG_CHOICE" in
        en)
            download_model_atomically "en_US-lessac-high"
            ;;
        no)
            download_model_atomically "no_NO-talesyntese-medium"
            ;;
        both)
            download_model_atomically "en_US-lessac-high"
            download_model_atomically "no_NO-talesyntese-medium"
            ;;
    esac
}

# ==============================================================================
# 4. Safe Speech Dispatcher Wrapper & Non-Destructive Configuration
# ==============================================================================
create_synth_wrapper() {
    info "Creating safe synthesis wrapper at ${SYNTH_WRAPPER}..."

    cat > "$SYNTH_WRAPPER" <<'EOF'
#!/usr/bin/env bash
# Safe synthesis wrapper for Speech Dispatcher -> Piper TTS.
# Reads text strictly from standard input (never interpolates text as shell code),
# dynamically reads the model's sample rate from its .onnx.json file, and streams
# raw audio to the system audio player.

set -euo pipefail

INSTALL_DIR="${HOME}/.local/share/piper-tts"
VOICE_NAME="${1:-en_US-lessac-high}"
LANG_CODE="${2:-en}"

# Sanitize voice name to prevent path traversal
case "$VOICE_NAME" in
    en_US-lessac-high|no_NO-talesyntese-medium) ;;
    *)
        if [[ "$LANG_CODE" == nb* ]] || [[ "$LANG_CODE" == no* ]] || [[ "$LANG_CODE" == nn* ]]; then
            if [ -f "${INSTALL_DIR}/no_NO-talesyntese-medium.onnx" ]; then
                VOICE_NAME="no_NO-talesyntese-medium"
            else
                VOICE_NAME="en_US-lessac-high"
            fi
        else
            if [ -f "${INSTALL_DIR}/en_US-lessac-high.onnx" ]; then
                VOICE_NAME="en_US-lessac-high"
            else
                VOICE_NAME="no_NO-talesyntese-medium"
            fi
        fi
        ;;
esac

MODEL_ONNX="${INSTALL_DIR}/${VOICE_NAME}.onnx"
MODEL_JSON="${INSTALL_DIR}/${VOICE_NAME}.onnx.json"

if [ ! -f "$MODEL_ONNX" ] || [ ! -f "$MODEL_JSON" ]; then
    exit 1
fi

# Extract sample rate from model metadata JSON
SAMPLE_RATE="$(grep -oE '"sample_rate"[[:space:]]*:[[:space:]]*[0-9]+' "$MODEL_JSON" | head -n1 | grep -oE '[0-9]+' || true)"
SAMPLE_RATE="${SAMPLE_RATE:-22050}"

if command -v paplay >/dev/null 2>&1; then
    "${INSTALL_DIR}/piper/piper" --model "$MODEL_ONNX" --output-raw \
        | paplay --raw --rate="$SAMPLE_RATE" --format=s16le --channels=1
elif command -v pw-play >/dev/null 2>&1; then
    "${INSTALL_DIR}/piper/piper" --model "$MODEL_ONNX" --output-raw \
        | pw-play --rate="$SAMPLE_RATE" --format=s16 --channels=1 -
else
    "${INSTALL_DIR}/piper/piper" --model "$MODEL_ONNX" --output-raw \
        | aplay -q -r "$SAMPLE_RATE" -f S16_LE -t raw -
fi
EOF

    chmod +x "$SYNTH_WRAPPER"
}

configure_speech_dispatcher() {
    info "Configuring Speech Dispatcher..."
    mkdir -p "${SPD_CONFIG_DIR}/modules" "${SPD_CONFIG_DIR}/clients" "$STATE_DIR"

    create_synth_wrapper

    local audio_dep="aplay"
    if command -v paplay >/dev/null 2>&1; then
        audio_dep="paplay"
    elif command -v pw-play >/dev/null 2>&1; then
        audio_dep="pw-play"
    fi

    local default_voice="en_US-lessac-high"
    local default_lang="en"
    if [ "$LANG_CHOICE" = "no" ]; then
        default_voice="no_NO-talesyntese-medium"
        default_lang="nb"
    fi

    # Write module configuration.
    # Speech Dispatcher's sd_generic replaces $DATA inside double-quoted strings,
    # so we strip single quotes and backslashes via GenericStripPunctChars and pass
    # '$DATA' inside single quotes into printf '%s', piped directly to SYNTH_WRAPPER stdin.
    {
        cat <<EOF
# Auto-generated by setup-linux-tts.sh
Debug 0
GenericExecuteSynth "printf '%s' '\$DATA' | ${SYNTH_WRAPPER} '\$VOICE' '\$LANGUAGE'"
GenericCmdDependency "${INSTALL_DIR}/piper/piper"
GenericCmdDependency "${SYNTH_WRAPPER}"
GenericCmdDependency "${audio_dep}"
GenericSoundIconFolder "/usr/share/sounds/sound-icons/"
GenericPunctNone ""
GenericPunctSome "--punct=\"()[]{};:\""
GenericPunctMost "--punct=\"()[]{};:\""
GenericPunctAll "--punct"
GenericStripPunctChars "'\\\`\$"
EOF
        if [ "$LANG_CHOICE" = "en" ] || [ "$LANG_CHOICE" = "both" ]; then
            cat <<EOF
GenericLanguage "en" "en_US" "utf-8"
AddVoice "en" "FEMALE1" "en_US-lessac-high"
AddVoice "en" "MALE1" "en_US-lessac-high"
EOF
        fi
        if [ "$LANG_CHOICE" = "no" ] || [ "$LANG_CHOICE" = "both" ]; then
            cat <<EOF
GenericLanguage "nb" "nb_NO" "utf-8"
GenericLanguage "no" "nb_NO" "utf-8"
GenericLanguage "nn" "nn_NO" "utf-8"
AddVoice "nb" "FEMALE1" "no_NO-talesyntese-medium"
AddVoice "nb" "MALE1" "no_NO-talesyntese-medium"
AddVoice "no" "FEMALE1" "no_NO-talesyntese-medium"
AddVoice "nn" "FEMALE1" "no_NO-talesyntese-medium"
EOF
        fi
        printf 'DefaultVoice "%s"\n' "$default_voice"
    } > "${SPD_CONFIG_DIR}/modules/piper-generic.conf"

    local speechd_conf="${SPD_CONFIG_DIR}/speechd.conf"

    # If existing speechd.conf was overwritten by v1 of our script, restore from /etc/speech-dispatcher/speechd.conf first
    if [ -f "$speechd_conf" ] && head -n 2 "$speechd_conf" | grep -qF "# Auto-generated by setup-linux-tts.sh"; then
        if [ -f /etc/speech-dispatcher/speechd.conf ]; then
            cp /etc/speech-dispatcher/speechd.conf "$speechd_conf"
            info "Restored base template from /etc/speech-dispatcher/speechd.conf"
        fi
    fi

    # Backup existing speechd.conf once before our first modification
    if [ -f "$speechd_conf" ] && [ ! -f "${STATE_DIR}/speechd.conf.backup" ]; then
        if ! grep -qF "$MARKER_BEGIN" "$speechd_conf" 2>/dev/null; then
            cp -p "$speechd_conf" "${STATE_DIR}/speechd.conf.backup"
            info "Backed up existing ${speechd_conf} to ${STATE_DIR}/speechd.conf.backup"
        fi
    fi

    # If no user speechd.conf exists yet, copy the system template or create a minimal base
    if [ ! -f "$speechd_conf" ]; then
        if [ -f /etc/speech-dispatcher/speechd.conf ]; then
            cp /etc/speech-dispatcher/speechd.conf "$speechd_conf"
        else
            cat > "$speechd_conf" <<'EOF'
LogLevel 3
LogDir "default"
DefaultVolume 100
SymbolsPreproc "char"
SymbolsPreprocFile "gender-neutral.dic"
SymbolsPreprocFile "font-variants.dic"
SymbolsPreprocFile "symbols.dic"
SymbolsPreprocFile "emojis.dic"
SymbolsPreprocFile "orca.dic"
SymbolsPreprocFile "orca-chars.dic"
Include "clients/*.conf"
EOF
        fi
    fi

    # Build managed block for speechd.conf
    local spd_block="AddModule \"piper-generic\" \"sd_generic\" \"piper-generic.conf\"
DefaultModule piper-generic
DefaultLanguage \"${default_lang}\""

    if [ "$LANG_CHOICE" = "en" ] || [ "$LANG_CHOICE" = "both" ]; then
        spd_block="${spd_block}
LanguageDefaultModule \"en\" \"piper-generic\""
    fi
    if [ "$LANG_CHOICE" = "no" ] || [ "$LANG_CHOICE" = "both" ]; then
        spd_block="${spd_block}
LanguageDefaultModule \"nb\" \"piper-generic\"
LanguageDefaultModule \"no\" \"piper-generic\"
LanguageDefaultModule \"nn\" \"piper-generic\""
    fi

    upsert_managed_block "$speechd_conf" "$spd_block"

    # Save active default language for speak-selection
    printf '%s\n' "$default_lang" > "${STATE_DIR}/default_lang"
    printf '%s\n' "$SELECTION_SOURCE" > "${STATE_DIR}/selection_source"
    printf '%s\n' "$MAX_CHARS" > "${STATE_DIR}/max_chars"

    # Restart speech-dispatcher and wait until ready
    pkill -x speech-dispatcher >/dev/null 2>&1 || true
    local attempt=0
    while [ "$attempt" -lt 20 ]; do
        if spd-say -O >/dev/null 2>&1; then
            break
        fi
        sleep 0.2
        attempt=$((attempt + 1))
    done

    if [ "$LANG_CHOICE" = "en" ]; then
        info "Note: Only the English voice model (en_US-lessac-high) is installed."
        info "      Run with '--lang no' or '--lang both' if you want Norwegian pronunciation."
    fi
    success "Speech Dispatcher configured (preserving existing settings)."
}

# ==============================================================================
# 5. Create `~/.local/bin/speak-selection` (PID-File Controlled & Chunked)
# ==============================================================================
create_speak_script() {
    info "Creating ${SPEAK_SCRIPT}..."
    mkdir -p "$BIN_DIR"

    cat > "$SPEAK_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# Toggle reading selected or clipboard text aloud via Speech Dispatcher (Piper TTS).
# Uses a dedicated PID file + process group so pressing the hotkey again stops
# ONLY the speech session started by this script.

set -euo pipefail

STATE_DIR="${HOME}/.local/share/piper-tts/state"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
PID_FILE="${RUNTIME_DIR}/speak-selection-${UID}.pid"

DEFAULT_LANG="en"
[ -f "${STATE_DIR}/default_lang" ] && DEFAULT_LANG="$(cat "${STATE_DIR}/default_lang")"

SELECTION_SOURCE="auto"
[ -f "${STATE_DIR}/selection_source" ] && SELECTION_SOURCE="$(cat "${STATE_DIR}/selection_source")"

MAX_CHARS=8000
[ -f "${STATE_DIR}/max_chars" ] && MAX_CHARS="$(cat "${STATE_DIR}/max_chars")"

# 1. Check if an active speak-selection worker is already running -> stop it and exit
if [ -f "$PID_FILE" ]; then
    OLD_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        # Verify the process is actually our speak-selection / spd-say worker
        PROC_CMD="$(ps -p "$OLD_PID" -o comm= 2>/dev/null || true)"
        case "$PROC_CMD" in
            speak-selection|bash|spd-say)
                rm -f "$PID_FILE"
                spd-say -C 2>/dev/null || spd-say -S 2>/dev/null || true
                kill -TERM "-${OLD_PID}" 2>/dev/null || kill -TERM "$OLD_PID" 2>/dev/null || true
                exit 0
                ;;
        esac
    fi
    rm -f "$PID_FILE"
fi

get_primary_text() {
    local t=""
    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
        if command -v wl-paste >/dev/null 2>&1; then
            t="$(wl-paste --primary --no-newline 2>/dev/null || true)"
        fi
    fi
    if [ -z "$t" ] && command -v xclip >/dev/null 2>&1; then
        t="$(xclip -o -selection primary 2>/dev/null || true)"
    elif [ -z "$t" ] && command -v xsel >/dev/null 2>&1; then
        t="$(xsel -op 2>/dev/null || true)"
    fi
    printf '%s' "$t"
}

get_clipboard_text() {
    local t=""
    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
        if command -v wl-paste >/dev/null 2>&1; then
            t="$(wl-paste --no-newline 2>/dev/null || true)"
        fi
    fi
    if [ -z "$t" ] && command -v xclip >/dev/null 2>&1; then
        t="$(xclip -o -selection clipboard 2>/dev/null || true)"
    elif [ -z "$t" ] && command -v xsel >/dev/null 2>&1; then
        t="$(xsel -ob 2>/dev/null || true)"
    fi
    if [ -z "$t" ]; then
        if command -v qdbus6 >/dev/null 2>&1; then
            t="$(qdbus6 org.kde.klipper /klipper org.kde.klipper.klipper.getClipboardContents 2>/dev/null || true)"
        elif command -v qdbus >/dev/null 2>&1; then
            t="$(qdbus org.kde.klipper /klipper org.kde.klipper.klipper.getClipboardContents 2>/dev/null || true)"
        fi
    fi
    printf '%s' "$t"
}

TEXT=""
case "$SELECTION_SOURCE" in
    primary)
        TEXT="$(get_primary_text)"
        ;;
    clipboard)
        TEXT="$(get_clipboard_text)"
        if [ -z "$TEXT" ]; then
            TEXT="$(get_primary_text)"
        fi
        ;;
    auto|*)
        TEXT="$(get_primary_text)"
        if [ -z "$TEXT" ]; then
            TEXT="$(get_clipboard_text)"
        fi
        ;;
esac

# Strip leading/trailing whitespace and check if non-empty
TEXT="$(printf '%s' "$TEXT" | tr '\r\n' '  ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
if [ -z "$TEXT" ]; then
    exit 0
fi

# Enforce maximum character limit to prevent excessive memory/CPU use on huge clipboards
if [ "${#TEXT}" -gt "$MAX_CHARS" ]; then
    TEXT="${TEXT:0:$MAX_CHARS}"
fi

# Run playback in a dedicated process group piping stdin directly into piper-spd-synth
# (100% immune to shell injection and avoids speech-dispatcher startup overhead)
setsid bash -c '
    PID_FILE="$1"
    LANG_CODE="$2"
    FULL_TEXT="$3"
    SYNTH_BIN="${HOME}/.local/share/piper-tts/piper-spd-synth"
    echo "$$" > "$PID_FILE"
    trap "rm -f \"$PID_FILE\"; pkill -P $$ 2>/dev/null || true" EXIT INT TERM

    VOICE_NAME="en_US-lessac-high"
    if [[ "$LANG_CODE" == nb* ]] || [[ "$LANG_CODE" == no* ]] || [[ "$LANG_CODE" == nn* ]]; then
        VOICE_NAME="no_NO-talesyntese-medium"
    fi

    if [ -x "$SYNTH_BIN" ]; then
        printf "%s\n" "$FULL_TEXT" | "$SYNTH_BIN" "$VOICE_NAME" "$LANG_CODE"
    else
        printf "%s\n" "$FULL_TEXT" | spd-say -w -e -l "$LANG_CODE"
    fi
' _ "$PID_FILE" "$DEFAULT_LANG" "$TEXT" >/dev/null 2>&1 &
EOF

    chmod +x "$SPEAK_SCRIPT"
    success "Created ${SPEAK_SCRIPT}"
}

# ==============================================================================
# 6. Idempotent & Reversible Hotkey Setup Across Desktop Variants
# ==============================================================================
configure_hotkey() {
    mkdir -p "$STATE_DIR"
    local de="${XDG_CURRENT_DESKTOP:-}${DESKTOP_SESSION:-}"
    de="$(echo "$de" | tr '[:upper:]' '[:lower:]')"
    info "Configuring shortcut (Super+Alt+S) for desktop environment '${de:-unknown}'..."

    # --- KDE Plasma (5 & 6) ---
    if [[ "$de" == *"kde"* ]] || [[ "$de" == *"plasma"* ]]; then
        mkdir -p "${HOME}/.local/share/applications" "${HOME}/.local/share/kglobalaccel"

        cat > "${HOME}/.local/share/applications/speak-selection.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Read Selected Text
Name[nb]=Les merket tekst høyt
Comment=Read highlighted text aloud with Piper TTS
Icon=preferences-desktop-accessibility
Exec=${SPEAK_SCRIPT}
Terminal=false
StartupNotify=false
NoDisplay=true
X-KDE-Shortcuts=Meta+Alt+S
X-KDE-GlobalAccel-CommandShortcut=true
EOF
        cp -f "${HOME}/.local/share/applications/speak-selection.desktop" \
              "${HOME}/.local/share/kglobalaccel/speak-selection.desktop"

        local kwrite=""
        local kread=""
        if command -v kwriteconfig6 >/dev/null 2>&1; then
            kwrite="kwriteconfig6"
            kread="kreadconfig6"
        elif command -v kwriteconfig5 >/dev/null 2>&1; then
            kwrite="kwriteconfig5"
            kread="kreadconfig5"
        fi

        if [ -n "$kwrite" ]; then
            if [ ! -f "${STATE_DIR}/kde_prev_screenreader_shortcut" ] && command -v "$kread" >/dev/null 2>&1; then
                "$kread" --file kglobalshortcutsrc --group "services" --group "org.kde.screenreader.desktop" --key "toggleScreenReader" \
                    > "${STATE_DIR}/kde_prev_screenreader_shortcut" 2>/dev/null || true
            fi
            "$kwrite" --file kglobalshortcutsrc --group "services" --group "org.kde.screenreader.desktop" --key "toggleScreenReader" "none"
            "$kwrite" --file kglobalshortcutsrc --group "services" --group "speak-selection.desktop" --key "_launch" "Meta+Alt+S"
        fi

        if command -v kbuildsycoca6 >/dev/null 2>&1; then
            kbuildsycoca6 >/dev/null 2>&1 || warn "kbuildsycoca6 returned non-zero; KDE shortcut cache will refresh on next login."
        elif command -v kbuildsycoca5 >/dev/null 2>&1; then
            kbuildsycoca5 >/dev/null 2>&1 || warn "kbuildsycoca5 returned non-zero; KDE shortcut cache will refresh on next login."
        fi
        success "KDE Plasma shortcut configured (Meta+Alt+S)."
        return 0
    fi

    # --- GNOME / Ubuntu / Budgie ---
    if [[ "$de" == *"gnome"* ]] || [[ "$de" == *"ubuntu"* ]] || [[ "$de" == *"budgie"* ]]; then
        if command -v gsettings >/dev/null 2>&1; then
            local schema="org.gnome.settings-daemon.plugins.media-keys"
            local key_path="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/speak-selection/"

            if [ ! -f "${STATE_DIR}/gnome_prev_screenreader" ]; then
                gsettings get "$schema" screenreader > "${STATE_DIR}/gnome_prev_screenreader" 2>/dev/null || true
            fi
            gsettings set "$schema" screenreader "[]"

            local current_list
            current_list="$(gsettings get "$schema" custom-keybindings)"
            if [[ "$current_list" != *"$key_path"* ]]; then
                if [[ "$current_list" == "@as []" ]] || [[ "$current_list" == "[]" ]]; then
                    current_list="['${key_path}']"
                else
                    current_list="${current_list%]*}, '${key_path}']"
                fi
                gsettings set "$schema" custom-keybindings "$current_list"
            fi

            gsettings set "${schema}.custom-keybinding:${key_path}" name "Read Selected Text"
            gsettings set "${schema}.custom-keybinding:${key_path}" command "${SPEAK_SCRIPT}"
            gsettings set "${schema}.custom-keybinding:${key_path}" binding "<Super><Alt>s"
            success "GNOME shortcut configured: Super+Alt+S"
            return 0
        fi
    fi

    # --- Cinnamon ---
    if [[ "$de" == *"x-cinnamon"* ]] || [[ "$de" == *"cinnamon"* ]]; then
        if command -v dconf >/dev/null 2>&1 && command -v gsettings >/dev/null 2>&1; then
            local cpath="/org/cinnamon/desktop/keybindings/custom-keybindings/speak-selection/"
            dconf write "${cpath}name" "'Read Selected Text'"
            dconf write "${cpath}command" "'${SPEAK_SCRIPT}'"
            dconf write "${cpath}binding" "['<Super><Alt>s']"

            local clist
            clist="$(gsettings get org.cinnamon.desktop.keybindings custom-list)"
            if [[ "$clist" != *"speak-selection"* ]]; then
                if [[ "$clist" == "@as []" ]] || [[ "$clist" == "[]" ]]; then
                    clist="['speak-selection']"
                else
                    clist="${clist%]*}, 'speak-selection']"
                fi
                gsettings set org.cinnamon.desktop.keybindings custom-list "$clist"
            fi
            success "Cinnamon shortcut configured: Super+Alt+S"
            return 0
        fi
    fi

    # --- MATE ---
    if [[ "$de" == *"mate"* ]]; then
        if command -v dconf >/dev/null 2>&1; then
            local mpath="/org/mate/desktop/keybindings/speak-selection/"
            dconf write "${mpath}name" "'Read Selected Text'"
            dconf write "${mpath}action" "'${SPEAK_SCRIPT}'"
            dconf write "${mpath}binding" "'<Mod4><Alt>s'"
            success "MATE shortcut configured: Super+Alt+S"
            return 0
        fi
    fi

    # --- XFCE ---
    if [[ "$de" == *"xfce"* ]]; then
        if command -v xfconf-query >/dev/null 2>&1; then
            xfconf-query -c xfce4-keyboard-shortcuts \
                -p "/commands/custom/<Super><Alt>s" \
                -n -t string -s "${SPEAK_SCRIPT}"
            success "XFCE shortcut configured: Super+Alt+S"
            return 0
        fi
    fi

    # --- Hyprland ---
    if [[ "$de" == *"hyprland"* ]] || [ -f "${HOME}/.config/hypr/hyprland.conf" ]; then
        local hypr_conf="${HOME}/.config/hypr/hyprland.conf"
        if [ -f "$hypr_conf" ]; then
            upsert_managed_block "$hypr_conf" "bind = SUPER ALT, S, exec, ${SPEAK_SCRIPT}"
            success "Updated managed keybind block in ${hypr_conf}"
            return 0
        fi
    fi

    # --- Sway ---
    if [[ "$de" == *"sway"* ]] || [ -f "${HOME}/.config/sway/config" ]; then
        local sway_conf="${HOME}/.config/sway/config"
        if [ -f "$sway_conf" ]; then
            upsert_managed_block "$sway_conf" "bindsym Mod4+Mod1+s exec ${SPEAK_SCRIPT}"
            if command -v swaymsg >/dev/null 2>&1 && [ -n "${SWAYSOCK:-}" ]; then
                swaymsg reload >/dev/null 2>&1 || warn "Could not reload Sway automatically; run 'swaymsg reload'."
            fi
            success "Updated managed keybind block in ${sway_conf}"
            return 0
        fi
    fi

    # --- i3wm ---
    if [[ "$de" == *"i3"* ]] || [ -f "${HOME}/.config/i3/config" ]; then
        local i3_conf="${HOME}/.config/i3/config"
        if [ -f "$i3_conf" ]; then
            upsert_managed_block "$i3_conf" "bindsym Mod4+Mod1+s exec --no-startup-id ${SPEAK_SCRIPT}"
            if command -v i3-msg >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
                i3-msg reload >/dev/null 2>&1 || warn "Could not reload i3 automatically; press Mod+Shift+R."
            fi
            success "Updated managed keybind block in ${i3_conf}"
            return 0
        fi
    fi

    warn "Automatic hotkey registration is not supported for '${de:-unknown}'."
    info "Manual setup: Bind 'Super+Alt+S' in your desktop's keyboard settings to: ${SPEAK_SCRIPT}"
}

# ==============================================================================
# 7. Post-Installation Verification
# ==============================================================================
verify_installation() {
    info "Verifying installation..."
    local errors=0

    if [ ! -x "${INSTALL_DIR}/piper/piper" ]; then
        error "Verification failed: Piper binary missing or not executable."
        errors=$((errors + 1))
    fi

    if [ ! -x "$SYNTH_WRAPPER" ]; then
        error "Verification failed: Synth wrapper (${SYNTH_WRAPPER}) missing."
        errors=$((errors + 1))
    fi

    if [ ! -x "$SPEAK_SCRIPT" ]; then
        error "Verification failed: Speak script (${SPEAK_SCRIPT}) missing."
        errors=$((errors + 1))
    fi

    if [ ! -f "${SPD_CONFIG_DIR}/modules/piper-generic.conf" ]; then
        error "Verification failed: Speech Dispatcher module config missing."
        errors=$((errors + 1))
    fi

    # Verify Piper can synthesize a test phrase to raw bytes
    local test_model="en_US-lessac-high"
    [ "$LANG_CHOICE" = "no" ] && test_model="no_NO-talesyntese-medium"
    local audio_bytes
    audio_bytes="$(printf 'test' | "${INSTALL_DIR}/piper/piper" --model "${INSTALL_DIR}/${test_model}.onnx" --output-raw 2>/dev/null | wc -c)"
    if [ "${audio_bytes:-0}" -le 100 ]; then
        error "Verification failed: Piper produced no audio output (${audio_bytes} bytes)."
        errors=$((errors + 1))
    fi

    if [ "$errors" -gt 0 ]; then
        error "Installation verification failed with ${errors} error(s)."
        exit 1
    fi

    success "All verification checks passed (${audio_bytes} bytes synthesized in dry-run test)."
}

# ==============================================================================
# 8. Clean Uninstall (`--uninstall`)
# ==============================================================================
uninstall_all() {
    info "Uninstalling Piper TTS setup and restoring previous configuration..."

    # Stop any active speech
    spd-say -C 2>/dev/null || true

    # Restore or clean speechd.conf
    local speechd_conf="${SPD_CONFIG_DIR}/speechd.conf"
    if [ -f "${STATE_DIR}/speechd.conf.backup" ]; then
        mv -f "${STATE_DIR}/speechd.conf.backup" "$speechd_conf"
        success "Restored original ${speechd_conf} from backup."
    elif [ -f "$speechd_conf" ]; then
        remove_managed_block "$speechd_conf"
        success "Removed managed Piper block from ${speechd_conf}."
    fi

    rm -f "${SPD_CONFIG_DIR}/modules/piper-generic.conf"
    pkill -x speech-dispatcher >/dev/null 2>&1 || true

    # Remove KDE shortcut & restore previous screenreader shortcut if backed up
    rm -f "${HOME}/.local/share/applications/speak-selection.desktop" \
          "${HOME}/.local/share/kglobalaccel/speak-selection.desktop"
    if command -v kwriteconfig6 >/dev/null 2>&1; then
        kwriteconfig6 --file kglobalshortcutsrc --group "services" --group "speak-selection.desktop" --key "_launch" --delete 2>/dev/null || true
        if [ -f "${STATE_DIR}/kde_prev_screenreader_shortcut" ]; then
            local prev_kde
            prev_kde="$(cat "${STATE_DIR}/kde_prev_screenreader_shortcut")"
            [ -n "$prev_kde" ] && kwriteconfig6 --file kglobalshortcutsrc --group "services" --group "org.kde.screenreader.desktop" --key "toggleScreenReader" "$prev_kde" || true
        fi
    fi

    # Restore GNOME shortcut if backed up
    if [ -f "${STATE_DIR}/gnome_prev_screenreader" ] && command -v gsettings >/dev/null 2>&1; then
        local prev_gnome
        prev_gnome="$(cat "${STATE_DIR}/gnome_prev_screenreader")"
        [ -n "$prev_gnome" ] && gsettings set org.gnome.settings-daemon.plugins.media-keys screenreader "$prev_gnome" 2>/dev/null || true
    fi

    # Remove XFCE shortcut if present
    if command -v xfconf-query >/dev/null 2>&1; then
        xfconf-query -c xfce4-keyboard-shortcuts -p "/commands/custom/<Super><Alt>s" -r 2>/dev/null || true
    fi

    # Clean managed blocks from WM configs
    for wm_conf in "${HOME}/.config/hypr/hyprland.conf" "${HOME}/.config/sway/config" "${HOME}/.config/i3/config"; do
        remove_managed_block "$wm_conf"
    done

    # Remove scripts and installation directory
    rm -f "$SPEAK_SCRIPT"
    rm -rf "$INSTALL_DIR"

    success "Uninstallation complete."
    exit 0
}

# ==============================================================================
# Main Execution Flow
# ==============================================================================
main() {
    if [ "$(id -u)" -eq 0 ]; then
        error "Please run this script as your normal desktop user (not root)."
        exit 1
    fi

    parse_args "$@"
    acquire_lock

    if [ "$UNINSTALL" = true ]; then
        uninstall_all
    fi

    printf '%b==============================================================%b\n' "${BOLD}" "${NC}"
    printf '%b  Universal Linux Neural Read-Aloud Installer (Piper TTS)%b\n' "${BOLD}" "${NC}"
    printf '%b==============================================================%b\n' "${BOLD}" "${NC}"

    detect_distro_and_pm
    install_dependencies
    install_piper
    configure_speech_dispatcher
    create_speak_script
    configure_hotkey
    verify_installation

    local test_lang="en"
    local test_msg="Setup complete! Highlight any text and press Super Alt S to read it aloud."
    if [ "$LANG_CHOICE" = "no" ]; then
        test_lang="nb"
        test_msg="Oppsettet er klart! Marker tekst og trykk Super Alt S for å lese den høyt."
    fi

    info "Playing quick audio test via Speech Dispatcher (${test_lang})..."
    printf '%s' "$test_msg" | spd-say -e -l "$test_lang" || warn "Audio test command returned non-zero."

    echo ""
    printf '%b%bAll done!%b\n' "${GREEN}" "${BOLD}" "${NC}"
    printf '  • Script installed at:  %b%s%b\n' "${BOLD}" "${SPEAK_SCRIPT}" "${NC}"
    printf '  • Piper engine & model: %b%s%b\n' "${BOLD}" "${INSTALL_DIR}" "${NC}"
    printf '  • Language configured:  %b%s%b\n' "${BOLD}" "${LANG_CHOICE}" "${NC}"
    printf '  • Selection priority:   %b%s%b\n' "${BOLD}" "${SELECTION_SOURCE}" "${NC}"
    printf '  • Hotkey:               %bSuper + Alt + S%b (press again anytime to stop)\n' "${BOLD}" "${NC}"
    printf '  • To uninstall cleanly: %b%s --uninstall%b\n' "${BOLD}" "$0" "${NC}"
}

main "$@"
