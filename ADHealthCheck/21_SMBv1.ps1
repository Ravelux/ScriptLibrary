<#
.SYNOPSIS
    Prueft und behebt das Finding "SMBv1 Status" aus dem ADHealth-Check.

.DESCRIPTION
    Analysiert den SMBv1-Status lokal auf dem Server und deaktiviert SMBv1
    wenn die Ninja-Checkbox "bereinigung" gesetzt ist.

    Ninja Script Variablen:
      bereinigung  (Checkbox)
        Nicht gesetzt : Nur Analyse, keine Aenderungen
        Gesetzt       : SMBv1 wird deaktiviert/entfernt

    Deaktivierungswege (alle werden ausgefuehrt):
      1. Set-SmbServerConfiguration  -EnableSMB1Protocol $false
      2. Set-SmbClientConfiguration  -EnableSMB1Protocol $false  (falls unterstuetzt)
      3. Disable-WindowsOptionalFeature (SMB1Protocol*)
      4. Remove-WindowsFeature FS-SMB1 (Server-Rolle, falls vorhanden)
      5. Registry-Fallback: LanmanServer\Parameters\SMB1 = 0
                            mrxsmb10 Start = 4 (Treiber deaktiviert)

    Voraussetzungen:
      - Administratorrechte
      - Lokale Ausfuehrung auf dem Ziel-Server (via Ninja-Agent)

    Backup:
      Registry-Export nach C:\ProgramData\TechboldADHealth\SMBv1\Backup_<timestamp>\
      vor jeder Aenderung.
#>

#region ── Pfade und Log-Initialisierung ─────────────────────────────────────

$timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$baseDir   = 'C:\ProgramData\TechboldADHealth\SMBv1'
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
Write-Log "  Techbold ADHealth - SMBv1 Status"
Write-Log "========================================"
Write-Log "Computer  : $env:COMPUTERNAME"
Write-Log "Modus     : $(if ($remediateMode) { 'REMEDIATION (Aenderungen aktiv)' } else { 'READ-ONLY (keine Aenderungen)' })"
Write-Log "Log-Datei : $logFile"
if ($remediateMode) {
    Write-Log "Backup-Dir: $backupDir"
}
Write-Log ""

#endregion

#region ── Adminpruefung ─────────────────────────────────────────────────────

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "Skript muss als Administrator ausgefuehrt werden." 'ERROR'
    exit 1
}

#endregion

#region ── Backup-Funktion ───────────────────────────────────────────────────

function Backup-SMBRegistry {
    Write-Log "Erstelle Registry-Backup vor Aenderungen..."
    try {
        $regPaths = @(
            @{ Name = 'LanmanServer';  Path = 'HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' }
            @{ Name = 'mrxsmb10';      Path = 'HKLM\SYSTEM\CurrentControlSet\Services\mrxsmb10' }
            @{ Name = 'LanmanWorkstation'; Path = 'HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters' }
        )
        foreach ($reg in $regPaths) {
            $outFile = "$backupDir\Registry_$($reg.Name).reg"
            $result  = reg export $reg.Path $outFile /y 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Backup gespeichert: $outFile"
            }
            else {
                Write-Log "Registry-Pfad '$($reg.Path)' nicht vorhanden oder Export fehlgeschlagen (wird uebersprungen)." 'WARN'
            }
        }
    }
    catch {
        Write-Log "Backup fehlgeschlagen: $($_.Exception.Message)" 'WARN'
    }
}

#endregion

#region ── Analyse ───────────────────────────────────────────────────────────

Write-Log "---- Analyse ----"

$analysis = [ordered]@{
    OS                   = $null
    SMB1ServerEnabled    = $null
    SMB2ServerEnabled    = $null
    SMB1ClientEnabled    = $null
    SMB1FeatureInstalled = $null
    SMB1ServerFeature    = $null
    RegistrySMB1Value    = $null
    Mrxsmb10StartValue   = $null
}

# Betriebssystem
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $analysis.OS = "$($os.Caption) ($($os.Version))"
    Write-Log "OS: $($analysis.OS)"
}
catch {
    Write-Log "OS-Abfrage fehlgeschlagen: $($_.Exception.Message)" 'WARN'
}

# SMB Server-Konfiguration
if (Get-Command Get-SmbServerConfiguration -ErrorAction SilentlyContinue) {
    try {
        $srv = Get-SmbServerConfiguration -ErrorAction Stop
        $analysis.SMB1ServerEnabled = [bool]$srv.EnableSMB1Protocol
        $analysis.SMB2ServerEnabled = [bool]$srv.EnableSMB2Protocol
        Write-Log "SMB1 Server enabled  : $($analysis.SMB1ServerEnabled)"
        Write-Log "SMB2 Server enabled  : $($analysis.SMB2ServerEnabled)"
    }
    catch {
        Write-Log "Get-SmbServerConfiguration fehlgeschlagen: $($_.Exception.Message)" 'WARN'
    }
}

# SMB Client-Konfiguration
if (Get-Command Get-SmbClientConfiguration -ErrorAction SilentlyContinue) {
    try {
        $cli = Get-SmbClientConfiguration -ErrorAction Stop
        if ($cli.PSObject.Properties.Name -contains 'EnableSMB1Protocol') {
            $analysis.SMB1ClientEnabled = [bool]$cli.EnableSMB1Protocol
            Write-Log "SMB1 Client enabled  : $($analysis.SMB1ClientEnabled)"
        }
        else {
            Write-Log "SMB1 Client-Parameter nicht verfuegbar auf diesem OS."
        }
    }
    catch {
        Write-Log "Get-SmbClientConfiguration fehlgeschlagen: $($_.Exception.Message)" 'WARN'
    }
}

# Windows Optional Feature (Client/Workstation)
if (Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
    $featureNames  = @('SMB1Protocol', 'SMB1Protocol-Client', 'SMB1Protocol-Server')
    $anyInstalled  = $false
    foreach ($f in $featureNames) {
        try {
            $cur = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction Stop
            if ($cur.State -ne 'Disabled') {
                $anyInstalled = $true
                Write-Log "Optional Feature '$f': $($cur.State)"
            }
            else {
                Write-Log "Optional Feature '$f': Disabled"
            }
        }
        catch { }
    }
    $analysis.SMB1FeatureInstalled = $anyInstalled
}

# Windows Server Feature (aeltere Server-Rollen)
if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
    try {
        $sf = Get-WindowsFeature -Name FS-SMB1 -ErrorAction Stop
        $analysis.SMB1ServerFeature = [bool]$sf.Installed
        Write-Log "Server Feature FS-SMB1 installiert: $($analysis.SMB1ServerFeature)"
    }
    catch {
        Write-Log "Get-WindowsFeature FS-SMB1 nicht verfuegbar (kein Server-OS oder RSAT fehlt)." 'WARN'
    }
}

# Registry-Status
$lanmanPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'
try {
    $regVal = (Get-ItemProperty -Path $lanmanPath -Name SMB1 -ErrorAction Stop).SMB1
    $analysis.RegistrySMB1Value = $regVal
    Write-Log "Registry LanmanServer\SMB1   : $regVal (0=deaktiviert, 1=aktiv)"
}
catch {
    Write-Log "Registry LanmanServer\SMB1 nicht gesetzt (Standard: aktiv auf aelteren OS)."
    $analysis.RegistrySMB1Value = 'not set'
}

$mrxPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\mrxsmb10'
try {
    $mrxStart = (Get-ItemProperty -Path $mrxPath -Name Start -ErrorAction Stop).Start
    $analysis.Mrxsmb10StartValue = $mrxStart
    Write-Log "Registry mrxsmb10\Start      : $mrxStart (4=deaktiviert)"
}
catch {
    Write-Log "Registry mrxsmb10 nicht gefunden (SMB1-Treiber evtl. bereits entfernt)."
    $analysis.Mrxsmb10StartValue = 'not found'
}

# Gesamtbewertung
$smb1Active =
    ($analysis.SMB1ServerEnabled    -eq $true) -or
    ($analysis.SMB1ClientEnabled    -eq $true) -or
    ($analysis.SMB1FeatureInstalled -eq $true) -or
    ($analysis.SMB1ServerFeature    -eq $true) -or
    ($analysis.RegistrySMB1Value    -eq 1)

Write-Log ""
if ($smb1Active) {
    Write-Log "ERGEBNIS: SMBv1 ist AKTIV - Finding 'SMBv1 Status' ist vorhanden." 'WARN'
}
else {
    Write-Log "ERGEBNIS: SMBv1 ist INAKTIV - Finding 'SMBv1 Status' ist nicht vorhanden oder bereits behoben."
}
Write-Log ""

#endregion

#region ── Remediation ───────────────────────────────────────────────────────

Write-Log "---- Remediation ----"

if (-not $smb1Active) {
    Write-Log "Kein Handlungsbedarf. SMBv1 ist bereits deaktiviert."
    Write-Log "Log gespeichert: $logFile"
    exit 0
}

if (-not $remediateMode) {
    Write-Log "Read-Only-Modus: Ninja-Checkbox 'bereinigung' ist nicht gesetzt."
    Write-Log "Setze die Checkbox um SMBv1 zu deaktivieren."
    Write-Log "Log gespeichert: $logFile"
    exit 0
}

# Backup vor allen Aenderungen
Backup-SMBRegistry

$changed          = $false
$rebootRecommended = $false
$errors           = @()

# 1) SMB Server deaktivieren
Write-Log "Schritt 1: SMB Server-Konfiguration..."
if (Get-Command Set-SmbServerConfiguration -ErrorAction SilentlyContinue) {
    try {
        $srv = Get-SmbServerConfiguration -ErrorAction Stop
        if ($srv.EnableSMB1Protocol) {
            Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction Stop
            Write-Log "SMB1 Server: deaktiviert."
            $changed = $true
        }
        else {
            Write-Log "SMB1 Server: war bereits deaktiviert."
        }
        if (-not $srv.EnableSMB2Protocol) {
            Set-SmbServerConfiguration -EnableSMB2Protocol $true -Force -ErrorAction Stop
            Write-Log "SMB2 Server: aktiviert."
            $changed = $true
        }
        else {
            Write-Log "SMB2 Server: war bereits aktiv."
        }
    }
    catch {
        Write-Log "Set-SmbServerConfiguration fehlgeschlagen: $($_.Exception.Message)" 'ERROR'
        $errors += "SMB Server: $($_.Exception.Message)"
    }
}
else {
    Write-Log "Set-SmbServerConfiguration nicht verfuegbar - wird uebersprungen." 'WARN'
}

# 2) SMB Client deaktivieren
Write-Log "Schritt 2: SMB Client-Konfiguration..."
if (Get-Command Set-SmbClientConfiguration -ErrorAction SilentlyContinue) {
    try {
        $cli = Get-SmbClientConfiguration -ErrorAction Stop
        if ($cli.PSObject.Properties.Name -contains 'EnableSMB1Protocol') {
            if ($cli.EnableSMB1Protocol) {
                Set-SmbClientConfiguration -EnableSMB1Protocol $false -Force -ErrorAction Stop
                Write-Log "SMB1 Client: deaktiviert."
                $changed = $true
            }
            else {
                Write-Log "SMB1 Client: war bereits deaktiviert."
            }
        }
        else {
            Write-Log "SMB1 Client-Parameter nicht unterstuetzt - wird uebersprungen."
        }
    }
    catch {
        Write-Log "Set-SmbClientConfiguration fehlgeschlagen: $($_.Exception.Message)" 'ERROR'
        $errors += "SMB Client: $($_.Exception.Message)"
    }
}
else {
    Write-Log "Set-SmbClientConfiguration nicht verfuegbar - wird uebersprungen." 'WARN'
}

# 3) Windows Optional Feature deaktivieren
Write-Log "Schritt 3: Windows Optional Features..."
if (Get-Command Disable-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
    foreach ($f in @('SMB1Protocol', 'SMB1Protocol-Client', 'SMB1Protocol-Server')) {
        try {
            $cur = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction Stop
            if ($cur.State -ne 'Disabled') {
                Disable-WindowsOptionalFeature -Online -FeatureName $f -NoRestart -ErrorAction Stop | Out-Null
                Write-Log "Optional Feature '$f': deaktiviert. Neustart empfohlen."
                $changed          = $true
                $rebootRecommended = $true
            }
            else {
                Write-Log "Optional Feature '$f': war bereits deaktiviert."
            }
        }
        catch {
            Write-Log "Optional Feature '$f': $($_.Exception.Message)" 'WARN'
        }
    }
}
else {
    Write-Log "Disable-WindowsOptionalFeature nicht verfuegbar - wird uebersprungen." 'WARN'
}

# 4) Windows Server Feature entfernen
Write-Log "Schritt 4: Windows Server Feature FS-SMB1..."
if (Get-Command Remove-WindowsFeature -ErrorAction SilentlyContinue) {
    try {
        $sf = Get-WindowsFeature -Name FS-SMB1 -ErrorAction Stop
        if ($sf -and $sf.Installed) {
            Remove-WindowsFeature -Name FS-SMB1 -Restart:$false -ErrorAction Stop | Out-Null
            Write-Log "Server Feature FS-SMB1: entfernt. Neustart empfohlen."
            $changed          = $true
            $rebootRecommended = $true
        }
        else {
            Write-Log "Server Feature FS-SMB1: nicht installiert."
        }
    }
    catch {
        Write-Log "Remove-WindowsFeature FS-SMB1 fehlgeschlagen: $($_.Exception.Message)" 'WARN'
    }
}
else {
    Write-Log "Remove-WindowsFeature nicht verfuegbar (kein Server-OS) - wird uebersprungen."
}

# 5) Registry-Fallback
Write-Log "Schritt 5: Registry-Absicherung..."
try {
    if (-not (Test-Path $lanmanPath)) {
        New-Item -Path $lanmanPath -Force | Out-Null
    }
    $curVal = (Get-ItemProperty -Path $lanmanPath -Name SMB1 -ErrorAction SilentlyContinue).SMB1
    if ($curVal -ne 0) {
        New-ItemProperty -Path $lanmanPath -Name SMB1 -PropertyType DWord -Value 0 -Force | Out-Null
        Write-Log "Registry LanmanServer\SMB1: auf 0 gesetzt."
        $changed          = $true
        $rebootRecommended = $true
    }
    else {
        Write-Log "Registry LanmanServer\SMB1: war bereits 0."
    }
}
catch {
    Write-Log "Registry LanmanServer fehlgeschlagen: $($_.Exception.Message)" 'ERROR'
    $errors += "Registry LanmanServer: $($_.Exception.Message)"
}

try {
    if (Test-Path $mrxPath) {
        $curStart = (Get-ItemProperty -Path $mrxPath -Name Start -ErrorAction Stop).Start
        if ($curStart -ne 4) {
            Set-ItemProperty -Path $mrxPath -Name Start -Value 4 -Force -ErrorAction Stop
            Write-Log "Registry mrxsmb10\Start: auf 4 gesetzt (Treiber deaktiviert)."
            $changed          = $true
            $rebootRecommended = $true
        }
        else {
            Write-Log "Registry mrxsmb10\Start: war bereits 4."
        }
    }
    else {
        Write-Log "Registry mrxsmb10 nicht vorhanden (Treiber bereits entfernt)."
    }
}
catch {
    Write-Log "Registry mrxsmb10 fehlgeschlagen: $($_.Exception.Message)" 'ERROR'
    $errors += "Registry mrxsmb10: $($_.Exception.Message)"
}

#endregion

#region ── Abschluss-Check ───────────────────────────────────────────────────

Write-Log ""
Write-Log "---- Abschlusspruefung ----"

$smb1ActiveAfter = $false

if (Get-Command Get-SmbServerConfiguration -ErrorAction SilentlyContinue) {
    try {
        $srvAfter = Get-SmbServerConfiguration -ErrorAction Stop
        if ($srvAfter.EnableSMB1Protocol) { $smb1ActiveAfter = $true }
        Write-Log "SMB1 Server enabled (nach Remediation): $($srvAfter.EnableSMB1Protocol)"
    }
    catch { }
}

$regValAfter = (Get-ItemProperty -Path $lanmanPath -Name SMB1 -ErrorAction SilentlyContinue).SMB1
if ($regValAfter -eq 1) { $smb1ActiveAfter = $true }
Write-Log "Registry LanmanServer\SMB1 (nach Remediation): $(if ($null -eq $regValAfter) { 'not set' } else { $regValAfter })"

Write-Log ""
if ($smb1ActiveAfter) {
    Write-Log "WARNUNG: SMBv1 noch nicht vollstaendig deaktiviert. Neustart erforderlich oder manuelle Pruefung noetig." 'WARN'
}
elseif ($rebootRecommended) {
    Write-Log "SMBv1 deaktiviert. NEUSTART EMPFOHLEN um alle Aenderungen wirksam zu machen." 'WARN'
}
else {
    Write-Log "SMBv1 erfolgreich deaktiviert. Kein Neustart erforderlich."
    Write-Log "Finding 'SMBv1 Status' ist behoben."
}

#endregion

#region ── Zusammenfassung ───────────────────────────────────────────────────

Write-Log ""
Write-Log "========================================"
Write-Log "  Zusammenfassung"
Write-Log "========================================"
Write-Log "Aenderungen durchgefuehrt : $changed"
Write-Log "Neustart empfohlen        : $rebootRecommended"

if ($errors.Count -gt 0) {
    Write-Log "Fehler aufgetreten:" 'WARN'
    foreach ($e in $errors) { Write-Log "  - $e" 'WARN' }
}

Write-Log ""
Write-Log "Log gespeichert    : $logFile"
if ($remediateMode) {
    Write-Log "Backups gespeichert: $backupDir"
}
Write-Log "Fertig."

#endregion
