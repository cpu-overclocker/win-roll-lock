#Requires -RunAsAdministrator
# Install.ps1 : installe WinRollLock avec garde fous anti blocage
[CmdletBinding()]
param(
    [string]$User = $env:USERNAME,
    [string]$Format = 'ddMM',
    [string]$Prefix = '',
    [Parameter(Mandatory)][string]$MasterCode,
    [string]$Root = 'C:\ProgramData\WinRollLock'
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

Write-Host '1/9 Verification du compte cible' -ForegroundColor Cyan
$lu = Get-LocalUser -Name $User -ErrorAction Stop
if ($lu.PrincipalSource -ne 'Local') { throw "Le compte $User n'est pas un compte local Windows (compte Microsoft non supporte)." }

Write-Host '2/9 Verification d un administrateur de secours' -ForegroundColor Cyan
$rescue = Get-LocalGroupMember -SID 'S-1-5-32-544' |
    Where-Object { $_.ObjectClass -eq 'User' -and $_.PrincipalSource -eq 'Local' } |
    ForEach-Object { Get-LocalUser -Name (($_.Name -split '\\')[-1]) } |
    Where-Object { $_.Enabled -and $_.Name -ne $User } |
    Select-Object -First 1
if (-not $rescue) {
    Write-Host "Aucun autre administrateur local actif. Il en faut un, avec un mot de passe FIXE, hors du systeme tournant." -ForegroundColor Yellow
    $rn = Read-Host 'Nom du compte de secours a creer (vide pour annuler)'
    if (-not $rn) { throw 'Installation annulee : pas de compte de secours.' }
    $rp = Read-Host 'Mot de passe fixe du compte de secours' -AsSecureString
    New-LocalUser -Name $rn -Password $rp -PasswordNeverExpires -Description 'Secours WinRollLock' | Out-Null
    Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $rn
    $rescue = Get-LocalUser -Name $rn
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
$q1 = '&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name=''Microsoft-Windows-Power-Troubleshooter''] and EventID=1]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;'
$q2 = '&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name=''Microsoft-Windows-Kernel-Power''] and EventID=107]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;'
$q3 = '&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"&gt;&lt;Select Path="Microsoft-Windows-NetworkProfile/Operational"&gt;*[System[EventID=10000]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;'
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
