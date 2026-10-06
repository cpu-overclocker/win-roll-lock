# Update-RollingPass.ps1 : coeur du systeme (heure fiable, decision, mot de passe, banniere)
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$Root
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Time-Sync.ps1')
Set-WRLRoot $Root

$mutex = New-Object System.Threading.Mutex($false, 'Global\WinRollLock')
$have  = $false
try {
    $have = $mutex.WaitOne(90000)
    if (-not $have) { Write-Log 'Mutex non obtenu, abandon' 'WARN'; exit 2 }

    $cfg = Get-Content (Get-WRLPath 'config.json') -Raw | ConvertFrom-Json

    # Dernier instant valide connu
    $lastPath  = Get-WRLPath 'last_known_time.txt'
    $lastKnown = $null
    if (Test-Path $lastPath) {
        try {
            $raw = (Get-Content $lastPath -Raw).Trim()
            $lastKnown = [datetime]::Parse($raw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        } catch { Write-Log "last_known_time.txt illisible: $($_.Exception.Message)" 'WARN' }
    }

    # Niveau 1 : reseau
    $net    = Get-NetworkTimeUtc -NtpServers @($cfg.NtpServers)
    $sysUtc = (Get-Date).ToUniversalTime()
    $netUtc = $null
    if ($net) { $netUtc = $net.Utc }

    # Niveaux 2 et 3 : decision
    $d = Resolve-TimeDecision -NetworkUtc $netUtc -SystemUtc $sysUtc -LastKnownUtc $lastKnown -MinYear ([int]$cfg.MinYear)

    # Mise a l'heure Windows si ecart important et heure reseau fiable
    if ($d.Mode -eq 'SYNC' -and ([math]::Abs(($sysUtc - $netUtc).TotalSeconds) -gt 120) -and -not $DryRun) {
        try {
            Set-Date -Date ([TimeZoneInfo]::ConvertTimeFromUtc($netUtc, [TimeZoneInfo]::Local)) | Out-Null
            Write-Log "Horloge Windows recalee via $($net.Source)"
        } catch { Write-Log "Set-Date a echoue: $($_.Exception.Message)" 'WARN' }
    }

    # Mot de passe cible
    if ($d.Mode -eq 'FALLBACK') {
        $target = [string]$cfg.MasterCode
    } else {
        $localNow = [TimeZoneInfo]::ConvertTimeFromUtc($d.Utc, [TimeZoneInfo]::Local)
        $target   = Get-RollingPassword -LocalDate $localNow -Format ([string]$cfg.Format) -Prefix ([string]$cfg.Prefix)
    }

    # Banniere (Niveau 4)
    $banner = $null
    if ([bool]$cfg.Banner) {
        switch ($d.Mode) {
            'FALLBACK'   { $banner = 'CMOS error: fallback mode active.' }
            'OFFLINE_OK' { $banner = 'Offline: date not verified by the network.' }
            default      { $banner = $null }
        }
    }
    if ($DryRun) {
        [pscustomobject]@{ Mode = $d.Mode; Reason = $d.Reason; Source = $(if ($net) { $net.Source } else { 'aucune' }); PasswordCible = $target; Banniere = $banner }
        return
    }

    # Journal du dernier instant valide (jamais ecrit en mode FALLBACK)
    if ($d.Mode -ne 'FALLBACK') {
        if ($d.Mode -eq 'SYNC' -or $null -eq $lastKnown -or $d.Utc -gt $lastKnown) {
            Set-Content -Path $lastPath -Value $d.Utc.ToString('o') -Encoding ASCII
        }
    }

    # Application du mot de passe
    $state = Read-State
    if ($state -and ($state.User -eq $cfg.User) -and ($state.Password -eq $target)) {
        Write-Log "Mode $($d.Mode): mot de passe deja a jour"
    } else {
        $old = $null
        if ($state -and ($state.User -eq $cfg.User)) { $old = [string]$state.Password }
        $how = Set-AccountPassword -User $cfg.User -New $target -Old $old
        $ok  = Test-LocalCredential -User $cfg.User -Password $target
        if (-not $ok -and $how -eq 'CHANGE') {
            Write-Log 'Verification KO apres ChangePassword, reinitialisation' 'WARN'
            $how = Set-AccountPassword -User $cfg.User -New $target -Old $null
            $ok  = Test-LocalCredential -User $cfg.User -Password $target
        }
        Save-State @{ User = [string]$cfg.User; Password = $target; Mode = $d.Mode; Updated = (Get-Date).ToString('o') }
        $lvl = if ($ok) { 'INFO' } else { 'WARN' }
        Write-Log "Mode $($d.Mode) ($($d.Reason)), methode $how, verifie=$ok" $lvl
    }

    Set-LogonBanner -Text $banner
    exit 0
}
catch {
    Write-Log "ERREUR: $($_.Exception.Message)" 'ERROR'
    exit 1
}
finally {
    if ($have) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
