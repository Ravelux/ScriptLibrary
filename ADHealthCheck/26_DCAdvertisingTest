$ErrorActionPreference = "Continue"
$DCName = $env:COMPUTERNAME
$domain = (Get-ADDomain).DNSRoot

Write-Host "`n=== DC Advertising Check: $DCName ===" -ForegroundColor Cyan

# 1. Netlogon
Write-Host "`n[1] Netlogon-Dienst..." -ForegroundColor Yellow
try {
    $svc = Get-Service -Name "Netlogon"
    Write-Host "    Status   : $($svc.Status)"
    Write-Host "    Starttyp : $($svc.StartType)"
    $netlogonOK = $svc.Status -eq "Running"
} catch {
    Write-Warning "    Netlogon-Abfrage fehlgeschlagen: $_"
    $netlogonOK = $false
}

# 2. DCDiag Advertising
Write-Host "`n[2] DCDiag /test:Advertising..." -ForegroundColor Yellow
try {
    & dcdiag /test:Advertising 2>&1 | ForEach-Object { Write-Host "    $_" }
} catch {
    Write-Warning "    DCDiag fehlgeschlagen: $_"
}

# 3. SRV-Records
Write-Host "`n[3] DNS SRV-Records..." -ForegroundColor Yellow
$srvChecks = @(
    "_ldap._tcp.dc._msdcs.$domain",
    "_kerberos._tcp.dc._msdcs.$domain",
    "_gc._tcp.$domain",
    "_ldap._tcp.$domain"
)
foreach ($record in $srvChecks) {
    try {
        $result = Resolve-DnsName -Name $record -Type SRV -ErrorAction Stop
        if ($result | Where-Object { $_.NameTarget -like "*$DCName*" }) {
            Write-Host "    [OK] $record" -ForegroundColor Green
        } else {
            Write-Warning "    [FEHLT] $DCName nicht in $record"
        }
    } catch {
        Write-Warning "    [FEHLER] $record : $_"
    }
}

# Interaktive Abfrage
Write-Host ""
$answer = Read-Host "Bereinigung durchführen? Netlogon neu starten + dcdiag /fix ausführen (j/n)"

if ($answer -eq "j") {
    Write-Host "`n[AutoFix] Starte Netlogon neu..." -ForegroundColor Green
    try {
        Restart-Service -Name "Netlogon" -Force
        Write-Host "    Netlogon neu gestartet." -ForegroundColor Green
    } catch {
        Write-Warning "    Neustart fehlgeschlagen: $_"
    }

    Write-Host "`n[AutoFix] Führe dcdiag /fix aus..." -ForegroundColor Green
    try {
        & dcdiag /fix 2>&1 | ForEach-Object { Write-Host "    $_" }
    } catch {
        Write-Warning "    dcdiag /fix fehlgeschlagen: $_"
    }
} else {
    Write-Host "`nKeine Änderungen vorgenommen." -ForegroundColor Yellow
}

Write-Host "`n=== Abgeschlossen ===" -ForegroundColor Cyan