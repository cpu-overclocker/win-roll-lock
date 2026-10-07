<div align="center">

# 🔐 win-roll-lock

**A Windows local password that rotates every day.**
*No server, no AD, no hardware.*

<sub>Format auto-detected from your locale — or picked manually at install</sub>

![Platform](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6?logo=windows&logoColor=white)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)
![Status](https://img.shields.io/badge/status-beta-orange)

</div>

---

## ✨ What it does

Your Windows password **changes every day**, automatically. No server, no AD, no hardware — just a scheduled task.

| | |
|---|---|
| 🔄 | Password rotates daily |
| 🌐 | Pulls the time from the network (NTP / HTTP) |
| 🛡️ | Never trusts a doubtful BIOS clock |
| 🔑 | MasterCode as an emergency fallback |
| 🔐 | Encrypted state (machine DPAPI) |
| 📶 | Works offline — network is used to *verify*, not to *compute* |

**The format is auto-detected from your country.** It's always **day + month** or **month + day**, in that order, using two digits each:

| Your region | Format used | Example on October 4th |
|---|---|---|
| Most countries (FR, UK, DE, …) | `ddMM` (day + month) | `0410` |
| United States | `MMdd` (month + day) | `1004` |

No configuration needed — the script picks the right one for you on install.

---

## 📁 Repository layout

```
win-roll-lock/
├── README.md
├── Setup/
│   ├── Install.ps1        ← double-click this to install
│   └── Uninstall.ps1      ← double-click this to uninstall
└── src/
    ├── Common.ps1
    ├── Security-Policy.ps1
    ├── Time-Sync.ps1
    └── Update-RollingPass.ps1   ← runs from the scheduled task
```

The `Setup\` scripts auto-locate the `src\` folder, so you can also move them next to `src\` if you prefer a flat layout.

---

## 🚀 Install

> **Just double-click `Setup\Install.ps1`** — nothing else to do.

The script will:

1. Ask for admin rights (UAC popup)
2. Show a short explanation of the **MasterCode** and ask you to pick one
3. Let you **pick a local account** from a menu (or create a new one)
4. Verify everything, show the **target password for today**, and ask for confirmation
5. Set up the scheduled task and apply the password

> ⚠️ **Note down the MasterCode** and the **recovery account password** somewhere offline — they are your way back in if anything goes wrong.

> 💡 **Test with `Win + L`** right after install, **before** any reboot.

---

## ⚙️ Requirements

- Windows 10 / 11 · Server 2019+
- A **local** Windows account (Microsoft accounts are **not** supported)
- An active second local administrator with a fixed password
- BitLocker: save the recovery key beforehand

---

## 🗑️ Uninstall

> **Just double-click `Setup\Uninstall.ps1`** — nothing else to do.

The script will:

1. Ask for confirmation
2. Remove the scheduled task
3. Restore the original security policy (from the backup made at install)
4. Offer to delete the accounts it created
5. Ask if you want to set a fixed password (if the account still exists)
6. Clean up its files

Use `-KeepFiles` if you want to preserve `C:\ProgramData\win-roll-lock\` for inspection.

---

## 🧠 What is the MasterCode?

A **fixed fallback password** used **only** when the system clock is broken **and** the machine is offline.

| Situation | Password used |
|---|---|
| Normal day | Day + month, or month + day (auto-detected from your country) — ex: `0410` |
| Clock corrupted + offline | **MasterCode** — ex: `1234` |

The MasterCode is **never** valid when the clock is fine. It's a safety net, not a backdoor.

---

## 🔁 Reliability — when does the password actually refresh?

The scheduled task fires on **9 different triggers**, so the daily code is always up to date when you need it:

| Trigger | What it catches |
|---|---|
| `BootTrigger` | Cold boot |
| `ResumeTrigger` | Wake from sleep / hibernation |
| `SessionStateChangeTrigger` | Unlock (`Win+L`) |
| `LogonTrigger` | Any user logon |
| `CalendarTrigger` + `Repetition` (every 15 min) | Baseline — guarantees a refresh at most 15 min after midnight |
| `EventTrigger` — Power-Troubleshooter / EventID 1 | Modern Standby exit |
| `EventTrigger` — Kernel-Power / EventID 107 | Legacy sleep resume |
| `EventTrigger` — NetworkProfile / EventID 10000 | Network profile change |
| `EventTrigger` — WLAN-AutoConfig / EventID 8001 | Wi-Fi reconnection |

### Offline behavior

No network? The password still rotates — it's computed from **the local system clock**, not from the network. NTP / HTTP is only used to *validate* that the clock hasn't been tampered with or reset.

| Situation | Mode | Password used |
|---|---|---|
| Online, clock OK | `SYNC` | Day/month from network-corrected time |
| Offline, clock OK | `OFFLINE_OK` | Day/month from local time ✅ |
| Network check skipped (cache < 30 min) | `CACHED` | Day/month from local time ✅ |
| Offline **and** clock rolled back | `FALLBACK` | **MasterCode** |

A network cache (`last_sync.txt`) limits NTP queries to once every 30 minutes, so the 15-minute repetition doesn't hammer public time servers.

---

## 🗂️ What gets created

Everything lives in `C:\ProgramData\win-roll-lock\` (admin-only):

| File | Purpose |
|---|---|
| `config.json` | Settings (account, format, MasterCode, NTP servers) |
| `state.dat` | Encrypted state (machine DPAPI) — last applied password |
| `last_known_time.txt` | Last known-valid UTC instant (guards against clock rollback) |
| `last_sync.txt` | Timestamp of the last successful network sync (NTP cache) |
| `created_accounts.json` | Accounts created by the installer (offered for removal at uninstall) |
| `policy_original.json` | Backup of the local security policy, restored at uninstall |
| `log.txt` | Rolling log (auto-rotated at 512 KB) |
| `src\` | Scripts run by the scheduled task |

Plus a **scheduled task** named `win-roll-lock`, running under `SYSTEM`.

---

## ⚠️ Limitations

- **Local account only** (no Microsoft / Azure AD)
- **Windows Hello** stays separate — use the **Password** option at the logon screen
- A BIOS clock running **ahead** without network can't be detected
- Password complexity and minimum length are disabled **machine-wide** while installed (required for `ddMM`-style passwords)
- HTTP time fallback temporarily bypasses TLS certificate validation (documented in `Time-Sync.ps1`)
- Doesn't protect against a malicious admin

---

<div align="center">

### ❗ Warning

This tool **changes your Windows logon password**.

If you lose both the **MasterCode** and the **recovery account**, you may be **locked out**.

🧪 Test in a VM first · 💾 Save your BitLocker key · 🔍 Verify with `Win+L`

</div>