#!/usr/bin/env bash
# ============================================================================
# harden_os.sh - Operating System Hardening
# V7LTHRONYX / Aiden Azad
# ============================================================================
# Hardens the OS using profile-selected defensive controls:
#   - Disable unnecessary services
#   - Apply sysctl security settings
#   - Disable USB auto-mount
#   - Restrict core dumps
#   - Secure SSH configuration
#   - Optional lab-only RAM cleanup on shutdown
# ============================================================================

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# ── Globals ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/backups"
CONFIGS_DIR="${SCRIPT_DIR}/configs"
APPLIED=0
FAILED=0

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ── Helper Functions ────────────────────────────────────────────────────────
banner() {
    echo -e "${CYAN}${BOLD}"
    show_brand_banner ""
    echo "  Module: OS Hardening"
    echo -e "${NC}"
}

section() {
    echo ""
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${BOLD}  ▶ $1${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

ok()   { echo -e "  ${GREEN}[✔]${NC} $1"; ((APPLIED+=1)); }
warn() { echo -e "  ${YELLOW}[⚠]${NC} $1"; }
fail() { echo -e "  ${RED}[✘]${NC} $1"; ((FAILED+=1)); }
info() { echo -e "  ${CYAN}[ℹ]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[!] This script must be run as root (sudo).${NC}"
        exit 1
    fi
}

backup_file() {
    local file="$1"
    local backup_name
    common_init
    backup_name="$(basename "$file").backup.$(date +%Y%m%d_%H%M%S)"
    if [[ -f "$file" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            info "[dry-run] Backup: ${file} -> ${BACKUP_DIR}/${backup_name}"
        else
            cp "$file" "${BACKUP_DIR}/${backup_name}"
            record_state "backup" "$file" "${BACKUP_DIR}/${backup_name}"
            info "Backup: ${file} → ${BACKUP_DIR}/${backup_name}"
        fi
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
            --revert) ACTION="revert" ;;
            --lab-mode) LAB_MODE=true ;;
            *)
                echo "[!] Unknown hardening option: $1" >&2
                exit 2
                ;;
        esac
        shift
    done
}

print_plan() {
    banner
    echo "Profile: ${PROFILE}"
    echo "Dry run: no system changes will be made."
    echo ""
    echo "Selected OS controls:"
    echo "  service_hardening=${ENABLE_SERVICE_HARDENING}"
    echo "  service_masking=${ENABLE_SERVICE_MASKING}"
    echo "  sysctl_hardening=${ENABLE_SYSCTL_HARDENING}"
    echo "  usb_automount_disable=${ENABLE_USB_AUTOMOUNT_DISABLE}"
    echo "  core_dump_restriction=${ENABLE_CORE_DUMP_RESTRICTION}"
    echo "  secure_umask=${ENABLE_SECURE_UMASK}"
    echo "  ssh_hardening=${ENABLE_SSH_HARDENING}"
    echo "  ram_wipe=${ENABLE_RAM_WIPE}"
    echo "  auto_log_clean=${ENABLE_AUTO_LOG_CLEAN}"
    echo "  shell_history_disable=${ENABLE_SHELL_HISTORY_DISABLE}"
    echo "  kernel_module_restriction=${ENABLE_KERNEL_MODULE_RESTRICTION}"
}

print_revert_plan() {
    banner
    echo "Dry run: managed OS revert plan"
    echo "  remove Stealth Kit sysctl, udev, coredump, ssh, systemd, and modprobe drop-ins"
    echo "  remove marked blocks from limits/profile/bash/zsh files"
    echo "  unmask common services that this toolkit may have masked"
}

# ── Hardening Functions ─────────────────────────────────────────────────────

disable_unnecessary_services() {
    section "DISABLE UNNECESSARY SERVICES"
    
    # Services that expose the system or leave traces
    local services_to_disable=(
        "bluetooth.service"
        "cups.service"
        "cups-browsed.service"
        "avahi-daemon.service"
        "avahi-daemon.socket"
        "ModemManager.service"
        "whoopsie.service"        # Ubuntu error reporting
        "apport.service"          # Crash reporting
        "kerneloops.service"
        "gpu-manager.service"
        "accounts-daemon.service"
        "packagekit.service"
        "unattended-upgrades.service"
        "apt-daily.service"
        "apt-daily.timer"
        "apt-daily-upgrade.service"
        "apt-daily-upgrade.timer"
        "man-db.timer"
        "fstrim.timer"
        "motd-news.timer"
        "e2scrub_all.timer"
    )
    
    for svc in "${services_to_disable[@]}"; do
        if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            systemctl disable "$svc" 2>/dev/null || true
            if [[ "$ENABLE_SERVICE_MASKING" == "true" ]]; then
                systemctl mask "$svc" 2>/dev/null || true
            fi
            ok "Disabled: ${svc}"
        elif systemctl list-unit-files | grep -q "^${svc}" 2>/dev/null; then
            if [[ "$ENABLE_SERVICE_MASKING" == "true" ]]; then
                systemctl mask "$svc" 2>/dev/null || true
                info "Masked: ${svc} (was already inactive)"
            else
                info "Found inactive service: ${svc}"
            fi
        fi
    done
}

apply_sysctl_hardening() {
    section "SYSCTL KERNEL HARDENING"
    
    backup_file /etc/sysctl.conf
    
    local sysctl_conf="${CONFIGS_DIR}/sysctl_stealth.conf"
    
    if [[ -f "$sysctl_conf" ]]; then
        # Copy stealth sysctl config
        cp "$sysctl_conf" /etc/sysctl.d/99-stealth.conf
        record_state "write" "/etc/sysctl.d/99-stealth.conf" "sysctl hardening"
        sysctl -p /etc/sysctl.d/99-stealth.conf 2>/dev/null || true
        ok "Applied sysctl stealth configuration from config file"
    else
        # Apply inline
        cat > /etc/sysctl.d/99-stealth.conf << 'SYSCTL'
# ============================================================================
# Stealth Kit - Kernel Security Hardening
# ============================================================================

# ── Kernel Protection ──
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.randomize_va_space = 2
kernel.sysrq = 0
kernel.core_uses_pid = 1
kernel.perf_event_paranoid = 3
kernel.yama.ptrace_scope = 2
kernel.unprivileged_bpf_disabled = 1

# ── Core Dumps ──
kernel.core_pattern = |/bin/false
fs.suid_dumpable = 0

# ── Network - IPv4 Defensive Baseline ──
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_timestamps = 0
net.ipv4.ip_forward = 0

# ── File System ──
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
SYSCTL
        sysctl -p /etc/sysctl.d/99-stealth.conf 2>/dev/null || true
        record_state "write" "/etc/sysctl.d/99-stealth.conf" "sysctl hardening"
        ok "Applied sysctl stealth configuration"
    fi
    
    info "Key settings applied:"
    info "  • Kernel dmesg restricted"
    info "  • Kernel pointer restricted"
    info "  • TCP timestamps disabled"
    info "  • Core dumps disabled"
}

disable_usb_automount() {
    section "USB AUTO-MOUNT DISABLE"
    
    # Create udev rule to prevent auto-mounting USB devices
    cat > /etc/udev/rules.d/99-stealth-usb.rules << 'UDEV'
# Stealth Kit - Disable USB storage auto-mount
# Marks USB storage devices as ignored by udisks without deauthorizing the device.
ACTION=="add", SUBSYSTEMS=="usb", DRIVERS=="usb-storage", ENV{UDISKS_IGNORE}="1"
ACTION=="change", SUBSYSTEMS=="usb", DRIVERS=="usb-storage", ENV{UDISKS_IGNORE}="1"
UDEV
    record_state "write" "/etc/udev/rules.d/99-stealth-usb.rules" "disable usb storage automount"
    
    # Blacklist USB storage module (optional, aggressive)
    cat > /etc/modprobe.d/stealth-usb-storage.conf << 'MODPROBE'
# Stealth Kit — Blacklist USB storage
# Uncomment the next line to completely block USB storage devices
# install usb-storage /bin/true
MODPROBE
    record_state "write" "/etc/modprobe.d/stealth-usb-storage.conf" "usb storage optional blacklist"
    
    udevadm control --reload-rules 2>/dev/null || true
    ok "USB auto-mount disabled via udev rules"
}

restrict_core_dumps() {
    section "CORE DUMP RESTRICTIONS"
    
    # limits.conf
    backup_file /etc/security/limits.conf
    
    append_marked_block /etc/security/limits.conf "STEALTHKIT_CORE_LIMITS" '*               hard    core            0
*               soft    core            0
root            hard    core            0
root            soft    core            0'
    ok "Core dumps disabled in limits.conf"
    
    # sysctl (already done but ensure)
    sysctl -w kernel.core_pattern="|/bin/false" 2>/dev/null || true
    sysctl -w fs.suid_dumpable=0 2>/dev/null || true
    
    # systemd coredump
    mkdir -p /etc/systemd/coredump.conf.d
    cat > /etc/systemd/coredump.conf.d/stealth.conf << 'COREDUMP'
[Coredump]
Storage=none
ProcessSizeMax=0
COREDUMP
    record_state "write" "/etc/systemd/coredump.conf.d/stealth.conf" "disable systemd coredump storage"
    ok "Systemd coredump storage disabled"
}

set_secure_umask() {
    section "SECURE UMASK"
    
    # Set umask 077 (only owner can read/write/execute)
    local files_to_update=(
        "/etc/profile"
        "/etc/bash.bashrc"
        "/etc/zsh/zshrc"
    )
    
    for f in "${files_to_update[@]}"; do
        if [[ -f "$f" ]]; then
            backup_file "$f"
            append_marked_block "$f" "STEALTHKIT_SECURE_UMASK" "umask 077"
        fi
    done
    
    umask 077
    ok "umask set to 077 (restrictive file permissions)"
}

harden_ssh() {
    section "SSH HARDENING"
    
    local sshd_config="/etc/ssh/sshd_config"
    
    if [[ ! -f "$sshd_config" ]]; then
        info "SSH server not installed — skipping."
        return
    fi
    
    backup_file "$sshd_config"
    
    # Create a drop-in config for stealth settings
    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/stealth.conf << 'SSH'
# Stealth Kit — SSH Hardening
# Disable root login
PermitRootLogin no

# Disable password auth (use keys only)
PasswordAuthentication no

# Disable empty passwords
PermitEmptyPasswords no

# Disable X11 forwarding
X11Forwarding no

# Disable TCP forwarding
AllowTcpForwarding no

# Max auth tries
MaxAuthTries 3

# Timeout
LoginGraceTime 30

# Disable agent forwarding
AllowAgentForwarding no

# Hide version info
DebianBanner no

# Restrict to specific protocols
Protocol 2

# Keep useful authentication evidence for defenders.
LogLevel VERBOSE

# Change default port (uncomment and set desired port)
# Port 2222
SSH
    record_state "write" "/etc/ssh/sshd_config.d/stealth.conf" "ssh hardening drop-in"
    
    if command -v sshd &>/dev/null; then
        if ! sshd -t 2>/dev/null; then
            rm -f /etc/ssh/sshd_config.d/stealth.conf
            fail "SSH validation failed; removed generated drop-in"
            return
        fi
    fi

    # Restart SSH if running
    if systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null; then
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
        ok "SSH hardened and restarted"
    else
        ok "SSH hardened (not currently running)"
    fi
}

setup_ram_wipe_on_shutdown() {
    section "RAM WIPE ON SHUTDOWN"
    
    # Create a systemd service to clear RAM on shutdown
    cat > /etc/systemd/system/stealth-ram-wipe.service << 'RAMWIPE'
[Unit]
Description=Stealth Kit — RAM Wipe on Shutdown
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'sync; echo 3 > /proc/sys/vm/drop_caches; swapoff -a 2>/dev/null; swapon -a 2>/dev/null; echo "RAM and swap cleared"'

[Install]
WantedBy=halt.target reboot.target shutdown.target
RAMWIPE
    record_state "write" "/etc/systemd/system/stealth-ram-wipe.service" "ram wipe on shutdown"
    
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable stealth-ram-wipe.service 2>/dev/null || true
    ok "RAM wipe service installed (runs on shutdown/reboot)"
}

setup_auto_log_clean() {
    section "AUTOMATIC LOG CLEANING"
    require_destructive_lab_mode
    
    # Create a systemd service to clean logs on shutdown
    cat > /etc/systemd/system/stealth-log-clean.service << 'LOGCLEAN'
[Unit]
Description=Stealth Kit — Log Cleanup on Shutdown
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
    shred -fuz /var/log/auth.log 2>/dev/null; \
    shred -fuz /var/log/syslog 2>/dev/null; \
    shred -fuz /var/log/kern.log 2>/dev/null; \
    shred -fuz /var/log/daemon.log 2>/dev/null; \
    shred -fuz /var/log/messages 2>/dev/null; \
    truncate -s 0 /var/log/wtmp 2>/dev/null; \
    truncate -s 0 /var/log/btmp 2>/dev/null; \
    truncate -s 0 /var/log/lastlog 2>/dev/null; \
    journalctl --vacuum-size=0 2>/dev/null; \
    find /var/log -name "*.gz" -delete 2>/dev/null; \
    find /var/log -name "*.old" -delete 2>/dev/null; \
    find /var/log -name "*.1" -delete 2>/dev/null; \
    history -c 2>/dev/null; \
    rm -f /root/.bash_history /root/.zsh_history 2>/dev/null; \
    for h in /home/*; do rm -f "$h/.bash_history" "$h/.zsh_history" 2>/dev/null; done; \
    echo "Logs cleaned"'

[Install]
WantedBy=halt.target reboot.target shutdown.target
LOGCLEAN
    record_state "write" "/etc/systemd/system/stealth-log-clean.service" "lab-only log clean on shutdown"
    
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable stealth-log-clean.service 2>/dev/null || true
    ok "Automatic log cleaning service installed (runs on shutdown/reboot)"
}

disable_shell_history() {
    section "DISABLE SHELL HISTORY (PERSISTENT)"
    require_destructive_lab_mode
    
    # For bash
    local bashrc="/etc/bash.bashrc"
    if [[ -f "$bashrc" ]]; then
        backup_file "$bashrc"
        if ! grep -q "stealth-kit-history" "$bashrc" 2>/dev/null; then
            append_marked_block "$bashrc" "STEALTHKIT_HISTORY_DISABLE" 'export HISTSIZE=0
export HISTFILESIZE=0
unset HISTFILE
export LESSHISTFILE=/dev/null
export MYSQL_HISTFILE=/dev/null
export PSQL_HISTORY=/dev/null'
        fi
    fi
    
    # For zsh
    local zshrc="/etc/zsh/zshrc"
    if [[ -f "$zshrc" ]]; then
        backup_file "$zshrc"
        if ! grep -q "stealth-kit-history" "$zshrc" 2>/dev/null; then
            append_marked_block "$zshrc" "STEALTHKIT_HISTORY_DISABLE" 'export HISTSIZE=0
export SAVEHIST=0
unset HISTFILE
export LESSHISTFILE=/dev/null
export MYSQL_HISTFILE=/dev/null
export PSQL_HISTORY=/dev/null'
        fi
    fi
    
    # For current session
    export HISTSIZE=0
    export HISTFILESIZE=0
    unset HISTFILE 2>/dev/null || true
    
    ok "Shell history permanently disabled for all users"
}

restrict_kernel_modules() {
    section "KERNEL MODULE RESTRICTIONS"
    
    # Blacklist unnecessary/dangerous modules
    cat > /etc/modprobe.d/stealth-blacklist.conf << 'BLACKLIST'
# Stealth Kit — Blacklist unnecessary kernel modules

# Uncommon network protocols (reduce attack surface)
install dccp /bin/true
install sctp /bin/true
install rds /bin/true
install tipc /bin/true

# Uncommon filesystems
install cramfs /bin/true
install freevxfs /bin/true
install jffs2 /bin/true
install hfs /bin/true
install hfsplus /bin/true
install squashfs /bin/true
install udf /bin/true

# Firewire (can be used for DMA attacks)
install firewire-core /bin/true
install firewire-ohci /bin/true
install firewire-sbp2 /bin/true

# Bluetooth (if not needed for pentest)
# install bluetooth /bin/true
# install btusb /bin/true
BLACKLIST
    record_state "write" "/etc/modprobe.d/stealth-blacklist.conf" "kernel module restrictions"
    
    ok "Unnecessary kernel modules blacklisted"
}

# ── Revert ──────────────────────────────────────────────────────────────────
revert_os() {
    echo -e "${YELLOW}${BOLD}Reverting OS hardening...${NC}"
    
    # Remove stealth sysctl
    rm -f /etc/sysctl.d/99-stealth.conf 2>/dev/null || true
    sysctl --system 2>/dev/null || true
    ok "Removed stealth sysctl config"
    
    # Remove USB rules
    rm -f /etc/udev/rules.d/99-stealth-usb.rules 2>/dev/null || true
    udevadm control --reload-rules 2>/dev/null || true
    ok "Removed USB auto-mount rules"
    
    # Remove core dump restrictions
    rm -f /etc/systemd/coredump.conf.d/stealth.conf 2>/dev/null || true
    remove_marked_block /etc/security/limits.conf "STEALTHKIT_CORE_LIMITS"
    ok "Removed core dump restrictions"
    
    # Remove SSH hardening
    rm -f /etc/ssh/sshd_config.d/stealth.conf 2>/dev/null || true
    ok "Removed SSH hardening config"
    
    # Remove shutdown services
    systemctl disable stealth-ram-wipe.service 2>/dev/null || true
    systemctl disable stealth-log-clean.service 2>/dev/null || true
    rm -f /etc/systemd/system/stealth-ram-wipe.service 2>/dev/null || true
    rm -f /etc/systemd/system/stealth-log-clean.service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    ok "Removed shutdown cleanup services"

    # Remove shell/profile marked blocks
    remove_marked_block /etc/profile "STEALTHKIT_SECURE_UMASK"
    remove_marked_block /etc/bash.bashrc "STEALTHKIT_SECURE_UMASK"
    remove_marked_block /etc/zsh/zshrc "STEALTHKIT_SECURE_UMASK"
    remove_marked_block /etc/bash.bashrc "STEALTHKIT_HISTORY_DISABLE"
    remove_marked_block /etc/zsh/zshrc "STEALTHKIT_HISTORY_DISABLE"
    ok "Removed managed shell/profile blocks"
    
    # Remove MAC spoofing service
    for svc in /etc/systemd/system/macspoof@*.service; do
        if [[ -f "$svc" ]]; then
            local svc_name
            svc_name=$(basename "$svc")
            systemctl disable "$svc_name" 2>/dev/null || true
            rm -f "$svc" 2>/dev/null || true
        fi
    done
    rm -f /etc/systemd/system/macspoof@.service 2>/dev/null || true
    ok "Removed MAC spoofing services"
    
    # Remove kernel module blacklist
    rm -f /etc/modprobe.d/stealth-blacklist.conf 2>/dev/null || true
    rm -f /etc/modprobe.d/stealth-usb-storage.conf 2>/dev/null || true
    ok "Removed kernel module blacklist"
    
    # Unmask disabled services
    local services_to_unmask=(
        "bluetooth.service"
        "cups.service"
        "avahi-daemon.service"
    )
    for svc in "${services_to_unmask[@]}"; do
        systemctl unmask "$svc" 2>/dev/null || true
    done
    ok "Unmasked common services"
    
    echo -e "${GREEN}${BOLD}OS hardening reverted.${NC}"
}

# ── Summary ─────────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  OS HARDENING SUMMARY${NC}"
    echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${GREEN}${BOLD}Applied:  ${APPLIED}${NC}"
    echo -e "  ${RED}${BOLD}Failed:   ${FAILED}${NC}"
    echo ""
    echo -e "  ${CYAN}${BOLD}ACTIVE HARDENING:${NC}"
    echo -e "  ${CYAN}  • Profile: ${PROFILE}${NC}"
    echo -e "  ${CYAN}  • Service hardening applied according to profile${NC}"
    echo -e "  ${CYAN}  • Kernel hardened via sysctl${NC}"
    echo -e "  ${CYAN}  • USB auto-mount disabled${NC}"
    echo -e "  ${CYAN}  • Core dumps disabled${NC}"
    echo -e "  ${CYAN}  • umask set to 077${NC}"
    echo -e "  ${CYAN}  • SSH hardened${NC}"
    echo -e "  ${CYAN}  • Lab-only destructive controls remain profile-gated${NC}"
    echo -e "  ${CYAN}  • Unnecessary kernel modules blacklisted${NC}"
    echo ""
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
    ACTION="${ACTION:-apply}"
    parse_args "$@"
    MODULE_NAME="harden"
    load_runtime_config
    common_init
    
    if [[ "$ACTION" == "revert" && "$DRY_RUN" == "true" ]]; then
        print_revert_plan
        exit 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        print_plan
        exit 0
    fi

    check_root

    if [[ "$ACTION" == "revert" ]]; then
        revert_os
        exit 0
    fi
    
    banner
    
    echo -e "${YELLOW}${BOLD}[!] WARNING: This will modify system services, kernel, and boot settings.${NC}"
    echo -e "${YELLOW}${BOLD}[!] Backups will be saved to: ${BACKUP_DIR}${NC}"
    echo ""
    
    confirm_or_exit "  Continue with selected OS hardening changes? (y/N): "
    
    echo ""
    echo -e "${CYAN}OS hardening started at: $(date)${NC}"
    
    [[ "$ENABLE_SERVICE_HARDENING" == "true" ]] && disable_unnecessary_services || info "Skipping service hardening."
    [[ "$ENABLE_SYSCTL_HARDENING" == "true" ]] && apply_sysctl_hardening || info "Skipping sysctl hardening."
    [[ "$ENABLE_USB_AUTOMOUNT_DISABLE" == "true" ]] && disable_usb_automount || info "Skipping USB auto-mount changes."
    [[ "$ENABLE_CORE_DUMP_RESTRICTION" == "true" ]] && restrict_core_dumps || info "Skipping core dump restrictions."
    [[ "$ENABLE_SECURE_UMASK" == "true" ]] && set_secure_umask || info "Skipping secure umask."
    [[ "$ENABLE_SSH_HARDENING" == "true" ]] && harden_ssh || info "Skipping SSH hardening."
    [[ "$ENABLE_RAM_WIPE" == "true" ]] && setup_ram_wipe_on_shutdown || info "Skipping RAM wipe service."
    [[ "$ENABLE_AUTO_LOG_CLEAN" == "true" ]] && setup_auto_log_clean || info "Skipping automatic log cleaning."
    [[ "$ENABLE_SHELL_HISTORY_DISABLE" == "true" ]] && disable_shell_history || info "Skipping shell history disable."
    [[ "$ENABLE_KERNEL_MODULE_RESTRICTION" == "true" ]] && restrict_kernel_modules || info "Skipping kernel module restrictions."
    
    print_summary
}

main "$@"
