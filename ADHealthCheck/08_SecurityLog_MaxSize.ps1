<#
.SYNOPSIS
    Setzt die maximale Größe des Security-Eventlogs auf 4 GB.

.DESCRIPTION
    1. Setzt den Wert nachhaltig via GPO ("Default Domain Controllers Policy")
    2. Erzwingt gpupdate /force auf allen DCs
    3. Korrigiert den SYSTEM-Hive-Registry-Wert direkt (wird von Get-EventLog
       und dem ADHealthCheck gelesen)
    4. Verifiziert das Ergebnis auf dem lokalen DC

    Hintergrund:
    Die GPO schreibt:  HKLM\SOFTWARE\Policies\Microsoft\Windows\EventLog\Security\MaxSize (KB)
    wevtutil liest:    HKLM\SOFTWARE\Policies\... korrekt
    Get-EventLog liest HKLM\SYSTEM\CurrentControlSet\Services\EventLog\Security\MaxSize (Bytes)
    -- dieser Wert wird NICHT automatisch durch die GPO aktualisiert und muss
    daher zusätzlich direkt gesetzt werden.
#>

[CmdletBinding()]
param(
    [string]$GpoName    = "Default Domain Controllers Policy",
    [int64]$MaxSizeKB   = 4194304,
    [string]$BackupPath = "C:\Temp\GPO_Backups"
)

$ErrorActionPreference = "Stop"
Import-Module GroupPolicy    -ErrorAction Stop
Import-Module ActiveDirectory -ErrorAction Stop

# --- 0. Vorbereitung ---
$BackupPath   = [System.IO.Path]::GetFullPath($BackupPath)
$MaxSizeBytes = $MaxSizeKB * 1KB   # 4194304 KB = 4294967296 Bytes

if (-not (Test-Path -LiteralPath $BackupPath)) {
    New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
}

# --- 1. GPO-Backup und Policy-Wert setzen ---
Write-Host "`n[1] GPO konfigurieren..." -ForegroundColor Cyan

Get-GPO -Name $GpoName -ErrorAction Stop | Out-Null
Backup-GPO -Name $GpoName -Path $BackupPath -ErrorAction Stop
Write-Host "    Backup erstellt in: $BackupPath"

$regKey = "HKLM\Software\Policies\Microsoft\Windows\EventLog\Security"
Set-GPRegistryValue -Name $GpoName -Key $regKey -ValueName "MaxSize" -Type DWord -Value $MaxSizeKB

$val = Get-GPRegistryValue -Name $GpoName -Key $regKey -ValueName "MaxSize" -ErrorAction Stop
Write-Host "    GPO-Wert gesetzt: MaxSize = $($val.Value) KB"

# --- 2. gpupdate /force auf allen DCs ---
Write-Host "`n[2] Erzwinge gpupdate auf allen DCs..." -ForegroundColor Cyan

$DCs = Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName
foreach ($DC in $DCs) {
    Write-Host "    -> $DC ..." -NoNewline
    try {
        Invoke-Command -ComputerName $DC -ScriptBlock {
            gpupdate /force /wait:0 | Out-Null
        } -ErrorAction Stop
        Write-Host " OK"
    }
    catch {
        Write-Warning "gpupdate auf $DC fehlgeschlagen: $_"
    }
}

# --- 3. SYSTEM-Hive direkt korrigieren (alle DCs) ---
Write-Host "`n[3] Korrigiere SYSTEM-Hive auf allen DCs..." -ForegroundColor Cyan

$svcRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Security"

foreach ($DC in $DCs) {
    Write-Host "    -> $DC ..." -NoNewline
    try {
        Invoke-Command -ComputerName $DC -ScriptBlock {
            param($Path, $Value)
            Set-ItemProperty -Path $Path -Name "MaxSize" -Value $Value -Type QWord
        } -ArgumentList $svcRegPath, $MaxSizeBytes -ErrorAction Stop
        Write-Host " OK"
    }
    catch {
        Write-Warning "Registry-Korrektur auf $DC fehlgeschlagen: $_"
    }
}

# --- 4. Verifikation (lokal, exakt wie ADHealthCheck) ---
Write-Host "`n[4] Verifikation auf lokalem DC..." -ForegroundColor Cyan

$checkGetEventLog = (Get-EventLog -List | Where-Object Log -match "Security").MaximumKilobytes
$checkSvcReg      = (Get-ItemProperty -Path $svcRegPath -Name "MaxSize").MaxSize
$checkPolReg      = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EventLog\Security" -Name "MaxSize").MaxSize
$checkWevtutil    = (wevtutil gl Security | Select-String "maxSize").ToString().Trim()

Write-Host "    Get-EventLog (Health-Check-Methode) : $checkGetEventLog KB"
Write-Host "    SYSTEM-Hive MaxSize (Bytes)         : $checkSvcReg  (~$([math]::Round($checkSvcReg / 1KB)) KB)"
Write-Host "    GPO Policy MaxSize (KB)             : $checkPolReg KB"
Write-Host "    wevtutil                            : $checkWevtutil"

if ($checkGetEventLog -ge $MaxSizeKB) {
    Write-Host "`n    OK: ADHealthCheck wird den korrekten Wert lesen." -ForegroundColor Green
}
else {
    Write-Host "`n    WARNUNG: Get-EventLog liest weiterhin $checkGetEventLog KB -- manuelle Prüfung erforderlich." -ForegroundColor Yellow
}
