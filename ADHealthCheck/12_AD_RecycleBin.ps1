# 12_AD_RecycleBin.ps1
[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [string]$Domain = (Get-ADDomain).DNSRoot,
  [string]$ReportPath = ".\reports\12_AD_RecycleBin.csv",
  [switch]$Remediate
)

$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory
New-Item -ItemType Directory -Path (Split-Path $ReportPath) -Force | Out-Null

$feature = Get-ADOptionalFeature -Filter "name -like 'Recycle Bin Feature'" -Server $Domain
$enabled = (Get-ADOptionalFeature -Identity $feature.DistinguishedName -Properties EnabledScopes -Server $Domain).EnabledScopes.Count -gt 0

$row = [pscustomobject]@{
  Domain     = $Domain
  Enabled    = $enabled
  Remediated = $false
  Note       = ""
}

if ($Remediate -and -not $enabled) {
  if ($PSCmdlet.ShouldProcess($Domain, "Enable AD Recycle Bin (forest-wide, one-way change)")) {
    try {
      Enable-ADOptionalFeature -Identity $feature.DistinguishedName -Scope ForestOrConfigurationSet -Target $Domain -Server $Domain
      $row.Remediated = $true
      $row.Enabled = $true
    } catch { $row.Note = $_.Exception.Message }
  }
}

$row | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportPath
$row
