# 11_Users_PasswordLastSet_OverDays_REPORT.ps1
[CmdletBinding()]
param(
  [int]$Days = 90,
  [string]$ReportPath = ".\reports\11_Users_PasswordLastSet_OverDays.csv",
  [string[]]$ExcludeSamAccountName = @("Administrator","krbtgt")
)

$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory -ErrorAction Stop

$DomainDns = if ($env:USERDNSDOMAIN) { $env:USERDNSDOMAIN } else { (Get-ADDomain).DNSRoot }
New-Item -ItemType Directory -Path (Split-Path $ReportPath) -Force | Out-Null

$cutoff = (Get-Date).AddDays(-$Days)

$users = Get-ADUser -Server $DomainDns -Filter * `
  -Properties PasswordLastSet,PasswordNeverExpires,Enabled,Description

$rows = foreach ($u in $users) {
  if ($ExcludeSamAccountName -contains $u.SamAccountName) { continue }
  if (-not $u.PasswordLastSet) { continue }
  if ($u.PasswordLastSet -ge $cutoff) { continue }

  [pscustomobject]@{
    Domain              = $DomainDns
    SamAccountName      = $u.SamAccountName
    Enabled             = $u.Enabled
    PasswordNeverExpires= $u.PasswordNeverExpires
    PasswordLastSet     = $u.PasswordLastSet
    DaysSincePwdChange  = [int]((New-TimeSpan -Start $u.PasswordLastSet -End (Get-Date)).TotalDays)
    Description         = $u.Description
    DistinguishedName   = $u.DistinguishedName
  }
}

$rows | Sort-Object DaysSincePwdChange -Descending | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportPath
$rows | Sort-Object DaysSincePwdChange -Descending
