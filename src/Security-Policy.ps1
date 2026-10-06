# Security-Policy.ps1 : strategie de mot de passe locale via secedit
Set-StrictMode -Version 2.0

$script:PolicyKeys = @('MinimumPasswordAge', 'MaximumPasswordAge', 'MinimumPasswordLength', 'PasswordComplexity', 'PasswordHistorySize')

function Get-SecPolicyValues {
    $tmp = [IO.Path]::GetTempFileName()
    try {
        secedit /export /cfg $tmp /areas SECURITYPOLICY /quiet | Out-Null
        $lines = Get-Content $tmp
        $res = @{}
        foreach ($k in $script:PolicyKeys) {
            $m = $lines | Select-String -Pattern "^\s*$k\s*=\s*(-?\d+)" | Select-Object -First 1
            if ($m) { $res[$k] = [int]$m.Matches[0].Groups[1].Value }
        }
        return $res
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

function Set-SecPolicyValues {
    param([Parameter(Mandatory)][hashtable]$Values)
    $tmp = [IO.Path]::GetTempFileName()
    $db  = [IO.Path]::GetTempFileName()
    try {
        secedit /export /cfg $tmp /areas SECURITYPOLICY /quiet | Out-Null
        $c = @(Get-Content $tmp)
        foreach ($k in $Values.Keys) {
            $line = "$k = $($Values[$k])"
            $exists = @($c | Where-Object { $_ -match "^\s*$k\s*=" }).Count -gt 0
            if ($exists) {
                $c = $c | ForEach-Object { if ($_ -match "^\s*$k\s*=") { $line } else { $_ } }
            } else {
                $c = $c | ForEach-Object { $_; if ($_ -match '^\[System Access\]') { $line } }
            }
        }
        Set-Content -Path $tmp -Value $c -Encoding Unicode
        Remove-Item $db -Force -ErrorAction SilentlyContinue
        secedit /configure /db $db /cfg $tmp /areas SECURITYPOLICY /quiet | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "secedit /configure a echoue (code $LASTEXITCODE)" }
    } finally {
        Remove-Item $tmp, $db -Force -ErrorAction SilentlyContinue
    }
}

function Set-RollingPolicy {
    Set-SecPolicyValues @{
        PasswordComplexity    = 0
        MinimumPasswordLength = 0
        MaximumPasswordAge    = -1
        MinimumPasswordAge    = 0
        PasswordHistorySize   = 0
    }
}
