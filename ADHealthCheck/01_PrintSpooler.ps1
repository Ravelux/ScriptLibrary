# 01_PrintSpooler.ps1
# === Common Header ===
$ErrorActionPreference = "Stop"

function Read-YesNo {
  param(
    [Parameter(Mandatory=$true)][string]$Question,
    [bool]$DefaultNo = $true
  )
  $suffix = if ($DefaultNo) { " (j/N)" } else { " (J/n)" }
  $a = Read-Host ($Question + $suffix)
  if ([string]::IsNullOrWhiteSpace($a)) { return (-not $DefaultNo) }
  return ($a -match '^(j|ja|y|yes)$')
}

# Domain automatisch (falls AD Module später gebraucht werden)
$DomainDns = if ($env:USERDNSDOMAIN) { $env:USERDNSDOMAIN } else { $null }

# Report-Basis
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$BaseReportDir = if ($DomainDns) {
  "C:\Temp\AD-Healthcheck-Reports\$DomainDns\$ts"
} else {
  "C:\Temp\AD-Healthcheck-Reports\_nodomain_\$ts"
}
New-Item -ItemType Directory -Path $BaseReportDir -Force | Out-Null
# Paste Common Header above this line first

$ReportPath = Join-Path $BaseReportDir "01_PrintSpooler.csv"

function Get-LocalPrinters {
  if (Get-Command Get-Printer -ErrorAction SilentlyContinue) {
    try { return Get-Printer | Select-Object Name, DriverName, PortName, Shared, Published } catch {}
  }
  try { return Get-CimInstance Win32_Printer | Select-Object Name, DriverName, PortName, Shared, Published } catch { return @() }
}

$printers = Get-LocalPrinters
Write-Host "Gefundene Drucker auf $env:COMPUTERNAME:"
if ($printers -and $printers.Count -gt 0) { $printers | Sort-Object Name | Format-Table -AutoSize } else { Write-Host "Keine Drucker gefunden oder Abfrage nicht möglich." }

$svc = Get-Service -Name Spooler -ErrorAction SilentlyContinue
if (-not $svc) {
  $out = [pscustomobject]@{ Computer=$env:COMPUTERNAME; Printers=($printers.Count); Exists=$false; Status=$null; StartType=$null; Disabled=$false; Note="Spooler not found"; Timestamp=(Get-Date) }
  $out | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportPath
  $out
  return
}

$startType = (Get-CimInstance Win32_Service -Filter "Name='Spooler'").StartMode
Write-Host "Spooler Status: $($svc.Status) | Starttyp: $startType"

$didDisable = $false
$note = "No change"
if (Read-YesNo "Spooler stoppen und deaktivieren?") {
  try {
    Stop-Service Spooler -Force -ErrorAction SilentlyContinue
    Set-Service Spooler -StartupType Disabled
    $didDisable = $true
    $note = "Spooler disabled by operator"
  } catch { $note = $_.Exception.Message }
}

$svcAfter = Get-Service -Name Spooler -ErrorAction SilentlyContinue
$startTypeAfter = (Get-CimInstance Win32_Service -Filter "Name='Spooler'").StartMode

$out = [pscustomobject]@{
  Computer=$env:COMPUTERNAME
  Printers=($printers.Count)
  Exists=$true
  Status=$svcAfter.Status.ToString()
  StartType=$startTypeAfter
  Disabled=$didDisable
  Note=$note
  Timestamp=(Get-Date)
}

$out | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportPath
$out
