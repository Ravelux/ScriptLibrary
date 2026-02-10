# 10_Users_LastLogon_OverDays_REPORT.ps1
[CmdletBinding()]
param(
  [int]$Days = 90,
  [string]$ReportPath = ".\reports\10_Users_LastLogon_OverDays.csv",
  [string[]]$ExcludeSamAccountName = @("Administrator","krbtgt")
)

$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory -ErrorAction Stop

$DomainDns = if ($env:USERDNSDOMAIN) { $env:USERDNSDOMAIN } else { (Get-ADDomain).DNSRoot }
New-Item -ItemType Directory -Path (Split-Path $ReportPath) -Force | Out-Null

$cutoff = (Get-Date).AddDays(-$Days)

$users = Get-ADUser -Server $DomainDns -Filter * -Properties LastLogonDate,Enabled,Description

$rows = foreach ($u in $users) {
  if ($ExcludeSamAccountName -contains $u.SamAccountName) { continue }
  if (-not $u.LastLogonDate) { continue }
  if ($u.LastLogonDate -ge $cutoff) { continue }

  [pscustomobject]@{
    Domain            = $DomainDns
    SamAccountName    = $u.SamAccountName
    Enabled           = $u.Enabled
    LastLogonDate     = $u.LastLogonDate
    DaysSinceLogon    = [int]((New-TimeSpan -Start $u.LastLogonDate -End (Get-Date)).TotalDays)
    Description       = $u.Description
    DistinguishedName = $u.DistinguishedName
  }
}

$rows | Sort-Object DaysSinceLogon -Descending | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportPath
$rows | Sort-Object DaysSinceLogon -Descending
