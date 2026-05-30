<#
.SYNOPSIS
    Prueft und behebt das Finding "DNS SRV Records" aus dem ADHealth-Check.

.DESCRIPTION
    Der Report prueft ob der Domain Controller in den LDAP SRV-Records
    (_ldap._tcp.dc._msdcs.<domain>) eingetragen ist. Fehlt der Eintrag,
    wird das Finding ausgeloest.

    Dieses Skript:
      1. Prueft alle relevanten SRV-Records fuer diesen DC
      2. Prueft Netlogon-Dienst (Status + Starttyp)
      3. Prueft DNS-Dienst (Status)
      4. Prueft ob die DNS-Zone fuer die Domain erreichbar ist
      5. Zeigt detailliert welche Records vorhanden sind und welche fehlen

    Mit Ninja-Checkbox "bereinigung" werden folgende Korrekturen ausgefuehrt:
      - Netlogon-Dienst auf Automatic setzen und neu starten
        (Netlogon-Neustart erzwingt automatische SRV-Record-Registrierung)
      - DNS-Registrierung via nltest /dsregdns erzwingen
      - DNS-Client-Registrierung via ipconfig /registerdns
      - Abschlusspruefung aller SRV-Records

    HINWEIS:
      Sind die Records nach der Remediation immer noch fehlend, liegen
      tiefere Ursachen vor (DNS-Zone fehlt, AD-Replikation, Berechtigungen
      auf der DNS-Zone). Das Skript weist gezielt darauf hin.

    Ninja Script Variable:
      bereinigung  (Checkbox)
        Nicht gesetzt : Nur Analyse
        Gesetzt       : Korrekturen werden ausgefuehrt

    Voraussetzungen:
      - Administratorrechte
      - Ausfuehrung direkt auf dem betroffenen Domain Controller
#>

#region ── Pfade und Log-Initialisierung ─────────────────────────────────────

$timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$baseDir   = 'C:\ProgramData\TechboldADHealth\DNSSRVRecords'
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

#region ── Ninja-Variable einlesen ───────────────────────────────────────────
# Checkbox liefert den String 'true' (angehakt) oder 'false' (nicht angehakt).
# Variablenname im Ninja-Editor: bereinigung

$remediateMode = ($env:bereinigung -eq 'true')

Write-Log "========================================"
Write-Log "  Techbold ADHealth - DNS SRV Records"
Write-Log "========================================"
Write-Log "Computer  : $env:COMPUTERNAME"
Write-Log "Modus     : $(if ($remediateMode) { 'REMEDIATION (Aenderungen aktiv)' } else { 'READ-ONLY (keine Aenderungen)' })"
Write-Log "Log-Datei : $logFile"
if ($remediateMode) {
    Write-Log "Backup-Dir: $backupDir"
}
Write-Log ""

#endregion

#region ── Adminpruefung + DC-Validierung ────────────────────────────────────

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "Skript muss als Administrator ausgefuehrt werden." 'ERROR'
    exit 1
}

try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $dcInfo = Get-ADDomainController -Identity $env:COMPUTERNAME -ErrorAction Stop
    $domain = (Get-ADDomain).DNSRoot
    $dcFQDN = $dcInfo.HostName
    Write-Log "Domain    : $domain"
    Write-Log "DC-FQDN   : $dcFQDN"
    Write-Log ""
}
catch {
    Write-Log "Dieser Server ist kein Domain Controller oder das AD-Modul fehlt: $($_.Exception.Message)" 'ERROR'
    exit 1
}

#endregion

#region ── Backup-Funktion ───────────────────────────────────────────────────

function Backup-NetlogonRegistry {
    Write-Log "Erstelle Registry-Backup (Netlogon + DNS-Client)..."
    $regPaths = @(
        @{ Name = 'Netlogon_Parameters'; Path = 'HKLM\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters' }
        @{ Name = 'Netlogon_Service';    Path = 'HKLM\SYSTEM\CurrentControlSet\Services\Netlogon' }
        @{ Name = 'DNS_Client';          Path = 'HKLM\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' }
    )
    foreach ($reg in $regPaths) {
        $outFile = "$backupDir\Registry_$($reg.Name).reg"
        reg export $reg.Path $outFile /y 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Backup gespeichert: $outFile"
        }
        else {
            Write-Log "Registry-Pfad '$($reg.Path)' nicht exportierbar (wird uebersprungen)." 'WARN'
        }
    }
}

#endregion

#region ── SRV-Record-Prueffunktion ──────────────────────────────────────────

function Test-SRVRecord {
    param([string]$RecordName, [string]$DCName)
    try {
        $result = Resolve-DnsName -Name $RecordName -Type SRV -ErrorAction Stop
        $dcMatch = $result | Where-Object {
            $_.NameTarget -and $_.NameTarget -match [regex]::Escape($DCName)
        }
        return [PSCustomObject]@{
            Record   = $RecordName
            Found    = $true
            DCInRecord = ($null -ne $dcMatch)
            Targets  = ($result | Where-Object { $_.NameTarget } | Select-Object -ExpandProperty NameTarget) -join ', '
        }
    }
    catch {
        return [PSCustomObject]@{
            Record     = $RecordName
            Found      = $false
            DCInRecord = $false
            Targets    = "Fehler: $($_.Exception.Message)"
        }
    }
}

#endregion

#region ── Analyse ───────────────────────────────────────────────────────────

Write-Log "---- Analyse ----"

# Die vom Report geprueften Records (ldapRR = _ldap._tcp.dc._msdcs)
# plus alle weiteren relevanten SRV-Records
$srvRecords = @(
    "_ldap._tcp.dc._msdcs.$domain"          # Hauptpruefung im Report
    "_ldap._tcp.$domain"                     # Allgemeiner LDAP
    "_kerberos._tcp.dc._msdcs.$domain"       # Kerberos DC-spezifisch
    "_kerberos._tcp.$domain"                 # Allgemeiner Kerberos
    "_kerberos._udp.$domain"                 # Kerberos UDP
    "_gc._tcp.$domain"                       # Global Catalog (nur wenn GC)
    "_ldap._tcp.pdc._msdcs.$domain"          # PDC (nur wenn PDC-Emulator)
)

# Global Catalog und PDC-Status ermitteln
$isGC  = $dcInfo.IsGlobalCatalog
$isPDC = ($dcInfo.OperationMasterRoles -contains 'PDCEmulator')
Write-Log "IsGlobalCatalog : $isGC"
Write-Log "IsPDC-Emulator  : $isPDC"
Write-Log ""

# SRV-Records pruefen
Write-Log "Schritt 1: SRV-Record-Pruefung..."
$srvResults  = @()
$missingRecords = @()

foreach ($record in $srvRecords) {
    # GC-Record nur pruefen wenn DC ein GC ist
    if ($record -match '_gc\._tcp' -and -not $isGC) {
        Write-Log "  SKIP   : $record (DC ist kein Global Catalog)"
        continue
    }
    # PDC-Record nur pruefen wenn DC PDC-Emulator ist
    if ($record -match 'pdc\._msdcs' -and -not $isPDC) {
        Write-Log "  SKIP   : $record (DC ist nicht PDC-Emulator)"
        continue
    }

    $res = Test-SRVRecord -RecordName $record -DCName $env:COMPUTERNAME
    $srvResults += $res

    if (-not $res.Found) {
        Write-Log "  FEHLER : $record - Zone/Record nicht aufloesbar" 'WARN'
        $missingRecords += $record
    }
    elseif (-not $res.DCInRecord) {
        Write-Log "  FEHLT  : $($env:COMPUTERNAME) nicht in $record (vorhandene Targets: $($res.Targets))" 'WARN'
        $missingRecords += $record
    }
    else {
        Write-Log "  OK     : $record -> $($env:COMPUTERNAME) gefunden"
    }
}

# SRV-Ergebnis als CSV sichern
$srvResults | Export-Csv "$baseDir\SRVCheck_$timestamp.csv" -NoTypeInformation -Encoding UTF8
Write-Log ""
Write-Log "SRV-Ergebnisse gespeichert: $baseDir\SRVCheck_$timestamp.csv"

# Kritischer Record fuer Report-Finding
$ldapDCRecord    = "_ldap._tcp.dc._msdcs.$domain"
$ldapDCResult    = $srvResults | Where-Object { $_.Record -eq $ldapDCRecord }
$reportFindingOK = $ldapDCResult -and $ldapDCResult.DCInRecord

Write-Log ""
if ($reportFindingOK) {
    Write-Log "ERGEBNIS Report-Finding: OK - DC ist in '$ldapDCRecord' eingetragen."
    Write-Log "Finding 'DNS SRV Records' ist nicht vorhanden oder bereits behoben."
    Write-Log "Log gespeichert: $logFile"
    exit 0
}
else {
    Write-Log "ERGEBNIS Report-Finding: FEHLER - DC fehlt in '$ldapDCRecord'." 'WARN'
    Write-Log "Finding 'DNS SRV Records' ist vorhanden." 'WARN'
}

Write-Log ""
Write-Log "Fehlende Records ($($missingRecords.Count)):"
foreach ($mr in $missingRecords) { Write-Log "  - $mr" 'WARN' }
Write-Log ""

# Schritt 2: Netlogon-Dienst
Write-Log "Schritt 2: Netlogon-Dienst pruefen..."
$netlogon = Get-Service -Name 'Netlogon' -ErrorAction SilentlyContinue
if ($netlogon) {
    Write-Log "  Status   : $($netlogon.Status)"
    Write-Log "  Starttyp : $($netlogon.StartType)"
    if ($netlogon.Status -ne 'Running') {
        Write-Log "  PROBLEM: Netlogon laeuft nicht - SRV-Records koennen nicht registriert werden!" 'WARN'
    }
}
else {
    Write-Log "  PROBLEM: Netlogon-Dienst nicht gefunden!" 'ERROR'
}

# Schritt 3: DNS-Dienst
Write-Log "Schritt 3: DNS-Server-Dienst pruefen..."
$dns = Get-Service -Name 'DNS' -ErrorAction SilentlyContinue
if ($dns) {
    Write-Log "  Status   : $($dns.Status)"
    Write-Log "  Starttyp : $($dns.StartType)"
    if ($dns.Status -ne 'Running') {
        Write-Log "  PROBLEM: DNS-Dienst laeuft nicht!" 'WARN'
    }
}
else {
    Write-Log "  DNS-Dienst nicht gefunden (kein lokaler DNS-Server)." 'WARN'
}

# Schritt 4: DNS-Zone erreichbar?
Write-Log "Schritt 4: DNS-Zone '$domain' pruefen..."
try {
    $zone = Get-DnsServerZone -Name $domain -ErrorAction Stop
    Write-Log "  Zone gefunden: $($zone.ZoneName) (Typ: $($zone.ZoneType), IsDsIntegrated: $($zone.IsDsIntegrated))"
}
catch {
    Write-Log "  PROBLEM: DNS-Zone '$domain' nicht auf diesem DC gefunden: $($_.Exception.Message)" 'WARN'
    Write-Log "  Moegliche Ursache: DNS-Zone nicht repliziert oder DC nicht als DNS-Server konfiguriert." 'WARN'
}

# Schritt 5: Netlogon-Eventlog auf SRV-Registrierungsfehler
Write-Log "Schritt 5: Netlogon-Eventlog pruefen (letzte 24h)..."
try {
    $netlogonEvents = Get-EventLog -LogName System -Source 'NETLOGON' -EntryType Error, Warning `
        -After (Get-Date).AddHours(-24) -ErrorAction Stop | Select-Object -First 10
    if ($netlogonEvents) {
        foreach ($evt in $netlogonEvents) {
            Write-Log "  Event $($evt.EventID) [$($evt.EntryType)]: $($evt.Message -replace '\r?\n',' ')" 'WARN'
        }
        if ($remediateMode) {
            $netlogonEvents | Export-Csv "$backupDir\NetlogonEvents_PreRemediation.csv" -NoTypeInformation -Encoding UTF8
        }
    }
    else {
        Write-Log "  Keine Netlogon-Fehler/Warnungen in den letzten 24h."
    }
}
catch {
    Write-Log "  Eventlog-Abfrage fehlgeschlagen: $($_.Exception.Message)" 'WARN'
}

Write-Log ""

#endregion

#region ── Remediation ───────────────────────────────────────────────────────

Write-Log "---- Remediation ----"

if (-not $remediateMode) {
    Write-Log "Read-Only-Modus: Ninja-Checkbox 'bereinigung' ist nicht gesetzt."
    Write-Log "Setze die Checkbox um die Korrekturen durchzufuehren."
    Write-Log ""
    Write-Log "Geplante Aktionen bei Bereinigung:"
    Write-Log "  1. Registry-Backup erstellen"
    Write-Log "  2. DNS-Dienst sicherstellen (Starttyp Automatic + laufend)"
    Write-Log "  3. Netlogon Starttyp auf Automatic setzen"
    Write-Log "  4. DNS-Registrierung erzwingen (nltest /dsregdns)"
    Write-Log "  5. Netlogon neu starten (erzwingt SRV-Record-Registrierung)"
    Write-Log "  6. ipconfig /registerdns"
    Write-Log "  7. Abschlusspruefung aller SRV-Records"
    Write-Log ""
    Write-Log "Log gespeichert: $logFile"
    exit 0
}

# Backup vor allen Aenderungen
Backup-NetlogonRegistry

$errors = @()

# Schritt 1: DNS-Dienst sicherstellen
Write-Log "Remediation Schritt 1: DNS-Dienst sicherstellen..."
if ($dns) {
    try {
        if ($dns.StartType -ne 'Automatic') {
            Set-Service -Name 'DNS' -StartupType Automatic -ErrorAction Stop
            Write-Log "DNS-Dienst Starttyp auf Automatic gesetzt."
        }
        if ($dns.Status -ne 'Running') {
            Start-Service -Name 'DNS' -ErrorAction Stop
            Write-Log "DNS-Dienst gestartet."
            Start-Sleep -Seconds 5
        }
        else {
            Write-Log "DNS-Dienst laeuft bereits."
        }
    }
    catch {
        Write-Log "DNS-Dienst Korrektur fehlgeschlagen: $($_.Exception.Message)" 'ERROR'
        $errors += "DNS-Dienst: $($_.Exception.Message)"
    }
}
else {
    Write-Log "DNS-Dienst nicht vorhanden - wird uebersprungen." 'WARN'
}

# Schritt 2: Netlogon Starttyp korrigieren
Write-Log "Remediation Schritt 2: Netlogon Starttyp sicherstellen..."
try {
    if ($netlogon.StartType -ne 'Automatic') {
        Set-Service -Name 'Netlogon' -StartupType Automatic -ErrorAction Stop
        Write-Log "Netlogon Starttyp auf Automatic gesetzt."
    }
    else {
        Write-Log "Netlogon Starttyp war bereits Automatic."
    }
}
catch {
    Write-Log "Netlogon Starttyp setzen fehlgeschlagen: $($_.Exception.Message)" 'ERROR'
    $errors += "Netlogon Starttyp: $($_.Exception.Message)"
}

# Schritt 3: DNS-Registrierung via nltest erzwingen
Write-Log "Remediation Schritt 3: DNS-Registrierung erzwingen (nltest /dsregdns)..."
try {
    $nltestOut = & nltest /dsregdns 2>&1
    $nltestOut | ForEach-Object { Write-Log "  nltest: $_" }
    Write-Log "nltest /dsregdns ausgefuehrt."
}
catch {
    Write-Log "nltest /dsregdns fehlgeschlagen: $($_.Exception.Message)" 'WARN'
}

# Schritt 4: Netlogon neu starten - registriert SRV-Records automatisch
Write-Log "Remediation Schritt 4: Netlogon neu starten (registriert SRV-Records)..."
try {
    Restart-Service -Name 'Netlogon' -Force -ErrorAction Stop
    Write-Log "Netlogon erfolgreich neu gestartet."
    Write-Log "Warte 15 Sekunden auf SRV-Record-Registrierung..."
    Start-Sleep -Seconds 15
}
catch {
    Write-Log "Netlogon Neustart fehlgeschlagen: $($_.Exception.Message)" 'ERROR'
    $errors += "Netlogon Neustart: $($_.Exception.Message)"
}

# Schritt 5: ipconfig /registerdns
Write-Log "Remediation Schritt 5: ipconfig /registerdns..."
try {
    $ipconfigOut = & ipconfig /registerdns 2>&1
    $ipconfigOut | ForEach-Object { Write-Log "  ipconfig: $_" }
    Write-Log "ipconfig /registerdns ausgefuehrt."
    Start-Sleep -Seconds 5
}
catch {
    Write-Log "ipconfig /registerdns fehlgeschlagen: $($_.Exception.Message)" 'WARN'
}

#endregion

#region ── Abschluss-Check ───────────────────────────────────────────────────

Write-Log ""
Write-Log "---- Abschlusspruefung ----"
Write-Log "Pruefe alle SRV-Records erneut..."

$srvResultsAfter = @()
$missingAfter    = @()

foreach ($record in $srvRecords) {
    if ($record -match '_gc\._tcp'   -and -not $isGC)  { continue }
    if ($record -match 'pdc\._msdcs' -and -not $isPDC) { continue }

    $res = Test-SRVRecord -RecordName $record -DCName $env:COMPUTERNAME
    $srvResultsAfter += $res

    if (-not $res.Found -or -not $res.DCInRecord) {
        Write-Log "  FEHLT  : $record" 'WARN'
        $missingAfter += $record
    }
    else {
        Write-Log "  OK     : $record -> $($env:COMPUTERNAME)"
    }
}

$srvResultsAfter | Export-Csv "$baseDir\SRVCheck_After_$timestamp.csv" -NoTypeInformation -Encoding UTF8

# Report-relevanter Record
$ldapDCAfter = $srvResultsAfter | Where-Object { $_.Record -eq $ldapDCRecord }
$fixedOK     = $ldapDCAfter -and $ldapDCAfter.DCInRecord

Write-Log ""
if ($fixedOK) {
    Write-Log "Abschlusspruefung OK: DC ist jetzt in '$ldapDCRecord' eingetragen."
    Write-Log "Finding 'DNS SRV Records' ist behoben."
}
else {
    Write-Log "WARNUNG: '$ldapDCRecord' enthaelt den DC noch nicht." 'WARN'
    Write-Log "Moegliche tiefere Ursachen die manuelle Analyse erfordern:" 'WARN'
    Write-Log "  - DNS-Zone '$domain' ist nicht auf diesem DC vorhanden oder nicht repliziert" 'WARN'
    Write-Log "    Pruefen mit: Get-DnsServerZone -Name $domain" 'WARN'
    Write-Log "  - Fehlende Schreibrechte auf der DNS-Zone fuer das DC-Computerkonto" 'WARN'
    Write-Log "    Pruefen mit: Get-DnsServerZone $domain | Get-DnsServerZoneAging" 'WARN'
    Write-Log "  - AD-Replikationsfehler verhindern Zone-Sync" 'WARN'
    Write-Log "    Pruefen mit: repadmin /replsummary" 'WARN'
    Write-Log "  - Netlogon-Dienst kann Records nicht registrieren (Berechtigungsproblem)" 'WARN'
    Write-Log "    Pruefen mit: nltest /dsgetdc:$domain" 'WARN'
    Write-Log "  - DNS-Zone ist 'Secure only' und DC-Computerkonto hat keine Schreibrechte" 'WARN'
}

if ($missingAfter.Count -gt 0 -and $missingAfter.Count -lt $missingRecords.Count) {
    Write-Log ""
    Write-Log "Teilweise behoben: $($missingRecords.Count - $missingAfter.Count) von $($missingRecords.Count) fehlenden Records wiederhergestellt." 'WARN'
}

#endregion

#region ── Zusammenfassung ───────────────────────────────────────────────────

Write-Log ""
Write-Log "========================================"
Write-Log "  Zusammenfassung"
Write-Log "========================================"
Write-Log "Report-Finding ($ldapDCRecord):"
Write-Log "  Vorher : $(if ($reportFindingOK) { 'OK' } else { 'FEHLEND' })"
Write-Log "  Nachher: $(if ($fixedOK) { 'OK - behoben' } else { 'FEHLEND - manuelle Analyse erforderlich' })"

if ($errors.Count -gt 0) {
    Write-Log ""
    Write-Log "Fehler waehrend Remediation:" 'WARN'
    foreach ($e in $errors) { Write-Log "  - $e" 'WARN' }
}

Write-Log ""
Write-Log "Log gespeichert           : $logFile"
Write-Log "SRV-Check vorher (CSV)    : $baseDir\SRVCheck_$timestamp.csv"
Write-Log "SRV-Check nachher (CSV)   : $baseDir\SRVCheck_After_$timestamp.csv"
if ($remediateMode) {
    Write-Log "Backups gespeichert       : $backupDir"
}
Write-Log "Fertig."

#endregion
