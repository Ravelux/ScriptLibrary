# 01_PrintSpooler.ps1
# Analyse und optionale Bereinigung des Print Spooler Findings
# Exportiert eine CSV zur Dokumentation / Weitergabe

$ErrorActionPreference = "Stop"

function Read-YesNo {
  param(
    [Parameter(Mandatory = $true)][string]$Question,
    [bool]$DefaultNo = $true
  )
  $suffix = if ($DefaultNo) { " (j/N)" } else { " (J/n)" }
  $a = Read-Host ($Question + $suffix)
  if ([string]::IsNullOrWhiteSpace($a)) { return (-not $DefaultNo) }
  return ($a -match '^(j|ja|y|yes)$')
}

function Get-LocalPrinters {
  if (Get-Command Get-Printer -ErrorAction SilentlyContinue) {
    try {
      return Get-Printer | Select-Object Name, DriverName, PortName, Shared, Published
    } catch {}
  }

  try {
    return Get-CimInstance Win32_Printer | Select-Object Name, DriverName, PortName, Shared, Published
  } catch {
    return @()
  }
}

function Get-SpoolerStartMode {
  try {
    return (Get-CimInstance Win32_Service -Filter "Name='Spooler'").StartMode
  } catch {
    return $null
  }
}

# Domain automatisch für Reportpfad
$DomainDns = if ($env:USERDNSDOMAIN) { $env:USERDNSDOMAIN } else { $null }

# Reportpfad
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$BaseReportDir = if ($DomainDns) {
  "C:\Temp\AD-Healthcheck-Reports\$DomainDns\$ts"
} else {
  "C:\Temp\AD-Healthcheck-Reports\_nodomain_\$ts"
}
New-Item -ItemType Directory -Path $BaseReportDir -Force | Out-Null

$ReportPath = Join-Path $BaseReportDir "01_PrintSpooler.csv"

Write-Host ""
Write-Host "=== Analyse Print Spooler auf $env:COMPUTERNAME ===" -ForegroundColor Cyan

$printers = Get-LocalPrinters
$printerCount = if ($printers) { @($printers).Count } else { 0 }

Write-Host ""
Write-Host "Gefundene Drucker:"
if ($printerCount -gt 0) {
  $printers | Sort-Object Name | Format-Table -AutoSize
} else {
  Write-Host "Keine Drucker gefunden oder Abfrage nicht möglich."
}

$svc = Get-Service -Name Spooler -ErrorAction SilentlyContinue
if (-not $svc) {
  $out = [pscustomobject]@{
    Computer              = $env:COMPUTERNAME
    PrintersFound         = $printerCount
    ServiceExists         = $false
    ServiceStatusBefore   = $null
    StartTypeBefore       = $null
    ServiceStatusAfter    = $null
    StartTypeAfter        = $null
    ActionTaken           = "Keine Aktion"
    Recommendation        = "Spooler-Dienst nicht vorhanden"
    ExceptionRecommended  = $false
    ExceptionHint         = $null
    Note                  = "Spooler not found"
    Timestamp             = Get-Date
  }

  $out | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportPath
  Write-Host ""
  Write-Host "Spooler-Dienst wurde auf diesem System nicht gefunden."
  Write-Host "Report: $ReportPath"
  return
}

$startTypeBefore = Get-SpoolerStartMode
$statusBefore = $svc.Status.ToString()

Write-Host ""
Write-Host "Spooler Status vor Änderung: $statusBefore"
Write-Host "Spooler Starttyp vor Änderung: $startTypeBefore"

$likelyNeedsPrinting = $false
if ($printerCount -gt 0) {
  $likelyNeedsPrinting = $true
}

$actionTaken = "Keine Aktion"
$recommendation = ""
$exceptionRecommended = $false
$exceptionHint = $null
$note = "No change"

if ($likelyNeedsPrinting) {
  Write-Host ""
  Write-Host "Hinweis: Es wurden Drucker gefunden. Prüfen, ob der Server bewusst Druckfunktionen bereitstellt." -ForegroundColor Yellow
}

$customerUsesPrintServer = Read-YesNo "Handelt es sich um einen Server, der bewusst Druckfunktionen bereitstellt oder als Printserver genutzt wird?" $true

if ($customerUsesPrintServer) {
  $exceptionRecommended = $true
  $exceptionHint = "$env:COMPUTERNAME Print Spooler Service Status"
  $recommendation = "Printfunktion erforderlich. Finding als Ausnahme in ADHealth_Excluded_Inspectors eintragen."
  $actionTaken = "Keine technische Änderung"
  $note = "Printing required or Printserver in use"
} else {
  $recommendation = "Printfunktion nicht erforderlich. Spooler sollte deaktiviert werden."

  if (Read-YesNo "Spooler stoppen und deaktivieren?" $true) {
    try {
      if ($svc.Status -ne 'Stopped') {
        Stop-Service -Name Spooler -Force -ErrorAction Stop
      }
      Set-Service -Name Spooler -StartupType Disabled
      $actionTaken = "Spooler gestoppt und deaktiviert"
      $note = "Spooler disabled by operator"
    } catch {
      $actionTaken = "Fehler bei Änderung"
      $note = $_.Exception.Message
    }
  } else {
    $actionTaken = "Keine Änderung durch Operator"
    $note = "Operator skipped disable action"
  }
}

$svcAfter = Get-Service -Name Spooler -ErrorAction SilentlyContinue
$startTypeAfter = Get-SpoolerStartMode
$statusAfter = if ($svcAfter) { $svcAfter.Status.ToString() } else { $null }

$out = [pscustomobject]@{
  Computer              = $env:COMPUTERNAME
  PrintersFound         = $printerCount
  ServiceExists         = $true
  ServiceStatusBefore   = $statusBefore
  StartTypeBefore       = $startTypeBefore
  ServiceStatusAfter    = $statusAfter
  StartTypeAfter        = $startTypeAfter
  ActionTaken           = $actionTaken
  Recommendation        = $recommendation
  ExceptionRecommended  = $exceptionRecommended
  ExceptionHint         = $exceptionHint
  Note                  = $note
  Timestamp             = Get-Date
}

$out | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportPath

Write-Host ""
Write-Host "=== Ergebnis ===" -ForegroundColor Cyan
$out | Format-List

Write-Host ""
Write-Host "CSV-Report gespeichert unter: $ReportPath" -ForegroundColor Green

if ($exceptionRecommended -and $exceptionHint) {
  Write-Host ""
  Write-Host "Ausnahmehinweis:" -ForegroundColor Yellow
  Write-Host "Wenn das Finding bewusst bestehen bleiben soll, in ADHealth_Excluded_Inspectors folgenden Eintrag hinterlegen:"
  Write-Host $exceptionHint -ForegroundColor Yellow
}