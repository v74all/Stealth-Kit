#!/usr/bin/env bash
# Common helpers for Stealth Kit modules.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${ROOT_DIR}/backups"
CONFIGS_DIR="${ROOT_DIR}/configs"
PROFILES_DIR="${ROOT_DIR}/profiles"
STATE_DIR="${BACKUP_DIR}/state"

TOOL_NAME="${TOOL_NAME:-Stealth Kit}"
BRAND="${BRAND:-V7LTHRONYX}"
AUTHOR="${AUTHOR:-Aiden Azad}"
TAGLINE="${TAGLINE:-Authorized Linux Security Audit & Hardening Toolkit}"
PROJECT_URL="${PROJECT_URL:-}"

DRY_RUN="${DRY_RUN:-false}"
YES="${YES:-false}"
LAB_MODE="${LAB_MODE:-false}"
PROFILE="${PROFILE:-workstation-hardening}"
MODULE_NAME="${MODULE_NAME:-stealthkit}"
ALLOW_PACKAGE_INSTALL="${ALLOW_PACKAGE_INSTALL:-false}"
ALLOW_DESTRUCTIVE_CLEAN="${ALLOW_DESTRUCTIVE_CLEAN:-false}"

STATE_FILE="${STATE_FILE:-}"

common_init() {
    mkdir -p "$BACKUP_DIR" "$STATE_DIR"
    if [[ -z "$STATE_FILE" ]]; then
        STATE_FILE="${STATE_DIR}/state_$(date +%Y%m%d_%H%M%S).jsonl"
    fi
}

load_runtime_config() {
    local base_config="${CONFIGS_DIR}/stealthkit.conf"
    local profile_config="${PROFILES_DIR}/${PROFILE}.conf"

    if [[ -f "$base_config" ]]; then
        # shellcheck source=/dev/null
        source "$base_config"
    fi

    if [[ -f "$profile_config" ]]; then
        # shellcheck source=/dev/null
        source "$profile_config"
    else
        echo "[!] Unknown profile: ${PROFILE}" >&2
        echo "    Expected a file under ${PROFILES_DIR}/" >&2
        exit 2
    fi
}

brand_line() {
    if [[ -n "$PROJECT_URL" ]]; then
        printf '%s by %s | %s | %s\n' "$TOOL_NAME" "$BRAND" "$AUTHOR" "$PROJECT_URL"
    else
        printf '%s by %s | %s\n' "$TOOL_NAME" "$BRAND" "$AUTHOR"
    fi
}

show_brand_banner() {
    local version="${1:-}"
    cat << 'BANNER'

__     _______ _   _____ _   _ ____   ___  _   ___   ____  __
\ \   / /___  | | |_   _| | | |  _ \ / _ \| \ | \ \ / /\ \/ /
 \ \ / /   / /| |   | | | |_| | |_) | | | |  \| |\ V /  \  / 
  \ V /   / / | |___| | |  _  |  _ <| |_| | |\  | | |   /  \ 
   \_/   /_/  |_____|_| |_| |_|_| \_\\___/|_| \_| |_|  /_/\_\

BANNER
    printf '  %s\n' "$(brand_line)"
    if [[ -n "$version" ]]; then
        printf '  Version: %s\n' "$version"
    fi
    printf '  %s\n\n' "$TAGLINE"
}

show_phase() {
    local current="$1"
    local total="$2"
    local title="$3"
    local width=20
    local filled=$((current * width / total))
    local empty=$((width - filled))
    local bar=""
    local i
    for ((i = 0; i < filled; i += 1)); do bar+="#"; done
    for ((i = 0; i < empty; i += 1)); do bar+="-"; done
    printf '\n[%02d/%02d] [%s] %s\n' "$current" "$total" "$bar" "$title"
}

json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    printf '%s' "$value"
}

record_state() {
    local action="$1"
    local target="$2"
    local detail="${3:-}"
    common_init
    printf '{"time":"%s","module":"%s","action":"%s","target":"%s","detail":"%s"}\n' \
        "$(date -Is)" \
        "$(json_escape "$MODULE_NAME")" \
        "$(json_escape "$action")" \
        "$(json_escape "$target")" \
        "$(json_escape "$detail")" >> "$STATE_FILE"
}

need_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "[!] This action must be run as root. Use sudo, or run with --dry-run for a plan." >&2
        exit 1
    fi
}

confirm_or_exit() {
    local prompt="$1"
    if [[ "$YES" == "true" ]]; then
        return 0
    fi
    read -rp "$prompt" confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Aborted."
        exit 0
    fi
}

run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        printf '  [dry-run] %q' "$1"
        shift
        for arg in "$@"; do
            printf ' %q' "$arg"
        done
        printf '\n'
        return 0
    fi
    "$@"
}

backup_file() {
    local file="$1"
    local backup_name
    common_init
    backup_name="$(basename "$file").backup.$(date +%Y%m%d_%H%M%S)"
    if [[ -f "$file" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "  [dry-run] backup ${file} -> ${BACKUP_DIR}/${backup_name}"
        else
            cp "$file" "${BACKUP_DIR}/${backup_name}"
            record_state "backup" "$file" "${BACKUP_DIR}/${backup_name}"
        fi
    fi
}

write_file() {
    local target="$1"
    local content="$2"
    local mode="${3:-0644}"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [dry-run] write ${target}"
        return 0
    fi
    printf '%s\n' "$content" > "$target"
    chmod "$mode" "$target" 2>/dev/null || true
    record_state "write" "$target" "mode=${mode}"
}

append_marked_block() {
    local target="$1"
    local marker="$2"
    local content="$3"
    if [[ ! -f "$target" ]]; then
        return 0
    fi
    if grep -Fq "BEGIN ${marker}" "$target"; then
        return 0
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [dry-run] append marked block ${marker} to ${target}"
        return 0
    fi
    {
        printf '\n# BEGIN %s\n' "$marker"
        printf '%s\n' "$content"
        printf '# END %s\n' "$marker"
    } >> "$target"
    record_state "append_block" "$target" "$marker"
}

remove_marked_block() {
    local target="$1"
    local marker="$2"
    if [[ ! -f "$target" ]]; then
        return 0
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [dry-run] remove marked block ${marker} from ${target}"
        return 0
    fi
    awk -v marker="$marker" '
        $0 == "# BEGIN " marker {skip=1; next}
        $0 == "# END " marker {skip=0; next}
        !skip {print}
    ' "$target" > "${target}.stealthkit.tmp"
    cat "${target}.stealthkit.tmp" > "$target"
    rm -f "${target}.stealthkit.tmp"
    record_state "remove_block" "$target" "$marker"
}

require_destructive_lab_mode() {
    if [[ "$LAB_MODE" != "true" || "$ALLOW_DESTRUCTIVE_CLEAN" != "true" ]]; then
        echo "[!] Destructive cleanup is disabled." >&2
        echo "    This toolkit defaults to audit and defensive hardening." >&2
        echo "    Use --dry-run to inspect planned targets." >&2
        echo "    Lab-only cleanup requires --lab-mode plus ALLOW_DESTRUCTIVE_CLEAN=true in a lab profile." >&2
        exit 2
    fi
}
