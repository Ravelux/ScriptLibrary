# 12_AD_RecycleBin.ps1
# === Common Header ===
$ErrorActionPreference = "Stop"

function Read-YesNo {
  param(
    [Parameter(Mandatory=$true)][string]$Question,
    [bool]$DefaultNo = $true
  )
  $suffix = if ($DefaultNo) { " (j/N)" } else { " (J/n)" }
  $a = Read-Host ($Question + $suffix)
  if ([string]::IsNullOrWhiteSpace($a)) { return (-not $DefaultNo) }
  return ($a -match '^(j|ja|y|yes)$')
}

# Domain automatisch (falls AD Module später gebraucht werden)
$DomainDns = if ($env:USERDNSDOMAIN) { $env:USERDNSDOMAIN } else { $null }

# Report-Basis
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$BaseReportDir = if ($DomainDns) {
  "C:\Temp\AD-Healthcheck-Reports\$DomainDns\$ts"
} else {
  "C:\Temp\AD-Healthcheck-Reports\_nodomain_\$ts"
}
New-Item -ItemType Directory -Path $BaseReportDir -Force | Out-Null
# Paste Common Header above this line first

Import-Module ActiveDirectory -ErrorAction Stop
if (-not $DomainDns) { $DomainDns = (Get-ADDomain).DNSRoot }

$ReportPath = Join-Path $BaseReportDir "12_AD_RecycleBin.csv"

$feature = Get-ADOptionalFeature -Filter "name -like 'Recycle Bin Feature'" -Server $DomainDns
$enabledScopes = (Get-ADOptionalFeature -Identity $feature.DistinguishedName -Properties EnabledScopes -Server $DomainDns).EnabledScopes
$enabled = ($enabledScopes.Count -gt 0)

Write-Host "AD Recycle Bin aktiv: $enabled"
if (-not $enabled) {
  Write-Host "Hinweis: Aktivieren ist nicht rückgängig machbar."
}

$rem = $false
$note = "No change"

if (-not $enabled) {
  if (Read-YesNo "Recycle Bin jetzt aktivieren (Forest-weit, Einweg)?") {
    try {
      Enable-ADOptionalFeature -Identity $feature.DistinguishedName -Scope ForestOrConfigurationSet -Target $DomainDns -Server $DomainDns
      $rem = $true
      $enabled = $true
      $note = "Enabled"
    } catch { $note = $_.Exception.Message }
  }
}

$out = [pscustomobject]@{ Domain=$DomainDns; Enabled=$enabled; Remediated=$rem; Note=$note; Timestamp=(Get-Date) }
$out | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportPath
$out