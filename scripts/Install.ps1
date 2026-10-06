# Install.ps1 : installe WinRollLock avec garde fous anti blocage
# S'auto-élève en administrateur AVANT toute autre chose.
[CmdletBinding()]
param(
    [string]$User = $env:USERNAME,
    [string]$Format = 'ddMM',
    [string]$Prefix = '',
    [string]$MasterCode = '',
    [string]$Root = 'C:\ProgramData\WinRollLock',
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

    if ([string]::IsNullOrEmpty($MasterCode)) {
        $MasterCode = Read-Host 'MasterCode'
        if ([string]::IsNullOrEmpty($MasterCode)) {
            Write-Host 'MasterCode is required. Aborting.' -ForegroundColor Red
            return 1
        }
    }

    $quotedSelf = '"' + $self + '"'
    $argsList = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File',       $quotedSelf
        '-User',       ('"' + $User       + '"')
        '-Format',     ('"' + $Format     + '"')
        '-MasterCode', ('"' + $MasterCode + '"')
        '-Root',       ('"' + $Root       + '"')
    )
    if ($Prefix)  { $argsList += @('-Prefix', ('"' + $Prefix + '"')) }
    if ($NoPause) { $argsList += '-NoPause' }
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

if ([string]::IsNullOrEmpty($MasterCode)) {
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

try {
    Write-Host '1/9 Verification du compte cible' -ForegroundColor Cyan
    $lu = Get-LocalUser -Name $User -ErrorAction Stop
    if ($lu.PrincipalSource -ne 'Local') { throw "Le compte $User n'est pas un compte local Windows (compte Microsoft non supporte)." }

    Write-Host '2/9 Verification d un administrateur de secours' -ForegroundColor Cyan
    $rescue = $null
    $members = Get-LocalGroupMember -SID 'S-1-5-32-544'
    foreach ($m in $members) {
        $name = ($m.Name -split '\\')[-1]
        $u = Get-LocalUser -Name $name -ErrorAction SilentlyContinue
        if ($u -and $u.Enabled -and $u.Name -ne $User) {
            $rescue = $u
            break
        }
    }

    if (-not $rescue) {
        Write-Host "Aucun autre administrateur local actif. Il en faut un, avec un mot de passe FIXE." -ForegroundColor Yellow
        $rn = Read-Host 'Nom du compte de secours a creer ou reparer (vide pour annuler)'
        if (-not $rn) { throw 'Installation annulee : pas de compte de secours.' }

        $existing = Get-LocalUser -Name $rn -ErrorAction SilentlyContinue

        if ($existing) {
            Write-Host "   Le compte '$rn' existe deja. Reparation..." -ForegroundColor Yellow

            if (-not $existing.Enabled) {
                Enable-LocalUser -Name $rn
                Write-Host '     - compte active' -ForegroundColor Green
            }

            $rp = Read-Host "Mot de passe FIXE pour '$rn'" -AsSecureString
            Set-LocalUser -Name $rn -Password $rp -PasswordNeverExpires $true
            Write-Host '     - mot de passe defini' -ForegroundColor Green

            $inAdmin = $false
            foreach ($m in (Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction SilentlyContinue)) {
                if ($m.Name -match "\\$([regex]::Escape($rn))$") { $inAdmin = $true; break }
            }
            if (-not $inAdmin) {
                Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $rn
                Write-Host '     - ajoute au groupe Administrateurs' -ForegroundColor Green
            } else {
                Write-Host '     - deja dans Administrateurs' -ForegroundColor Green
            }

            $rescue = Get-LocalUser -Name $rn
        } else {
            Write-Host "   Creation du compte '$rn'..." -ForegroundColor Cyan
            $rp = Read-Host "Mot de passe FIXE pour '$rn'" -AsSecureString
            New-LocalUser -Name $rn -Password $rp -PasswordNeverExpires -Description 'Secours WinRollLock' | Out-Null
            Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $rn
            $rescue = Get-LocalUser -Name $rn
            Write-Host '     - compte cree et ajoute aux Administrateurs' -ForegroundColor Green
        }
    }

    Write-Host "   Compte de secours : $($rescue.Name)"

    Write-Host '3/9 Verification BitLocker' -ForegroundColor Cyan
    $bl = (& manage-bde -status $env:SystemDrive 2>$null) -join "`n"
    if ($bl -match 'Protection On|Protection activ') {
        Write-Host 'BitLocker est actif. La cle de recuperation doit etre sauvegardee AVANT de continuer.' -ForegroundColor Yellow
        if ((Read-Host 'Cle de recuperation sauvegardee ? Tape OUI') -ne 'OUI') { throw 'Installation annulee.' }
    }

    Write-Host '4/9 Mot de passe actuel du compte' -ForegroundColor Cyan
    $cur = ConvertTo-Plain (Read-Host "Mot de passe actuel de $User (vide si aucun)" -AsSecureString)
    if ($cur -ne '' -and -not (Test-LocalCredential -User $User -Password $cur)) { throw 'Mot de passe actuel incorrect.' }

    Write-Host '5/9 Copie des fichiers et config' -ForegroundColor Cyan
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

    Write-Host '6/9 Essai a blanc (rien n est modifie)' -ForegroundColor Cyan
    $dry = & (Join-Path $Root 'src\Update-RollingPass.ps1') -DryRun -Root $Root
    $dry | Format-List
    if ((Read-Host 'Le mot de passe cible est correct ? Tape OUI') -ne 'OUI') { throw 'Installation annulee apres essai a blanc.' }

    Write-Host '7/9 Strategie de securite locale' -ForegroundColor Cyan
    $orig = Get-SecPolicyValues
    $orig | ConvertTo-Json | Set-Content (Join-Path $Root 'policy_original.json') -Encoding UTF8
    Set-RollingPolicy

    Write-Host '8/9 Etat initial et tache planifiee' -ForegroundColor Cyan
    Save-State @{ User = $User; Password = $cur; Mode = 'INIT'; Updated = (Get-Date).ToString('o') }

    $ps  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $scr = Join-Path $Root 'src\Update-RollingPass.ps1'

    $q1raw = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-Power-Troubleshooter''] and EventID=1]]</Select></Query></QueryList>'
    $q2raw = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-Kernel-Power''] and EventID=107]]</Select></Query></QueryList>'
    $q3raw = '<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"><Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[EventID=10000]]</Select></Query></QueryList>'

    $q1 = [System.Security.SecurityElement]::Escape($q1raw)
    $q2 = [System.Security.SecurityElement]::Escape($q2raw)
    $q3 = [System.Security.SecurityElement]::Escape($q3raw)

    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>WinRollLock : mot de passe tournant</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled></BootTrigger>
    <CalendarTrigger><StartBoundary>2026-01-01T00:00:01</StartBoundary><Enabled>true</Enabled><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger>
    <EventTrigger><Enabled>true</Enabled><Delay>PT5S</Delay><Subscription>$q1</Subscription></EventTrigger>
    <EventTrigger><Enabled>true</Enabled><Delay>PT5S</Delay><Subscription>$q2</Subscription></EventTrigger>
    <EventTrigger><Enabled>true</Enabled><Delay>PT10S</Delay><Subscription>$q3</Subscription></EventTrigger>
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
    Register-ScheduledTask -TaskName 'WinRollLock' -Xml $xml -Force | Out-Null

    Write-Host '9/9 Premiere execution' -ForegroundColor Cyan
    & $ps -NoProfile -ExecutionPolicy Bypass -File $scr
    Get-Content (Join-Path $Root 'log.txt') -Tail 5
    Write-Host "Termine. Compte de secours : $($rescue.Name). Teste avec Win+L avant de redemarrer." -ForegroundColor Green
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