#Requires -RunAsAdministrator
# Uninstall.ps1 : retire WinRollLock et restaure un mot de passe fixe
[CmdletBinding()]
param(
    [string]$Root = 'C:\ProgramData\WinRollLock',
    [switch]$KeepFiles
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'src\Common.ps1')
. (Join-Path $repo 'src\Security-Policy.ps1')
Set-WRLRoot $Root

function ConvertTo-Plain([SecureString]$s) {
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

# 1. Stopper la tache d'abord pour eviter toute course
Unregister-ScheduledTask -TaskName 'WinRollLock' -Confirm:$false -ErrorAction SilentlyContinue
Write-Host 'Tache planifiee supprimee.'

# 2. Mot de passe fixe (ChangePassword avec l'etat connu, donc DPAPI preserve si possible)
$cfg   = Get-Content (Get-WRLPath 'config.json') -Raw | ConvertFrom-Json
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
