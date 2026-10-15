# Stealth Kit by V7LTHRONYX

**Authorized Linux Security Audit & Hardening Toolkit**  
**Version:** 1.1.0  
**Author:** Aiden Azad  
**Brand:** V7LTHRONYX  
**Target:** Kali/Debian-based Linux systems  
**Default posture:** audit-first, defensive, reversible where possible

---

## فارسی

### معرفی

Stealth Kit یک ابزار خط فرمانی برای بررسی امنیتی، گزارش‌گیری و سخت‌سازی دفاعی سیستم‌های لینوکسی مبتنی بر Debian/Kali است. این پروژه با برند **V7LTHRONYX** و توسط **Aiden Azad** آماده شده و هدف آن استفاده در محیط‌های مجاز، سیستم‌های شخصی، لَب امنیتی، یا تست‌های دفاعی است.

این ابزار برای مخفی‌کاری مخرب، پاک‌سازی ردپا در سیستم‌های غیرمجاز، یا دور زدن نظارت طراحی نشده است. مسیر پیش‌فرض برنامه امن و دفاعی است: اول وضعیت سیستم را اسکن می‌کند، سپس در صورت انتخاب کاربر تنظیمات hardening را با profile مشخص اعمال می‌کند، و برای عملیات حساس از `--dry-run`، profile، تأیید کاربر و gate ایمنی استفاده می‌کند.

### برنامه چه کاری انجام می‌دهد؟

- وضعیت امنیتی سیستم را scan می‌کند.
- پورت‌های باز، سرویس‌ها، firewall، تنظیمات kernel، swap، cron، SSH و چند سطح hardening را بررسی می‌کند.
- گزارش‌های متنی، Markdown و JSON تولید می‌کند.
- سخت‌سازی سیستم‌عامل را بر اساس profile انجام می‌دهد.
- تنظیمات شبکه را به شکل کنترل‌شده و قابل بازگشت اعمال می‌کند.
- تغییرات مدیریت‌شده را در state manifest ثبت می‌کند.
- قبل از عملیات حساس امکان پیش‌نمایش با `--dry-run` می‌دهد.
- cleanup مخرب را در حالت عادی اجرا نمی‌کند و فقط با profile لَب و تأیید صریح فعال می‌شود.

### ساختار پروژه

```text
stealth-kit/
├── stealth_master.sh              # کنترلر اصلی CLI
├── lib/common.sh                  # توابع مشترک، banner، config، state، safety helpers
├── modules/
│   ├── scan_system.sh             # scan و report امنیتی
│   ├── harden_os.sh               # hardening سیستم‌عامل
│   ├── stealth_network.sh         # hardening شبکه و کنترل‌های قابل بازگشت
│   └── clean_traces.sh            # cleanup gate مخصوص لَب
├── configs/
│   ├── stealthkit.conf            # تنظیمات مرکزی و metadata برند
│   ├── sysctl_stealth.conf        # baseline دفاعی sysctl
│   ├── iptables_stealth.rules     # نمونه rules دفاعی
│   └── resolv_stealth.conf        # نمونه DNS config
├── profiles/
│   ├── audit-only.conf            # فقط scan و گزارش
│   ├── workstation-hardening.conf # hardening محافظه‌کارانه workstation
│   ├── reversible-network.conf    # hardening شبکه با تمرکز روی برگشت‌پذیری
│   └── kali-lab.conf              # profile مخصوص لَب کنترل‌شده
├── tests/run_static_checks.sh     # تست‌های غیرمخرب پروژه
└── backups/                       # گزارش‌ها، backupها و state manifests
```

### شروع سریع

```bash
chmod 755 stealth_master.sh modules/*.sh tests/*.sh

./stealth_master.sh --help
./stealth_master.sh --version
./stealth_master.sh --scan --json
```

برای پیش‌نمایش بدون تغییر سیستم:

```bash
sudo ./stealth_master.sh --harden --dry-run --profile workstation-hardening
sudo ./stealth_master.sh --network --dry-run --profile reversible-network
sudo ./stealth_master.sh --full --dry-run --profile audit-only --json
```

برای اجرای واقعی hardening فقط وقتی آماده هستید:

```bash
sudo ./stealth_master.sh --harden --profile workstation-hardening
sudo ./stealth_master.sh --network --profile reversible-network
sudo ./stealth_master.sh --full --profile workstation-hardening
```

### دستورهای اصلی

```bash
./stealth_master.sh --help
./stealth_master.sh --version
./stealth_master.sh --scan --json
./stealth_master.sh --status

sudo ./stealth_master.sh --harden --profile workstation-hardening
sudo ./stealth_master.sh --network --profile reversible-network
sudo ./stealth_master.sh --full --profile workstation-hardening
sudo ./stealth_master.sh --revert
```

پرچم‌های مهم:

```text
--dry-run       نمایش برنامه اجرا بدون تغییر دادن سیستم
--profile NAME  انتخاب profile از پوشه profiles/
--yes           رد کردن تأییدهای معمول برای عملیات مدیریت‌شده و غیرمخرب
--json          تولید خروجی JSON برای scan
--lab-mode      فعال‌سازی مسیرهای مخصوص لَب، فقط برای محیط کنترل‌شده
```

### Profileها

`audit-only`  
حالت read-only برای scan، بررسی وضعیت، report و ارزیابی اولیه. مناسب وقتی که نمی‌خواهید هیچ تغییری روی سیستم اعمال شود.

`workstation-hardening`  
profile محافظه‌کارانه برای سیستم کاری. روی hardening دفاعی مثل sysctl، SSH، core dumps، umask، بعضی سرویس‌ها، USB auto-mount و module controls تمرکز دارد.

`reversible-network`  
profile شبکه با تمرکز روی تغییرات قابل بازگشت. برای firewall، کاهش broadcast/noisy traffic و کنترل‌های شبکه استفاده می‌شود. رفتارهای حساس مثل MAC spoofing، تغییر hostname، نصب Tor یا rewrite اجباری DNS در پیش‌فرض فعال نیستند.

`kali-lab`  
profile مخصوص لَب disposable و کنترل‌شده. حتی در این profile هم cleanup مخرب بدون `--lab-mode` و تأیید صریح اجرا نمی‌شود.

### مدل ایمنی

مسیر عادی برنامه log، history، browser data یا cacheها را پاک نمی‌کند. ماژول cleanup فقط یک gate مخصوص لَب است و بدون همه شرط‌های زیر اجرا نمی‌شود:

```bash
sudo ./stealth_master.sh --clean \
  --profile kali-lab \
  --lab-mode \
  --i-understand-destruction
```

قبل از هر اجرای حساس، اول dry-run بگیرید:

```bash
./stealth_master.sh --clean --profile kali-lab --dry-run
```

### گزارش‌ها و خروجی‌ها

Scanها در پوشه `backups/` ذخیره می‌شوند:

- `scan_report_*.txt`
- `scan_report_*.md`
- `scan_report_*.json` وقتی `--json` فعال باشد

تغییرات مدیریت‌شده در state manifest ثبت می‌شوند:

```text
backups/state/state_*.jsonl
```

### تست و اعتبارسنجی

تست‌های غیرمخرب پروژه:

```bash
tests/run_static_checks.sh
```

این تست‌ها بررسی می‌کنند:

- syntax همه scriptهای Bash
- نبودن الگوی مشکل‌ساز `((counter++))` در حالت `set -e`
- اجرای dry-run برای hardening، network و cleanup gate
- وجود branding در help/version/docs/config
- رد شدن cleanup بدون تأیید صریح destruction
- نبودن فایل world-writable در پروژه

### وضعیت تست فعلی

آخرین بررسی انجام‌شده:

```text
tests/run_static_checks.sh                 passed
./stealth_master.sh --scan --json          passed
./stealth_master.sh --status               passed
./stealth_master.sh --full --dry-run       passed
```

نمونه report واقعی scan:

```text
backups/scan_report_20261015_075433.json
```

نکته: اجرای واقعی `--harden` و `--network` تنظیمات سیستم را تغییر می‌دهد؛ برای همین ابتدا با `--dry-run` تست و review کنید.

---

## English

### Overview

Stealth Kit is a command-line toolkit for authorized Linux security auditing, reporting, and defensive hardening on Debian/Kali-based systems. It is branded as **V7LTHRONYX** and authored by **Aiden Azad**.

The toolkit is intended for systems you own, administer, or are explicitly authorized to assess. It is not intended for unauthorized stealth, malicious trace removal, or bypassing monitoring on third-party systems. The default workflow is audit-first and defensive: scan the host, review the report, preview risky actions with `--dry-run`, then apply profile-based hardening only when you intentionally choose to do so.

### What does it do?

- Audits host exposure and security posture.
- Checks open ports, services, firewall visibility, kernel settings, swap, cron, SSH, and hardening controls.
- Generates text, Markdown, and JSON reports.
- Applies profile-based operating system hardening.
- Applies controlled and reversible network hardening.
- Records managed changes in state manifests.
- Supports `--dry-run` previews for sensitive operations.
- Keeps destructive cleanup disabled unless a disposable lab profile and explicit acknowledgement are used.

### Project layout

```text
stealth-kit/
├── stealth_master.sh              # Main CLI controller
├── lib/common.sh                  # Shared banner, config, state, safety helpers
├── modules/
│   ├── scan_system.sh             # Security scan and reporting
│   ├── harden_os.sh               # OS hardening
│   ├── stealth_network.sh         # Network hardening and reversible controls
│   └── clean_traces.sh            # Lab-only cleanup gate
├── configs/
│   ├── stealthkit.conf            # Central settings and brand metadata
│   ├── sysctl_stealth.conf        # Defensive sysctl baseline
│   ├── iptables_stealth.rules     # Defensive firewall example rules
│   └── resolv_stealth.conf        # DNS example config
├── profiles/
│   ├── audit-only.conf            # Read-only audit/reporting
│   ├── workstation-hardening.conf # Conservative workstation hardening
│   ├── reversible-network.conf    # Reversible network controls
│   └── kali-lab.conf              # Controlled disposable lab profile
├── tests/run_static_checks.sh     # Non-destructive project checks
└── backups/                       # Reports, backups, and state manifests
```

### Quick start

```bash
chmod 755 stealth_master.sh modules/*.sh tests/*.sh

./stealth_master.sh --help
./stealth_master.sh --version
./stealth_master.sh --scan --json
```

Preview actions without changing the system:

```bash
sudo ./stealth_master.sh --harden --dry-run --profile workstation-hardening
sudo ./stealth_master.sh --network --dry-run --profile reversible-network
sudo ./stealth_master.sh --full --dry-run --profile audit-only --json
```

Apply real hardening only after review:

```bash
sudo ./stealth_master.sh --harden --profile workstation-hardening
sudo ./stealth_master.sh --network --profile reversible-network
sudo ./stealth_master.sh --full --profile workstation-hardening
```

### Main commands

```bash
./stealth_master.sh --help
./stealth_master.sh --version
./stealth_master.sh --scan --json
./stealth_master.sh --status

sudo ./stealth_master.sh --harden --profile workstation-hardening
sudo ./stealth_master.sh --network --profile reversible-network
sudo ./stealth_master.sh --full --profile workstation-hardening
sudo ./stealth_master.sh --revert
```

Common flags:

```text
--dry-run       Print the selected plan without changing the system
--profile NAME  Select a profile from profiles/
--yes           Skip normal confirmations for managed non-destructive actions
--json          Write a JSON scan summary
--lab-mode      Enable lab-only paths for controlled environments
```

### Profiles

`audit-only`  
Read-only mode for scanning, reporting, and initial assessment. Use it when no system changes should be made.

`workstation-hardening`  
Conservative workstation hardening. It focuses on defensive sysctl settings, SSH hardening, core dump controls, umask, selected service controls, USB auto-mount behavior, and kernel module controls.

`reversible-network`  
Network-focused profile with reversible controls. It is used for firewall, broadcast/noisy traffic reduction, and network checks. Sensitive controls such as MAC spoofing, hostname randomization, Tor installation, or forced DNS rewrites are not enabled by default.

`kali-lab`  
Disposable lab profile for controlled testing. Even with this profile, destructive cleanup still requires `--lab-mode` and explicit acknowledgement.

### Safety model

The normal workflow does not wipe logs, shell history, browser data, or caches. The cleanup module is a guarded lab-only gate and refuses to run unless every condition below is present:

```bash
sudo ./stealth_master.sh --clean \
  --profile kali-lab \
  --lab-mode \
  --i-understand-destruction
```

Preview cleanup first:

```bash
./stealth_master.sh --clean --profile kali-lab --dry-run
```

### Reports and state

Scans write generated reports under `backups/`:

- `scan_report_*.txt`
- `scan_report_*.md`
- `scan_report_*.json` when `--json` is used

Managed apply/revert actions append JSONL state records under:

```text
backups/state/state_*.jsonl
```

### Validation

Run non-destructive checks:

```bash
tests/run_static_checks.sh
```

The test script verifies:

- Bash syntax for all scripts
- no old `((counter++))` pattern that breaks under `set -e`
- dry-run execution for hardening, network, and cleanup gate
- branding in help/version/docs/config
- cleanup refusal without explicit destruction acknowledgement
- no world-writable files in the project

### Current validation status

Last verified checks:

```text
tests/run_static_checks.sh                 passed
./stealth_master.sh --scan --json          passed
./stealth_master.sh --status               passed
./stealth_master.sh --full --dry-run       passed
```

Example real scan report:

```text
backups/scan_report_20261015_075433.json
```

Note: real `--harden` and `--network` runs change system settings. Review `--dry-run` output first and keep generated reports/backups.

## License

Copyright (c) 2026 Aiden Azad / V7LTHRONYX. See `LICENSE`.
