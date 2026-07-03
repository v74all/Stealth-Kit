#!/usr/bin/env bash
# ============================================================================
# stealth_network.sh - Network Hardening
# V7LTHRONYX / Aiden Azad
# ============================================================================
# Configures selected network controls by profile:
#   - Firewall hardening and broadcast suppression
#   - Optional IPv6/ICMP controls
#   - Optional DNS resolver hardening
#   - Optional lab-only MAC/hostname/Tor changes
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
    echo -e "${MAGENTA}${BOLD}"
    show_brand_banner ""
    echo "  Module: Network Hardening"
    echo -e "${NC}"
}

section() {
    echo ""
    echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${MAGENTA}${BOLD}  ▶ $1${NC}"
    echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
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
                echo "[!] Unknown network option: $1" >&2
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
    echo "Selected network controls:"
    echo "  firewall=${ENABLE_FIREWALL}"
    echo "  broadcast_suppression=${ENABLE_BROADCAST_SUPPRESSION}"
    echo "  ipv6_disable=${ENABLE_IPV6_DISABLE}"
    echo "  icmp_disable=${ENABLE_ICMP_DISABLE}"
    echo "  dns_privacy=${ENABLE_DNS_PRIVACY}"
    echo "  tcp_fingerprint_reduction=${ENABLE_TCP_FINGERPRINT_REDUCTION}"
    echo "  mac_spoof=${ENABLE_MAC_SPOOF}"
    echo "  hostname_randomization=${ENABLE_HOSTNAME_RANDOMIZATION}"
    echo "  tor_proxychains=${ENABLE_TOR_PROXYCHAINS}"
    echo "  package_install=${ALLOW_PACKAGE_INSTALL}"
}

print_revert_plan() {
    banner
    echo "Dry run: managed network revert plan"
    echo "  restore latest iptables backup if present"
    echo "  restore latest hostname and DNS backups if present"
    echo "  restore recorded MAC addresses if present"
    echo "  remove NetworkManager broadcast-suppression drop-in"
    echo "  remove macspoof systemd unit"
    echo "  reset managed runtime sysctl values where applicable"
}

# Generate a random hostname that looks like a generic Windows/Linux device
random_hostname() {
    local prefixes=("DESKTOP" "LAPTOP" "PC" "WORKSTATION" "WIN" "USER" "NODE" "HOST")
    local prefix="${prefixes[$((RANDOM % ${#prefixes[@]}))]}"
    local suffix
    suffix=$(head -c 4 /dev/urandom | xxd -p | tr '[:lower:]' '[:upper:]')
    echo "${prefix}-${suffix}"
}

# ── Network Stealth Functions ──────────────────────────────────────────────

setup_mac_spoofing() {
    section "MAC ADDRESS SPOOFING"
    
    # Install macchanger if not present
    if ! command -v macchanger &>/dev/null; then
        if [[ "$ALLOW_PACKAGE_INSTALL" == "true" ]]; then
            info "Installing macchanger..."
            apt-get install -y macchanger -qq 2>/dev/null || {
                fail "Could not install macchanger"
                return
            }
        else
            warn "macchanger not found; skipping MAC spoofing. Enable ALLOW_PACKAGE_INSTALL only in a controlled lab."
            return
        fi
    fi
    
    # Get all non-loopback interfaces
    local interfaces
    interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" | grep -v "^$")
    
    for iface in $interfaces; do
        info "Spoofing MAC for: ${iface}"
        
        # Save current MAC
        local current_mac
        current_mac=$(ip link show "$iface" | grep -oP 'link/ether \K[\da-f:]+' || echo "N/A")
        echo "$iface=$current_mac" >> "${BACKUP_DIR}/mac_addresses.backup"
        
        # Bring interface down, change MAC, bring back up
        ip link set "$iface" down 2>/dev/null || true
        macchanger -r "$iface" 2>/dev/null && ok "MAC spoofed for ${iface}" || warn "Failed to spoof MAC for ${iface}"
        ip link set "$iface" up 2>/dev/null || true
        
        local new_mac
        new_mac=$(ip link show "$iface" | grep -oP 'link/ether \K[\da-f:]+' || echo "N/A")
        info "  Old: ${current_mac} → New: ${new_mac}"
    done
    
    if [[ "$ENABLE_PERSISTENT_MAC_SPOOF" != "true" ]]; then
        info "Persistent MAC spoofing disabled by profile."
        return
    fi

    # Create systemd service for persistent MAC spoofing on boot
    cat > /etc/systemd/system/macspoof@.service << 'UNIT'
[Unit]
Description=MAC Address Spoofing for %i
Wants=network-pre.target
Before=network-pre.target
BindsTo=sys-subsystem-net-devices-%i.device
After=sys-subsystem-net-devices-%i.device

[Service]
Type=oneshot
ExecStart=/usr/bin/macchanger -r %i
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    
    # Enable for all interfaces
    for iface in $interfaces; do
        systemctl enable "macspoof@${iface}.service" 2>/dev/null || true
    done
    record_state "write" "/etc/systemd/system/macspoof@.service" "persistent mac spoofing"
    ok "Created persistent MAC spoofing service"
}

setup_hostname_randomization() {
    section "HOSTNAME RANDOMIZATION"
    
    local current_hostname
    current_hostname=$(hostname)
    backup_file /etc/hostname
    backup_file /etc/hosts
    
    local new_hostname
    new_hostname=$(random_hostname)
    
    info "Old hostname: ${current_hostname}"
    info "New hostname: ${new_hostname}"
    
    # Change hostname
    hostnamectl set-hostname "$new_hostname" 2>/dev/null || {
        echo "$new_hostname" > /etc/hostname
        hostname "$new_hostname"
    }
    
    # Update /etc/hosts
    sed -i "s/${current_hostname}/${new_hostname}/g" /etc/hosts 2>/dev/null || true
    
    # Also change transient hostname
    hostnamectl set-hostname "$new_hostname" --transient 2>/dev/null || true
    
    ok "Hostname changed to: ${new_hostname}"
}

setup_firewall() {
    section "FIREWALL HARDENING (iptables)"
    
    # Backup current rules
    iptables-save > "${BACKUP_DIR}/iptables.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    
    # Load stealth rules from config
    local rules_file="${CONFIGS_DIR}/iptables_stealth.rules"
    if [[ -f "$rules_file" ]]; then
        iptables-restore < "$rules_file" 2>/dev/null && ok "Loaded iptables stealth rules from config" || {
            warn "Failed to load rules file, applying inline rules..."
        }
    fi
    
    # Apply rules inline as fallback / primary
    # Flush existing rules
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t nat -X
    iptables -t mangle -F
    iptables -t mangle -X
    
    # Default policies: DROP all incoming, ACCEPT outgoing
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    
    # Allow loopback
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    
    # Allow established connections
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    
    # Drop invalid packets
    iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
    
    # Drop all ICMP (no ping response)
    iptables -A INPUT -p icmp -j DROP
    iptables -A OUTPUT -p icmp --icmp-type echo-reply -j DROP
    
    # Drop NetBIOS
    iptables -A INPUT -p tcp --dport 137:139 -j DROP
    iptables -A INPUT -p udp --dport 137:139 -j DROP
    iptables -A INPUT -p tcp --dport 445 -j DROP
    iptables -A INPUT -p udp --dport 445 -j DROP
    
    # Drop mDNS / SSDP / LLMNR
    iptables -A INPUT -p udp --dport 5353 -j DROP   # mDNS
    iptables -A INPUT -p udp --dport 1900 -j DROP   # SSDP
    iptables -A INPUT -p udp --dport 5355 -j DROP   # LLMNR
    
    # Drop broadcast
    iptables -A INPUT -m addrtype --dst-type BROADCAST -j DROP
    iptables -A INPUT -m addrtype --dst-type MULTICAST -j DROP
    
    # Log dropped packets (limited rate to avoid log flooding)
    iptables -A INPUT -m limit --limit 3/min -j LOG --log-prefix "STEALTH-DROP: " --log-level 4
    
    # Final DROP
    iptables -A INPUT -j DROP
    
    # Save rules persistently
    if command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    
    ok "Firewall hardened: DROP all incoming, stealth mode enabled"
}

disable_ipv6() {
    section "IPv6 DISABLE"
    
    backup_file /etc/sysctl.conf
    
    # Kernel parameters
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 2>/dev/null || true
    sysctl -w net.ipv6.conf.lo.disable_ipv6=1 2>/dev/null || true
    
    # ip6tables: drop everything
    if command -v ip6tables &>/dev/null; then
        ip6tables -P INPUT DROP 2>/dev/null || true
        ip6tables -P OUTPUT DROP 2>/dev/null || true
        ip6tables -P FORWARD DROP 2>/dev/null || true
        
        if command -v ip6tables-save &>/dev/null; then
            mkdir -p /etc/iptables
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
        fi
    fi
    
    ok "IPv6 completely disabled"
}

disable_icmp() {
    section "ICMP RESPONSE DISABLE"
    
    sysctl -w net.ipv4.icmp_echo_ignore_all=1 2>/dev/null || true
    sysctl -w net.ipv4.icmp_echo_ignore_broadcasts=1 2>/dev/null || true
    sysctl -w net.ipv4.icmp_ignore_bogus_error_responses=1 2>/dev/null || true
    
    ok "ICMP ping response disabled"
}

setup_dns_privacy() {
    section "DNS PRIVACY"
    
    backup_file /etc/resolv.conf
    
    # Option 1: Use dnscrypt-proxy if available
    if command -v dnscrypt-proxy &>/dev/null; then
        info "dnscrypt-proxy found, configuring..."
        systemctl enable dnscrypt-proxy 2>/dev/null || true
        systemctl start dnscrypt-proxy 2>/dev/null || true
        
        # Point resolv.conf to local
        chattr -i /etc/resolv.conf 2>/dev/null || true
        cat > /etc/resolv.conf << 'DNS'
# Stealth DNS configuration — dnscrypt-proxy
nameserver 127.0.0.1
options edns0
DNS
        if [[ "$ALLOW_RESOLV_CONF_IMMUTABLE" == "true" ]]; then
            chattr +i /etc/resolv.conf 2>/dev/null || true
        fi
        ok "DNS via dnscrypt-proxy (encrypted)"
        return
    fi
    
    # Option 2: Use stubby if available
    if command -v stubby &>/dev/null; then
        info "stubby found, configuring..."
        systemctl enable stubby 2>/dev/null || true
        systemctl start stubby 2>/dev/null || true
        
        chattr -i /etc/resolv.conf 2>/dev/null || true
        cat > /etc/resolv.conf << 'DNS'
# Stealth DNS configuration — stubby (DNS-over-TLS)
nameserver 127.0.0.1
options edns0
DNS
        if [[ "$ALLOW_RESOLV_CONF_IMMUTABLE" == "true" ]]; then
            chattr +i /etc/resolv.conf 2>/dev/null || true
        fi
        ok "DNS via stubby (DNS-over-TLS)"
        return
    fi
    
    # Option 3: Fallback to Tor DNS if Tor is available
    if [[ "$ENABLE_TOR_DNS" == "true" ]] && command -v tor &>/dev/null; then
        info "Falling back to Tor for DNS..."
        chattr -i /etc/resolv.conf 2>/dev/null || true
        cat > /etc/resolv.conf << 'DNS'
# Stealth DNS configuration — Tor
nameserver 127.0.0.1
DNS
        if [[ "$ALLOW_RESOLV_CONF_IMMUTABLE" == "true" ]]; then
            chattr +i /etc/resolv.conf 2>/dev/null || true
        fi
        ok "DNS routed through Tor"
        return
    fi
    
    # Option 4: Use privacy-focused resolvers as last resort
    warn "No encrypted DNS tool found. Installing dnscrypt-proxy is recommended."
    warn "Falling back to privacy-focused public resolvers."
    
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf << 'DNS'
# Privacy-focused DNS (not encrypted — install dnscrypt-proxy for encryption)
# Quad9 (malware blocking + privacy)
nameserver 9.9.9.9
nameserver 149.112.112.112
DNS
    if [[ "$ALLOW_RESOLV_CONF_IMMUTABLE" == "true" ]]; then
        chattr +i /etc/resolv.conf 2>/dev/null || true
    fi
    ok "DNS set to Quad9 (privacy-focused)"
}

setup_tcp_obfuscation() {
    section "TCP FINGERPRINT OBFUSCATION"
    
    # Change default TTL to match Windows (128) to confuse OS fingerprinting
    sysctl -w net.ipv4.ip_default_ttl=128 2>/dev/null || true
    ok "Default TTL changed to 128 (mimics Windows)"
    
    # TCP window scaling
    sysctl -w net.ipv4.tcp_window_scaling=1 2>/dev/null || true
    
    # Disable TCP timestamps (used for OS fingerprinting)
    sysctl -w net.ipv4.tcp_timestamps=0 2>/dev/null || true
    ok "TCP timestamps disabled (anti-fingerprinting)"
    
    # Disable TCP SACK (can be used for fingerprinting)
    sysctl -w net.ipv4.tcp_sack=0 2>/dev/null || true
    ok "TCP SACK disabled"
    
    # Randomize source ports
    sysctl -w net.ipv4.ip_local_port_range="32768 60999" 2>/dev/null || true
    ok "Source port range randomized"
    
    # Disable source routing
    sysctl -w net.ipv4.conf.all.accept_source_route=0 2>/dev/null || true
    sysctl -w net.ipv4.conf.default.accept_source_route=0 2>/dev/null || true
    ok "Source routing disabled"
    
    # Disable ICMP redirects
    sysctl -w net.ipv4.conf.all.accept_redirects=0 2>/dev/null || true
    sysctl -w net.ipv4.conf.default.accept_redirects=0 2>/dev/null || true
    sysctl -w net.ipv4.conf.all.send_redirects=0 2>/dev/null || true
    sysctl -w net.ipv4.conf.default.send_redirects=0 2>/dev/null || true
    ok "ICMP redirects disabled"
    
    # Enable reverse path filtering (anti-spoofing)
    sysctl -w net.ipv4.conf.all.rp_filter=1 2>/dev/null || true
    sysctl -w net.ipv4.conf.default.rp_filter=1 2>/dev/null || true
    ok "Reverse path filtering enabled"
    
    # SYN cookies (anti-SYN flood, also reduces fingerprint)
    sysctl -w net.ipv4.tcp_syncookies=1 2>/dev/null || true
    ok "SYN cookies enabled"
}

disable_broadcast_services() {
    section "BROADCAST SERVICE SUPPRESSION"
    
    # Avahi (mDNS / Bonjour)
    if systemctl is-active --quiet avahi-daemon 2>/dev/null; then
        systemctl stop avahi-daemon 2>/dev/null || true
        systemctl disable avahi-daemon 2>/dev/null || true
        ok "Stopped and disabled avahi-daemon (mDNS)"
    else
        info "avahi-daemon already inactive"
    fi
    
    # Disable NetworkManager mDNS
    local nm_conf="/etc/NetworkManager/conf.d/stealth-mdns.conf"
    mkdir -p /etc/NetworkManager/conf.d
    cat > "$nm_conf" << 'NM'
[connection]
mdns=0
llmnr=0
NM
    ok "Disabled mDNS and LLMNR in NetworkManager"
    
    # Restart NetworkManager to apply
    record_state "write" "$nm_conf" "disable mdns llmnr"
    systemctl restart NetworkManager 2>/dev/null || true
}

setup_tor_proxychains() {
    section "TOR & PROXYCHAINS SETUP"
    
    # Check and install Tor
    if ! command -v tor &>/dev/null; then
        if [[ "$ALLOW_PACKAGE_INSTALL" == "true" ]]; then
            info "Installing Tor..."
            apt-get install -y tor -qq 2>/dev/null || {
                fail "Could not install Tor"
                return
            }
        else
            warn "Tor not found; skipping Tor/proxychains setup. Enable ALLOW_PACKAGE_INSTALL only in a controlled lab."
            return
        fi
    fi
    
    # Start Tor
    systemctl enable tor 2>/dev/null || true
    systemctl start tor 2>/dev/null || true
    
    if systemctl is-active --quiet tor; then
        ok "Tor is running"
    else
        fail "Tor failed to start"
    fi
    
    # Configure proxychains
    if command -v proxychains4 &>/dev/null || command -v proxychains &>/dev/null; then
        local pc_conf="/etc/proxychains4.conf"
        if [[ ! -f "$pc_conf" ]]; then
            pc_conf="/etc/proxychains.conf"
        fi
        
        if [[ -f "$pc_conf" ]]; then
            backup_file "$pc_conf"
            
            # Ensure dynamic_chain is enabled, strict_chain is disabled
            sed -i 's/^strict_chain/#strict_chain/' "$pc_conf" 2>/dev/null || true
            sed -i 's/^#dynamic_chain/dynamic_chain/' "$pc_conf" 2>/dev/null || true
            
            # Ensure Tor SOCKS proxy is configured
            if ! grep -q "socks5.*127.0.0.1.*9050" "$pc_conf"; then
                echo "" >> "$pc_conf"
                echo "# Tor SOCKS proxy" >> "$pc_conf"
                echo "socks5 127.0.0.1 9050" >> "$pc_conf"
            fi
            
            ok "Proxychains configured with Tor"
            info "Usage: proxychains4 <command> (e.g., proxychains4 nmap ...)"
        fi
    else
        warn "proxychains not found. Install with: apt install proxychains4"
    fi
}

# ── Summary ─────────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${MAGENTA}${BOLD}══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}${BOLD}  NETWORK STEALTH SUMMARY${NC}"
    echo -e "${MAGENTA}${BOLD}══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${GREEN}${BOLD}Applied:  ${APPLIED}${NC}"
    echo -e "  ${RED}${BOLD}Failed:   ${FAILED}${NC}"
    echo ""
    echo -e "  ${CYAN}${BOLD}SELECTED CONTROLS:${NC}"
    echo -e "  ${CYAN}  • Profile: ${PROFILE}${NC}"
    echo -e "  ${CYAN}  • Firewall: ${ENABLE_FIREWALL}${NC}"
    echo -e "  ${CYAN}  • Broadcast suppression: ${ENABLE_BROADCAST_SUPPRESSION}${NC}"
    echo -e "  ${CYAN}  • DNS privacy changes: ${ENABLE_DNS_PRIVACY}${NC}"
    echo -e "  ${CYAN}  • Lab MAC/hostname/Tor controls are profile-gated${NC}"
    echo ""
    echo -e "  ${YELLOW}${BOLD}TIP: Use 'proxychains4 <tool>' to route traffic through Tor${NC}"
    echo ""
}

# ── Revert ──────────────────────────────────────────────────────────────────
revert_network() {
    echo -e "${YELLOW}${BOLD}Reverting network settings...${NC}"
    
    # Restore MAC addresses
    if [[ -f "${BACKUP_DIR}/mac_addresses.backup" ]]; then
        while IFS='=' read -r iface mac; do
            ip link set "$iface" down 2>/dev/null || true
            ip link set "$iface" address "$mac" 2>/dev/null || true
            ip link set "$iface" up 2>/dev/null || true
            info "Restored MAC for ${iface}: ${mac}"
        done < "${BACKUP_DIR}/mac_addresses.backup"
    fi
    
    # Restore iptables
    local latest_ipt_backup
    latest_ipt_backup=$(ls -t "${BACKUP_DIR}"/iptables.backup.* 2>/dev/null | head -1)
    if [[ -n "$latest_ipt_backup" ]]; then
        iptables-restore < "$latest_ipt_backup" 2>/dev/null && ok "Restored iptables rules"
    fi
    
    # Restore hostname
    local hostname_backup
    hostname_backup=$(ls -t "${BACKUP_DIR}"/hostname.backup.* 2>/dev/null | head -1)
    if [[ -n "$hostname_backup" ]]; then
        local old_hostname
        old_hostname=$(cat "$hostname_backup")
        hostnamectl set-hostname "$old_hostname" 2>/dev/null || true
        ok "Restored hostname: ${old_hostname}"
    fi

    # Restore /etc/hosts
    local hosts_backup
    hosts_backup=$(ls -t "${BACKUP_DIR}"/hosts.backup.* 2>/dev/null | head -1)
    if [[ -n "$hosts_backup" ]]; then
        cp "$hosts_backup" /etc/hosts
        ok "Restored hosts file"
    fi
    
    # Restore resolv.conf
    chattr -i /etc/resolv.conf 2>/dev/null || true
    local dns_backup
    dns_backup=$(ls -t "${BACKUP_DIR}"/resolv.conf.backup.* 2>/dev/null | head -1)
    if [[ -n "$dns_backup" ]]; then
        cp "$dns_backup" /etc/resolv.conf
        ok "Restored DNS configuration"
    fi

    # Restore proxychains config if a backup exists.
    local pc_backup pc_target
    pc_backup=$(ls -t "${BACKUP_DIR}"/proxychains4.conf.backup.* "${BACKUP_DIR}"/proxychains.conf.backup.* 2>/dev/null | head -1)
    if [[ -n "$pc_backup" ]]; then
        case "$(basename "$pc_backup")" in
            proxychains4.conf.backup.*) pc_target="/etc/proxychains4.conf" ;;
            *) pc_target="/etc/proxychains.conf" ;;
        esac
        cp "$pc_backup" "$pc_target" 2>/dev/null && ok "Restored proxychains configuration"
    fi
    
    # Re-enable IPv6
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 2>/dev/null || true
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 2>/dev/null || true
    ok "Re-enabled IPv6"
    
    # Restore ICMP
    sysctl -w net.ipv4.icmp_echo_ignore_all=0 2>/dev/null || true
    ok "Re-enabled ICMP ping response"
    
    # Restore TTL
    sysctl -w net.ipv4.ip_default_ttl=64 2>/dev/null || true
    ok "Restored default TTL (64)"
    
    # Re-enable TCP timestamps
    sysctl -w net.ipv4.tcp_timestamps=1 2>/dev/null || true
    ok "Re-enabled TCP timestamps"
    
    echo -e "${GREEN}${BOLD}Network settings reverted.${NC}"
}

remove_network_dropins() {
    rm -f /etc/NetworkManager/conf.d/stealth-mdns.conf 2>/dev/null || true
    rm -f /etc/systemd/system/macspoof@.service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
    ACTION="${ACTION:-apply}"
    parse_args "$@"
    MODULE_NAME="network"
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
        revert_network
        remove_network_dropins
        exit 0
    fi
    
    banner
    
    echo -e "${YELLOW}${BOLD}[!] WARNING: This will modify network settings significantly.${NC}"
    echo -e "${YELLOW}${BOLD}[!] Backups will be saved to: ${BACKUP_DIR}${NC}"
    echo ""
    
    confirm_or_exit "  Continue with selected network changes? (y/N): "
    
    echo ""
    echo -e "${CYAN}Network hardening started at: $(date)${NC}"
    
    [[ "$ENABLE_MAC_SPOOF" == "true" ]] && setup_mac_spoofing || info "Skipping MAC spoofing."
    [[ "$ENABLE_HOSTNAME_RANDOMIZATION" == "true" ]] && setup_hostname_randomization || info "Skipping hostname randomization."
    [[ "$ENABLE_FIREWALL" == "true" ]] && setup_firewall || info "Skipping firewall changes."
    [[ "$ENABLE_IPV6_DISABLE" == "true" ]] && disable_ipv6 || info "Skipping IPv6 disable."
    [[ "$ENABLE_ICMP_DISABLE" == "true" ]] && disable_icmp || info "Skipping ICMP disable."
    [[ "$ENABLE_DNS_PRIVACY" == "true" ]] && setup_dns_privacy || info "Skipping DNS changes."
    [[ "$ENABLE_TCP_FINGERPRINT_REDUCTION" == "true" ]] && setup_tcp_obfuscation || info "Skipping TCP fingerprint changes."
    [[ "$ENABLE_BROADCAST_SUPPRESSION" == "true" ]] && disable_broadcast_services || info "Skipping broadcast suppression."
    [[ "$ENABLE_TOR_PROXYCHAINS" == "true" ]] && setup_tor_proxychains || info "Skipping Tor/proxychains setup."
    
    print_summary
}

main "$@"
