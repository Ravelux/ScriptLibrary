# 05_SystemLog_Test.ps1
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

$ReportPath = Join-Path $BaseReportDir "05_SystemLog_Test.csv"
$Source = "ADHealthcheckScript"
$EventId = 42001

$do = Read-YesNo "Systemlog Test ausführen (Event Source anlegen falls nötig, Testevent schreiben)?"

$note = ""
$wrote = $false
try {
  if ($do) {
    $svc = Get-Service -Name eventlog -ErrorAction Stop
    if ($svc.StartType -ne "Automatic") { Set-Service -Name eventlog -StartupType Automatic }
    if ($svc.Status -ne "Running") { Start-Service -Name eventlog }

    if (-not [System.Diagnostics.EventLog]::SourceExists($Source)) {
      New-EventLog -LogName System -Source $Source
    }

    Write-EventLog -LogName System -Source $Source -EventId $EventId -EntryType Information -Message "System log write test."
    $found = Get-WinEvent -FilterHashtable @{LogName="System"; Id=$EventId} -MaxEvents 1 -ErrorAction SilentlyContinue
    $wrote = [bool]$found
  } else {
    $note = "Skipped by operator"
  }
} catch { $note = $_.Exception.Message }

$out = [pscustomobject]@{
  Computer    = $env:COMPUTERNAME
  EventLogSvc = (Get-Service eventlog).Status.ToString()
  Tested      = $do
  WroteEvent  = $wrote
  EventId     = $EventId
  Note        = $note
  Timestamp   = (Get-Date)
}
$out | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportPath
$out