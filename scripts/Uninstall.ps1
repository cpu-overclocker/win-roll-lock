# Uninstall.ps1 : retire WinRollLock et restaure un mot de passe fixe
# S'auto-élève en administrateur AVANT toute autre chose.
[CmdletBinding()]
param(
    [string]$Root = 'C:\ProgramData\WinRollLock',
    [switch]$KeepFiles,
    [switch]$NoPause
)

# ============================================================
# 1. AUTO-ELEVATION — première chose exécutée
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
# 2. ADMIN — à partir d'ici on est élevé
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
    # 1. Stopper la tache d'abord pour eviter toute course
    Unregister-ScheduledTask -TaskName 'WinRollLock' -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host 'Tache planifiee supprimee.'

    # 2. Mot de passe fixe (ChangePassword avec l'etat connu, donc DPAPI preserve si possible)
    $cfgPath = Get-WRLPath 'config.json'
    if (-not (Test-Path $cfgPath)) {
        Write-Host "Config introuvable ($cfgPath). Rien a desinstaller." -ForegroundColor Yellow
        Wait-BeforeExit 0
    }
    $cfg   = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $state = Read-State
    $p1 = ConvertTo-Plain (Read-Host "Nouveau mot de passe FIXE pour $($cfg.User) (vide pour aucun)" -AsSecureString)
    $p2 = ConvertTo-Plain (Read-Host 'Confirme le mot de passe' -AsSecureString)
    if ($p1 -ne $p2) { throw 'Les deux mots de passe different. Tache deja supprimee, relance le script.' }
    $old = $null
    if ($state) { $old = [string]$state.Password }
    $how = Set-AccountPassword -User $cfg.User -New $p1 -Old $old
    Write-Host "Mot de passe fixe applique (methode $how)."

    # 3. Strategie de securite d'origine
    $polPath = Get-WRLPath 'policy_original.json'
    if (Test-Path $polPath) {
        $o = Get-Content $polPath -Raw | ConvertFrom-Json
        $h = @{}
        $o.PSObject.Properties | ForEach-Object { $h[$_.Name] = [int]$_.Value }
        Set-SecPolicyValues $h
        Write-Host 'Strategie de securite restauree.'
    } else {
        Set-SecPolicyValues @{ MaximumPasswordAge = 42 }
        Write-Host 'Sauvegarde absente : expiration remise a 42 jours.'
    }

    # 4. Banniere
    Set-LogonBanner -Text $null

    # 5. Fichiers
    if (-not $KeepFiles) {
        Remove-Item $Root -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Dossier $Root supprime."
    }

    Write-Host 'Desinstallation terminee.' -ForegroundColor Green
    Wait-BeforeExit 0
}
catch {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host "ERREUR : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    Wait-BeforeExit 1
}