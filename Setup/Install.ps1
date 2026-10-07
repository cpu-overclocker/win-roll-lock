# Install.ps1 : installs win-roll-lock with anti-lockout safeguards
# Self-elevates to administrator BEFORE anything else.
[CmdletBinding()]
param(
    [string]$User = '',
    [string]$Format = '',
    [string]$Prefix = '',
    [string]$MasterCode = '',
    [string]$Root = 'C:\ProgramData\win-roll-lock',
    [switch]$NoPause
)

# ============================================================
# 1. AUTO-ELEVATION — first thing executed
# ============================================================
$current = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = $current.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host 'Elevation required. Relaunching as administrator...' -ForegroundColor Yellow

    $self = $PSCommandPath
    if ([string]::IsNullOrEmpty($self)) { $self = $MyInvocation.MyCommand.Path }
    if ([string]::IsNullOrEmpty($self)) { $self = $MyInvocation.MyCommand.Definition }
    if ([string]::IsNullOrEmpty($self)) {
        Write-Host 'Cannot determine script path. Aborting.' -ForegroundColor Red
        return 1
    }

    $quotedSelf = '"' + $self + '"'
    $argsList = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File',   $quotedSelf
        '-Format', ('"' + $Format + '"')
        '-Root',   ('"' + $Root   + '"')
    )
    if ($User)       { $argsList += @('-User',       ('"' + $User       + '"')) }
    if ($Prefix)     { $argsList += @('-Prefix',     ('"' + $Prefix     + '"')) }
    if ($MasterCode) { $argsList += @('-MasterCode', ('"' + $MasterCode + '"')) }
    if ($NoPause)    { $argsList += '-NoPause' }
    $argString = $argsList -join ' '

    try {
        $p = Start-Process -FilePath 'powershell.exe' `
                           -ArgumentList $argString `
                           -Verb RunAs `
                           -PassThru `
                           -ErrorAction Stop
    } catch {
        Write-Host ''
        Write-Host 'Failed to start elevated process.' -ForegroundColor Red
        Write-Host "Reason: $($_.Exception.Message)" -ForegroundColor DarkRed
        Write-Host ''
        Write-Host 'Tip: is UAC enabled? Right-click PowerShell -> Run as administrator.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'Press any key to close...' -ForegroundColor Yellow
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        return 1
    }

    if (-not $p) {
        Write-Host 'Start-Process returned nothing.' -ForegroundColor Red
        return 1
    }

    $p.WaitForExit()
    return $p.ExitCode
}

# ============================================================
# 2. ADMIN — from here we are elevated
# ============================================================
$ErrorActionPreference = 'Stop'

# Détecte la racine du dépôt quel que soit l'emplacement du script :
#  - Setup\Install.ps1   → parent = racine du repo
#  - Install.ps1 (racine) → $PSScriptRoot = racine du repo
$repoCandidates = @(
    (Split-Path $PSScriptRoot -Parent),
    $PSScriptRoot
)
$repo = $repoCandidates | Where-Object {
    $_ -and (Test-Path (Join-Path $_ 'src\Common.ps1'))
} | Select-Object -First 1

if (-not $repo) {
    throw "Cannot locate 'src\Common.ps1'. Check the repository structure (expected: <repo>\src\Common.ps1)."
}

. (Join-Path $repo 'src\Common.ps1')
. (Join-Path $repo 'src\Security-Policy.ps1')
. (Join-Path $repo 'src\Time-Sync.ps1')

Set-WRLRoot $Root

# Detects the local date convention to pick the right rolling format.
# Returns 'ddMM' for day-first cultures (most of the world), 'MMdd' for month-first (US).
function Get-DefaultDateFormat {
    try {
        $culture = [System.Globalization.CultureInfo]::CurrentCulture
        $pattern = $culture.DateTimeFormat.ShortDatePattern

        $firstSep = $pattern.IndexOfAny([char[]]'/.-')
        $leading  = if ($firstSep -gt 0) { $pattern.Substring(0, $firstSep) } else { $pattern }

        if ($leading -match '^y+$') {
            $rest = $pattern.Substring($firstSep + 1)
            $nextSep = $rest.IndexOfAny([char[]]'/.-')
            $leading = if ($nextSep -gt 0) { $rest.Substring(0, $nextSep) } else { $rest }
        }

        if ($leading -match '^d') { return 'ddMM' }
        if ($leading -match '^M') { return 'MMdd' }
        return 'ddMM'
    } catch {
        return 'ddMM'
    }
}

if ([string]::IsNullOrEmpty($Format)) {
    $detected = Get-DefaultDateFormat
    $culture  = [System.Globalization.CultureInfo]::CurrentCulture
    $display  = if ($detected -eq 'ddMM') { 'dd/MM' } else { 'MM/dd' }

    Write-Host ''
    Write-Host "Detected culture: $($culture.Name)" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '  TIMESTAMP FORMAT' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  The OS timestamp format on this machine is : $display" -ForegroundColor White
    Write-Host ''
    Write-Host '  This format is used to build the daily rolling password.' -ForegroundColor Gray
    Write-Host '  (e.g. MM/dd -> password "0415" on April 15th)' -ForegroundColor DarkGray
    Write-Host ''

    $ans = Read-Host "Use the OS format ($display)? (Y/N)"
    if ($ans -match '^(y|yes|o|oui)$') {
        $Format = $detected
    } else {
        do {
            Write-Host ''
            Write-Host 'Choose the timestamp format:' -ForegroundColor White
            Write-Host ''
            Write-Host '  [1] MM/dd   (month first - US style)'   -ForegroundColor Gray
            Write-Host '  [2] dd/MM   (day first  - EU style)'   -ForegroundColor Gray
            Write-Host ''
            $fmtChoice = (Read-Host 'Select (1 or 2)').Trim()
            if ($fmtChoice -eq '1') {
                $Format = 'MMdd'
            } elseif ($fmtChoice -eq '2') {
                $Format = 'ddMM'
            } else {
                Write-Host 'Invalid choice. Try again.' -ForegroundColor Red
            }
        } while ([string]::IsNullOrEmpty($Format))
    }

    Write-Host ''
    Write-Host "Selected format: $Format" -ForegroundColor Green
}

# --- Windows Hello detection (real check, no false positives) ---
function Test-WindowsHelloEnabled {
    try {
        $output = & dsregcmd /status 2>$null
        foreach ($line in $output) {
            if ($line -match '^\s*NgcSet\s*:\s*(\w+)') {
                return ($matches[1] -eq 'YES')
            }
        }
        return $false
    } catch {
        return $false
    }
}
if (Test-WindowsHelloEnabled) {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Yellow
    Write-Host '  WINDOWS HELLO DETECTED' -ForegroundColor Yellow
    Write-Host '============================================================' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Windows Hello (PIN, fingerprint, face) is enabled on' -ForegroundColor White
    Write-Host '  this machine. win-roll-lock only changes the TRADITIONAL' -ForegroundColor White
    Write-Host '  account password, NOT the Hello PIN.' -ForegroundColor White
    Write-Host ''
    Write-Host '  At the logon screen, choose the PASSWORD option' -ForegroundColor Gray
    Write-Host '  (not the PIN) to use the rolling password.' -ForegroundColor Gray
    Write-Host ''
    $helloAck = Read-Host 'Continue anyway? (Y/N)'
    if ($helloAck -notmatch '^(y|yes|o|oui)$') { throw 'Installation cancelled.' }
}

if ([string]::IsNullOrEmpty($MasterCode)) {
    $sample = Get-RollingPassword -LocalDate (Get-Date) -Format $Format
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '  MASTER CODE' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  A FIXED fallback password used ONLY if the system clock' -ForegroundColor White
    Write-Host '  is corrupted AND the machine is offline.' -ForegroundColor White
    Write-Host ''
    Write-Host "  Normal days  :  the daily code (ex: $sample today)" -ForegroundColor Gray
    Write-Host '  Emergency    :  this MasterCode (ex: 1234)' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  Write it down and keep it offline.' -ForegroundColor Yellow
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''
    $MasterCode = Read-Host 'MasterCode'
    if ([string]::IsNullOrEmpty($MasterCode)) { throw 'MasterCode is required.' }
}

function ConvertTo-Plain([SecureString]$s) {
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Wait-BeforeExit {
    param([int]$Code)
    if (-not $NoPause) {
        Write-Host ''
        Write-Host 'Press any key to close...' -ForegroundColor Yellow
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
    exit $Code
}

function Add-CreatedAccount {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Test-Path $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    $path = Join-Path $Root 'created_accounts.json'
    $list = @()
    if (Test-Path $path) {
        try { $list = @(Get-Content $path -Raw | ConvertFrom-Json) } catch { $list = @() }
    }
    if ($list -notcontains $Name) {
        $list += $Name
        $list | ConvertTo-Json | Set-Content $path -Encoding UTF8
    }
}

try {
    # ------------------------------------------------------------
    # 1. Account selection
    # ------------------------------------------------------------
    $isExplicitUser = $PSBoundParameters.ContainsKey('User') -and $User
    $currentUser = $env:USERNAME

    if (-not $isExplicitUser) {
        Write-Host '1/9 Selecting target account' -ForegroundColor Cyan

        while ($true) {
            $builtin = @('Administrateur','Administrator','DefaultAccount','Invité','Guest','WDAGUtilityAccount')
            $allLocal = @(Get-LocalUser | Where-Object {
                $_.Enabled -and
                $_.PrincipalSource -eq 'Local' -and
                $_.Name -notin $builtin
            })

            $activeLocal = $allLocal | Where-Object { $_.Name -eq $currentUser } | Select-Object -First 1
            $others      = @($allLocal | Where-Object { $_.Name -ne $currentUser } | Sort-Object Name)

            $localUsers = @()
            if ($activeLocal) { $localUsers += $activeLocal }
            $localUsers += $others

            Write-Host ''
            Write-Host 'Available local accounts:' -ForegroundColor White
            Write-Host ''
            Write-Host '  [0] Create a new local account' -ForegroundColor Green
            for ($i = 0; $i -lt $localUsers.Count; $i++) {
                $name = $localUsers[$i].Name
                $tags = @()
                if ($name -eq $currentUser) { $tags += 'active' }
                $tagStr = if ($tags.Count) { '  [' + ($tags -join ', ') + ']' } else { '' }
                Write-Host ("  [{0}] {1}{2}" -f ($i + 1), $name, $tagStr)
            }
            Write-Host ''

            if (-not $activeLocal) {
                Write-Host "Note: current session user '$currentUser' is not a local account (Microsoft/Azure AD)." -ForegroundColor Yellow
                Write-Host '      Pick a LOCAL account from the list above, or create one with [0].' -ForegroundColor Yellow
                Write-Host ''
            }

            do {
                $choice = Read-Host "Select account number "
                $idx = -1
                $valid = [int]::TryParse($choice, [ref]$idx) -and $idx -ge 0 -and $idx -le $localUsers.Count
                if (-not $valid) { Write-Host 'Invalid choice. Try again.' -ForegroundColor Red }
            } while (-not $valid)

            if ($idx -eq 0) {
                Write-Host ''
                Write-Host 'Create a new local account' -ForegroundColor Cyan
                Write-Host ''

                do {
                    $newName = (Read-Host 'New account name').Trim()
                    if ([string]::IsNullOrEmpty($newName)) {
                        Write-Host 'Name cannot be empty.' -ForegroundColor Red
                        continue
                    }
                    if ($newName -match '[\\/:*?"<>|]') {
                        Write-Host 'Name contains invalid characters.' -ForegroundColor Red
                        continue
                    }
                    $exists = Get-LocalUser -Name $newName -ErrorAction SilentlyContinue
                    if ($exists) {
                        Write-Host "Account '$newName' already exists. Pick another name." -ForegroundColor Red
                        continue
                    }
                    break
                } while ($true)

                do {
                    $pwd1 = Read-Host "Password for '$newName'" -AsSecureString
                    $pwd2 = Read-Host "Confirm password" -AsSecureString
                    $plain1 = ConvertTo-Plain $pwd1
                    $plain2 = ConvertTo-Plain $pwd2
                    if ($plain1 -ne $plain2) {
                        Write-Host 'Passwords do not match. Try again.' -ForegroundColor Red
                        continue
                    }
                    break
                } while ($true)

                $addAdminAns = Read-Host "Add '$newName' to Administrators? (Y/N)"
                $addAdmin = $addAdminAns -match '^(y|yes|o|oui)$'

                try {
                    New-LocalUser -Name $newName -Password $pwd1 -PasswordNeverExpires `
                                   -Description 'win-roll-lock rolling account' | Out-Null
                    Write-Host "   Account '$newName' created." -ForegroundColor Green
                    Add-CreatedAccount -Name $newName

                    if ($addAdmin) {
                        Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $newName
                        Write-Host "   Added to Administrators." -ForegroundColor Green
                    }

                    $User = $newName
                    Write-Host "   Selected account: $User" -ForegroundColor Green
                    break
                } catch {
                    Write-Host "Failed to create account: $($_.Exception.Message)" -ForegroundColor Red
                    Write-Host 'Back to account selection.' -ForegroundColor Yellow
                    continue
                }
            }

            $User = $localUsers[$idx - 1].Name
            Write-Host "   Selected account: $User" -ForegroundColor Green
            break
        }
    } else {
        Write-Host '1/9 Verifying target account' -ForegroundColor Cyan
    }

    $lu = Get-LocalUser -Name $User -ErrorAction Stop
    if ($lu.PrincipalSource -ne 'Local') {
        throw "Account $User is not a local Windows account (Microsoft account not supported)."
    }
    if (-not $lu.Enabled) {
        throw "Account $User is disabled."
    }
    if ($isExplicitUser) {
        Write-Host "   Account: $($lu.Name)" -ForegroundColor Green
    }

    # ------------------------------------------------------------
    # 2. Recovery administrator
    # ------------------------------------------------------------
    Write-Host '2/9 Selecting recovery administrator' -ForegroundColor Cyan

    $builtin = @('Administrateur','Administrator','DefaultAccount','Invité','Guest','WDAGUtilityAccount')
    $rescue = $null

    while ($true) {
        $adminCandidates = @()
        foreach ($m in (Get-LocalGroupMember -SID 'S-1-5-32-544')) {
            $n = ($m.Name -split '\\')[-1]
            $u = Get-LocalUser -Name $n -ErrorAction SilentlyContinue
            if ($u -and $u.Enabled -and $u.PrincipalSource -eq 'Local' -and
                $u.Name -ne $User -and $u.Name -notin $builtin) {
                $adminCandidates += $u
            }
        }
        $adminCandidates = @($adminCandidates | Sort-Object Name -Unique)

        Write-Host ''
        Write-Host 'Recovery administrator is used if the rolling account gets locked.' -ForegroundColor White
        Write-Host 'It must have a FIXED password you remember.' -ForegroundColor White
        Write-Host ''
        Write-Host 'Available recovery accounts:' -ForegroundColor White
        Write-Host ''
        Write-Host '  [0] Create a new recovery account' -ForegroundColor Green
        for ($i = 0; $i -lt $adminCandidates.Count; $i++) {
            Write-Host ("  [{0}] {1}" -f ($i + 1), $adminCandidates[$i].Name)
        }
        Write-Host ''

        if ($adminCandidates.Count -eq 0) {
            Write-Host 'No eligible recovery admin found. Choose [0] to create one.' -ForegroundColor Yellow
            Write-Host ''
        }

        do {
            $choice = Read-Host 'Select account number (0 to cancel)'
            $idx = -1
            $valid = [int]::TryParse($choice, [ref]$idx) -and $idx -ge 0 -and $idx -le $adminCandidates.Count
            if (-not $valid) { Write-Host 'Invalid choice. Try again.' -ForegroundColor Red }
        } while (-not $valid)

        if ($idx -eq 0) {
            Write-Host ''
            Write-Host 'Create a new recovery account' -ForegroundColor Cyan
            Write-Host ''

            do {
                $rn = (Read-Host 'Recovery account name').Trim()
                if ([string]::IsNullOrEmpty($rn)) {
                    Write-Host 'Name cannot be empty.' -ForegroundColor Red
                    continue
                }
                if ($rn -match '[\\/:*?"<>|]') {
                    Write-Host 'Name contains invalid characters.' -ForegroundColor Red
                    continue
                }
                $exists = Get-LocalUser -Name $rn -ErrorAction SilentlyContinue
                if ($exists) {
                    Write-Host "Account '$rn' already exists. Pick another name." -ForegroundColor Red
                    continue
                }
                break
            } while ($true)

            do {
                $rp1 = Read-Host "FIXED password for '$rn'" -AsSecureString
                $rp2 = Read-Host 'Confirm password' -AsSecureString
                $plain1 = ConvertTo-Plain $rp1
                $plain2 = ConvertTo-Plain $rp2
                if ($plain1 -ne $plain2) {
                    Write-Host 'Passwords do not match. Try again.' -ForegroundColor Red
                    continue
                }
                if ([string]::IsNullOrEmpty($plain1)) {
                    Write-Host 'Password cannot be empty for a recovery account.' -ForegroundColor Red
                    continue
                }
                break
            } while ($true)

            try {
                New-LocalUser -Name $rn -Password $rp1 -PasswordNeverExpires `
                               -Description 'win-roll-lock recovery' | Out-Null
                Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $rn
                Add-CreatedAccount -Name $rn
                $rescue = Get-LocalUser -Name $rn
                Write-Host "   Account '$rn' created and added to Administrators." -ForegroundColor Green
                break
            } catch {
                Write-Host "Failed to create account: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host 'Back to recovery account selection.' -ForegroundColor Yellow
                continue
            }
        }

        $rn = $adminCandidates[$idx - 1].Name
        Write-Host ''
        Write-Host "Confirm FIXED password for '$rn' (used as recovery)." -ForegroundColor Cyan
        do {
            $rp1 = Read-Host 'Password' -AsSecureString
            $rp2 = Read-Host 'Confirm password' -AsSecureString
            $plain1 = ConvertTo-Plain $rp1
            $plain2 = ConvertTo-Plain $rp2
            if ($plain1 -ne $plain2) {
                Write-Host 'Passwords do not match. Try again.' -ForegroundColor Red
                continue
            }
            if ([string]::IsNullOrEmpty($plain1)) {
                Write-Host 'Password cannot be empty for a recovery account.' -ForegroundColor Red
                continue
            }
            break
        } while ($true)

        try {
            Set-LocalUser -Name $rn -Password $rp1 -PasswordNeverExpires $true
            $rescue = Get-LocalUser -Name $rn
            Write-Host "   Password set for '$rn'." -ForegroundColor Green
            break
        } catch {
            Write-Host "Failed to set password: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host 'Back to recovery account selection.' -ForegroundColor Yellow
            continue
        }
    }

    Write-Host "   Recovery account: $($rescue.Name)"

    # ------------------------------------------------------------
    # 3. BitLocker
    # ------------------------------------------------------------
    Write-Host '3/9 Verifying BitLocker' -ForegroundColor Cyan
    $blActive = $false
    try {
        $vol = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        if ($vol.ProtectionStatus -eq 'On') { $blActive = $true }
    } catch {
        $blActive = $false
    }

    if ($blActive) {
        Write-Host 'BitLocker is active. The recovery key must be saved BEFORE continuing.' -ForegroundColor Yellow
        $ans = Read-Host 'Recovery key saved? (Y/N)'
        if ($ans -notmatch '^(y|yes|o|oui)$') { throw 'Installation cancelled.' }
    }

    # ------------------------------------------------------------
    # 4. Current password
    # ------------------------------------------------------------
    Write-Host '4/9 Current account password' -ForegroundColor Cyan
    $cur = ConvertTo-Plain (Read-Host "Current password for $User (empty if none)" -AsSecureString)
    if ($cur -ne '' -and -not (Test-LocalCredential -User $User -Password $cur)) { throw 'Current password is incorrect.' }

    # ------------------------------------------------------------
    # 5. Copy files and config
    # ------------------------------------------------------------
    Write-Host '5/9 Copying files and config' -ForegroundColor Cyan
    New-Item -ItemType Directory -Path "$Root\src" -Force | Out-Null
    Copy-Item (Join-Path $repo 'src\*') "$Root\src" -Recurse -Force
    $cfg = [ordered]@{
        User = $User; Format = $Format; Prefix = $Prefix; MasterCode = $MasterCode
        MinYear = (Get-Date).Year
        NtpServers = @('pool.ntp.org', 'time.cloudflare.com', 'time.windows.com')
        Banner = $true
    }
    $cfg | ConvertTo-Json | Set-Content (Join-Path $Root 'config.json') -Encoding UTF8
    & icacls $Root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null

    # ------------------------------------------------------------
    # 6. Dry run
    # ------------------------------------------------------------
    Write-Host '6/9 Dry run (nothing is modified)' -ForegroundColor Cyan
    $dry = & (Join-Path $Root 'src\Update-RollingPass.ps1') -DryRun -Root $Root
    $dry | Format-List
    $ans = Read-Host 'Is the target password correct? (Y/N)'
    if ($ans -notmatch '^(y|yes|o|oui)$') {
        Write-Host ''
        Write-Host 'Installation cancelled.' -ForegroundColor Yellow

        $createdPath = Join-Path $Root 'created_accounts.json'
        if (Test-Path $createdPath) {
            try { $created = @(Get-Content $createdPath -Raw | ConvertFrom-Json) } catch { $created = @() }
            foreach ($name in $created) {
                if (-not $name) { continue }
                if ($name -eq $env:USERNAME) {
                    Write-Host "  Skipping '$name' (current session)." -ForegroundColor Yellow
                    continue
                }
                try {
                    Remove-LocalUser -Name $name -ErrorAction Stop
                    Write-Host "  Account '$name' deleted." -ForegroundColor Green
                } catch {
                    Write-Host "  Failed to delete '$name': $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }

        if (Test-Path $Root) {
            Remove-Item $Root -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  Folder $Root removed." -ForegroundColor Green
        }

        Wait-BeforeExit 1
    }

    # ------------------------------------------------------------
    # 7. Security policy
    # ------------------------------------------------------------
    Write-Host '7/9 Local security policy' -ForegroundColor Cyan
    $orig = Get-SecPolicyValues
    $orig | ConvertTo-Json | Set-Content (Join-Path $Root 'policy_original.json') -Encoding UTF8
    Set-RollingPolicy

    # ------------------------------------------------------------
    # 8. Initial state + scheduled task
    # ------------------------------------------------------------
    Write-Host '8/9 Initial state and scheduled task' -ForegroundColor Cyan
    Save-State @{ User = $User; Password = $cur; Mode = 'INIT'; Updated = (Get-Date).ToString('o') }

    $ps  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $scr = Join-Path $Root 'src\Update-RollingPass.ps1'

    # >>> MODIF : ajout de la requête WLAN-AutoConfig/8001 (connexion WiFi réussie)
    $q1raw = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-Power-Troubleshooter''] and EventID=1]]</Select></Query></QueryList>'
    $q2raw = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-Kernel-Power''] and EventID=107]]</Select></Query></QueryList>'
    $q3raw = '<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"><Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[EventID=10000]]</Select></Query></QueryList>'
    $q4raw = '<QueryList><Query Id="0" Path="Microsoft-Windows-WLAN-AutoConfig/Operational"><Select Path="Microsoft-Windows-WLAN-AutoConfig/Operational">*[System[EventID=8001]]</Select></Query></QueryList>'

    $q1 = [System.Security.SecurityElement]::Escape($q1raw)
    $q2 = [System.Security.SecurityElement]::Escape($q2raw)
    $q3 = [System.Security.SecurityElement]::Escape($q3raw)
    $q4 = [System.Security.SecurityElement]::Escape($q4raw)

    # >>> MODIF : triggers refondus. Ajout de ResumeTrigger, SessionStateChangeTrigger,
    #            LogonTrigger, Repetition (filet de sécurité) et EventTrigger WLAN.
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>win-roll-lock : rolling password</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled></BootTrigger>

    <!-- AJOUT : reprise de veille / hibernation (le trigger qui manquait) -->
    <ResumeTrigger><Enabled>true</Enabled><Delay>PT15S</Delay></ResumeTrigger>

    <!-- AJOUT : déverrouillage de session (rafraîchit après Win+L) -->
    <SessionStateChangeTrigger><Enabled>true</Enabled><StateChange>SessionUnlock</StateChange></SessionStateChangeTrigger>

    <!-- AJOUT : à chaque ouverture de session -->
    <LogonTrigger><Enabled>true</Enabled><Delay>PT30S</Delay></LogonTrigger>

    <!-- MODIF : quotidien + répétition toutes les 15 min (filet de sécurité) -->
    <CalendarTrigger>
      <StartBoundary>2026-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>
      <Repetition>
        <Interval>PT15M</Interval>
        <Duration>P1D</Duration>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </CalendarTrigger>

    <EventTrigger><Enabled>true</Enabled><Delay>PT5S</Delay><Subscription>$q1</Subscription></EventTrigger>
    <EventTrigger><Enabled>true</Enabled><Delay>PT5S</Delay><Subscription>$q2</Subscription></EventTrigger>
    <EventTrigger><Enabled>true</Enabled><Delay>PT10S</Delay><Subscription>$q3</Subscription></EventTrigger>

    <!-- AJOUT : reconnexion WiFi fiable -->
    <EventTrigger><Enabled>true</Enabled><Delay>PT5S</Delay><Subscription>$q4</Subscription></EventTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>Queue</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author"><Exec><Command>$ps</Command><Arguments>-NoProfile -ExecutionPolicy Bypass -File "$scr"</Arguments></Exec></Actions>
</Task>
"@
    Register-ScheduledTask -TaskName 'win-roll-lock' -Xml $xml -Force | Out-Null

    # ------------------------------------------------------------
    # 9. First run
    # ------------------------------------------------------------
    Write-Host '9/9 First run' -ForegroundColor Cyan
    & $ps -NoProfile -ExecutionPolicy Bypass -File $scr
    Get-Content (Join-Path $Root 'log.txt') -Tail 5
    Write-Host "Done. Recovery account: $($rescue.Name). Test with Win+L before rebooting." -ForegroundColor Green
    Wait-BeforeExit 0
}
catch {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    Wait-BeforeExit 1
}