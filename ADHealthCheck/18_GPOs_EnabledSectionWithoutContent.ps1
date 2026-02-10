# 18_GPOs_EnabledSectionWithoutContent.ps1
[CmdletBinding()]
param(
  [string]$ReportPath = ".\reports\18_GPOs_EnabledSectionWithoutContent.csv"
)

$ErrorActionPreference = "Stop"
Import-Module GroupPolicy
New-Item -ItemType Directory -Path (Split-Path $ReportPath) -Force | Out-Null

function Test-GpoSectionHasContent {
  param(
    [xml]$Xml,
    [ValidateSet("User","Computer")]$Section
  )
  $node = $Xml.GPO.$Section
  if (-not $node) { return $false }

  $hasExt = $false
  if ($node.ExtensionData -and $node.ExtensionData.Extension) {
    foreach ($e in $node.ExtensionData.Extension) {
      if ($e.InnerXml -and $e.InnerXml.Trim().Length -gt 0) { $hasExt = $true; break }
      if ($e.Name -and $e.Name.Trim().Length -gt 0) { $hasExt = $true; break }
    }
  }

  $hasPolicy = $false
  if ($node.Policy -and $node.Policy.Count -gt 0) { $hasPolicy = $true }

  return ($hasExt -or $hasPolicy)
}

$gpos = Get-GPO -All
$rows = foreach ($g in $gpos) {
  $xmlText = Get-GPOReport -Guid $g.Id -ReportType Xml
  $xml = [xml]$xmlText

  $userEnabled = ($g.GpoStatus -ne "ComputerSettingsDisabled")
  $compEnabled = ($g.GpoStatus -ne "UserSettingsDisabled")

  $userHas = Test-GpoSectionHasContent -Xml $xml -Section User
  $compHas = Test-GpoSectionHasContent -Xml $xml -Section Computer

  if ($userEnabled -and -not $userHas) {
    [pscustomobject]@{
      GpoName      = $g.DisplayName
      GpoId        = $g.Id
      Section      = "User"
      Enabled      = $true
      HasContent   = $false
      Note         = "User settings enabled but no detectable content"
    }
  }
  if ($compEnabled -and -not $compHas) {
    [pscustomobject]@{
      GpoName      = $g.DisplayName
      GpoId        = $g.Id
      Section      = "Computer"
      Enabled      = $true
      HasContent   = $false
      Note         = "Computer settings enabled but no detectable content"
    }
  }
}

$rows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportPath
$rows
