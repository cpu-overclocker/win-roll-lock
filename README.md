<div align="center">

# 🔐 win-roll-lock

**A Windows local password that rotates every day.**
*No server, no AD, no hardware.*

<sub>Default `ddMM` — e.g. `0410` on October 4th</sub>

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

**The format is auto-detected from your country.** It's always **day + month** or **month + day**, in that order, using two digits each:

| Your region | Format used | Example on October 4th |
|---|---|---|
| Most countries (FR, UK, DE, …) | `ddMM` (day + month) | `0410` |
| United States | `MMdd` (month + day) | `1004` |

No configuration needed — the script picks the right one for you on install.

---

## 🚀 Install

> **Just double-click `Install.ps1`** — nothing else to do.

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

> **Just double-click `Uninstall.ps1`** — nothing else to do.

The script will:

1. Ask for confirmation
2. Remove the scheduled task
3. Offer to delete the accounts it created
4. Ask if you want to set a fixed password (if the account still exists)
5. Clean up its files

---

## 🧠 What is the MasterCode?

A **fixed fallback password** used **only** when the system clock is broken **and** the machine is offline.

| Situation | Password used |
|---|---|
| Normal day | Day + month, or month + day (auto-detected from your country) — ex: `0410` |
| Clock corrupted + offline | **MasterCode** — ex: `1234` |

The MasterCode is **never** valid when the clock is fine. It's a safety net, not a backdoor.

---

## 🗂️ What gets created

Everything lives in `C:\ProgramData\win-roll-lock\` (admin-only):

| File | Purpose |
|---|---|
| `config.json` | Settings (account, format, MasterCode) |
| `state.dat` | Encrypted state |
| `log.txt` | Log |
| `src\` | Scripts run by the scheduled task |

Plus a **scheduled task** named `win-roll-lock`, running under `SYSTEM`.

---

## ⚠️ Limitations

- **Local account only** (no Microsoft / Azure AD)
- **Windows Hello** stays separate — use the **Password** option at the logon screen
- A BIOS clock running **ahead** without network can't be detected
- Doesn't protect against a malicious admin

---

<div align="center">

### ❗ Warning

This tool **changes your Windows logon password**.

If you lose both the **MasterCode** and the **recovery account**, you may be **locked out**.

🧪 Test in a VM first · 💾 Save your BitLocker key · 🔍 Verify with `Win+L`

</div>