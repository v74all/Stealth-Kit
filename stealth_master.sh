#!/usr/bin/env bash
# ============================================================================
#
#   ███████╗████████╗███████╗ █████╗ ██╗  ████████╗██╗  ██╗
#   ██╔════╝╚══██╔══╝██╔════╝██╔══██╗██║  ╚══██╔══╝██║  ██║
#   ███████╗   ██║   █████╗  ███████║██║     ██║   ███████║
#   ╚════██║   ██║   ██╔══╝  ██╔══██║██║     ██║   ██╔══██║
#   ███████║   ██║   ███████╗██║  ██║███████╗██║   ██║  ██║
#   ╚══════╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚══════╝╚═╝   ╚═╝  ╚═╝
#              ██╗  ██╗██╗████████╗
#              ██║ ██╔╝██║╚══██╔══╝
#              █████╔╝ ██║   ██║
#              ██╔═██╗ ██║   ██║
#              ██║  ██╗██║   ██║
#              ╚═╝  ╚═╝╚═╝   ╚═╝
#
# stealth_master.sh - Master Controller for Stealth Kit
# V7LTHRONYX / Aiden Azad
# ============================================================================
# Usage:
#   sudo ./stealth_master.sh              # Interactive menu
#   sudo ./stealth_master.sh --scan       # Scan system only
#   sudo ./stealth_master.sh --clean      # Lab-only destructive cleanup
#   sudo ./stealth_master.sh --network    # Network hardening only
#   sudo ./stealth_master.sh --harden     # OS hardening only
#   sudo ./stealth_master.sh --full       # Full workflow (scan → harden → network → verify)
#   sudo ./stealth_master.sh --revert     # Revert all changes
#   sudo ./stealth_master.sh --status     # Quick status check
# ============================================================================

set -euo pipefail

# ── Globals ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="${SCRIPT_DIR}/modules"
BACKUP_DIR="${SCRIPT_DIR}/backups"
VERSION="1.1.0"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

MODULE_FLAGS=()
ACTION="menu"
SCAN_JSON=false

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Helper Functions ────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}${BOLD}"
        echo "╔══════════════════════════════════════════════════════════════╗"
        echo "║  [!] ERROR: This toolkit must be run as root (sudo).       ║"
        echo "║                                                            ║"
        echo "║  Usage: sudo ./stealth_master.sh [options]                 ║"
        echo "╚══════════════════════════════════════════════════════════════╝"
        echo -e "${NC}"
        exit 1
    fi
}

show_banner() {
    if [[ -t 1 && -n "${TERM:-}" && "${TERM:-dumb}" != "dumb" ]]; then
        clear
    fi
    echo -e "${RED}${BOLD}"
    show_brand_banner "$VERSION"
    echo -e "${NC}${DIM}  Profile: ${PROFILE} | Dry-run: ${DRY_RUN} | Lab mode: ${LAB_MODE}${NC}"
    echo -e "${DIM}  ----------------------------------------------------------------${NC}"
    echo ""
}

show_disclaimer() {
    echo -e "${YELLOW}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                        ⚠  DISCLAIMER  ⚠                       ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    echo "║  This toolkit is designed for AUTHORIZED security audit and    ║"
    echo "║  defensive hardening work ONLY.                                ║"
    echo "║                                                                ║"
    echo "║  Unauthorized use of this toolkit is ILLEGAL and unethical.    ║"
    echo "║  The author assumes no liability for misuse.                   ║"
    echo "║                                                                ║"
    echo "║  Always obtain written authorization before engagement.        ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
}

# ── Module Runners ──────────────────────────────────────────────────────────
run_scan() {
    echo -e "${CYAN}${BOLD}[*] Running System Scan...${NC}"
    echo ""
    if [[ "$SCAN_JSON" == "true" ]]; then
        bash "${MODULES_DIR}/scan_system.sh" "${MODULE_FLAGS[@]}" --json
    else
        bash "${MODULES_DIR}/scan_system.sh" "${MODULE_FLAGS[@]}"
    fi
}

run_clean() {
    echo -e "${RED}${BOLD}[*] Running Lab Cleanup Gate...${NC}"
    echo ""
    bash "${MODULES_DIR}/clean_traces.sh" "${MODULE_FLAGS[@]}"
}

run_network() {
    echo -e "${MAGENTA}${BOLD}[*] Running Network Hardening...${NC}"
    echo ""
    bash "${MODULES_DIR}/stealth_network.sh" "${MODULE_FLAGS[@]}"
}

run_harden() {
    echo -e "${BLUE}${BOLD}[*] Running OS Hardening...${NC}"
    echo ""
    bash "${MODULES_DIR}/harden_os.sh" "${MODULE_FLAGS[@]}"
}

run_full() {
    echo -e "${RED}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           FULL HARDENING WORKFLOW                          ║"
    echo "║           Audit, harden, network, verify                   ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${YELLOW}${BOLD}[!] This will:${NC}"
    echo -e "${YELLOW}  1. Scan system state (pre-assessment)${NC}"
    echo -e "${YELLOW}  2. Harden operating system${NC}"
    echo -e "${YELLOW}  3. Apply selected network hardening${NC}"
    echo -e "${YELLOW}  4. Re-scan to verify (post-assessment)${NC}"
    echo -e "${YELLOW}  Cleanup/destructive actions are never part of --full.${NC}"
    echo ""
    
    if [[ "$YES" != "true" && "$DRY_RUN" != "true" ]]; then
        read -rp "  Proceed with FULL stealth activation? (y/N): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo -e "${RED}Aborted.${NC}"
            return
        fi
    fi
    
    YES="true"
    MODULE_FLAGS+=("--yes")
    
    show_phase 1 4 "PRE-SCAN"
    run_scan
    
    show_phase 2 4 "OS HARDENING"
    run_harden
    
    show_phase 3 4 "NETWORK HARDENING"
    run_network
    
    show_phase 4 4 "POST-SCAN VERIFICATION"
    run_scan
    
    echo ""
    echo -e "${GREEN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║               HARDENING WORKFLOW COMPLETE                  ║"
    echo "║                                                            ║"
    echo "║  Review the generated reports and state manifest.          ║"
    echo "║  Use '--revert' to roll back managed settings.             ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

run_revert() {
    echo -e "${YELLOW}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           REVERTING MANAGED CHANGES                        ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    echo -e "${YELLOW}${BOLD}[!] This will restore original system settings from backups.${NC}"
    echo ""
    
    confirm_or_exit "  Revert managed changes? (y/N): "
    
    echo ""
    echo -e "${CYAN}Reverting network settings...${NC}"
    bash "${MODULES_DIR}/stealth_network.sh" "${MODULE_FLAGS[@]}" --revert 2>/dev/null || true
    
    echo ""
    echo -e "${CYAN}Reverting OS hardening...${NC}"
    bash "${MODULES_DIR}/harden_os.sh" "${MODULE_FLAGS[@]}" --revert 2>/dev/null || true
    
    echo ""
    echo -e "${GREEN}${BOLD}All stealth changes reverted.${NC}"
    echo -e "${YELLOW}A system reboot is recommended.${NC}"
}

quick_status() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                  QUICK STATUS CHECK                        ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    # Hostname
    echo -e "  ${CYAN}Hostname:${NC}     $(hostname)"
    
    # MAC address (first non-lo interface)
    local mac
    mac=$(ip -o link show 2>/dev/null | grep -v "lo:" | head -1 | grep -oP 'link/ether \K[\da-f:]+' || true)
    [[ -z "$mac" ]] && mac="N/A"
    echo -e "  ${CYAN}MAC Address:${NC}  ${mac}"
    
    # Open ports
    local ports
    ports=$(ss -tulnp 2>/dev/null | awk 'BEGIN{count=0} /LISTEN/{count++} END{print count}')
    if [[ "$ports" -gt 0 ]]; then
        echo -e "  ${RED}Open Ports:${NC}   ${ports} (EXPOSED)"
    else
        echo -e "  ${GREEN}Open Ports:${NC}   0 (STEALTH)"
    fi
    
    # Firewall
    local fw_output fw_rules
    if fw_output=$(iptables -L -n 2>/dev/null); then
        fw_rules=$(printf '%s\n' "$fw_output" | awk 'BEGIN{count=0} !/^Chain/ && !/^target/ && NF{count++} END{print count}')
    else
        fw_rules="N/A"
    fi
    if [[ "$fw_rules" == "N/A" ]]; then
        echo -e "  ${YELLOW}Firewall:${NC}     Not inspectable in this session"
    elif [[ "$fw_rules" -gt 0 ]]; then
        echo -e "  ${GREEN}Firewall:${NC}     Active (${fw_rules} rules)"
    else
        echo -e "  ${RED}Firewall:${NC}     INACTIVE"
    fi
    
    # ICMP
    local icmp
    icmp=$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null || echo "0")
    if [[ "$icmp" == "1" ]]; then
        echo -e "  ${GREEN}ICMP (Ping):${NC}  Disabled (STEALTH)"
    else
        echo -e "  ${RED}ICMP (Ping):${NC}  Enabled (VISIBLE)"
    fi
    
    # IPv6
    local ipv6
    ipv6=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
    if [[ "$ipv6" == "1" ]]; then
        echo -e "  ${GREEN}IPv6:${NC}         Disabled"
    else
        echo -e "  ${YELLOW}IPv6:${NC}         Enabled"
    fi
    
    # Tor
    if pgrep -x tor &>/dev/null; then
        echo -e "  ${GREEN}Tor:${NC}          Running"
    else
        echo -e "  ${YELLOW}Tor:${NC}          Not running"
    fi
    
    # VPN
    if ip link show 2>/dev/null | grep -qE "tun0|wg0|ppp0"; then
        echo -e "  ${GREEN}VPN:${NC}          Connected"
    else
        echo -e "  ${YELLOW}VPN:${NC}          Not connected"
    fi
    
    # History
    local hist_size="${HISTSIZE:-999}"
    if [[ "$hist_size" == "0" ]]; then
        echo -e "  ${GREEN}History:${NC}      Disabled"
    else
        echo -e "  ${YELLOW}History:${NC}      Enabled (HISTSIZE=${hist_size})"
    fi
    
    # Logs
    local log_size
    log_size=$(du -sh /var/log 2>/dev/null | awk '{print $1}' || true)
    [[ -z "$log_size" ]] && log_size="N/A"
    echo -e "  ${CYAN}Log Size:${NC}     ${log_size}"
    
    # TTL
    local ttl
    ttl=$(sysctl -n net.ipv4.ip_default_ttl 2>/dev/null || echo "64")
    if [[ "$ttl" == "128" ]]; then
        echo -e "  ${GREEN}TTL:${NC}          ${ttl} (custom)"
    else
        echo -e "  ${YELLOW}TTL:${NC}          ${ttl} (default Linux)"
    fi
    
    echo ""
}

# ── Interactive Menu ────────────────────────────────────────────────────────
show_menu() {
    echo -e "${BOLD}   SELECT AN OPERATION:${NC}"
    echo ""
    echo -e "   ${CYAN}[1]${NC}  🔍  Scan System          ${DIM}— Audit current exposure${NC}"
    echo -e "   ${CYAN}[2]${NC}  🛡️   Harden OS             ${DIM}— Disable services, secure kernel${NC}"
    echo -e "   ${CYAN}[3]${NC}  🌐  Network Hardening     ${DIM}— Firewall, DNS, broadcast controls${NC}"
    echo -e "   ${CYAN}[4]${NC}  🧹  Lab Cleanup Gate      ${DIM}— Disabled unless lab mode is explicit${NC}"
    echo -e "   ${RED}[5]${NC}  🛡️   ${RED}FULL HARDEN${NC}          ${DIM}— Scan, harden, network, verify${NC}"
    echo ""
    echo -e "   ${YELLOW}[6]${NC}  ↩️   Revert Changes       ${DIM}— Restore original settings${NC}"
    echo -e "   ${CYAN}[7]${NC}  📊  Quick Status          ${DIM}— Check current stealth level${NC}"
    echo ""
    echo -e "   ${DIM}[0]${NC}  Exit"
    echo ""
    echo -ne "   ${BOLD}Choice [0-7]: ${NC}"
}

interactive_menu() {
    while true; do
        show_banner
        show_disclaimer
        show_menu
        
        read -r choice
        echo ""
        
        case "$choice" in
            1) run_scan ;;
            2) run_harden ;;
            3) run_network ;;
            4) run_clean ;;
            5) run_full ;;
            6) run_revert ;;
            7) quick_status ;;
            0|q|Q|exit)
                echo -e "${GREEN}${BOLD}   Goodbye.${NC}"
                echo ""
                exit 0
                ;;
            *)
                echo -e "${RED}   Invalid choice. Try again.${NC}"
                ;;
        esac
        
        echo ""
        echo -ne "${DIM}   Press Enter to return to menu...${NC}"
        read -r
    done
}

# ── Usage ───────────────────────────────────────────────────────────────────
show_usage() {
    echo -e "${BOLD}Usage:${NC}"
    echo "  ./stealth_master.sh [OPTION] [--profile NAME] [--dry-run]"
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo "  (none)       Interactive menu"
    echo "  --scan       Scan system for exposure points"
    echo "  --clean      Lab-only destructive cleanup gate"
    echo "  --network    Apply selected network hardening"
    echo "  --harden     Harden the operating system"
    echo "  --full       Scan, harden, network harden, verify"
    echo "  --revert     Revert managed changes"
    echo "  --status     Quick stealth status check"
    echo "  --profile    Profile: audit-only, workstation-hardening, reversible-network, kali-lab"
    echo "  --dry-run    Print the plan without mutating the system"
    echo "  --yes        Skip confirmations for non-destructive managed actions"
    echo "  --json       Write scan JSON summary"
    echo "  --lab-mode   Required for lab-only cleanup"
    echo "  --version    Show version and brand metadata"
    echo "  --help       Show this help message"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  ./stealth_master.sh --scan --json"
    echo "  sudo ./stealth_master.sh --harden --dry-run"
    echo "  sudo ./stealth_master.sh --full --profile workstation-hardening"
    echo "  sudo ./stealth_master.sh --revert"
    echo ""
}

show_version() {
    echo "$(brand_line)"
    echo "Version: ${VERSION}"
    echo "Tagline: ${TAGLINE}"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --scan|-s) ACTION="scan" ;;
            --clean|-c) ACTION="clean" ;;
            --network|-n) ACTION="network" ;;
            --harden|-H) ACTION="harden" ;;
            --full|-f) ACTION="full" ;;
            --revert|-r) ACTION="revert" ;;
            --status|-S) ACTION="status" ;;
            --help|-h) ACTION="help" ;;
            --version|-v) ACTION="version" ;;
            --dry-run)
                DRY_RUN=true
                MODULE_FLAGS+=("--dry-run")
                ;;
            --yes|--force)
                YES=true
                MODULE_FLAGS+=("--yes")
                ;;
            --profile)
                shift
                if [[ -z "${1:-}" ]]; then
                    echo "--profile requires a value" >&2
                    exit 2
                fi
                PROFILE="$1"
                MODULE_FLAGS+=("--profile" "$PROFILE")
                ;;
            --json)
                SCAN_JSON=true
                ;;
            --lab-mode)
                LAB_MODE=true
                MODULE_FLAGS+=("--lab-mode")
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}" >&2
                ACTION="help"
                return 1
                ;;
        esac
        shift
    done
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@" || true
    MODULE_NAME="master"
    load_runtime_config
    
    # Ensure backup directory exists
    mkdir -p "$BACKUP_DIR"
    
    case "$ACTION" in
        scan)
            show_banner
            run_scan
            ;;
        clean)
            show_banner
            run_clean
            ;;
        network)
            show_banner
            run_network
            ;;
        harden)
            show_banner
            run_harden
            ;;
        full)
            show_banner
            show_disclaimer
            run_full
            ;;
        revert)
            show_banner
            run_revert
            ;;
        status)
            show_banner
            quick_status
            ;;
        help)
            show_banner
            show_usage
            ;;
        version)
            show_version
            ;;
        menu)
            interactive_menu
            ;;
        *)
            show_banner
            echo -e "${RED}Unknown option: $1${NC}"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
