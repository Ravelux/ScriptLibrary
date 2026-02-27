<#
Setzt in der GPO "Default Domain Controllers Policy" die maximale Größe des System-Eventlogs auf 1 GB (1048576 KB).

Registry-Policy:
HKLM\Software\Policies\Microsoft\Windows\EventLog\System
  MaxSize (DWORD) = 1048576
#>

[CmdletBinding()]
param(
  [string]$GpoName = "Default Domain Controllers Policy",
  [int]$MaxSizeKB = 1048576,
  [string]$BackupPath = "C:\Temp\GPO_Backups"
)

$ErrorActionPreference = "Stop"
Import-Module GroupPolicy -ErrorAction Stop

# Absoluten Pfad erzwingen
$BackupPath = [System.IO.Path]::GetFullPath($BackupPath)

# Ordner sicher anlegen
if (-not (Test-Path -LiteralPath $BackupPath)) {
  New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
}

# GPO prüfen
Get-GPO -Name $GpoName -ErrorAction Stop

# Backup erstellen
Backup-GPO -Name $GpoName -Path $BackupPath -ErrorAction Stop

# Wert setzen
$regKey = "HKLM\Software\Policies\Microsoft\Windows\EventLog\System"
Set-GPRegistryValue -Name $GpoName -Key $regKey -ValueName "MaxSize" -Type DWord -Value $MaxSizeKB

# Kontrolle
$val = Get-GPRegistryValue -Name $GpoName -Key $regKey -ValueName "MaxSize" -ErrorAction Stop

Write-Host "OK: '$GpoName' angepasst."
Write-Host "Backup erstellt in: $BackupPath"
Write-Host "System Log MaxSize (KB): $($val.Value)"