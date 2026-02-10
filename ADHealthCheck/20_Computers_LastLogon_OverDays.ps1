# 20_Computers_LastLogon_OverDays.ps1
# Finding: Computer accounts with last Logon date over X days ago (medium)
# Zweck: Erst Report erstellen, dann abfragen ob Bereinigung (Disable/Move) durchgeführt werden soll
# Allgemein: Domain automatisch, lauffähig auf jedem DC

[CmdletBinding()]
param(
  [int]$Days = 90,
  [string]$QuarantineOU = "",          # optional: z.B. "OU=Quarantine,DC=contoso,DC=local"
  [switch]$IncludeDisabled = $true,    # auch deaktivierte Computer im Report anzeigen
  [switch]$SkipServers = $false        # optional: Server-OS ausfiltern
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
$BaseReportDir = if ($DomainDns) {
  "C:\Temp\AD-Healthcheck-Reports\$DomainDns\$ts"
} else {
  "C:\Temp\AD-Healthcheck-Reports\_nodomain_\$ts"
}
New-Item -ItemType Directory -Path $BaseReportDir -Force | Out-Null

# === Modules ===
Import-Module ActiveDirectory -ErrorAction Stop
if (-not $DomainDns) { $DomainDns = (Get-ADDomain).DNSRoot }

$ReportPath   = Join-Path $BaseReportDir "20_Computers_LastLogon_OverDays.csv"
$RemediateLog = Join-Path $BaseReportDir "20_Computers_LastLogon_OverDays_Remediation.csv"

$cutoff = (Get-Date).AddDays(-$Days)

Write-Host "Domain: $DomainDns"
Write-Host "Cutoff: $cutoff (>$Days Tage)"
Write-Host "Report: $ReportPath"
Write-Host ""

# === Report ===
$props = @("LastLogonDate","Enabled","OperatingSystem","OperatingSystemVersion","Description","whenCreated","DistinguishedName")
$comps = Get-ADComputer -Server $DomainDns -Filter * -Properties $props

$rows = foreach ($c in $comps) {
  if (-not $IncludeDisabled -and $c.Enabled -eq $false) { continue }

  $ll = $c.LastLogonDate
  if (-not $ll) { continue }
  if ($ll -ge $cutoff) { continue }

  if ($SkipServers -and $c.OperatingSystem -like "*Server*") { continue }

  [pscustomobject]@{
    Domain            = $DomainDns
    Name              = $c.Name
    Enabled           = $c.Enabled
    LastLogonDate     = $ll
    DaysSinceLogon    = [int]((New-TimeSpan -Start $ll -End (Get-Date)).TotalDays)
    OperatingSystem   = $c.OperatingSystem
    OSVersion         = $c.OperatingSystemVersion
    WhenCreated       = $c.whenCreated
    Description       = $c.Description
    DistinguishedName = $c.DistinguishedName
  }
}

$rowsSorted = $rows | Sort-Object `
  @{Expression='DaysSinceLogon'; Descending=$true}, `
  @{Expression='Name'; Descending=$false}
$rowsSorted | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportPath

Write-Host "Gefundene Computerobjekte: $($rowsSorted.Count)"
if ($rowsSorted.Count -gt 0) {
  $rowsSorted | Select-Object Name,Enabled,DaysSinceLogon,LastLogonDate,OperatingSystem | Format-Table -AutoSize
  Write-Host ""
}

# === Abfrage: Report only oder Bereinigung? ===
if ($rowsSorted.Count -eq 0) { return }

$doCleanup = Read-YesNo "Soll die Bereinigung jetzt durchgeführt werden (sonst nur Report)?"
if (-not $doCleanup) { return }

# === Bereinigung (interaktiv) ===
Write-Host ""
Write-Host "Bereinigung läuft interaktiv pro Objekt."
if ($QuarantineOU) {
  Write-Host "QuarantineOU gesetzt: $QuarantineOU (Verschieben wird zusätzlich gefragt)"
} else {
  Write-Host "QuarantineOU nicht gesetzt: es wird nur deaktiviert (wenn gewählt)"
}
Write-Host ""

$remRows = New-Object System.Collections.Generic.List[object]

foreach ($r in $rowsSorted) {
  $action = "Skipped"
  $ok = $true
  $note = ""

  $q = "Computer '$($r.Name)' deaktivieren? (LastLogon: $($r.LastLogonDate), Days: $($r.DaysSinceLogon), Enabled: $($r.Enabled))"
  if (Read-YesNo $q) {
    try {
      Disable-ADAccount -Server $DomainDns -Identity $r.DistinguishedName
      $action = "Disabled"
    } catch {
      $ok = $false
      $note = $_.Exception.Message
    }

    if ($ok -and $QuarantineOU) {
      $q2 = "Computer '$($r.Name)' zusätzlich nach QuarantineOU verschieben?"
      if (Read-YesNo $q2) {
        try {
          Move-ADObject -Server $DomainDns -Identity $r.DistinguishedName -TargetPath $QuarantineOU
          $action = "Disabled+Moved"
        } catch {
          $ok = $false
          $note = $_.Exception.Message
        }
      }
    }
  } else {
    $note = "Operator hat nicht zugestimmt"
  }

  $remRows.Add([pscustomobject]@{
    Domain            = $DomainDns
    Name              = $r.Name
    DistinguishedName = $r.DistinguishedName
    LastLogonDate     = $r.LastLogonDate
    DaysSinceLogon    = $r.DaysSinceLogon
    Action            = $action
    Success           = $ok
    Note              = $note
    Timestamp         = (Get-Date)
  })
}

$remRows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $RemediateLog
Write-Host ""
Write-Host "Remediation Log: $RemediateLog"
$remRows | Format-Table -AutoSize
