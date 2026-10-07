# Uninstall.ps1 : removes win-roll-lock and restores a fixed password
# Self-elevates to administrator BEFORE anything else.
[CmdletBinding()]
param(
    [string]$Root = 'C:\ProgramData\win-roll-lock',
    [switch]$KeepFiles,
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
        '-File', $quotedSelf
        '-Root', ('"' + $Root + '"')
    )
    if ($KeepFiles) { $argsList += '-KeepFiles' }
    if ($NoPause)   { $argsList += '-NoPause' }
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
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'src\Common.ps1')
. (Join-Path $repo 'src\Security-Policy.ps1')
Set-WRLRoot $Root

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

try {
    # ------------------------------------------------------------
    # 0. Pre-flight check
    # ------------------------------------------------------------
    $cfgPath = Get-WRLPath 'config.json'
    if (-not (Test-Path $cfgPath)) {
        Write-Host "Config not found ($cfgPath). Nothing to uninstall." -ForegroundColor Yellow
        Wait-BeforeExit 0
    }
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json

    # ------------------------------------------------------------
    # 1. Global confirmation
    # ------------------------------------------------------------
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '  UNINSTALL win-roll-lock' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  This will :' -ForegroundColor White
    Write-Host '    - remove the scheduled task' -ForegroundColor Gray
    Write-Host '    - restore the original security policy' -ForegroundColor Gray
    Write-Host '    - clear the logon banner' -ForegroundColor Gray
    Write-Host "    - handle the rolling account ($($cfg.User))" -ForegroundColor Gray
    Write-Host ''
    $confirm = Read-Host 'Proceed with uninstall? (Y/N)'
    if ($confirm -notmatch '^(y|yes|o|oui)$') {
        Write-Host 'Uninstall cancelled.' -ForegroundColor Yellow
        Wait-BeforeExit 0
    }

    # ------------------------------------------------------------
    # 2. Stop the task
    # ------------------------------------------------------------
    Unregister-ScheduledTask -TaskName 'win-roll-lock' -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host 'Scheduled task removed.'

    # ------------------------------------------------------------
    # 3. Original security policy
    # ------------------------------------------------------------
    $polPath = Get-WRLPath 'policy_original.json'
    if (Test-Path $polPath) {
        $o = Get-Content $polPath -Raw | ConvertFrom-Json
        $h = @{}
        $o.PSObject.Properties | ForEach-Object { $h[$_.Name] = [int]$_.Value }
        Set-SecPolicyValues $h
        Write-Host 'Security policy restored.'
    } else {
        Set-SecPolicyValues @{ MaximumPasswordAge = 42 }
        Write-Host 'No backup found: expiration reset to 42 days.'
    }

    # ------------------------------------------------------------
    # 4. Banner
    # ------------------------------------------------------------
    Set-LogonBanner -Text $null

    # ------------------------------------------------------------
    # 5. Created accounts cleanup
    # ------------------------------------------------------------
    $createdPath = Join-Path $Root 'created_accounts.json'
    $deletedAccounts = @()
    $targetWasDeleted = $false

    if (Test-Path $createdPath) {
        try {
            $created = @(Get-Content $createdPath -Raw | ConvertFrom-Json)
        } catch {
            $created = @()
        }

        # Keep only accounts that still exist
        $created = @($created | Where-Object {
            $_ -and (Get-LocalUser -Name $_ -ErrorAction SilentlyContinue)
        })

        if ($created.Count -gt 0) {
            Write-Host ''
            Write-Host 'Accounts created by win-roll-lock:' -ForegroundColor Cyan
            foreach ($name in $created) {
                $marker = if ($name -eq $cfg.User) { ' (rolling account)' } else { '' }
                Write-Host "  - $name$marker"
            }
            Write-Host ''

            $ans = Read-Host 'Delete these accounts? (Y/N)'
            if ($ans -match '^(y|yes|o|oui)$') {
                foreach ($name in $created) {
                    try {
                        # Cannot delete the account we're currently running as
                        if ($name -eq $env:USERNAME) {
                            Write-Host "  Skipping '$name' (current session)." -ForegroundColor Yellow
                            continue
                        }
                        Remove-LocalUser -Name $name
                        Write-Host "  Account '$name' deleted." -ForegroundColor Green
                        $deletedAccounts += $name
                        if ($name -eq $cfg.User) { $targetWasDeleted = $true }
                    } catch {
                        Write-Host "  Failed to delete '$name': $($_.Exception.Message)" -ForegroundColor Red
                    }
                }
            } else {
                Write-Host '  Accounts kept.' -ForegroundColor Yellow
            }
        }
    }

    # ------------------------------------------------------------
    # 6. Fixed password (only if the target account still exists)
    # ------------------------------------------------------------
    $targetStillExists = Get-LocalUser -Name $cfg.User -ErrorAction SilentlyContinue
    if ($targetWasDeleted -or -not $targetStillExists) {
        Write-Host ''
        Write-Host "Rolling account '$($cfg.User)' was deleted. Skipping password reset." -ForegroundColor Gray
    } else {
        Write-Host ''
        Write-Host "Account '$($cfg.User)' still exists." -ForegroundColor Cyan
        Write-Host "Set a FIXED password to replace the rolling one." -ForegroundColor Cyan
        Write-Host "(Leave empty to remove the password entirely.)" -ForegroundColor Gray
        Write-Host ''

        do {
            $p1 = ConvertTo-Plain (Read-Host "New FIXED password for $($cfg.User)" -AsSecureString)
            $p2 = ConvertTo-Plain (Read-Host 'Confirm password' -AsSecureString)
            if ($p1 -ne $p2) {
                Write-Host 'Passwords do not match. Try again.' -ForegroundColor Red
                continue
            }
            break
        } while ($true)

        $state = Read-State
        $old = $null
        if ($state) { $old = [string]$state.Password }
        $how = Set-AccountPassword -User $cfg.User -New $p1 -Old $old
        if ($p1 -eq '') {
            Write-Host "Password removed (method $how)." -ForegroundColor Green
        } else {
            Write-Host "Fixed password applied (method $how)." -ForegroundColor Green
        }
    }

    # ------------------------------------------------------------
    # 7. Files
    # ------------------------------------------------------------
    if (-not $KeepFiles) {
        Remove-Item $Root -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Folder $Root removed."
    }

    Write-Host ''
    Write-Host 'Uninstall complete.' -ForegroundColor Green
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