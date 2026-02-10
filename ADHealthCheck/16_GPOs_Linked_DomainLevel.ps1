# 16_GPOs_Linked_DomainLevel.ps1
[CmdletBinding()]
param(
  [string]$Domain = (Get-ADDomain).DNSRoot,
  [string]$ReportPath = ".\reports\16_GPOs_Linked_DomainLevel.csv"
)

$ErrorActionPreference = "Stop"
Import-Module GroupPolicy
New-Item -ItemType Directory -Path (Split-Path $ReportPath) -Force | Out-Null

$inh = Get-GPInheritance -Target $Domain
$rows = foreach ($l in $inh.GpoLinks) {
  [pscustomobject]@{
    Domain        = $Domain
    DisplayName   = $l.DisplayName
    Enabled       = $l.Enabled
    Enforced      = $l.Enforced
    Order         = $l.Order
    GpoId         = $l.GpoId
  }
}

$rows | Sort-Object Order | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportPath
$rows | Sort-Object Order
