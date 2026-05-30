<#
.SYNOPSIS
    Prueft und behebt das Finding "GPOs Enabled User or Computer Config without Content"
    aus dem ADHealth-Check.

.DESCRIPTION
    Der Report prueft:
      GPOs bei denen Computer.enabled = 'true' aber keine ExtensionData vorhanden
      GPOs bei denen User.enabled = 'true' aber keine ExtensionData vorhanden
      Finding aktiv wenn mindestens eine solche GPO gefunden wird.

    Das Skript deaktiviert den jeweils leeren Teil (User oder Computer Konfiguration)
    in den betroffenen GPOs.

    Ausnahmen koennen in folgender Datei hinterlegt werden (eine GPO pro Zeile):
      C:\ProgramData\TechboldADHealth\GPOEmptyConfigs\Exceptions.txt

    Die Datei wird beim ersten Start automatisch erstellt (leer).
    GPO-Namen in der Datei werden beim Scan uebersprungen.

    Ninja Script Variable:
      bereinigung  (Checkbox)
        Nicht gesetzt : Nur Analyse, keine Aenderungen
        Gesetzt       : Leere GPO-Konfigurationsteile werden deaktiviert

    Backup:
      Vor jeder Aenderung wird ein HTML-Report der GPO exportiert
      nach C:\ProgramData\TechboldADHealth\GPOEmptyConfigs\Backup_<timestamp>\

    Voraussetzungen:
      - Domain Admin Rechte
      - GroupPolicy PowerShell Modul (RSAT)
      - Ausfuehrung auf einem Domain Controller oder mit AD-Remoting
#>

#region ── Pfade und Log-Initialisierung ─────────────────────────────────────

$timestamp     = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$baseDir       = 'C:\ProgramData\TechboldADHealth\GPOEmptyConfigs'
$backupDir     = "$baseDir\Backup_$timestamp"
$logFile       = "$baseDir\Log_$timestamp.txt"
$exceptionFile = "$baseDir\Exceptions.txt"

foreach ($dir in @($baseDir, $backupDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# Ausnahmedatei erstellen falls nicht vorhanden
if (-not (Test-Path $exceptionFile)) {
    @"
# GPO-Ausnahmeliste fuer Remediate-GPOEmptyConfigs
# Eine GPO pro Zeile eintragen (exakter Name wie im Group Policy Management)
# Zeilen die mit # beginnen werden ignoriert
# Beispiel:
# Default Domain Policy
# Meine Test-GPO
"@ | Out-File -FilePath $exceptionFile -Encoding UTF8
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
Write-Log "  Techbold ADHealth - GPOs Empty Config"
Write-Log "========================================"
Write-Log "Computer       : $env:COMPUTERNAME"
Write-Log "Modus          : $(if ($remediateMode) { 'REMEDIATION (Aenderungen aktiv)' } else { 'READ-ONLY (keine Aenderungen)' })"
Write-Log "Ausnahmedatei  : $exceptionFile"
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

foreach ($mod in @('GroupPolicy', 'ActiveDirectory')) {
    try {
        Import-Module $mod -ErrorAction Stop
    }
    catch {
        Write-Log "Modul '$mod' nicht verfuegbar: $($_.Exception.Message)" 'ERROR'
        exit 1
    }
}

#endregion

#region ── Ausnahmeliste einlesen ────────────────────────────────────────────

$exceptions = @()
try {
    $exceptions = Get-Content $exceptionFile -Encoding UTF8 -ErrorAction Stop |
        Where-Object { $_ -and $_ -notmatch '^\s*#' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }

    if ($exceptions.Count -gt 0) {
        Write-Log "Ausnahmen geladen ($($exceptions.Count)):"
        foreach ($ex in $exceptions) { Write-Log "  - $ex" }
    }
    else {
        Write-Log "Keine Ausnahmen konfiguriert."
    }
}
catch {
    Write-Log "Ausnahmedatei konnte nicht gelesen werden: $($_.Exception.Message)" 'WARN'
}
Write-Log ""

#endregion

#region ── Analyse ───────────────────────────────────────────────────────────

Write-Log "---- Analyse ----"

try {
    $domain  = (Get-ADDomain).DNSRoot
    $allGPOs = Get-GPO -All -Domain $domain -ErrorAction Stop
    Write-Log "$($allGPOs.Count) GPOs in Domain '$domain' gefunden."
}
catch {
    Write-Log "GPO-Abfrage fehlgeschlagen: $($_.Exception.Message)" 'ERROR'
    exit 1
}

$affectedGPOs = @()

foreach ($gpo in $allGPOs) {

    # Ausnahme pruefen
    if ($gpo.DisplayName -in $exceptions) {
        Write-Log "  SKIP (Ausnahme): $($gpo.DisplayName)"
        continue
    }

    # GPO-Report als XML laden um ExtensionData zu pruefen
    try {
        [xml]$gpoReport = Get-GPOReport -Guid $gpo.Id -ReportType Xml -ErrorAction Stop
    }
    catch {
        Write-Log "  FEHLER beim Lesen von '$($gpo.DisplayName)': $($_.Exception.Message)" 'WARN'
        continue
    }

    $gpoXml       = $gpoReport.GPO
    $computerEmpty = $false
    $userEmpty     = $false

    # Computer-Konfiguration: aktiviert aber keine ExtensionData?
    if ($gpoXml.Computer.Enabled -eq 'true' -and -not $gpoXml.Computer.ExtensionData) {
        $computerEmpty = $true
    }

    # User-Konfiguration: aktiviert aber keine ExtensionData?
    if ($gpoXml.User.Enabled -eq 'true' -and -not $gpoXml.User.ExtensionData) {
        $userEmpty = $true
    }

    if ($computerEmpty -or $userEmpty) {
        $affected = [PSCustomObject]@{
            GPOName       = $gpo.DisplayName
            GPOId         = $gpo.Id
            ComputerEmpty = $computerEmpty
            UserEmpty     = $userEmpty
            GPOObject     = $gpo
        }
        $affectedGPOs += $affected

        $parts = @()
        if ($computerEmpty) { $parts += 'Computer-Konfiguration (aktiviert, leer)' }
        if ($userEmpty)     { $parts += 'User-Konfiguration (aktiviert, leer)' }
        Write-Log "  BETROFFEN: $($gpo.DisplayName) -> $($parts -join ' | ')" 'WARN'
    }
}

Write-Log ""
Write-Log "$($affectedGPOs.Count) betroffene GPO(s) gefunden."

# Ergebnis-CSV speichern
$affectedGPOs | Select-Object GPOName, GPOId, ComputerEmpty, UserEmpty |
    Export-Csv "$baseDir\GPOCheck_$timestamp.csv" -NoTypeInformation -Encoding UTF8
Write-Log "Ergebnis gespeichert: $baseDir\GPOCheck_$timestamp.csv"

if ($affectedGPOs.Count -eq 0) {
    Write-Log ""
    Write-Log "ERGEBNIS: Keine betroffenen GPOs gefunden."
    Write-Log "Finding 'GPOs Enabled User or Computer Config without Content' ist nicht vorhanden."
    Write-Log "Log gespeichert: $logFile"
    exit 0
}

Write-Log ""

#endregion

#region ── Remediation ───────────────────────────────────────────────────────

Write-Log "---- Remediation ----"

if (-not $remediateMode) {
    Write-Log "Read-Only-Modus: Ninja-Checkbox 'bereinigung' ist nicht gesetzt."
    Write-Log ""
    Write-Log "Geplante Aktionen bei Bereinigung:"
    foreach ($gpo in $affectedGPOs) {
        if ($gpo.ComputerEmpty) {
            Write-Log "  [$($gpo.GPOName)] Computer-Konfiguration deaktivieren"
        }
        if ($gpo.UserEmpty) {
            Write-Log "  [$($gpo.GPOName)] User-Konfiguration deaktivieren"
        }
    }
    Write-Log ""
    Write-Log "Ausnahmen koennen eingetragen werden in: $exceptionFile"
    Write-Log "Log gespeichert: $logFile"
    exit 0
}

$errors  = @()
$changed = 0

foreach ($gpo in $affectedGPOs) {

    Write-Log "Verarbeite GPO: $($gpo.GPOName)..."

    # Backup: HTML-Report der GPO vor Aenderung exportieren
    try {
        $safeGPOName = $gpo.GPOName -replace '[^a-zA-Z0-9._-]', '_'
        Get-GPOReport -Guid $gpo.GPOId -ReportType Html `
            -Path "$backupDir\$safeGPOName`_PreRemediation.html" `
            -ErrorAction Stop
        Write-Log "  Backup gespeichert: $backupDir\$safeGPOName`_PreRemediation.html"
    }
    catch {
        Write-Log "  Backup fehlgeschlagen: $($_.Exception.Message)" 'WARN'
    }

    # Computer-Konfiguration deaktivieren
    if ($gpo.ComputerEmpty) {
        try {
            $gpo.GPOObject.GpoStatus = switch ($gpo.GPOObject.GpoStatus) {
                'AllSettingsEnabled'       { 'ComputerSettingsDisabled' }
                'UserSettingsDisabled'     { 'AllSettingsDisabled' }
                default                    { 'ComputerSettingsDisabled' }
            }
            Write-Log "  Computer-Konfiguration deaktiviert. Neuer Status: $($gpo.GPOObject.GpoStatus)"
            $changed++
        }
        catch {
            Write-Log "  Computer-Konfiguration deaktivieren fehlgeschlagen: $($_.Exception.Message)" 'ERROR'
            $errors += "[$($gpo.GPOName)] Computer: $($_.Exception.Message)"
        }
    }

    # User-Konfiguration deaktivieren
    if ($gpo.UserEmpty) {
        try {
            $gpo.GPOObject.GpoStatus = switch ($gpo.GPOObject.GpoStatus) {
                'AllSettingsEnabled'          { 'UserSettingsDisabled' }
                'ComputerSettingsDisabled'    { 'AllSettingsDisabled' }
                default                       { 'UserSettingsDisabled' }
            }
            Write-Log "  User-Konfiguration deaktiviert. Neuer Status: $($gpo.GPOObject.GpoStatus)"
            $changed++
        }
        catch {
            Write-Log "  User-Konfiguration deaktivieren fehlgeschlagen: $($_.Exception.Message)" 'ERROR'
            $errors += "[$($gpo.GPOName)] User: $($_.Exception.Message)"
        }
    }
}

#endregion

#region ── Abschluss-Check ───────────────────────────────────────────────────

Write-Log ""
Write-Log "---- Abschlusspruefung ----"
Write-Log "Pruefe betroffene GPOs erneut..."

$remainingAffected = @()
foreach ($gpo in $affectedGPOs) {
    try {
        [xml]$gpoReport   = Get-GPOReport -Guid $gpo.GPOId -ReportType Xml -ErrorAction Stop
        $gpoXml            = $gpoReport.GPO
        $stillCompEmpty    = $gpoXml.Computer.Enabled -eq 'true' -and -not $gpoXml.Computer.ExtensionData
        $stillUserEmpty    = $gpoXml.User.Enabled -eq 'true' -and -not $gpoXml.User.ExtensionData

        if ($stillCompEmpty -or $stillUserEmpty) {
            $remainingAffected += $gpo.GPOName
            Write-Log "  NOCH BETROFFEN: $($gpo.GPOName)" 'WARN'
        }
        else {
            Write-Log "  OK: $($gpo.GPOName)"
        }
    }
    catch {
        Write-Log "  Pruefung fehlgeschlagen fuer '$($gpo.GPOName)': $($_.Exception.Message)" 'WARN'
    }
}

Write-Log ""
if ($remainingAffected.Count -eq 0) {
    Write-Log "Abschlusspruefung OK: Finding 'GPOs Enabled User or Computer Config without Content' ist behoben."
}
else {
    Write-Log "$($remainingAffected.Count) GPO(s) noch betroffen - manuelle Pruefung erforderlich." 'WARN'
}

#endregion

#region ── Zusammenfassung ───────────────────────────────────────────────────

Write-Log ""
Write-Log "========================================"
Write-Log "  Zusammenfassung"
Write-Log "========================================"
Write-Log "Betroffene GPOs gefunden : $($affectedGPOs.Count)"
Write-Log "Erfolgreich bereinigt    : $changed"
Write-Log "Noch betroffen           : $($remainingAffected.Count)"

if ($errors.Count -gt 0) {
    Write-Log "Fehler:" 'WARN'
    foreach ($e in $errors) { Write-Log "  - $e" 'WARN' }
}

Write-Log ""
Write-Log "Log gespeichert    : $logFile"
Write-Log "Ergebnis-CSV       : $baseDir\GPOCheck_$timestamp.csv"
Write-Log "Ausnahmedatei      : $exceptionFile"
if ($remediateMode) {
    Write-Log "Backups gespeichert: $backupDir"
}
Write-Log "Fertig."

#endregion
