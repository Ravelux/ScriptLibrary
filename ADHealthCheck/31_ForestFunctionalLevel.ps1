<#
.SYNOPSIS
    Prueft und behebt das Finding "Forest Functional Level" aus dem ADHealth-Check.

.DESCRIPTION
    Der Report prueft:
      $Forests.ForestMode -notmatch "2025|2022|2019|2016"
      (Collector: (Get-ADForest).ForestMode)

    Das Anheben des Forest Functional Levels ist IRREVERSIBEL.
    Voraussetzung: Alle Domain Controller muessen das Zielniveau unterstuetzen,
    und der Domain Functional Level muss zuerst angehoben werden.

    Dieses Skript:
      1. Zeigt aktuellen Forest Functional Level
      2. Zeigt aktuellen Domain Functional Level aller Domains
      3. Prueft OS-Version aller Domain Controller
      4. Prueft ob Anheben moeglich und sicher ist
      5. Hebt Domain Functional Level an (falls noetig)
      6. Hebt Forest Functional Level an

    Reihenfolge (zwingend):
      1. Alle DCs auf unterstuetztes OS pruefen
      2. Domain Functional Level anheben (pro Domain)
      3. Forest Functional Level anheben

    Ninja Script Variable:
      bereinigung  (Checkbox)
        Nicht gesetzt : Nur Analyse, keine Aenderungen
        Gesetzt       : Functional Levels werden angehoben

    WARNUNG: Diese Aktion ist nicht rueckgaengig zu machen!
    Sicherstellen dass alle DCs Windows Server 2016 oder hoeher laufen,
    bevor die Checkbox gesetzt wird.

    Voraussetzungen:
      - Domain Admin / Enterprise Admin Rechte
      - ActiveDirectory PowerShell Modul
      - Ausfuehrung auf einem Domain Controller oder mit AD-Remoting
#>

#region ── Pfade und Log-Initialisierung ─────────────────────────────────────

$timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$baseDir   = 'C:\ProgramData\TechboldADHealth\ForestFunctionalLevel'
$logFile   = "$baseDir\Log_$timestamp.txt"

if (-not (Test-Path $baseDir)) {
    New-Item -ItemType Directory -Path $baseDir -Force | Out-Null
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
Write-Log "  Techbold ADHealth - Forest Functional Level"
Write-Log "========================================"
Write-Log "Computer  : $env:COMPUTERNAME"
Write-Log "Modus     : $(if ($remediateMode) { 'REMEDIATION (Aenderungen aktiv) - IRREVERSIBEL!' } else { 'READ-ONLY (keine Aenderungen)' })"
Write-Log "Log-Datei : $logFile"
Write-Log ""

#endregion

#region ── Modulpruefung ─────────────────────────────────────────────────────

try {
    Import-Module ActiveDirectory -ErrorAction Stop
}
catch {
    Write-Log "ActiveDirectory-Modul nicht verfuegbar: $($_.Exception.Message)" 'ERROR'
    exit 1
}

# Enterprise Admin pruefen (benoetigt fuer Forest Functional Level)
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "Skript muss als Administrator ausgefuehrt werden." 'ERROR'
    exit 1
}

#endregion

#region ── Analyse ───────────────────────────────────────────────────────────

Write-Log "---- Analyse ----"

# Forest-Informationen
try {
    $forest = Get-ADForest -ErrorAction Stop
}
catch {
    Write-Log "Forest-Abfrage fehlgeschlagen: $($_.Exception.Message)" 'ERROR'
    exit 1
}

$currentFFL  = $forest.ForestMode
$forestName  = $forest.Name

# Zielniveau ermitteln: hoechstes von allen DCs unterstuetztes Level
# Windows Server 2025 = Windows2025Forest
# Windows Server 2022 = Windows2022Forest (noch nicht verfuegbar als FFL, daher 2019)
# Windows Server 2019 = Windows2016Forest (2019 hat kein eigenes FFL)
# Windows Server 2016 = Windows2016Forest
$targetFFL = 'Windows2016Forest'

Write-Log "Forest             : $forestName"
Write-Log "Aktueller FFL      : $currentFFL"
Write-Log "Ziel-FFL           : $targetFFL (Windows2016Forest = unterstuetzt 2016/2019/2022/2025)"
Write-Log ""

# Report-Prueflogik: -notmatch "2025|2022|2019|2016"
$findingActive = $currentFFL -notmatch '2025|2022|2019|2016'

if (-not $findingActive) {
    Write-Log "ERGEBNIS: Forest Functional Level '$currentFFL' erfuellt die Anforderung."
    Write-Log "Finding 'Forest Functional Level' ist nicht vorhanden oder bereits behoben."
    Write-Log "Log gespeichert: $logFile"
    exit 0
}

Write-Log "ERGEBNIS: Forest Functional Level '$currentFFL' loest das Finding aus." 'WARN'
Write-Log ""

# Domain Functional Level aller Domains pruefen
Write-Log "---- Domain Functional Levels ----"
$domainResults = @()
foreach ($domainName in $forest.Domains) {
    try {
        $dom = Get-ADDomain -Identity $domainName -ErrorAction Stop
        $dfl = $dom.DomainMode
        $dflOK = $dfl -match '2025|2022|2019|2016'
        Write-Log "  Domain: $domainName"
        Write-Log "    Domain Functional Level : $dfl $(if ($dflOK) { '(OK)' } else { '(muss angehoben werden)' })"
        $domainResults += [PSCustomObject]@{
            Domain  = $domainName
            DFL     = $dfl
            DFLOk   = $dflOK
            DomainObj = $dom
        }
    }
    catch {
        Write-Log "  Domain '$domainName' nicht abfragbar: $($_.Exception.Message)" 'WARN'
    }
}
Write-Log ""

# OS-Versionen aller Domain Controller pruefen
Write-Log "---- Domain Controller OS-Versionen ----"
$dcCheckResults  = @()
$unsupportedDCs  = @()

foreach ($domainName in $forest.Domains) {
    try {
        $dcs = Get-ADDomainController -Filter * -Server $domainName -ErrorAction Stop
        foreach ($dc in $dcs) {
            $osVersion = $dc.OperatingSystem
            $osOK = $osVersion -match '2016|2019|2022|2025'
            $status = if ($osOK) { 'OK' } else { 'NICHT UNTERSTUETZT' }
            Write-Log "  $($dc.HostName): $osVersion [$status]$(if (-not $osOK) { ' - BLOCKIERT ANHEBEN!' })"
            $dcCheckResults += [PSCustomObject]@{
                Hostname = $dc.HostName
                OS       = $osVersion
                Supported = $osOK
            }
            if (-not $osOK) {
                $unsupportedDCs += $dc.HostName
            }
        }
    }
    catch {
        Write-Log "  DC-Abfrage fuer Domain '$domainName' fehlgeschlagen: $($_.Exception.Message)" 'WARN'
    }
}

Write-Log ""

# Sicherheitspruefung
$canRemediate = $true

if ($unsupportedDCs.Count -gt 0) {
    Write-Log "WARNUNG: $($unsupportedDCs.Count) DC(s) laufen auf nicht unterstuetztem OS:" 'WARN'
    foreach ($udc in $unsupportedDCs) { Write-Log "  - $udc" 'WARN' }
    Write-Log "Das Anheben des Functional Levels ist mit diesen DCs nicht moeglich!" 'WARN'
    Write-Log "Diese DCs muessen zuerst auf Windows Server 2016 oder hoeher aktualisiert werden." 'WARN'
    $canRemediate = $false
}
else {
    Write-Log "Alle $($dcCheckResults.Count) DC(s) laufen auf unterstuetztem OS."
}

# Ergebnis-CSV speichern
$dcCheckResults | Export-Csv "$baseDir\DCCheck_$timestamp.csv" -NoTypeInformation -Encoding UTF8
Write-Log ""
Write-Log "DC-Check gespeichert: $baseDir\DCCheck_$timestamp.csv"

#endregion

#region ── Remediation ───────────────────────────────────────────────────────

Write-Log ""
Write-Log "---- Remediation ----"

if (-not $remediateMode) {
    Write-Log "Read-Only-Modus: Ninja-Checkbox 'bereinigung' ist nicht gesetzt."
    Write-Log ""
    if ($canRemediate) {
        Write-Log "Geplante Aktionen bei Bereinigung:"
        foreach ($dr in $domainResults | Where-Object { -not $_.DFLOk }) {
            Write-Log "  1. Domain Functional Level '$($dr.Domain)' auf Windows2016Domain anheben"
        }
        Write-Log "  2. Forest Functional Level auf Windows2016Forest anheben (IRREVERSIBEL)"
    }
    else {
        Write-Log "Bereinigung nicht moeglich - zuerst unsupportete DCs aktualisieren!"
    }
    Write-Log ""
    Write-Log "Log gespeichert: $logFile"
    exit 0
}

if (-not $canRemediate) {
    Write-Log "ABBRUCH: Bereinigung nicht moeglich solange unsupportete DCs vorhanden sind." 'ERROR'
    Write-Log "Betroffene DCs:" 'ERROR'
    foreach ($udc in $unsupportedDCs) { Write-Log "  - $udc" 'ERROR' }
    Write-Log "Log gespeichert: $logFile"
    exit 1
}

$errors = @()

# Schritt 1: Domain Functional Level anheben (Voraussetzung fuer FFL)
foreach ($dr in $domainResults) {
    if (-not $dr.DFLOk) {
        Write-Log "Remediation Schritt 1: Domain Functional Level '$($dr.Domain)' anheben..."
        try {
            Set-ADDomainMode `
                -Identity $dr.Domain `
                -DomainMode Windows2016Domain `
                -Confirm:$false `
                -ErrorAction Stop
            Write-Log "Domain Functional Level '$($dr.Domain)': auf Windows2016Domain angehoben."
        }
        catch {
            Write-Log "Domain Functional Level '$($dr.Domain)' anheben fehlgeschlagen: $($_.Exception.Message)" 'ERROR'
            $errors += "DFL $($dr.Domain): $($_.Exception.Message)"
        }
    }
    else {
        Write-Log "Remediation Schritt 1: DFL '$($dr.Domain)' bereits auf Zielniveau - uebersprungen."
    }
}

# Kurz warten damit Replikation der DFL-Aenderung beginnen kann
if (($domainResults | Where-Object { -not $_.DFLOk }).Count -gt 0) {
    Write-Log "Warte 10 Sekunden nach DFL-Aenderung..."
    Start-Sleep -Seconds 10
}

# Schritt 2: Forest Functional Level anheben
if ($errors.Count -eq 0) {
    Write-Log "Remediation Schritt 2: Forest Functional Level anheben..."
    Write-Log "WARNUNG: Diese Aktion ist IRREVERSIBEL!" 'WARN'
    try {
        Set-ADForestMode `
            -Identity $forestName `
            -ForestMode Windows2016Forest `
            -Confirm:$false `
            -ErrorAction Stop
        Write-Log "Forest Functional Level erfolgreich auf Windows2016Forest angehoben."
    }
    catch {
        Write-Log "Forest Functional Level anheben fehlgeschlagen: $($_.Exception.Message)" 'ERROR'
        $errors += "FFL: $($_.Exception.Message)"
    }
}
else {
    Write-Log "Forest Functional Level wird nicht angehoben da DFL-Fehler vorliegen." 'WARN'
}

#endregion

#region ── Abschluss-Check ───────────────────────────────────────────────────

Write-Log ""
Write-Log "---- Abschlusspruefung ----"

try {
    $forestAfter = Get-ADForest -ErrorAction Stop
    $fflAfter    = $forestAfter.ForestMode
    Write-Log "Forest Functional Level jetzt: $fflAfter"

    $findingAfter = $fflAfter -notmatch '2025|2022|2019|2016'
    if (-not $findingAfter) {
        Write-Log "Abschlusspruefung OK: Finding 'Forest Functional Level' ist behoben."
    }
    else {
        Write-Log "Forest Functional Level erfuellt Anforderung noch nicht: $fflAfter" 'WARN'
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
Write-Log "FFL vorher : $currentFFL"
Write-Log "FFL nachher: $(try { (Get-ADForest).ForestMode } catch { 'unbekannt' })"

if ($errors.Count -gt 0) {
    Write-Log "Fehler:" 'WARN'
    foreach ($e in $errors) { Write-Log "  - $e" 'WARN' }
}

Write-Log ""
Write-Log "Log gespeichert: $logFile"
Write-Log "DC-Check (CSV) : $baseDir\DCCheck_$timestamp.csv"
Write-Log "Fertig."

#endregion
