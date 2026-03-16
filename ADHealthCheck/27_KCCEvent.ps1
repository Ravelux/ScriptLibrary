# ============================================================
# AD Health - KCC Event Finding Remediation
# ============================================================
# Interaktives Skript zur Analyse und Behebung von KCC-Fehlern
# Verwendbar fuer mehrere Kunden/Umgebungen
# ============================================================

#Requires -Modules ActiveDirectory

# --- Eingabe: Betroffener Domaincontroller ---
$targetDC = Read-Host "Bitte den betroffenen Domaincontroller eingeben (FQDN oder Hostname)"

if (-not $targetDC) {
    Write-Warning "Kein Domaincontroller angegeben. Skript wird beendet."
    exit
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " KCC Event Analyse fuer: $targetDC" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# --- Schritt 1: Event Log auf KCC-Fehler pruefen ---
Write-Host "[1/4] Pruefe Event Log auf KCC-Fehler (Event ID 1311, 1265, 1925, 1566)..." -ForegroundColor Yellow

try {
    $kccEvents = Get-WinEvent -ComputerName $targetDC -LogName "Directory Service" -MaxEvents 50 -ErrorAction Stop |
        Where-Object { $_.Id -in @(1311, 1265, 1925, 1566, 1308) }

    if ($kccEvents) {
        Write-Host "  Gefundene KCC-relevante Ereignisse:" -ForegroundColor Red
        $kccEvents | Select-Object TimeCreated, Id, Message | Format-Table -AutoSize -Wrap
    } else {
        Write-Host "  Keine aktuellen KCC-Fehler im Event Log gefunden." -ForegroundColor Green
    }
} catch {
    Write-Warning "  Event Log konnte nicht abgerufen werden: $_"
}

# --- Schritt 2: Replikationsstatus pruefen ---
Write-Host "`n[2/4] Pruefe Replikationsstatus (repadmin /showrepl)..." -ForegroundColor Yellow

try {
    $replOutput = repadmin /showrepl $targetDC 2>&1
    $replOutput | Out-String | Write-Host
} catch {
    Write-Warning "  repadmin konnte nicht ausgefuehrt werden: $_"
}

# --- Schritt 3: Konnektivitaet zu Replikationspartnern pruefen ---
Write-Host "`n[3/4] Pruefe Konnektivitaet zu Replikationspartnern..." -ForegroundColor Yellow

try {
    $partners = repadmin /showrepl $targetDC | Select-String "DC=" | ForEach-Object {
        ($_ -split "DC=")[0].Trim().TrimStart("=>").Trim()
    } | Where-Object { $_ -ne "" } | Sort-Object -Unique

    if ($partners) {
        foreach ($partner in $partners) {
            $ping = Test-Connection -ComputerName $partner -Count 1 -Quiet -ErrorAction SilentlyContinue
            $status = if ($ping) { "ERREICHBAR" } else { "NICHT ERREICHBAR" }
            $color  = if ($ping) { "Green" } else { "Red" }
            Write-Host "  $partner -> $status" -ForegroundColor $color
        }
    } else {
        Write-Host "  Keine Replikationspartner gefunden." -ForegroundColor Yellow
    }
} catch {
    Write-Warning "  Fehler beim Pruefen der Replikationspartner: $_"
}

# --- Schritt 4: KCC-Topologie neu berechnen ---
Write-Host "`n[4/4] KCC-Topologie neu berechnen (repadmin /kcc)..." -ForegroundColor Yellow

$confirm = Read-Host "  Soll die KCC-Neuberechnung auf '$targetDC' jetzt ausgefuehrt werden? (j/n)"
if ($confirm -eq "j") {
    try {
        $kccResult = repadmin /kcc $targetDC 2>&1
        Write-Host "  Ergebnis: $kccResult" -ForegroundColor Green
    } catch {
        Write-Warning "  KCC-Neuberechnung fehlgeschlagen: $_"
    }
} else {
    Write-Host "  KCC-Neuberechnung uebersprungen." -ForegroundColor Yellow
}

# --- Abschlusszusammenfassung ---
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " Analyse abgeschlossen fuer: $targetDC"  -ForegroundColor Cyan
Write-Host " Bitte Ergebnisse pruefen und im Ticket" -ForegroundColor Cyan
Write-Host " dokumentieren."                          -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan