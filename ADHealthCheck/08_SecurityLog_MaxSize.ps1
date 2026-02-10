# 08_SecurityLog_MaxSize.ps1
# Paste Common Header above this line first

$ReportPath = Join-Path $BaseReportDir "08_SecurityLog_MaxSize.csv"
$TargetMB = 256

$gl = wevtutil gl Security 2>$null
$msLine = ($gl | Select-String -Pattern "^maxSize").ToString()
$cur = [int64]($msLine.Split(":")[1].Trim())

Write-Host "Security Log maxSize aktuell: $([math]::Round($cur/1MB,2)) MB | Ziel: $TargetMB MB"

$rem = $false
$note = "No change"

if ($cur -lt ([int64]$TargetMB * 1MB)) {
  if (Read-YesNo "Auf Zielwert setzen?") {
    try {
      wevtutil sl Security /ms:$([int64]$TargetMB * 1MB) | Out-Null
      $rem = $true
      $note = "Updated"
      $gl = wevtutil gl Security 2>$null
      $msLine = ($gl | Select-String -Pattern "^maxSize").ToString()
      $cur = [int64]($msLine.Split(":")[1].Trim())
    } catch { $note = $_.Exception.Message }
  }
}

$out = [pscustomobject]@{
  Computer=$env:COMPUTERNAME; LogName="Security"; CurrentMB=[math]::Round($cur/1MB,2); TargetMB=$TargetMB; Remediated=$rem; Note=$note; Timestamp=(Get-Date)
}
$out | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportPath
$out