# 02_Users_PasswordNeverExpires_REPORT.ps1
[CmdletBinding()]
param(
  [string]$ReportPath = ".\reports\02_Users_PasswordNeverExpires.csv",
  [string[]]$ExcludeSamAccountName = @("Administrator","krbtgt")
)

$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory -ErrorAction Stop

$DomainDns = if ($env:USERDNSDOMAIN) { $env:USERDNSDOMAIN } else { (Get-ADDomain).DNSRoot }
New-Item -ItemType Directory -Path (Split-Path $ReportPath) -Force | Out-Null

$users = Get-ADUser -Server $DomainDns `
  -LDAPFilter "(userAccountControl:1.2.840.113556.1.4.803:=65536)" `
  -Properties Enabled,PasswordNeverExpires,PasswordLastSet,LastLogonDate,Description

$rows = foreach ($u in $users) {
  if ($ExcludeSamAccountName -contains $u.SamAccountName) { continue }
  [pscustomobject]@{
    Domain              = $DomainDns
    SamAccountName      = $u.SamAccountName
    Enabled             = $u.Enabled
    PasswordNeverExpires= $u.PasswordNeverExpires
    PasswordLastSet     = $u.PasswordLastSet
    LastLogonDate       = $u.LastLogonDate
    Description         = $u.Description
    DistinguishedName   = $u.DistinguishedName
  }
}

$rows | Sort-Object SamAccountName | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportPath
$rows | Sort-Object SamAccountName