<#
Setzt in der GPO "Default Domain Controllers Policy" die maximale Größe des Security-Eventlogs auf 4 GB (4194304 KB).

Registry-Policy:
HKLM\Software\Policies\Microsoft\Windows\EventLog\Security
  MaxSize (DWORD) = 4194304
#>

[CmdletBinding()]
param(
  [string]$GpoName = "Default Domain Controllers Policy",
  [int]$MaxSizeKB = 4194304,
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
$regKey = "HKLM\Software\Policies\Microsoft\Windows\EventLog\Security"
Set-GPRegistryValue -Name $GpoName -Key $regKey -ValueName "MaxSize" -Type DWord -Value $MaxSizeKB

# Kontrolle
$val = Get-GPRegistryValue -Name $GpoName -Key $regKey -ValueName "MaxSize" -ErrorAction Stop

Write-Host "OK: '$GpoName' angepasst."
Write-Host "Backup erstellt in: $BackupPath"
Write-Host "Security Log MaxSize (KB): $($val.Value)"