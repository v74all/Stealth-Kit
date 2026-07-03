#!/usr/bin/env bash
# ============================================================================
# clean_traces.sh - Lab-Only Cleanup Gate
# V7LTHRONYX / Aiden Azad
# ============================================================================
# Destructive cleanup is disabled by default and requires a lab profile,
# --lab-mode, and --i-understand-destruction.
# ============================================================================

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Globals ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHRED_PASSES=3
CLEANED=0
FAILED=0
DESTRUCTION_ACK=false

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ── Helper Functions ────────────────────────────────────────────────────────
banner() {
    echo -e "${RED}${BOLD}"
    show_brand_banner ""
    echo "  Module: Lab-Only Cleanup Gate"
    echo "  Destructive actions are disabled by default."
    echo -e "${NC}"
}

ok()      { echo -e "  ${GREEN}[✔]${NC} $1"; ((CLEANED+=1)); }
warn()    { echo -e "  ${YELLOW}[⚠]${NC} $1"; }
fail()    { echo -e "  ${RED}[✘]${NC} $1"; ((FAILED+=1)); }
info()    { echo -e "  ${CYAN}[ℹ]${NC} $1"; }
section() {
    echo ""
    echo -e "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}${BOLD}  ▶ $1${NC}"
    echo -e "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[!] This script must be run as root (sudo).${NC}"
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=true ;;
            --yes|--force|-f) YES=true ;;
            --profile)
                shift
                PROFILE="${1:-$PROFILE}"
                ;;
            --lab-mode) LAB_MODE=true ;;
            --i-understand-destruction) DESTRUCTION_ACK=true ;;
            *)
                echo "[!] Unknown cleanup option: $1" >&2
                exit 2
                ;;
        esac
        shift
    done
}

print_plan() {
    banner
    echo "Profile: ${PROFILE}"
    echo "Dry run: no files will be modified or removed."
    echo ""
    echo "Cleanup targets that would be touched in lab mode:"
    echo "  system logs and journald retention"
    echo "  shell/application histories"
    echo "  /tmp and /var/tmp"
    echo "  browser cache/profile data"
    echo "  recent files, thumbnails, trash, clipboard"
    echo "  swap cycle, core dumps, package caches, DNS/ARP/cache flush"
    echo ""
    echo "Execution requires: --profile kali-lab --lab-mode --i-understand-destruction"
}

require_cleanup_ack() {
    require_destructive_lab_mode
    if [[ "$DESTRUCTION_ACK" != "true" ]]; then
        echo "[!] Missing --i-understand-destruction." >&2
        echo "    Refusing to run destructive cleanup." >&2
        exit 2
    fi
}

# Securely delete a file using shred
secure_delete() {
    local file="$1"
    if [[ -f "$file" ]]; then
        shred -vfz -n "$SHRED_PASSES" "$file" 2>/dev/null && rm -f "$file" 2>/dev/null
        ok "Shredded: ${file}"
    fi
}

# Securely delete all files in a directory
secure_delete_dir() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        find "$dir" -type f -exec shred -fz -n "$SHRED_PASSES" {} \; 2>/dev/null
        rm -rf "$dir" 2>/dev/null
        ok "Shredded directory: ${dir}"
    fi
}

# Truncate a file to zero bytes (for files that shouldn't be deleted)
secure_truncate() {
    local file="$1"
    if [[ -f "$file" ]]; then
        shred -fz -n "$SHRED_PASSES" "$file" 2>/dev/null
        truncate -s 0 "$file" 2>/dev/null
        ok "Truncated: ${file}"
    fi
}

# ── Cleaning Functions ──────────────────────────────────────────────────────

clean_system_logs() {
    section "SYSTEM LOGS"
    
    # Shred individual log files
    local log_files=(
        /var/log/syslog
        /var/log/syslog.1
        /var/log/auth.log
        /var/log/auth.log.1
        /var/log/kern.log
        /var/log/kern.log.1
        /var/log/daemon.log
        /var/log/daemon.log.1
        /var/log/messages
        /var/log/messages.1
        /var/log/debug
        /var/log/dpkg.log
        /var/log/alternatives.log
        /var/log/bootstrap.log
        /var/log/fontconfig.log
        /var/log/gpu-manager.log
        /var/log/installer/syslog
    )
    
    for logf in "${log_files[@]}"; do
        secure_truncate "$logf"
    done
    
    # Shred compressed logs
    find /var/log -name "*.gz" -exec shred -fz -n "$SHRED_PASSES" {} \; -exec rm -f {} \; 2>/dev/null
    ok "Removed all compressed (.gz) logs"
    
    find /var/log -name "*.old" -exec shred -fz -n "$SHRED_PASSES" {} \; -exec rm -f {} \; 2>/dev/null
    ok "Removed all .old logs"
    
    find /var/log -name "*.1" -exec shred -fz -n "$SHRED_PASSES" {} \; -exec rm -f {} \; 2>/dev/null
    ok "Removed all rotated (.1) logs"
    
    # APT logs
    if [[ -d /var/log/apt ]]; then
        find /var/log/apt -type f -exec shred -fz -n "$SHRED_PASSES" {} \; 2>/dev/null
        find /var/log/apt -type f -exec truncate -s 0 {} \; 2>/dev/null
        ok "Cleaned APT logs"
    fi
    
    # Journald
    if command -v journalctl &>/dev/null; then
        journalctl --rotate 2>/dev/null || true
        journalctl --vacuum-time=1s 2>/dev/null || true
        journalctl --vacuum-size=0 2>/dev/null || true
        ok "Vacuumed journald logs"
    fi
    
    # Login records
    secure_truncate /var/log/wtmp
    secure_truncate /var/log/btmp
    secure_truncate /var/log/lastlog
    secure_truncate /var/log/faillog
    secure_truncate /var/run/utmp
    
    ok "Cleared login records (wtmp, btmp, lastlog, utmp)"
}

clean_shell_histories() {
    section "SHELL & APPLICATION HISTORIES"
    
    local history_files=(
        "$HOME/.bash_history"
        "$HOME/.zsh_history"
        "$HOME/.zshrc_history"
        "$HOME/.python_history"
        "$HOME/.mysql_history"
        "$HOME/.psql_history"
        "$HOME/.lesshst"
        "$HOME/.wget-hsts"
        "$HOME/.viminfo"
        "$HOME/.local/share/fish/fish_history"
        "/root/.bash_history"
        "/root/.zsh_history"
        "/root/.python_history"
        "/root/.mysql_history"
        "/root/.psql_history"
        "/root/.lesshst"
        "/root/.wget-hsts"
        "/root/.viminfo"
    )
    
    for hf in "${history_files[@]}"; do
        secure_delete "$hf"
    done
    
    # Nano history
    if [[ -d "$HOME/.nano" ]]; then
        secure_delete_dir "$HOME/.nano"
        ok "Cleaned nano history"
    fi
    if [[ -d "/root/.nano" ]]; then
        secure_delete_dir "/root/.nano"
    fi
    
    # Clear in-memory history for current session
    history -c 2>/dev/null || true
    export HISTSIZE=0
    export HISTFILESIZE=0
    unset HISTFILE 2>/dev/null || true
    
    ok "Cleared in-memory shell history"
    
    # Clean all user histories
    for user_home in /home/*; do
        if [[ -d "$user_home" ]]; then
            for hf in .bash_history .zsh_history .python_history .mysql_history .lesshst .wget-hsts .viminfo; do
                secure_delete "${user_home}/${hf}" 2>/dev/null || true
            done
        fi
    done
    ok "Cleaned all user histories"
}

clean_temp_files() {
    section "TEMPORARY FILES"
    
    # /tmp
    find /tmp -mindepth 1 -maxdepth 1 -exec rm -rf {} \; 2>/dev/null || true
    ok "Cleaned /tmp"
    
    # /var/tmp
    find /var/tmp -mindepth 1 -maxdepth 1 -exec rm -rf {} \; 2>/dev/null || true
    ok "Cleaned /var/tmp"
    
    # User cache
    if [[ -d "$HOME/.cache" ]]; then
        rm -rf "$HOME/.cache"/* 2>/dev/null || true
        ok "Cleaned ~/.cache"
    fi
    
    # Root cache
    if [[ -d "/root/.cache" ]]; then
        rm -rf /root/.cache/* 2>/dev/null || true
        ok "Cleaned /root/.cache"
    fi
}

clean_browser_data() {
    section "BROWSER DATA"
    
    # Firefox ESR
    local firefox_dir="$HOME/.mozilla/firefox"
    if [[ -d "$firefox_dir" ]]; then
        # Find all profile directories
        find "$firefox_dir" -name "*.default*" -type d | while read -r profile; do
            # Remove specific data dirs/files
            local targets=(
                "cache2" "startupCache" "thumbnails"
                "cookies.sqlite" "cookies.sqlite-wal"
                "places.sqlite" "places.sqlite-wal"
                "formhistory.sqlite"
                "downloads.json"
                "sessionstore.jsonlz4"
                "sessionstore-backups"
                "webappsstore.sqlite"
                "storage"
            )
            for target in "${targets[@]}"; do
                if [[ -d "${profile}/${target}" ]]; then
                    rm -rf "${profile}/${target}" 2>/dev/null || true
                elif [[ -f "${profile}/${target}" ]]; then
                    secure_delete "${profile}/${target}" 2>/dev/null || true
                fi
            done
        done
        ok "Cleaned Firefox data"
    else
        info "No Firefox profile found."
    fi
    
    # Chromium
    local chromium_dir="$HOME/.config/chromium"
    if [[ -d "$chromium_dir" ]]; then
        rm -rf "$chromium_dir" 2>/dev/null || true
        ok "Removed Chromium profile"
    fi
    
    # Chrome
    local chrome_dir="$HOME/.config/google-chrome"
    if [[ -d "$chrome_dir" ]]; then
        rm -rf "$chrome_dir" 2>/dev/null || true
        ok "Removed Chrome profile"
    fi
}

clean_recent_files() {
    section "RECENT FILES & THUMBNAILS"
    
    # recently-used.xbel
    local recent_file="$HOME/.local/share/recently-used.xbel"
    if [[ -f "$recent_file" ]]; then
        secure_delete "$recent_file"
    fi
    
    # Thumbnails
    if [[ -d "$HOME/.cache/thumbnails" ]]; then
        rm -rf "$HOME/.cache/thumbnails" 2>/dev/null || true
        ok "Cleaned thumbnail cache"
    fi
    
    # GNOME Tracker
    if [[ -d "$HOME/.local/share/tracker" ]]; then
        rm -rf "$HOME/.local/share/tracker" 2>/dev/null || true
        ok "Cleaned GNOME Tracker data"
    fi
    
    # Zeitgeist
    if [[ -d "$HOME/.local/share/zeitgeist" ]]; then
        rm -rf "$HOME/.local/share/zeitgeist" 2>/dev/null || true
        ok "Cleaned Zeitgeist activity log"
    fi
    
    # Trash
    if [[ -d "$HOME/.local/share/Trash" ]]; then
        rm -rf "$HOME/.local/share/Trash"/* 2>/dev/null || true
        ok "Emptied Trash"
    fi
    
    # Clipboard (xclip / xsel)
    if command -v xclip &>/dev/null; then
        echo -n "" | xclip -selection clipboard 2>/dev/null || true
        echo -n "" | xclip -selection primary 2>/dev/null || true
        ok "Cleared clipboard (xclip)"
    fi
    if command -v xsel &>/dev/null; then
        xsel --clipboard --clear 2>/dev/null || true
        xsel --primary --clear 2>/dev/null || true
        ok "Cleared clipboard (xsel)"
    fi
}

clean_swap() {
    section "SWAP MEMORY"
    
    local swap_on
    swap_on=$(swapon --show --noheadings 2>/dev/null | wc -l)
    
    if [[ $swap_on -gt 0 ]]; then
        info "Disabling swap to clear sensitive data..."
        swapoff -a 2>/dev/null || warn "Failed to disable swap"
        swapon -a 2>/dev/null || warn "Failed to re-enable swap"
        ok "Swap cleared (swapoff/swapon cycle)"
    else
        ok "No swap active."
    fi
}

clean_core_dumps() {
    section "CORE DUMPS"
    
    # Disable core dumps
    ulimit -c 0 2>/dev/null || true
    
    # Remove existing core dumps
    find / -maxdepth 3 -name "core" -type f -exec shred -fz -n "$SHRED_PASSES" {} \; -exec rm -f {} \; 2>/dev/null || true
    find / -maxdepth 3 -name "core.*" -type f -exec shred -fz -n "$SHRED_PASSES" {} \; -exec rm -f {} \; 2>/dev/null || true
    
    # Systemd coredump directory
    if [[ -d /var/lib/systemd/coredump ]]; then
        rm -rf /var/lib/systemd/coredump/* 2>/dev/null || true
        ok "Cleaned systemd coredumps"
    fi
    
    ok "Core dumps disabled and cleaned"
}

clean_misc() {
    section "MISCELLANEOUS"
    
    # SSH known_hosts
    local ssh_files=(
        "$HOME/.ssh/known_hosts"
        "/root/.ssh/known_hosts"
    )
    for sf in "${ssh_files[@]}"; do
        if [[ -f "$sf" ]]; then
            secure_truncate "$sf"
        fi
    done
    
    # Package manager cache
    apt-get clean 2>/dev/null || true
    ok "Cleaned APT package cache"
    
    # Pip cache
    if command -v pip &>/dev/null; then
        pip cache purge 2>/dev/null || true
        ok "Cleaned pip cache"
    fi
    
    # Clear DNS cache
    if command -v systemd-resolve &>/dev/null; then
        systemd-resolve --flush-caches 2>/dev/null || true
        ok "Flushed systemd DNS cache"
    elif command -v resolvectl &>/dev/null; then
        resolvectl flush-caches 2>/dev/null || true
        ok "Flushed DNS cache"
    fi
    
    # Clear ARP cache
    ip neigh flush all 2>/dev/null || true
    ok "Flushed ARP cache"
    
    # Drop filesystem caches
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    ok "Dropped filesystem caches"
}

# ── Summary ─────────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${RED}${BOLD}══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}${BOLD}  CLEANING SUMMARY${NC}"
    echo -e "${RED}${BOLD}══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${GREEN}${BOLD}Items Cleaned:  ${CLEANED}${NC}"
    echo -e "  ${RED}${BOLD}Items Failed:   ${FAILED}${NC}"
    echo ""
    echo -e "  ${YELLOW}${BOLD}This lab-only cleanup is destructive and not part of normal hardening.${NC}"
    echo ""
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"
    MODULE_NAME="cleanup"
    load_runtime_config
    common_init

    if [[ "$DRY_RUN" == "true" ]]; then
        print_plan
        exit 0
    fi

    require_cleanup_ack
    check_root
    banner
    
    echo -e "${YELLOW}${BOLD}[!] WARNING: This will permanently destroy logs, histories, and caches.${NC}"
    echo -e "${YELLOW}${BOLD}[!] This action is IRREVERSIBLE. Use only in disposable authorized labs.${NC}"
    echo ""
    
    confirm_or_exit "  Continue with destructive lab cleanup? (y/N): "
    
    echo ""
    echo -e "${CYAN}Cleaning started at: $(date)${NC}"
    
    clean_system_logs
    clean_shell_histories
    clean_temp_files
    clean_browser_data
    clean_recent_files
    clean_swap
    clean_core_dumps
    clean_misc
    
    print_summary
    
    # Self-clean: ensure this session's history is also cleared
    history -c 2>/dev/null || true
    unset HISTFILE 2>/dev/null || true
}

main "$@"
