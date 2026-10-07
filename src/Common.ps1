# Common.ps1 : fonctions partagees (log, etat, mot de passe, banniere)
Set-StrictMode -Version 2.0

$script:WRLRoot = 'C:\ProgramData\win-roll-lock'

function Set-WRLRoot {
    param([Parameter(Mandatory)][string]$Path)
    $script:WRLRoot = $Path
}

function Get-WRLPath {
    param([Parameter(Mandatory)][string]$Name)
    Join-Path $script:WRLRoot $Name
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    try {
        $p = Get-WRLPath 'log.txt'
        if ((Test-Path $p) -and ((Get-Item $p).Length -gt 512KB)) {
            Move-Item $p "$p.old" -Force
        }
        $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
        Add-Content -Path $p -Value $line -Encoding UTF8
    } catch { }
    Write-Verbose $Message
}

# Etat chiffre (DPAPI machine) : dernier mot de passe applique, necessaire pour
# ChangePassword(ancien, nouveau) et donc pour ne PAS casser les cles DPAPI de l'utilisateur.
function Save-State {
    param([Parameter(Mandatory)][hashtable]$State)
    Add-Type -AssemblyName System.Security
    $json  = $State | ConvertTo-Json -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $enc   = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    [IO.File]::WriteAllBytes((Get-WRLPath 'state.dat'), $enc)
}

function Read-State {
    $p = Get-WRLPath 'state.dat'
    if (-not (Test-Path $p)) { return $null }
    try {
        Add-Type -AssemblyName System.Security
        $enc   = [IO.File]::ReadAllBytes($p)
        $bytes = [Security.Cryptography.ProtectedData]::Unprotect($enc, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
    } catch {
        Write-Log "Etat illisible: $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Test-LocalCredential {
    param([string]$User, [string]$Password)
    try {
        Add-Type -AssemblyName System.DirectoryServices.AccountManagement
        $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext('Machine', $env:COMPUTERNAME)
        return [bool]$ctx.ValidateCredentials($User, $Password, [System.DirectoryServices.AccountManagement.ContextOptions]::Negotiate)
    } catch {
        return $false
    }
}

# Retourne 'CHANGE' (avec ancien mot de passe, DPAPI preserve) ou 'RESET' (reinitialisation admin).
function Set-AccountPassword {
    param(
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][AllowEmptyString()][string]$New,
        [AllowNull()][string]$Old
    )
    if ($null -ne $Old) {
        try {
            $u = [ADSI]"WinNT://$env:COMPUTERNAME/$User,user"
            $u.ChangePassword($Old, $New)
            return 'CHANGE'
        } catch {
            Write-Log "ChangePassword a echoue ($($_.Exception.Message)), bascule sur reinitialisation" 'WARN'
        }
    }
    if ($New -eq '') { $secure = New-Object System.Security.SecureString }
    else { $secure = ConvertTo-SecureString $New -AsPlainText -Force }
    Set-LocalUser -Name $User -Password $secure
    return 'RESET'
}

# Banniere avant ecran de connexion. Ne contient jamais le mot de passe.
function Set-LogonBanner {
    param([string]$Text)
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    if ($Text) {
        Set-ItemProperty -Path $k -Name 'legalnoticecaption' -Value 'win-roll-lock'
        Set-ItemProperty -Path $k -Name 'legalnoticetext' -Value $Text
    } else {
        $cap = try { Get-ItemPropertyValue -Path $k -Name 'legalnoticecaption' } catch { $null }
        if ($cap -eq 'win-roll-lock') {
            Remove-ItemProperty -Path $k -Name 'legalnoticecaption' -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $k -Name 'legalnoticetext' -ErrorAction SilentlyContinue
        }
    }
}
