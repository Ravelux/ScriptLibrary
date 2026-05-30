<#
.SYNOPSIS
    Prueft und behebt das Finding "DNS Server Forwarder count" aus dem ADHealth-Check.

.DESCRIPTION
    Der Report prueft:
      $VariableProperty.DNS.ServerForwarder.IPAddress
      Finding aktiv wenn: count -gt 3 ODER count -le 1
      Zielzustand: genau 2 Forwarder

    Bei Bereinigung werden folgende Forwarder gesetzt:
      Primaer  : 1.1.1.1 (Cloudflare)
      Sekundaer: 8.8.8.8 (Google)

    Ninja Script Variable:
      bereinigung  (Checkbox)
        Nicht gesetzt : Nur Analyse
        Gesetzt       : Forwarder werden auf 1.1.1.1 und 8.8.8.8 gesetzt

    Voraussetzungen:
      - Administratorrechte
      - DnsServer-Modul (DNS-Rolle oder RSAT)
      - Ausfuehrung direkt auf dem DNS-Server / Domain Controller
#>

#region ── Pfade und Log-Initialisierung ─────────────────────────────────────

$timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$baseDir   = 'C:\ProgramData\TechboldADHealth\DNSForwarderCount'
$backupDir = "$baseDir\Backup_$timestamp"
$logFile   = "$baseDir\Log_$timestamp.txt"

foreach ($dir in @($baseDir, $backupDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

#endregion

#region ── Ziel-Forwarder ────────────────────────────────────────────────────
# Primaer : 1.1.1.1 (Cloudflare)
# Sekundaer: 8.8.8.8 (Google)

$targetForwarders = @('1.1.1.1', '8.8.8.8')

#endregion

#region ── Ninja-Variable einlesen ───────────────────────────────────────────
# Checkbox liefert den String 'true' (angehakt) oder 'false' (nicht angehakt).
# Variablenname im Ninja-Editor: bereinigung

$remediateMode = ($env:bereinigung -eq 'true')

Write-Log "========================================"
Write-Log "  Techbold ADHealth - DNS Server Forwarder Count"
Write-Log "========================================"
Write-Log "Computer       : $env:COMPUTERNAME"
Write-Log "Modus          : $(if ($remediateMode) { 'REMEDIATION (Aenderungen aktiv)' } else { 'READ-ONLY (keine Aenderungen)' })"
Write-Log "Ziel-Forwarder : $($targetForwarders -join ', ')"
Write-Log "Log-Datei      : $logFile"
if ($remediateMode) {
    Write-Log "Backup-Dir     : $backupDir"
}
Write-Log ""

#endregion

#region ── Modulpruefung + Admincheck ────────────────────────────────────────

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "Skript muss als Administrator ausgefuehrt werden." 'ERROR'
    exit 1
}

try {
    Import-Module DnsServer -ErrorAction Stop
}
catch {
    Write-Log "DnsServer-Modul nicht verfuegbar: $($_.Exception.Message)" 'ERROR'
    exit 1
}

#endregion

#region ── Analyse ───────────────────────────────────────────────────────────

Write-Log "---- Analyse ----"

try {
    $currentForwarders = Get-DnsServerForwarder -ErrorAction Stop
    $forwarderIPs      = @($currentForwarders.IPAddress | Where-Object { $_ })
    $forwarderCount    = $forwarderIPs.Count
}
catch {
    Write-Log "DNS-Forwarder konnten nicht abgefragt werden: $($_.Exception.Message)" 'ERROR'
    exit 1
}

Write-Log "Anzahl Forwarder aktuell : $forwarderCount"
if ($forwarderCount -eq 0) {
    Write-Log "  (keine Forwarder konfiguriert)"
}
else {
    foreach ($ip in $forwarderIPs) {
        Write-Log "  - $ip"
    }
}
Write-Log ""

# Report-Logik: Finding aktiv wenn count -gt 3 ODER count -le 1
$findingActive = ($forwarderCount -gt 3) -or ($forwarderCount -le 1)

if ($forwarderCount -eq 0) {
    Write-Log "ERGEBNIS: Keine Forwarder konfiguriert. Finding aktiv." 'WARN'
}
elseif ($forwarderCount -eq 1) {
    Write-Log "ERGEBNIS: Nur 1 Forwarder konfiguriert - kein Fallback vorhanden. Finding aktiv." 'WARN'
}
elseif ($forwarderCount -gt 3) {
    Write-Log "ERGEBNIS: $forwarderCount Forwarder konfiguriert - zu viele. Finding aktiv." 'WARN'
}
else {
    Write-Log "ERGEBNIS: Forwarder-Anzahl ($forwarderCount) ist im gueltigen Bereich (2-3)."
    Write-Log "Finding 'DNS Server Forwarder count' ist nicht vorhanden oder bereits behoben."
    Write-Log "Log gespeichert: $logFile"
    exit 0
}

# Aktuellen Zustand als CSV sichern
[PSCustomObject]@{
    Timestamp = $timestamp
    Count     = $forwarderCount
    IPs       = ($forwarderIPs -join ', ')
} | Export-Csv "$baseDir\ForwarderCheck_$timestamp.csv" -NoTypeInformation -Encoding UTF8

Write-Log ""

#endregion

#region ── Remediation ───────────────────────────────────────────────────────

Write-Log "---- Remediation ----"

if (-not $remediateMode) {
    Write-Log "Read-Only-Modus: Ninja-Checkbox 'bereinigung' ist nicht gesetzt."
    Write-Log ""
    Write-Log "Geplante Aktionen bei Bereinigung:"
    Write-Log "  1. Registry-Backup der DNS-Konfiguration erstellen"
    Write-Log "  2. Alle bestehenden Forwarder entfernen ($($forwarderIPs -join ', '))"
    Write-Log "  3. Forwarder setzen: $($targetForwarders -join ', ')"
    Write-Log "  4. Abschlusspruefung"
    Write-Log ""
    Write-Log "Log gespeichert: $logFile"
    exit 0
}

# Backup
Write-Log "Erstelle Backup der aktuellen DNS-Konfiguration..."
try {
    $regPath = 'HKLM\SYSTEM\CurrentControlSet\Services\DNS\Parameters'
    $regFile = "$backupDir\Registry_DNS_Parameters.reg"
    reg export $regPath $regFile /y 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Registry-Backup gespeichert: $regFile"
    }
    else {
        Write-Log "Registry-Export nicht moeglich (uebersprungen)." 'WARN'
    }

    $currentForwarders | Export-Clixml "$backupDir\Forwarders_PreRemediation.xml" -Force
    Write-Log "Forwarder-Backup gespeichert: $backupDir\Forwarders_PreRemediation.xml"
}
catch {
    Write-Log "Backup fehlgeschlagen: $($_.Exception.Message)" 'WARN'
}

$errors = @()

# Schritt 1: Alle bestehenden Forwarder entfernen
Write-Log "Remediation Schritt 1: Bestehende Forwarder entfernen..."
try {
    Set-DnsServerForwarder -IPAddress @() -ErrorAction Stop
    Write-Log "Bestehende Forwarder entfernt."
}
catch {
    # Fallback: einzeln entfernen
    Write-Log "Bulk-Entfernung fehlgeschlagen, versuche einzeln: $($_.Exception.Message)" 'WARN'
    try {
        if ($forwarderIPs.Count -gt 0) {
            Remove-DnsServerForwarder -IPAddress $forwarderIPs -Force -ErrorAction Stop
            Write-Log "Forwarder einzeln entfernt."
        }
    }
    catch {
        Write-Log "Forwarder entfernen fehlgeschlagen: $($_.Exception.Message)" 'ERROR'
        $errors += "Forwarder entfernen: $($_.Exception.Message)"
    }
}

# Schritt 2: Ziel-Forwarder setzen
Write-Log "Remediation Schritt 2: Forwarder setzen ($($targetForwarders -join ', '))..."
try {
    Set-DnsServerForwarder -IPAddress $targetForwarders -ErrorAction Stop
    Write-Log "Forwarder erfolgreich gesetzt: $($targetForwarders -join ', ')"
}
catch {
    Write-Log "Forwarder setzen fehlgeschlagen: $($_.Exception.Message)" 'ERROR'
    $errors += "Forwarder setzen: $($_.Exception.Message)"
}

#endregion

#region ── Abschluss-Check ───────────────────────────────────────────────────

Write-Log ""
Write-Log "---- Abschlusspruefung ----"

try {
    $forwardersAfter = Get-DnsServerForwarder -ErrorAction Stop
    $ipsAfter        = @($forwardersAfter.IPAddress | Where-Object { $_ })
    $countAfter      = $ipsAfter.Count

    Write-Log "Forwarder-Anzahl nach Remediation: $countAfter"
    foreach ($ip in $ipsAfter) {
        Write-Log "  - $ip"
    }

    # DNS-Aufloesung testen
    Write-Log ""
    Write-Log "DNS-Aufloesung testen..."
    foreach ($testDomain in @('google.com', 'microsoft.com')) {
        try {
            $result = Resolve-DnsName -Name $testDomain -Type A -ErrorAction Stop | Select-Object -First 1
            Write-Log "  OK    : $testDomain -> $($result.IPAddress)"
        }
        catch {
            Write-Log "  FEHLER: $testDomain konnte nicht aufgeloest werden: $($_.Exception.Message)" 'WARN'
        }
    }

    $findingAfter = ($countAfter -gt 3) -or ($countAfter -le 1)
    Write-Log ""
    if (-not $findingAfter) {
        Write-Log "Abschlusspruefung OK: Finding 'DNS Server Forwarder count' ist behoben."
    }
    else {
        Write-Log "Finding noch aktiv: Forwarder-Anzahl $countAfter entspricht nicht dem Zielwert." 'WARN'
    }
}
catch {
    Write-Log "Abschlusspruefung fehlgeschlagen: $($_.Exception.Message)" 'WARN'
}

#endregion

#region ── Zusammenfassung ───────────────────────────────────────────────────

Write-Log ""
Write-Log "========================================"
Write-Log "  Zusammenfassung"
Write-Log "========================================"
Write-Log "Forwarder vorher : $forwarderCount ($($forwarderIPs -join ', '))"
try {
    $finalIPs = @((Get-DnsServerForwarder).IPAddress | Where-Object { $_ })
    Write-Log "Forwarder nachher: $($finalIPs.Count) ($($finalIPs -join ', '))"
}
catch {
    Write-Log "Forwarder nachher: (nicht abfragbar)"
}

if ($errors.Count -gt 0) {
    Write-Log "Fehler:" 'WARN'
    foreach ($e in $errors) { Write-Log "  - $e" 'WARN' }
}

Write-Log ""
Write-Log "Log gespeichert    : $logFile"
if ($remediateMode) {
    Write-Log "Backups gespeichert: $backupDir"
}
Write-Log "Fertig."

#endregion
