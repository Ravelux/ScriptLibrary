# 14_DNS_Scavenging.ps1
# Paste Common Header above this line first

$ReportPath = Join-Path $BaseReportDir "14_DNS_Scavenging.csv"
Import-Module DnsServer -ErrorAction Stop

$cur = Get-DnsServerScavenging
Write-Host "Scavenging aktiv: $($cur.ScavengingState)"
Write-Host "NoRefresh: $($cur.NoRefreshInterval.Days) Tage | Refresh: $($cur.RefreshInterval.Days) Tage | Interval: $($cur.ScavengingInterval.Days) Tage"

$NoRefreshDays = 7
$RefreshDays = 7
$ScavengingIntervalDays = 7

$rem = $false
$note = "No change"

if (-not $cur.ScavengingState) {
  if (Read-YesNo "DNS Scavenging aktivieren (Standard 7/7/7)?") {
    try {
      Set-DnsServerScavenging -ScavengingState $true `
        -NoRefreshInterval (New-TimeSpan -Days $NoRefreshDays) `
        -RefreshInterval (New-TimeSpan -Days $RefreshDays) `
        -ScavengingInterval (New-TimeSpan -Days $ScavengingIntervalDays)
      $rem = $true
      $note = "Enabled"
      $cur = Get-DnsServerScavenging
    } catch { $note = $_.Exception.Message }
  }
}

$out = [pscustomobject]@{
  Computer=$env:COMPUTERNAME
  ScavengingState=$cur.ScavengingState
  NoRefreshDays=$cur.NoRefreshInterval.Days
  RefreshDays=$cur.RefreshInterval.Days
  ScavengingIntervalDays=$cur.ScavengingInterval.Days
  Remediated=$rem
  Note=$note
  Timestamp=(Get-Date)
}
$out | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportPath
$out
