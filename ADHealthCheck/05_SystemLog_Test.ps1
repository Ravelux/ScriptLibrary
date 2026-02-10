# 05_SystemLog_Test.ps1
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