#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

scripts=(
  "stealth_master.sh"
  "lib/common.sh"
  "modules/scan_system.sh"
  "modules/stealth_network.sh"
  "modules/harden_os.sh"
  "modules/clean_traces.sh"
)

echo "[*] bash syntax"
bash -n "${scripts[@]}"

echo "[*] counter increment pattern"
if grep -RIn '((.*++))' stealth_master.sh lib modules configs profiles; then
  echo "[x] Found post-increment arithmetic that can break under set -e"
  exit 1
fi

echo "[*] dry-run commands"
./stealth_master.sh --help >/tmp/stealthkit-help.out
./stealth_master.sh --version >/tmp/stealthkit-version.out
bash modules/harden_os.sh --dry-run --profile workstation-hardening >/tmp/stealthkit-harden-plan.out
bash modules/stealth_network.sh --dry-run --profile reversible-network >/tmp/stealthkit-network-plan.out
bash modules/clean_traces.sh --dry-run --profile kali-lab >/tmp/stealthkit-clean-plan.out

echo "[*] branding"
grep -q "V7LTHRONYX" /tmp/stealthkit-help.out
grep -q "Aiden Azad" /tmp/stealthkit-version.out
grep -q "V7LTHRONYX" README.md
grep -q "Aiden Azad" README.md
grep -q "V7LTHRONYX" LICENSE
grep -q "Aiden Azad" configs/stealthkit.conf

echo "[*] cleanup acknowledgement gate"
if bash modules/clean_traces.sh --profile kali-lab --lab-mode --yes >/tmp/stealthkit-clean-refusal.out 2>&1; then
  echo "[x] Cleanup ran without --i-understand-destruction"
  exit 1
fi

echo "[*] file permissions"
world_writable="$(find . -maxdepth 3 -type f -perm -002 -not -path './.git/*' -print)"
if [[ -n "$world_writable" ]]; then
  echo "[x] World-writable files found:"
  echo "$world_writable"
  exit 1
fi

echo "[+] static checks passed"
