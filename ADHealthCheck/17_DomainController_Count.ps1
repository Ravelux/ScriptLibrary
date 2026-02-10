# 17_DomainController_Count.ps1
[CmdletBinding()]
param(
  [string]$Domain = (Get-ADDomain).DNSRoot,
  [string]$ReportPath = ".\reports\17_DomainController_Count.csv"
)

$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory
New-Item -ItemType Directory -Path (Split-Path $ReportPath) -Force | Out-Null

$dcs = Get-ADDomainController -Server $Domain -Filter * | Select-Object HostName,IPv4Address,Site,IsGlobalCatalog,IsReadOnly,OperatingSystem
$rows = $dcs | ForEach-Object {
  [pscustomobject]@{
    Domain          = $Domain
    HostName        = $_.HostName
    IPv4Address     = $_.IPv4Address
    Site            = $_.Site
    IsGlobalCatalog = $_.IsGlobalCatalog
    IsReadOnly      = $_.IsReadOnly
    OperatingSystem = $_.OperatingSystem
  }
}

$rows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportPath
$rows
