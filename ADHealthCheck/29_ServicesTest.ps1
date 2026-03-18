# =============================================================================
# ADHealthCheck Finding: "Services Test"
# Zweck: Kritische DC-Dienste analysieren und optional reparieren
# Verwendung: Interaktiv, geeignet für mehrere Kunden/Umgebungen
# =============================================================================

param(
    [string]$TargetComputer = "",
    [int]$HoursBack = 12,
    [switch]$AutoFix
)

# --- Zielsystem bestimmen ---
if (-not $TargetComputer) {
    $userInput = Read-Host "Ziel-DC eingeben (leer lassen fuer lokalen Computer: $env:COMPUTERNAME)"
    $TargetComputer = if ($userInput) { $userInput } else { $env:COMPUTERNAME }
}

$isRemote = ($TargetComputer -ne $env:COMPUTERNAME)

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  ADHealthCheck - Services Test Analyse" -ForegroundColor Cyan
Write-Host "  Ziel: $TargetComputer" -ForegroundColor Cyan
Write-Host "  Zeitraum Eventlogs: letzte $HoursBack Stunden" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# --- Verbindungstest bei Remote ---
if ($isRemote) {
    Write-Host "Pruefe Verbindung zu $TargetComputer ..." -ForegroundColor Yellow
    if (-not (Test-Connection -ComputerName $TargetComputer -Count 1 -Quiet)) {
        Write-Host "FEHLER: $TargetComputer ist nicht erreichbar!" -ForegroundColor Red
        exit 1
    }
    Write-Host "Verbindung OK." -ForegroundColor Green
    Write-Host ""
}

# --- Kritische DC-Dienste ---
$criticalServices = @(
    @{ Name = "NTDS";              DisplayName = "Active Directory Domain Services" }
    @{ Name = "Netlogon";          DisplayName = "Netlogon" }
    @{ Name = "Kdc";               DisplayName = "Kerberos Key Distribution Center" }
    @{ Name = "DNS";               DisplayName = "DNS Server" }
    @{ Name = "DFSR";              DisplayName = "DFS Replication" }
    @{ Name = "IsmServ";           DisplayName = "Intersite Messaging" }
    @{ Name = "W32Time";           DisplayName = "Windows Time" }
    @{ Name = "LanmanServer";      DisplayName = "Server" }
    @{ Name = "LanmanWorkstation"; DisplayName = "Workstation" }
    @{ Name = "RpcSs";             DisplayName = "Remote Procedure Call" }
    @{ Name = "EventLog";          DisplayName = "Windows Event Log" }
    @{ Name = "SamSs";             DisplayName = "Security Accounts Manager" }
    @{ Name = "NtFrs";             DisplayName = "File Replication Service (Legacy)" }
)

# =============================================================================
# SCHRITT 1: Dienste-Status prüfen
# =============================================================================
Write-Host "--- [1/4] Dienste-Status auf $TargetComputer ---" -ForegroundColor Yellow
Write-Host ""

$scriptBlock = {
    param($services)
    foreach ($svc in $services) {
        $s = Get-CimInstance Win32_Service -Filter "Name='$($svc.Name)'" -ErrorAction SilentlyContinue
        if ($s) {
            [PSCustomObject]@{
                Name        = $s.Name
                DisplayName = $s.DisplayName
                State       = $s.State
                StartMode   = $s.StartMode
                StartAs     = $s.StartName
                Status      = if ($s.State -eq "Running") { "OK" } elseif ($s.StartMode -eq "Disabled") { "DISABLED" } else { "STOPPED" }
            }
        } else {
            [PSCustomObject]@{
                Name        = $svc.Name
                DisplayName = $svc.DisplayName + " (nicht installiert)"
                State       = "N/A"
                StartMode   = "N/A"
                StartAs     = "N/A"
                Status      = "NICHT INSTALLIERT"
            }
        }
    }
}

if ($isRemote) {
    $serviceResults = Invoke-Command -ComputerName $TargetComputer -ScriptBlock $scriptBlock -ArgumentList (,$criticalServices)
} else {
    $serviceResults = & $scriptBlock $criticalServices
}

$serviceResults | Sort-Object Name | Format-Table Name, DisplayName, State, StartMode, Status -AutoSize

$problemServices = $serviceResults | Where-Object { $_.State -ne "Running" -and $_.State -ne "N/A" }

if ($problemServices) {
    Write-Host ""
    Write-Host "!!! PROBLEMATISCHE DIENSTE GEFUNDEN !!!" -ForegroundColor Red
    $problemServices | Format-Table Name, DisplayName, State, StartMode, Status -AutoSize
} else {
    Write-Host "Alle geprueften Dienste laufen. Kein unmittelbarer Handlungsbedarf." -ForegroundColor Green
}

# =============================================================================
# SCHRITT 2: Event Logs analysieren
# =============================================================================
Write-Host ""
Write-Host "--- [2/4] Ereignisprotokoll-Analyse (letzte $HoursBack Stunden) ---" -ForegroundColor Yellow
Write-Host ""

$logScriptBlock = {
    param($hours)
    $since = (Get-Date).AddHours(-$hours)
    $results = @()

    $logs = @(
        @{ Log = "System";            Filter = "Service Control Manager|NETLOGON|Microsoft-Windows-DFSR|Microsoft-Windows-Time-Service|DNS|NTDS" }
        @{ Log = "Directory Service"; Filter = "." }
        @{ Log = "DNS Server";        Filter = "." }
    )

    foreach ($entry in $logs) {
        $events = Get-WinEvent -FilterHashtable @{
            LogName   = $entry.Log
            Level     = 1, 2, 3
            StartTime = $since
        } -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -match $entry.Filter }

        foreach ($ev in $events) {
            $results += [PSCustomObject]@{
                Log           = $entry.Log
                TimeCreated   = $ev.TimeCreated
                EventId       = $ev.Id
                Level         = $ev.LevelDisplayName
                Provider      = $ev.ProviderName
                Message       = ($ev.Message -split "`n")[0]  # nur erste Zeile
            }
        }
    }
    $results | Sort-Object TimeCreated -Descending
}

if ($isRemote) {
    $logResults = Invoke-Command -ComputerName $TargetComputer -ScriptBlock $logScriptBlock -ArgumentList $HoursBack
} else {
    $logResults = & $logScriptBlock $HoursBack
}

if ($logResults) {
    Write-Host "Gefundene kritische/warnende Ereignisse:" -ForegroundColor Red
    $logResults | Format-Table -AutoSize
} else {
    Write-Host "Keine kritischen Ereignisse in den letzten $HoursBack Stunden gefunden." -ForegroundColor Green
}

# =============================================================================
# SCHRITT 3: dcdiag Services-Test
# =============================================================================
Write-Host ""
Write-Host "--- [3/4] dcdiag /test:Services ---" -ForegroundColor Yellow
Write-Host ""

if ($isRemote) {
    dcdiag /test:Services /s:$TargetComputer
} else {
    dcdiag /test:Services /s:$TargetComputer
}

# =============================================================================
# SCHRITT 4: Optionale Reparatur
# =============================================================================
Write-Host ""
Write-Host "--- [4/4] Reparatur-Option ---" -ForegroundColor Yellow
Write-Host ""

if ($problemServices) {
    Write-Host "Folgende Dienste sind nicht aktiv:" -ForegroundColor Red
    $problemServices | ForEach-Object { Write-Host "  - $($_.Name) ($($_.DisplayName)) -> Status: $($_.State)" -ForegroundColor Red }
    Write-Host ""

    if (-not $AutoFix) {
        $answer = Read-Host "Sollen gestoppte (nicht deaktivierte) Dienste jetzt gestartet werden? (j/n)"
    }

    if ($AutoFix -or $answer -eq "j") {
        $toStart = $problemServices | Where-Object { $_.State -eq "Stopped" -and $_.StartMode -ne "Disabled" }

        if ($toStart) {
            foreach ($svc in $toStart) {
                Write-Host "Starte Dienst: $($svc.Name) ..." -ForegroundColor Yellow
                try {
                    if ($isRemote) {
                        Invoke-Command -ComputerName $TargetComputer -ScriptBlock {
                            param($n)
                            Start-Service -Name $n -ErrorAction Stop
                        } -ArgumentList $svc.Name
                    } else {
                        Start-Service -Name $svc.Name -ErrorAction Stop
                    }
                    Write-Host "  -> $($svc.Name) erfolgreich gestartet." -ForegroundColor Green
                } catch {
                    Write-Host "  -> FEHLER beim Starten von $($svc.Name): $_" -ForegroundColor Red
                }
            }

            Write-Host ""
            Write-Host "Warte 10 Sekunden und pruefe Status erneut ..." -ForegroundColor Cyan
            Start-Sleep -Seconds 10

            Write-Host ""
            Write-Host "Aktualisierter Dienste-Status:" -ForegroundColor Yellow
            if ($isRemote) {
                $updated = Invoke-Command -ComputerName $TargetComputer -ScriptBlock $scriptBlock -ArgumentList (,$criticalServices)
            } else {
                $updated = & $scriptBlock $criticalServices
            }
            $updated | Where-Object { $toStart.Name -contains $_.Name } | Format-Table Name, State, StartMode, Status -AutoSize

        } else {
            Write-Host "Keine Dienste zum automatischen Starten gefunden (deaktivierte Dienste muessen manuell behandelt werden)." -ForegroundColor Yellow
        }
    } else {
        Write-Host "Keine automatische Reparatur durchgefuehrt. Bitte Dienste manuell pruefen." -ForegroundColor Yellow
    }
} else {
    Write-Host "Keine Reparatur notwendig - alle Dienste laufen." -ForegroundColor Green
}

# =============================================================================
# Abschluss
# =============================================================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Analyse abgeschlossen: $TargetComputer" -ForegroundColor Cyan
Write-Host "  Hinweis: Persistente Ausfaelle bitte anhand der Eventlogs," -ForegroundColor Cyan
Write-Host "  Dienstabhaengigkeiten und Systemressourcen weiter bewerten." -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan