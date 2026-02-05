# 19_GPOs_DisabledLinks.ps1
# Finding: GPOs with disabled Link (low)
# Zweck: Listet alle GPO-Links, die deaktiviert sind (Enabled = false), inkl. Ziel (Domain/OU).
# Optional: Löscht GPOs, die NUR deaktivierte Links haben (keinen einzigen aktiven Link irgendwo).
# Hinweis: Löschen nur nach Operator-Entscheidung, inkl. optionalem Backup je GPO.

[CmdletBinding()]
param(
  [string]$ReportDir = "",
  [switch]$IncludeOUs = $true
)

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

# Domain automatisch
$DomainDns = if ($env:USERDNSDOMAIN) { $env:USERDNSDOMAIN } else { $null }

# Report-Basis
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
if ([string]::IsNullOrWhiteSpace($ReportDir)) {
  $BaseReportDir = if ($DomainDns) {
    "C:\Temp\AD-Healthcheck-Reports\$DomainDns\$ts"
  } else {
    "C:\Temp\AD-Healthcheck-Reports\_nodomain_\$ts"
  }
} else {
  $BaseReportDir = Join-Path $ReportDir $ts
}
New-Item -ItemType Directory -Path $BaseReportDir -Force | Out-Null

# === Modules ===
Import-Module GroupPolicy -ErrorAction Stop
Import-Module ActiveDirectory -ErrorAction Stop

# Domain ermitteln
if (-not $DomainDns) { $DomainDns = (Get-ADDomain).DNSRoot }
$DomainObj = Get-ADDomain -Server $DomainDns
$DomainDN  = $DomainObj.DistinguishedName

# Report Paths
$ReportDisabledLinks = Join-Path $BaseReportDir "19_GPOs_DisabledLinks.csv"
$ReportCandidates    = Join-Path $BaseReportDir "19_GPOs_DisabledLinks_Candidates.csv"
$ReportRemediation   = Join-Path $BaseReportDir "19_GPOs_DisabledLinks_Remediation.csv"

Write-Host "Domain: $DomainDns"
Write-Host "Report Ordner: $BaseReportDir"
Write-Host ""

# Targets sammeln (Domain + optional alle OUs)
$targets = New-Object System.Collections.Generic.List[object]
$targets.Add([pscustomobject]@{ Type="Domain"; DN=$DomainDN; Name=$DomainDns })

if ($IncludeOUs) {
  $ous = Get-ADOrganizationalUnit -Server $DomainDns -Filter * -Properties DistinguishedName,Name |
    Sort-Object DistinguishedName
  foreach ($ou in $ous) {
    $targets.Add([pscustomobject]@{ Type="OU"; DN=$ou.DistinguishedName; Name=$ou.Name })
  }
}

# Tracking: pro GPO ob irgendwo ein aktiver Link existiert
$hasEnabledLink = @{}   # key: Guid string, value: $true

# Disabled-Link Rows
$rows = New-Object System.Collections.Generic.List[object]

foreach ($t in $targets) {
  try {
    $inh = Get-GPInheritance -Target $t.DN -ErrorAction Stop
  } catch {
    $rows.Add([pscustomobject]@{
      Domain        = $DomainDns
      TargetType    = $t.Type
      TargetName    = $t.Name
      TargetDN      = $t.DN
      DisplayName   = ""
      GpoId         = ""
      LinkEnabled   = ""
      Enforced      = ""
      Order         = ""
      Note          = ("Get-GPInheritance failed: " + $_.Exception.Message)
    })
    continue
  }

  foreach ($l in $inh.GpoLinks) {
    $gpoId = ""
    if ($l.GpoId) { $gpoId = $l.GpoId.ToString() }

    # enabled links tracken
    if ($l.Enabled -eq $true -and $gpoId) {
      $hasEnabledLink[$gpoId] = $true
    }

    # disabled links reporten
    if ($l.Enabled -eq $false) {
      $rows.Add([pscustomobject]@{
        Domain        = $DomainDns
        TargetType    = $t.Type
        TargetName    = $t.Name
        TargetDN      = $t.DN
        DisplayName   = $l.DisplayName
        GpoId         = $gpoId
        LinkEnabled   = $l.Enabled
        Enforced      = $l.Enforced
        Order         = $l.Order
        Note          = ""
      })
    }
  }
}

# Report: Disabled Links
$rowsSorted = $rows | Sort-Object TargetType,TargetDN,Order,DisplayName
$rowsSorted | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportDisabledLinks

# Kandidaten: GPOs die nur deaktivierte Links haben (kein einziger aktiver Link)
$disabledGpoIds = $rowsSorted |
  Where-Object { $_.GpoId -and $_.LinkEnabled -eq $false } |
  Select-Object -ExpandProperty GpoId -Unique

$candidateIds = foreach ($id in $disabledGpoIds) {
  if (-not $hasEnabledLink.ContainsKey($id)) { $id }
}

$candidates = New-Object System.Collections.Generic.List[object]
foreach ($id in $candidateIds) {
  try {
    $g = Get-GPO -Guid $id -ErrorAction Stop
    # wie oft/wo ist der Link deaktiviert
    $linkCount = ($rowsSorted | Where-Object { $_.GpoId -eq $id }).Count

    $candidates.Add([pscustomobject]@{
      Domain              = $DomainDns
      DisplayName         = $g.DisplayName
      GpoId               = $g.Id.ToString()
      DisabledLinkCount   = $linkCount
      CreationTime        = $g.CreationTime
      ModificationTime    = $g.ModificationTime
      Owner               = $g.Owner
      CandidateForDeletion= $true
      Note                = "Kein aktiver Link gefunden. Nur deaktivierte Links."
    })
  } catch {
    $candidates.Add([pscustomobject]@{
      Domain              = $DomainDns
      DisplayName         = ""
      GpoId               = $id
      DisabledLinkCount   = ($rowsSorted | Where-Object { $_.GpoId -eq $id }).Count
      CreationTime        = ""
      ModificationTime    = ""
      Owner               = ""
      CandidateForDeletion= $true
      Note                = ("Get-GPO failed: " + $_.Exception.Message)
    })
  }
}

$candidatesSorted = $candidates | Sort-Object `
  @{Expression='DisabledLinkCount'; Descending=$true}, `
  @{Expression='DisplayName'; Descending=$false}
$candidatesSorted | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportCandidates

Write-Host "Ergebnis:"
Write-Host ("- Disabled Links gefunden: " + (($rowsSorted | Where-Object { $_.LinkEnabled -eq $false -and $_.GpoId }).Count))
Write-Host ("- GPO Kandidaten (nur deaktivierte Links): " + $candidatesSorted.Count)
Write-Host ""
Write-Host "CSV Reports:"
Write-Host "- $ReportDisabledLinks"
Write-Host "- $ReportCandidates"
Write-Host ""

if ($candidatesSorted.Count -gt 0) {
  $candidatesSorted | Select-Object DisplayName,GpoId,DisabledLinkCount,ModificationTime,Owner,Note | Format-Table -AutoSize
  Write-Host ""

  $doDelete = Read-YesNo "Sollen GPOs gelöscht werden, die nur deaktivierte Links haben?"
  if ($doDelete) {
    $doBackup = Read-YesNo "Vor dem Löschen je GPO ein Backup erstellen?"
    $backupDir = Join-Path $BaseReportDir "GPO-Backups"
    if ($doBackup) {
      New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }

    $remRows = New-Object System.Collections.Generic.List[object]

    foreach ($c in $candidatesSorted) {
      if ([string]::IsNullOrWhiteSpace($c.GpoId)) { continue }

      $ask = Read-YesNo ("GPO löschen: '" + $c.DisplayName + "' (" + $c.GpoId + ")?")
      if (-not $ask) {
        $remRows.Add([pscustomobject]@{
          Domain      = $DomainDns
          DisplayName = $c.DisplayName
          GpoId       = $c.GpoId
          Action      = "Skipped"
          Success     = $true
          Note        = "Operator hat nicht zugestimmt"
          Timestamp   = (Get-Date)
        })
        continue
      }

      $note = ""
      $ok = $false

      try {
        if ($doBackup) {
          Backup-GPO -Guid $c.GpoId -Path $backupDir -Comment "Backup before deletion (disabled links finding)" | Out-Null
        }
        Remove-GPO -Guid $c.GpoId -Confirm:$false
        $ok = $true
        $note = if ($doBackup) { "Deleted. Backup created." } else { "Deleted." }
      } catch {
        $ok = $false
        $note = $_.Exception.Message
      }

      $remRows.Add([pscustomobject]@{
        Domain      = $DomainDns
        DisplayName = $c.DisplayName
        GpoId       = $c.GpoId
        Action      = "Delete"
        Success     = $ok
        Note        = $note
        Timestamp   = (Get-Date)
      })
    }

    if ($remRows.Count -gt 0) {
      $remRows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportRemediation
      Write-Host ""
      Write-Host "Remediation Report:"
      Write-Host "- $ReportRemediation"
      Write-Host ""
      $remRows | Format-Table -AutoSize
    }
  }
} else {
  Write-Host "Keine GPOs mit deaktivierten Links gefunden, die nur deaktiviert verlinkt sind."
}