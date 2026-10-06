<div align="center">

# 🔐 WinRollLock

**Mot de passe Windows local qui change chaque jour.**
*Sans serveur, sans AD, sans matériel.*

<sub>Par défaut `ddMM` — ex. `0410` le 4 octobre</sub>

![Platform](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6?logo=windows&logoColor=white)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)
![Status](https://img.shields.io/badge/status-beta-orange)

</div>

---

## ✨ En bref

| | |
|---|---|
| 🔄 | Rotation **quotidienne** du mot de passe d'un compte local |
| 🌐 | Heure réseau multi-source : **NTP → HTTP `Date`** |
| 🛡️ | **3 niveaux de repli** — jamais de date BIOS douteuse |
| 🔑 | **MasterCode** de secours si horloge corrompue |
| 🔐 | État chiffré **DPAPI machine** |
| 🧩 | Tâche planifiée **SYSTEM** avec mutex |

---

## 🧠 Fonctionnement

À chaque déclenchement, l'heure est résolue par ordre de confiance :

    ┌─ 1. Réseau ──────► NTP (pool, Cloudflare, Microsoft)
    │                     puis HTTP Date de 1.1.1.1
    │                     ✅ mode SYNC  → Prefix + date
    │
    ├─ 2. Cohérence ───► Comparaison avec last_known_time.txt
    │                     Retard > 5 min = horloge corrompue
    │
    ├─ 3. Secours ─────► Corrompue + hors ligne
    │                     🚨 mode FALLBACK → MasterCode
    │
    └─ 4. Bannière ────► Message pré-connexion (jamais le mot de passe)

> `last_known_time.txt` n'est **jamais** mis à jour en mode `FALLBACK`.

---

## 📂 Arborescence

    windows-pin-roll-lock/
    ├── scripts/
    │   ├── Install.ps1            → installateur
    │   └── Uninstall.ps1          → désinstallateur
    ├── src/
    │   ├── Common.ps1             → log · DPAPI · bannière
    │   ├── Security-Policy.ps1    → politique via secedit
    │   ├── Time-Sync.ps1          → NTP · HTTP Date · décision
    │   └── Update-RollingPass.ps1 → cœur (exécuté par la tâche)
    ├── tests/
    │   └── Test-TimeFallback.ps1
    ├── config.example.json
    └── README.md

À l'installation, `src/` est copié dans `C:\ProgramData\WinRollLock\src\`.

---

## ⚙️ Prérequis

- Windows 10 / 11 · Server 2019+
- PowerShell 5.1 (intégré)
- Droits **administrateur**
- Un compte **local** (pas Microsoft)
- Un **second admin local** actif, mot de passe fixe
- BitLocker : clé de récupération sauvegardée

---

## 🚀 Installation

    # PowerShell administrateur, depuis la racine du dépôt
    .\scripts\Install.ps1 -MasterCode "9999"

<details>
<summary><b>Options disponibles</b></summary>

    .\scripts\Install.ps1 `
        -User       "MonCompte" `
        -Format     "ddMM"      `
        -Prefix     "Pin"       `
        -MasterCode "9999"

</details>

<details>
<summary><b>Les 9 étapes de l'installeur</b></summary>

1. Vérifie que le compte cible est **local**
2. Vérifie un **admin de secours** actif
3. Vérifie **BitLocker** (confirmation manuelle)
4. Valide le **mot de passe actuel**
5. Copie `src/` · écrit `config.json` · pose les **ACL**
6. **Essai à blanc** (aucune modification)
7. Sauvegarde puis applique la **politique tournante**
8. Enregistre l'état initial et la **tâche planifiée**
9. Première exécution + affichage du log

</details>

> ⚠️ **Testez `Win + L`** immédiatement après l'installation, **avant** tout redémarrage.

---

## 🔧 Configuration

Généré par l'installeur dans `C:\ProgramData\WinRollLock\config.json`.

    {
      "User": "TonCompteLocal",
      "Format": "ddMM",
      "Prefix": "",
      "MasterCode": "9999",
      "MinYear": 2026,
      "NtpServers": ["pool.ntp.org", "time.cloudflare.com", "time.windows.com"],
      "Banner": true
    }

| Champ | Rôle |
|---|---|
| `User` | Compte local cible |
| `Format` | Format .NET (`ddMM`, `MMdd`, `ddMMyy`…) |
| `Prefix` | Préfixe (`Pin` → `Pin0410`) |
| `MasterCode` | Mot de passe de secours (`FALLBACK`) |
| `MinYear` | Année minimum acceptée |
| `NtpServers` | Serveurs NTP dans l'ordre |
| `Banner` | Bannière en mode dégradé |

> Ne committez **jamais** un `config.json` réel.

---

## ⏰ Déclencheurs

| Événement | Détail |
|---|---|
| 🚀 Démarrage | — |
| 🕛 Quotidien | 00:00:01 |
| 😴 Sortie de veille | `Power-Troubleshooter` 1 · `Kernel-Power` 107 |
| 📶 Connexion réseau | `NetworkProfile` 10000 |

Un mutex global `WinRollLock` empêche les exécutions concurrentes.

---

## 🗂️ Fichiers runtime

`C:\ProgramData\WinRollLock\` — ACL : **SYSTEM** + **Administrateurs**

| Fichier | Rôle |
|---|---|
| `config.json` | Configuration |
| `state.dat` | État chiffré DPAPI machine |
| `last_known_time.txt` | Dernier instant UTC validé |
| `log.txt` | Journal (rotation 512 Ko) |
| `policy_original.json` | Politique d'origine |
| `src\` | Scripts exécutés |

---

## 🗑️ Désinstallation

    .\scripts\Uninstall.ps1
    # ou, pour conserver les fichiers :
    .\scripts\Uninstall.ps1 -KeepFiles

Supprime la tâche · applique un mot de passe fixe (préserve les clés DPAPI) · restaure la politique · retire la bannière · nettoie le dossier.

---

## 🧪 Tests

    .\tests\Test-TimeFallback.ps1

Fonctions pures uniquement — aucun accès système requis.
Couvre : pile CMOS morte · reset 2021 · extinction longue · dérive · absence d'historique · format · préfixe.

---

## 🔒 Sécurité

- 🛡️ ACL restrictives (`SYSTEM` + Admins uniquement)
- 🔐 `state.dat` chiffré **DPAPI machine** → préserve les clés utilisateur (navigateurs, EFS…)
- 🚫 `last_known_time.txt` jamais écrit en mode `FALLBACK`
- 🔏 TLS ignoré **uniquement** pour lire l'en-tête HTTP `Date`

---

## ⚠️ Limites

- Compte **local uniquement** (pas de Microsoft / Azure AD)
- **Windows Hello** reste indépendant → choisir « Mot de passe » à la connexion
- Horloge BIOS **en avance** sans réseau : non détectable
- Ne protège pas d'un administrateur local malveillant
- Mono-utilisateur

---

<div align="center">

### ❗ Avertissement

Ce projet **modifie le mot de passe de connexion Windows**.

Perte du `MasterCode` **et** du compte de secours = session potentiellement **inaccessible**.

🧪 Tester en VM · 💾 Sauver la clé BitLocker · 🔍 Vérifier avec `Win+L` · 📝 Noter le MasterCode hors ligne

</div>