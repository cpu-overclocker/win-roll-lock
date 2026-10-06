# Time-Sync.ps1 : heure reseau + decision de confiance (fonctions pures testables)
Set-StrictMode -Version 2.0

function Get-NtpTime {
    param([string]$Server = 'pool.ntp.org', [int]$TimeoutMs = 2000)
    $udp = $null
    try {
        $data = New-Object byte[] 48
        $data[0] = 0x1B
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Client.SendTimeout    = $TimeoutMs
        $udp.Connect($Server, 123)
        [void]$udp.Send($data, 48)
        $ep   = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $resp = $udp.Receive([ref]$ep)
        $secs = [BitConverter]::ToUInt32(@($resp[43], $resp[42], $resp[41], $resp[40]), 0)
        $frac = [BitConverter]::ToUInt32(@($resp[47], $resp[46], $resp[45], $resp[44]), 0)
        $ms   = ([double]$secs * 1000.0) + ([double]$frac * 1000.0 / 4294967296.0)
        $epoch = New-Object DateTime 1900, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
        return $epoch.AddMilliseconds($ms)
    } catch {
        return $null
    } finally {
        if ($udp) { $udp.Close() }
    }
}

# Lecture de l'en-tete HTTP Date. La validation du certificat est ignoree pour cette seule
# lecture, car avec une pile CMOS morte la date systeme fausse invalide tous les certificats.
function Get-HttpTime {
    param([string[]]$Urls = @('https://1.1.1.1', 'https://www.microsoft.com'), [int]$TimeoutMs = 2000)

    if (-not ('WRLTrust' -as [type])) {
        Add-Type -TypeDefinition @"
using System.Net.Security;
public static class WRLTrust {
    public static RemoteCertificateValidationCallback Callback = delegate { return true; };
}
"@
    }

    $previous = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = [WRLTrust]::Callback
        foreach ($u in $Urls) {
            $resp = $null
            try {
                $req = [System.Net.HttpWebRequest]::Create($u)
                $req.Method = 'HEAD'
                $req.Timeout = $TimeoutMs
                $req.AllowAutoRedirect = $false
                try { $resp = $req.GetResponse() }
                catch [System.Net.WebException] { $resp = $_.Exception.Response }
                if ($resp) {
                    $h = $resp.Headers['Date']
                    if ($h) {
                        $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
                        $t = [datetime]::Parse($h, [System.Globalization.CultureInfo]::InvariantCulture, $styles)
                        return [pscustomobject]@{ Utc = $t; Url = $u }
                    }
                }
            } catch { } finally { if ($resp) { $resp.Close() } }
        }
        return $null
    } finally {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previous
    }
}

# Niveau 1 : reseau. Retourne @{ Utc; Source } ou $null.
function Get-NetworkTimeUtc {
    param([string[]]$NtpServers = @('pool.ntp.org', 'time.cloudflare.com', 'time.windows.com'), [int]$TimeoutMs = 2000)
    if (-not [System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()) { return $null }
    foreach ($s in $NtpServers) {
        $t = Get-NtpTime -Server $s -TimeoutMs $TimeoutMs
        if ($t) { return [pscustomobject]@{ Utc = $t; Source = "NTP:$s" } }
    }
    $h = Get-HttpTime -TimeoutMs $TimeoutMs
    if ($h) { return [pscustomobject]@{ Utc = $h.Utc; Source = "HTTP:$($h.Url)" } }
    return $null
}

# Niveaux 2 et 3 : decision pure (aucun acces systeme, donc testable).
# Modes : SYNC (heure reseau), OFFLINE_OK (horloge locale coherente), FALLBACK (horloge corrompue).
function Resolve-TimeDecision {
    param(
        $NetworkUtc,
        [Parameter(Mandatory)][datetime]$SystemUtc,
        $LastKnownUtc,
        [int]$MinYear = 2000,
        [int]$ToleranceMinutes = 5
    )
    if ($null -ne $NetworkUtc) {
        return [pscustomobject]@{ Mode = 'SYNC'; Utc = ([datetime]$NetworkUtc); Reason = 'Heure reseau obtenue' }
    }
    if ($null -ne $LastKnownUtc) {
        if ($SystemUtc -lt ([datetime]$LastKnownUtc).AddMinutes(-$ToleranceMinutes)) {
            return [pscustomobject]@{ Mode = 'FALLBACK'; Utc = $SystemUtc; Reason = 'Horloge en retard sur le dernier instant valide' }
        }
    } elseif ($SystemUtc.Year -lt $MinYear) {
        return [pscustomobject]@{ Mode = 'FALLBACK'; Utc = $SystemUtc; Reason = "Aucun historique et annee < $MinYear" }
    }
    return [pscustomobject]@{ Mode = 'OFFLINE_OK'; Utc = $SystemUtc; Reason = 'Hors ligne, horloge coherente' }
}

function Get-RollingPassword {
    param([Parameter(Mandatory)][datetime]$LocalDate, [string]$Format = 'ddMM', [string]$Prefix = '')
    return $Prefix + $LocalDate.ToString($Format, [System.Globalization.CultureInfo]::InvariantCulture)
}
