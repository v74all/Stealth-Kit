#!/usr/bin/env bash
# ============================================================================
# scan_system.sh - System Security Audit Scanner
# V7LTHRONYX / Aiden Azad
# ============================================================================
# Scans the current system state and identifies exposure points:
#   - Running services & open ports
#   - Log files & shell histories
#   - Network configuration (MAC, hostname, DNS, firewall)
#   - Temp files, caches, cron jobs
#   - Kernel security settings
# ============================================================================

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ── Globals ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_BASE="${SCRIPT_DIR}/backups/scan_report_$(date +%Y%m%d_%H%M%S)"
REPORT_FILE="${REPORT_BASE}.txt"
REPORT_MD="${REPORT_BASE}.md"
REPORT_JSON="${REPORT_BASE}.json"
ISSUES=0
WARNINGS=0
WRITE_JSON=false

# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ── Helper Functions ────────────────────────────────────────────────────────
banner() {
    echo -e "${CYAN}${BOLD}"
    show_brand_banner ""
    echo "  Module: System Security Audit Scanner"
    echo -e "${NC}"
}

section() {
    echo ""
    echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${MAGENTA}${BOLD}  ▶ $1${NC}"
    echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

ok()      { echo -e "  ${GREEN}[✔]${NC} $1"; }
warn()    { echo -e "  ${YELLOW}[!]${NC} $1"; ((WARNINGS+=1)); }
danger()  { echo -e "  ${RED}[x]${NC} $1"; ((ISSUES+=1)); }
info()    { echo -e "  ${CYAN}[ℹ]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${YELLOW}[!] Not running as root; privileged checks will be partial.${NC}"
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) WRITE_JSON=true ;;
            --profile)
                shift
                PROFILE="${1:-$PROFILE}"
                ;;
            --dry-run|--yes|--lab-mode)
                ;;
            *)
                echo "[!] Unknown scan option: $1" >&2
                exit 2
                ;;
        esac
        shift
    done
}

# ── Scan Functions ──────────────────────────────────────────────────────────

scan_running_services() {
    section "RUNNING SERVICES"
    
    local services
    services=$(systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | awk '{print $1}' || true)
    local count
    count=$(echo "$services" | grep -c . || true)
    
    info "Total running services: ${count}"
    
    # Dangerous services for stealth
    local dangerous_services=(
        "ssh.service" "sshd.service"
        "apache2.service" "nginx.service" "lighttpd.service"
        "mysql.service" "mariadb.service" "postgresql.service"
        "cups.service" "cupsd.service"
        "bluetooth.service"
        "avahi-daemon.service"
        "smbd.service" "nmbd.service"
        "rpcbind.service"
        "nfs-server.service"
        "vsftpd.service"
        "snmpd.service"
    )
    
    for svc in "${dangerous_services[@]}"; do
        if echo "$services" | grep -q "^${svc}$"; then
            danger "Service running: ${svc} (exposes system on network)"
        fi
    done
    
    echo ""
    info "All running services:"
    if [[ -n "$services" ]]; then
        echo "$services" | while read -r svc; do
            [[ -n "$svc" ]] && echo "      • $svc"
        done
    else
        info "No services reported or systemd is unavailable in this context."
    fi
}

scan_open_ports() {
    section "OPEN PORTS & LISTENING SOCKETS"
    
    local listening
    listening=$(ss -tulnp 2>/dev/null || netstat -tulnp 2>/dev/null || true)
    
    local port_count
    port_count=$(echo "$listening" | grep -c "LISTEN" || true)
    
    if [[ $port_count -gt 0 ]]; then
        danger "Found ${port_count} listening port(s):"
        echo "$listening" | grep "LISTEN" | while read -r line; do
            echo "      ${line}"
        done
    else
        ok "No listening ports found."
    fi
    
    echo ""
    # Check for externally accessible ports (not just localhost)
    local external_ports
    external_ports=$(ss -tulnp 2>/dev/null | grep "LISTEN" | grep -v "127.0.0.1" | grep -v "::1" || true)
    if [[ -n "$external_ports" ]]; then
        danger "Externally accessible ports detected:"
        echo "$external_ports" | while read -r line; do
            echo "      ${line}"
        done
    else
        ok "No externally accessible ports."
    fi
}

scan_log_files() {
    section "LOG FILES & EVIDENCE"
    
    # /var/log size
    local log_size
    log_size=$(du -sh /var/log 2>/dev/null | awk 'NR==1{print $1}' || true)
    [[ -z "$log_size" ]] && log_size="N/A"
    info "Total /var/log size: ${log_size}"
    
    # Important log files
    local log_files=(
        "/var/log/syslog"
        "/var/log/auth.log"
        "/var/log/kern.log"
        "/var/log/daemon.log"
        "/var/log/messages"
        "/var/log/dpkg.log"
        "/var/log/apt/history.log"
        "/var/log/apt/term.log"
        "/var/log/lastlog"
        "/var/log/wtmp"
        "/var/log/btmp"
        "/var/log/faillog"
    )
    
    for logf in "${log_files[@]}"; do
        if [[ -f "$logf" ]]; then
            local fsize
            fsize=$(du -sh "$logf" 2>/dev/null | awk 'NR==1{print $1}' || true)
            if [[ "$fsize" != "0" ]]; then
                warn "Log file exists: ${logf} (${fsize})"
            fi
        fi
    done
    
    # Journald
    local journal_size
    journal_size=$(journalctl --disk-usage 2>/dev/null | grep -oP '[0-9]+([.][0-9]+)?[KMGT]?' | head -1 || echo "N/A")
    if [[ "$journal_size" != "N/A" ]]; then
        warn "Journald log size: ${journal_size}"
    fi
    
    # utmp / who
    local logged_in
    logged_in=$(who 2>/dev/null | wc -l)
    info "Currently logged-in sessions: ${logged_in}"
    
    # Last login records
    local last_count
    last_count=$(last -n 20 2>/dev/null | grep -c . || true)
    if [[ $last_count -gt 1 ]]; then
        warn "Login history exists (${last_count} recent entries in 'last')"
    fi
}

scan_shell_histories() {
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
        "$HOME/.nano/search_history"
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
        if [[ -f "$hf" ]]; then
            local lines
            lines=$(wc -l < "$hf" 2>/dev/null || echo "0")
            warn "History file: ${hf} (${lines} lines)"
        fi
    done
    
    # Check HISTFILE env
    if [[ -n "${HISTFILE:-}" ]]; then
        info "Current HISTFILE: ${HISTFILE}"
    fi
    
    # Check if HISTSIZE is set to 0
    if [[ "${HISTSIZE:-999}" != "0" ]]; then
        warn "HISTSIZE is not 0 (currently: ${HISTSIZE:-default})"
    else
        ok "HISTSIZE is set to 0."
    fi
}

scan_temp_files() {
    section "TEMPORARY FILES & CACHES"
    
    # /tmp
    local tmp_count
    tmp_count=$({ find /tmp -maxdepth 2 -type f 2>/dev/null || true; } | wc -l)
    if [[ $tmp_count -gt 0 ]]; then
        warn "/tmp contains ${tmp_count} file(s)"
    else
        ok "/tmp is clean."
    fi
    
    # /var/tmp
    local vartmp_count
    vartmp_count=$({ find /var/tmp -maxdepth 2 -type f 2>/dev/null || true; } | wc -l)
    if [[ $vartmp_count -gt 0 ]]; then
        warn "/var/tmp contains ${vartmp_count} file(s)"
    else
        ok "/var/tmp is clean."
    fi
    
    # Thumbnails
    local thumb_dir="$HOME/.cache/thumbnails"
    if [[ -d "$thumb_dir" ]]; then
        local thumb_count
        thumb_count=$({ find "$thumb_dir" -type f 2>/dev/null || true; } | wc -l)
        if [[ $thumb_count -gt 0 ]]; then
            warn "Thumbnail cache: ${thumb_count} file(s) in ${thumb_dir}"
        fi
    fi
    
    # Recently used
    local recent_file="$HOME/.local/share/recently-used.xbel"
    if [[ -f "$recent_file" ]]; then
        local recent_size
        recent_size=$(du -sh "$recent_file" 2>/dev/null | awk 'NR==1{print $1}' || true)
        warn "Recently-used file exists: ${recent_file} (${recent_size})"
    fi
    
    # Trash
    local trash_dir="$HOME/.local/share/Trash"
    if [[ -d "$trash_dir" ]]; then
        local trash_count
        trash_count=$({ find "$trash_dir" -type f 2>/dev/null || true; } | wc -l)
        if [[ $trash_count -gt 0 ]]; then
            warn "Trash contains ${trash_count} file(s)"
        fi
    fi
    
    # Browser cache (Firefox)
    local firefox_dir="$HOME/.mozilla/firefox"
    if [[ -d "$firefox_dir" ]]; then
        local ff_size
        ff_size=$(du -sh "$firefox_dir" 2>/dev/null | awk 'NR==1{print $1}' || true)
        warn "Firefox profile exists: ${firefox_dir} (${ff_size})"
    fi
    
    # Chromium cache
    local chromium_dir="$HOME/.config/chromium"
    if [[ -d "$chromium_dir" ]]; then
        local ch_size
        ch_size=$(du -sh "$chromium_dir" 2>/dev/null | awk 'NR==1{print $1}' || true)
        warn "Chromium profile exists: ${chromium_dir} (${ch_size})"
    fi
    
    # Google Chrome
    local chrome_dir="$HOME/.config/google-chrome"
    if [[ -d "$chrome_dir" ]]; then
        local gc_size
        gc_size=$(du -sh "$chrome_dir" 2>/dev/null | awk 'NR==1{print $1}' || true)
        warn "Google Chrome profile exists: ${chrome_dir} (${gc_size})"
    fi
}

scan_network_config() {
    section "NETWORK CONFIGURATION"
    
    # Hostname
    local hostname_val
    hostname_val=$(hostname)
    if [[ "$hostname_val" == *"kali"* ]]; then
        danger "Hostname contains 'kali': ${hostname_val} (easily identifiable!)"
    else
        info "Hostname: ${hostname_val}"
    fi
    
    # MAC addresses
    info "Network interfaces & MAC addresses:"
    while read -r line; do
        [[ -z "$line" ]] && continue
        local iface mac
        iface=$(echo "$line" | awk -F: '{print $2}' | tr -d ' ')
        mac=$(echo "$line" | grep -oP 'link/ether \K[\da-f:]+' || echo "N/A")
        if [[ "$mac" != "N/A" ]]; then
            echo "      • ${iface}: ${mac}"
            # Check if MAC looks like default (OUI check)
            local oui="${mac:0:8}"
            info "  OUI prefix: ${oui} (check if matches real hardware vendor)"
        fi
    done < <(ip -o link show 2>/dev/null || true)
    
    # DNS configuration
    info "DNS Resolvers:"
    if [[ -f /etc/resolv.conf ]]; then
        while read -r ns; do
            local dns_ip
            dns_ip=$(echo "$ns" | awk '{print $2}')
            if [[ "$dns_ip" == "8.8.8.8" || "$dns_ip" == "8.8.4.4" ]]; then
                warn "Using Google DNS: ${dns_ip} (DNS queries visible to Google)"
            elif [[ "$dns_ip" == "1.1.1.1" || "$dns_ip" == "1.0.0.1" ]]; then
                warn "Using Cloudflare DNS: ${dns_ip}"
            elif [[ "$dns_ip" == "127.0.0.1" || "$dns_ip" == "::1" ]]; then
                ok "DNS points to localhost (likely using local resolver)"
            else
                info "DNS: ${dns_ip}"
            fi
        done < <(grep "^nameserver" /etc/resolv.conf 2>/dev/null || true)
    fi
    
    # IPv6 status
    if [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null) == "1" ]]; then
        ok "IPv6 is disabled."
    else
        info "IPv6 is enabled. Disable only when the engagement profile requires it."
    fi
    
    # Check for Tor
    if pgrep -x tor &>/dev/null; then
        ok "Tor is running."
    else
        info "Tor is NOT running."
    fi
    
    # Check for VPN
    if ip link show 2>/dev/null | grep -qE "tun0|wg0|ppp0"; then
        ok "VPN tunnel interface detected."
    else
        info "No VPN tunnel interface detected."
    fi
}

scan_firewall() {
    section "FIREWALL STATUS"
    
    # iptables
    local ipt_output ipt_rules
    if ! ipt_output=$(iptables -L -n 2>/dev/null); then
        warn "Unable to inspect iptables rules (permission denied, unsupported backend, or missing command)."
        ipt_output=""
        ipt_rules=-1
    else
        ipt_rules=$(echo "$ipt_output" | grep -c -v "^Chain\|^target\|^$" || true)
    fi
    
    if [[ $ipt_rules -eq 0 ]]; then
        danger "iptables has NO rules configured (all traffic allowed!)"
    elif [[ $ipt_rules -gt 0 ]]; then
        info "iptables rules count: ${ipt_rules}"
        echo ""
        info "iptables INPUT policy:"
        echo "$ipt_output" | head -5 | while read -r line; do
            echo "      ${line}"
        done || true
    fi
    
    # nftables
    if command -v nft &>/dev/null; then
        local nft_rules
        nft_rules=$(nft list ruleset 2>/dev/null | wc -l || true)
        info "nftables rules: ${nft_rules} lines"
    fi
    
    # ufw
    if command -v ufw &>/dev/null; then
        local ufw_status
        ufw_status=$(ufw status 2>/dev/null | head -1)
        info "UFW status: ${ufw_status}"
    fi
}

scan_cron_jobs() {
    section "SCHEDULED TASKS (CRON)"
    
    # System crontab
    if [[ -f /etc/crontab ]]; then
        local cron_entries
        cron_entries=$(grep -v "^#\|^$\|^SHELL\|^PATH\|^MAILTO" /etc/crontab 2>/dev/null | wc -l)
        info "System crontab entries: ${cron_entries}"
    fi
    
    # User crontabs
    local user_cron
    user_cron=$(crontab -l 2>/dev/null | grep -v "^#\|^$" | wc -l || true)
    if [[ $user_cron -gt 0 ]]; then
        warn "User crontab has ${user_cron} entries:"
        crontab -l 2>/dev/null | grep -v "^#\|^$" | while read -r line; do
            echo "      ${line}"
        done
    else
        ok "No user crontab entries."
    fi
    
    # /etc/cron.d/
    local crond_count
    crond_count=$(ls /etc/cron.d/ 2>/dev/null | wc -l)
    info "Files in /etc/cron.d/: ${crond_count}"
    
    # Systemd timers
    local timer_count
    timer_count=$(systemctl list-timers --no-pager --no-legend 2>/dev/null | wc -l || true)
    info "Active systemd timers: ${timer_count}"
}

scan_kernel_security() {
    section "KERNEL SECURITY SETTINGS"
    
    local checks=(
        "kernel.dmesg_restrict|1|Kernel dmesg access restricted"
        "kernel.kptr_restrict|2|Kernel pointer restriction"
        "kernel.randomize_va_space|2|ASLR enabled"
        "net.ipv4.conf.all.rp_filter|1|Reverse path filtering"
        "net.ipv4.conf.all.accept_redirects|0|ICMP redirects disabled"
        "net.ipv4.conf.all.send_redirects|0|Send redirects disabled"
        "net.ipv4.conf.all.accept_source_route|0|Source routing disabled"
        "net.ipv4.tcp_syncookies|1|SYN cookies enabled"
        "fs.protected_hardlinks|1|Protected hardlinks enabled"
        "fs.protected_symlinks|1|Protected symlinks enabled"
        "kernel.core_pattern||Core dumps pattern (should be empty/disabled)"
    )
    
    for check in "${checks[@]}"; do
        IFS='|' read -r param expected desc <<< "$check"
        local current
        current=$(sysctl -n "$param" 2>/dev/null || echo "N/A")
        
        if [[ "$current" == "$expected" ]]; then
            ok "${desc}: ${current}"
        elif [[ -z "$expected" ]]; then
            info "${desc}: ${current}"
        else
            warn "${desc}: ${current} (recommended: ${expected})"
        fi
    done
    
    # Core dumps
    local core_limit
    core_limit=$(ulimit -c 2>/dev/null)
    if [[ "$core_limit" == "0" ]]; then
        ok "Core dumps disabled (ulimit -c 0)"
    else
        warn "Core dumps allowed: ulimit -c = ${core_limit}"
    fi
}

scan_swap() {
    section "SWAP & MEMORY"
    
    local swap_total
    swap_total=$(free -h 2>/dev/null | awk '/Swap:/{print $2}')
    local swap_used
    swap_used=$(free -h 2>/dev/null | awk '/Swap:/{print $3}')
    
    if [[ "$swap_used" != "0B" && "$swap_used" != "0" ]]; then
        warn "Swap in use: ${swap_used} / ${swap_total} (may contain sensitive data)"
    else
        ok "Swap is clean (${swap_used} used)."
    fi
    
    # Check if swap is encrypted
    if grep -q "swap" /etc/crypttab 2>/dev/null; then
        ok "Swap appears to be encrypted."
    else
        warn "Swap is NOT encrypted."
    fi
}

# ── Summary ─────────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  SCAN SUMMARY${NC}"
    echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    if [[ $ISSUES -gt 0 ]]; then
        echo -e "  ${RED}${BOLD}Critical Issues: ${ISSUES}${NC}"
    else
        echo -e "  ${GREEN}${BOLD}Critical Issues: 0${NC}"
    fi
    
    if [[ $WARNINGS -gt 0 ]]; then
        echo -e "  ${YELLOW}${BOLD}Warnings:        ${WARNINGS}${NC}"
    else
        echo -e "  ${GREEN}${BOLD}Warnings:        0${NC}"
    fi
    
    echo ""
    
    local total=$((ISSUES + WARNINGS))
    if [[ $total -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}System appears to meet the selected hardening baseline.${NC}"
    elif [[ $ISSUES -gt 5 ]]; then
        echo -e "  ${RED}${BOLD}System has multiple high-priority exposure points.${NC}"
    else
        echo -e "  ${YELLOW}${BOLD}System needs review; inspect warnings above.${NC}"
    fi
    
    echo ""
    echo -e "  ${CYAN}Report saved to: ${REPORT_FILE}${NC}"
    echo -e "  ${CYAN}Markdown saved to: ${REPORT_MD}${NC}"
    if [[ "$WRITE_JSON" == "true" ]]; then
        write_json_summary
        echo -e "  ${CYAN}JSON summary saved to: ${REPORT_JSON}${NC}"
    fi
    echo ""
}

write_json_summary() {
    cat > "$REPORT_JSON" << JSON
{
  "generated_at": "$(date -Is)",
  "tool": "$(json_escape "$TOOL_NAME")",
  "brand": "$(json_escape "$BRAND")",
  "author": "$(json_escape "$AUTHOR")",
  "profile": "$(json_escape "$PROFILE")",
  "issues": ${ISSUES},
  "warnings": ${WARNINGS},
  "text_report": "$(json_escape "$REPORT_FILE")",
  "markdown_report": "$(json_escape "$REPORT_MD")"
}
JSON
}

# ── Strip ANSI codes for clean file output ──────────────────────────────────
strip_ansi() {
    sed 's/\x1b\[[0-9;]*m//g; s/\x1b\[[0-9;]*[a-zA-Z]//g'
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"
    MODULE_NAME="scan"
    load_runtime_config
    common_init
    check_root
    banner
    
    echo -e "${CYAN}Scan started at: $(date)${NC}"
    echo -e "${CYAN}Running as: $(whoami)${NC}"
    echo ""
    
    # Run all scans — display with colors in terminal, save clean text to file
    {
        scan_running_services
        scan_open_ports
        scan_log_files
        scan_shell_histories
        scan_temp_files
        scan_network_config
        scan_firewall
        scan_cron_jobs
        scan_kernel_security
        scan_swap
        print_summary
    } 2>&1 | tee >(strip_ansi > "$REPORT_FILE") >(strip_ansi > "$REPORT_MD")
    chmod 600 "$REPORT_FILE" "$REPORT_MD" "$REPORT_JSON" 2>/dev/null || true
}

main "$@"
