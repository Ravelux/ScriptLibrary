<#
    Setzt die maximale Größe des Security-Eventlogs via GPO UND erzwingt
    die sofortige Anwendung auf allen DCs per gpupdate.
    Prüft anschließend den tatsächlichen Registry-Wert auf dem lokalen DC.

    GPO-Registry-Policy:
        HKLM\Software\Policies\Microsoft\Windows\EventLog\Security
        MaxSize (DWORD) = 4194304

    Tatsächlicher Eventlog-Registry-Wert (vom Health Check geprüft):
        HKLM\SYSTEM\CurrentControlSet\Services\EventLog\Security
        MaxSize (DWORD) = 4194304 * 1024  (Bytes!)
#>

[CmdletBinding()]
param(
    [string]$GpoName    = "Default Domain Controllers Policy",
    [int]$MaxSizeKB     = 4194304,
    [string]$BackupPath = "C:\Temp\GPO_Backups"
)

$ErrorActionPreference = "Stop"
Import-Module GroupPolicy -ErrorAction Stop
Import-Module ActiveDirectory -ErrorAction Stop

$BackupPath = [System.IO.Path]::GetFullPath($BackupPath)
if (-not (Test-Path -LiteralPath $BackupPath)) {
    New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
}

# --- 1. GPO prüfen und Backup erstellen ---
Get-GPO -Name $GpoName -ErrorAction Stop | Out-Null
Backup-GPO -Name $GpoName -Path $BackupPath -ErrorAction Stop
Write-Host "Backup erstellt in: $BackupPath"

# --- 2. GPO-Wert setzen ---
$regKey = "HKLM\Software\Policies\Microsoft\Windows\EventLog\Security"
Set-GPRegistryValue -Name $GpoName -Key $regKey -ValueName "MaxSize" `
    -Type DWord -Value $MaxSizeKB

$val = Get-GPRegistryValue -Name $GpoName -Key $regKey -ValueName "MaxSize" -ErrorAction Stop
Write-Host "GPO-Wert gesetzt: Security Log MaxSize = $($val.Value) KB"

# --- 3. gpupdate /force auf allen DCs erzwingen ---
Write-Host "`nErzwinge gpupdate auf allen DCs..."
$DCs = Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName

foreach ($DC in $DCs) {
    Write-Host "  -> $DC ..." -NoNewline
    try {
        Invoke-Command -ComputerName $DC -ScriptBlock {
            & gpupdate /force /wait:0 | Out-Null
        } -ErrorAction Stop
        Write-Host " OK"
    }
    catch {
        Write-Warning "  gpupdate auf $DC fehlgeschlagen: $_"
    }
}

# --- 4. Tatsächlichen Registry-Wert auf lokalen DC prüfen ---
# Health Checks lesen oft SYSTEM\CurrentControlSet\Services\EventLog\Security\MaxSize
# Dieser Wert wird in BYTES gespeichert (nicht KB!)
Write-Host "`nPruefe tatsaechlichen Registry-Wert auf lokalem DC..."

$svcKey  = "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Security"
$polKey  = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EventLog\Security"

foreach ($path in @($svcKey, $polKey)) {
    try {
        $raw = (Get-ItemProperty -Path $path -Name "MaxSize" -ErrorAction Stop).MaxSize
        # Wert kann in Bytes oder KB vorliegen -- heuristisch unterscheiden
        if ($raw -gt 10000000) {
            Write-Host "  $path -> $raw Bytes (~$([math]::Round($raw/1KB)) KB)"
        } else {
            Write-Host "  $path -> $raw KB"
        }
    }
    catch {
        Write-Host "  $path -> nicht vorhanden oder kein Zugriff"
    }
}

Write-Host "`nFertig. Bitte Health Check nach Replikation erneut ausfuehren."
