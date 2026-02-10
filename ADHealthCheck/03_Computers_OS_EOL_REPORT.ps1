# 03_Computers_OS_EOL_REPORT.ps1
[CmdletBinding()]
param(
  [string]$ReportPath = ".\reports\03_Computers_OS_EOL.csv",
  [string[]]$EolOsPatterns = @(
    "Windows 7","Windows 8","Windows 8.1",
    "Windows Server 2003","Windows Server 2008","Windows Server 2008 R2",
    "Windows Server 2012","Windows Server 2012 R2"
  )
)

$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory -ErrorAction Stop

$DomainDns = if ($env:USERDNSDOMAIN) { $env:USERDNSDOMAIN } else { (Get-ADDomain).DNSRoot }
New-Item -ItemType Directory -Path (Split-Path $ReportPath) -Force | Out-Null

$comps = Get-ADComputer -Server $DomainDns -Filter * `
  -Properties OperatingSystem,OperatingSystemVersion,LastLogonDate,Enabled,Description

$rows = foreach ($c in $comps) {
  $os = $c.OperatingSystem
  if (-not $os) { continue }

  $isEol = $false
  foreach ($p in $EolOsPatterns) {
    if ($os -like "*$p*") { $isEol = $true; break }
  }
  if (-not $isEol) { continue }

  [pscustomobject]@{
    Domain          = $DomainDns
    Name            = $c.Name
    Enabled         = $c.Enabled
    OperatingSystem = $c.OperatingSystem
    OSVersion       = $c.OperatingSystemVersion
    LastLogonDate   = $c.LastLogonDate
    Description     = $c.Description
    DistinguishedName = $c.DistinguishedName
  }
}

$rows | Sort-Object OperatingSystem,Name | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportPath
$rows | Sort-Object OperatingSystem,Name