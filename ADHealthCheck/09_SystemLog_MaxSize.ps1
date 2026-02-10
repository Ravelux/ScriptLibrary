# 09_SystemLog_MaxSize.ps1
# Paste Common Header above this line first

$ReportPath = Join-Path $BaseReportDir "09_SystemLog_MaxSize.csv"
$TargetMB = 128

$gl = wevtutil gl System 2>$null
$msLine = ($gl | Select-String -Pattern "^maxSize").ToString()
$cur = [int64]($msLine.Split(":")[1].Trim())

Write-Host "System Log maxSize aktuell: $([math]::Round($cur/1MB,2)) MB | Ziel: $TargetMB MB"

$rem = $false
$note = "No change"

if ($cur -lt ([int64]$TargetMB * 1MB)) {
  if (Read-YesNo "Auf Zielwert setzen?") {
    try {
      wevtutil sl System /ms:$([int64]$TargetMB * 1MB) | Out-Null
      $rem = $true
      $note = "Updated"
      $gl = wevtutil gl System 2>$null
      $msLine = ($gl | Select-String -Pattern "^maxSize").ToString()
      $cur = [int64]($msLine.Split(":")[1].Trim())
    } catch { $note = $_.Exception.Message }
  }
}

$out = [pscustomobject]@{
  Computer=$env:COMPUTERNAME; LogName="System"; CurrentMB=[math]::Round($cur/1MB,2); TargetMB=$TargetMB; Remediated=$rem; Note=$note; Timestamp=(Get-Date)
}
$out | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportPath
$out