<#
.SYNOPSIS
  ADHealthCheck DFSREvent Test - Analyse und geführte Basis-Remediation für DFSR SYSVOL.

.DESCRIPTION
  - Prüft DFSR Service, SYSVOL/NETLOGON Shares, DFS Replication Eventlog (Errors/Warnungen) und optional AD Replication Summary.
  - Interaktiv: Auswahl der DCs, Lookback-Zeitraum und optionale Aktionen.
  - Keine kunden- oder domain-spezifischen Annahmen.

.NOTES
  - Für Remote-Checks wird WinRM benötigt.
  - Autoritative/Non-Authoritative SYSVOL Sync (ADSIEdit) wird NICHT automatisiert (High-Risk).
#>

[CmdletBinding()]
param(
  [string[]]$ComputerName,
  [int]$LookbackDays = 7,
  [switch]$IncludeWarnings,
  [switch]$SkipRepadmin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Section([string]$Text) {
  Write-Host ""
  Write-Host ("=" * 78)
  Write-Host $Text
  Write-Host ("=" * 78)
}

function Get-DomainControllerListFromAD {
  try {
    if (Get-Module -ListAvailable -Name ActiveDirectory) {
      Import-Module ActiveDirectory -ErrorAction Stop | Out-Null
      return (Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName)
    }
  } catch { }
  return @()
}

function Get-DomainControllerListFallback {
  try {
    $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
    return ($domain.DomainControllers | ForEach-Object { $_.Name })
  } catch {
    return @()
  }
}

function Resolve-TargetList {
  if ($ComputerName -and $ComputerName.Count -gt 0) {
    return $ComputerName
  }

  Write-Section "Zielauswahl"
  Write-Host "1) Nur lokaler Server"
  Write-Host "2) Alle Domain Controller (Auto-Erkennung)"
  Write-Host "3) DC Namen manuell eingeben"
  $choice = Read-Host "Auswahl (1-3)"

  switch ($choice) {
    "1" { return @($env:COMPUTERNAME) }
    "2" {
      $dcs = Get-DomainControllerListFromAD
      if (-not $dcs -or $dcs.Count -eq 0) { $dcs = Try-GetDCsFallback }
      if (-not $dcs -or $dcs.Count -eq 0) {
        throw "Konnte keine DCs automatisch ermitteln. Bitte Option 3 nutzen."
      }
      return $dcs
    }
    "3" {
      $raw = Read-Host "DC Namen (kommagetrennt, zB DC01,DC02)"
      return ($raw -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    default { throw "Ungültige Auswahl." }
  }
}

function Invoke-RemoteSafe {
  param(
    [Parameter(Mandatory=$true)][string]$Target,
    [Parameter(Mandatory=$true)][scriptblock]$ScriptBlock
  )

  if ($Target -ieq $env:COMPUTERNAME -or $Target -ieq "localhost") {
    return & $ScriptBlock
  }

  return Invoke-Command -ComputerName $Target -ScriptBlock $ScriptBlock
}

function Get-DFSRLogEvents {
  param(
    [Parameter(Mandatory=$true)][string]$Target,
    [Parameter(Mandatory=$true)][datetime]$StartTime,
    [switch]$IncludeWarnings
  )

  $levels = if ($IncludeWarnings) { @(1,2,3) } else { @(1,2) } # 1 Critical, 2 Error, 3 Warning
  $script = {
    param($StartTime, $Levels)
    $logNames = @("DFS Replication")
    foreach ($ln in $logNames) {
      try {
        $fh = @{ LogName = $ln; StartTime = $StartTime }
        $ev = Get-WinEvent -FilterHashtable $fh -ErrorAction Stop |
          Where-Object { $Levels -contains $_.Level } |
          Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message
        return $ev
      } catch { }
    }
    return @()
  }

  return Invoke-RemoteSafe -Target $Target -ScriptBlock $script -ArgumentList $StartTime, $levels
}

function Get-ShareStatus {
  param([Parameter(Mandatory=$true)][string]$Target)

  $script = {
    $shares = Get-CimInstance Win32_Share | Select-Object -ExpandProperty Name
    [pscustomobject]@{
      SYSVOL   = $shares -contains "SYSVOL"
      NETLOGON = $shares -contains "NETLOGON"
    }
  }

  return Invoke-RemoteSafe -Target $Target -ScriptBlock $script
}

function Get-DFSRServiceStatus {
  param([Parameter(Mandatory=$true)][string]$Target)

  $script = {
    $svc = Get-Service -Name "DFSR" -ErrorAction Stop
    [pscustomobject]@{
      Status    = $svc.Status.ToString()
      StartType = (Get-CimInstance Win32_Service -Filter "Name='DFSR'").StartMode
    }
  }

  return Invoke-RemoteSafe -Target $Target -ScriptBlock $script
}

function Restart-DFSRService {
  param([Parameter(Mandatory=$true)][string]$Target)

  $script = {
    Restart-Service -Name "DFSR" -Force -ErrorAction Stop
    Start-Sleep -Seconds 5
    (Get-Service -Name "DFSR").Status.ToString()
  }

  return Invoke-RemoteSafe -Target $Target -ScriptBlock $script
}

function Invoke-DfsrdiagPollAD {
  param([Parameter(Mandatory=$true)][string]$Target)

  $script = {
    $cmd = Get-Command "dfsrdiag.exe" -ErrorAction SilentlyContinue
    if (-not $cmd) { return "dfsrdiag.exe nicht gefunden." }
    & dfsrdiag pollad 2>&1
  }

  return Invoke-RemoteSafe -Target $Target -ScriptBlock $script
}

function Get-DfsrVolumeConfig {
  param([Parameter(Mandatory=$true)][string]$Target)

  $script = {
    $vols = Get-CimInstance -Namespace "root\microsoftdfs" -ClassName "dfsrVolumeConfig" -ErrorAction Stop |
      Select-Object VolumeGuid, VolumePath

    if (-not $vols -or $vols.Count -eq 0) {
      return "Keine dfsrVolumeConfig Objekte gefunden."
    }

    $vols | Format-Table -AutoSize | Out-String

    # Rückgabe der Volumes an Aufrufer, damit er auswählen kann
    return $vols
  }

  return Invoke-RemoteSafe -Target $Target -ScriptBlock $script
}

function Invoke-ResumeReplication {
  param(
    [Parameter(Mandatory=$true)][string]$Target,
    [Parameter(Mandatory=$true)][string[]]$VolumeGuids
  )

  $script = {
    param($VolumeGuids)
    $all = Get-CimInstance -Namespace "root\microsoftdfs" -ClassName "dfsrVolumeConfig" -ErrorAction Stop
    $hits = $all | Where-Object { $VolumeGuids -contains $_.VolumeGuid }

    if (-not $hits) { return "Keine passenden VolumeGuids gefunden." }

    foreach ($v in $hits) {
      Invoke-CimMethod -InputObject $v -MethodName "ResumeReplication" -ErrorAction Stop | Out-Null
    }

    "ResumeReplication ausgeführt für: " + ($hits.VolumeGuid -join ", ")
  }

  return Invoke-RemoteSafe -Target $Target -ScriptBlock $script -ArgumentList (,$VolumeGuids)
}

# Main
if (-not (Test-IsAdmin)) {
  throw "Bitte PowerShell als Administrator starten."
}

$targets = Resolve-TargetList

Write-Section "Parameter"
if (-not $PSBoundParameters.ContainsKey("LookbackDays")) {
  $rawDays = Read-Host "Lookback in Tagen (Default 7)"
  if ($rawDays) { $LookbackDays = [int]$rawDays }
}
if (-not $PSBoundParameters.ContainsKey("IncludeWarnings")) {
  $w = Read-Host "Warnings mit auswerten? (j/n, Default n)"
  if ($w -match '^(j|y)') { $IncludeWarnings = $true }
}

$startTime = (Get-Date).AddDays(-1 * [Math]::Abs($LookbackDays))

Write-Section "Analyse startet"
Write-Host ("Ziele: " + ($targets -join ", "))
Write-Host ("Lookback ab: " + $startTime)

# Event IDs die bei SYSVOL/DFSR typischerweise relevant sind
$interestingIds = @(2213, 4012, 4612, 5002, 5008, 2104, 4114, 4602, 4604, 4614)

$results = @()

foreach ($t in $targets) {
  Write-Host ""
  Write-Host ("--- " + $t + " ---")

  $reachable = $false
  try { $reachable = Test-Connection -ComputerName $t -Count 1 -Quiet -ErrorAction Stop } catch { $reachable = $false }

  if (-not $reachable) {
    $results += [pscustomobject]@{
      DC                 = $t
      Reachable          = $false
      DFSRService        = "n/a"
      DFSRStartType      = "n/a"
      SYSVOL             = $false
      NETLOGON           = $false
      Errors             = "n/a"
      Warnings           = "n/a"
      TopEventIds        = ""
      LatestInteresting  = ""
      Note               = "Nicht erreichbar (Ping/ICMP)."
    }
    continue
  }

  $svc = $null
  $shares = $null
  $events = @()

  try { $svc = Get-DFSRServiceStatus -Target $t } catch { $svc = [pscustomobject]@{ Status="unbekannt"; StartType="unbekannt" } }
  try { $shares = Get-ShareStatus -Target $t } catch { $shares = [pscustomobject]@{ SYSVOL=$false; NETLOGON=$false } }
  try { $events = Get-DFSRLogEvents -Target $t -StartTime $startTime -IncludeWarnings:$IncludeWarnings } catch { $events = @() }

  $errCount = @($events | Where-Object { $_.LevelDisplayName -in @("Critical","Error") }).Count
  $warnCount = @($events | Where-Object { $_.LevelDisplayName -eq "Warning" }).Count

  $interesting = @($events | Where-Object { $interestingIds -contains $_.Id } | Sort-Object TimeCreated -Descending)
  $topIds = ($interesting | Group-Object Id | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { "$($_.Name)($($_.Count))" }) -join ", "
  $latestInteresting = if ($interesting.Count -gt 0) { $interesting[0].TimeCreated } else { $null }

  $note = @()
  if ($svc.Status -ne "Running") { $note += "DFSR läuft nicht." }
  if (-not $shares.SYSVOL -or -not $shares.NETLOGON) { $note += "SYSVOL/NETLOGON Share fehlt." }
  if ($interesting | Where-Object { $_.Id -eq 2213 }) { $note += "Event 2213 gefunden (ResumeReplication nötig)." }
  if ($interesting | Where-Object { $_.Id -eq 4012 }) { $note += "Event 4012 gefunden (SYSVOL stale, Reinit nötig)." }

  $results += [pscustomobject]@{
    DC                 = $t
    Reachable          = $true
    DFSRService        = $svc.Status
    DFSRStartType      = $svc.StartType
    SYSVOL             = [bool]$shares.SYSVOL
    NETLOGON           = [bool]$shares.NETLOGON
    Errors             = $errCount
    Warnings           = $warnCount
    TopEventIds        = $topIds
    LatestInteresting  = $latestInteresting
    Note               = ($note -join " ")
  }

  # Bei Bedarf Detailausgabe der interessanten Events
  if ($interesting.Count -gt 0) {
    Write-Host "Interessante DFSR Events (letzte 10):"
    $interesting | Select-Object -First 10 TimeCreated, Id, LevelDisplayName |
      Format-Table -AutoSize
  } else {
    Write-Host "Keine interessanten DFSR Events im Lookback gefunden."
  }
}

Write-Section "Ergebnisübersicht"
$results | Sort-Object DC | Format-Table -AutoSize

# Export
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$csv = Join-Path -Path (Get-Location) -ChildPath ("DFSREvent_Report_{0}.csv" -f $ts)
$txt = Join-Path -Path (Get-Location) -ChildPath ("DFSREvent_Report_{0}.txt" -f $ts)

$results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $csv
($results | Format-Table -AutoSize | Out-String) | Set-Content -Encoding UTF8 -Path $txt

Write-Host ""
Write-Host ("Report exportiert:")
Write-Host ("- " + $csv)
Write-Host ("- " + $txt)

# Optional: repadmin summary
if (-not $SkipRepadmin) {
  Write-Section "AD Replication Kurzcheck (repadmin)"
  $rep = Get-Command "repadmin.exe" -ErrorAction SilentlyContinue
  if ($rep) {
    try {
      & repadmin /replsummary 2>&1
    } catch {
      Write-Host "repadmin Aufruf fehlgeschlagen: $($_.Exception.Message)"
    }
  } else {
    Write-Host "repadmin.exe nicht gefunden."
  }
}

# Interaktive Aktionen
Write-Section "Optionale Aktionen"
Write-Host "0) Beenden"
Write-Host "1) DFSR Service neu starten (ausgewählte DCs)"
Write-Host "2) dfsrdiag pollad ausführen (ausgewählte DCs)"
Write-Host "3) Bei Event 2213: ResumeReplication ausführen (ausgewählte DCs)"
Write-Host "Hinweis: Bei Event 4012 wird ADSIEdit + Non-Authoritative/Authoritative SYSVOL Sync benötigt (nicht automatisiert)."

$action = Read-Host "Auswahl (0-3)"

if ($action -eq "0" -or -not $action) { return }

$rawSel = Read-Host "Ziel DCs für Aktion (kommagetrennt, oder ALL)"
$sel = @()
if ($rawSel -match '^(ALL|all)$') { $sel = $targets }
else { $sel = ($rawSel -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

if (-not $sel -or $sel.Count -eq 0) { throw "Keine Ziele ausgewählt." }

switch ($action) {
  "1" {
    Write-Host "WARNUNG: DFSR Restart kann kurzfristig SYSVOL Replikation unterbrechen."
    $confirm = Read-Host "Zum Fortfahren 'JA' tippen"
    if ($confirm -ne "JA") { Write-Host "Abgebrochen."; break }

    foreach ($t in $sel) {
      Write-Host ("Restart DFSR auf " + $t + " ...")
      try {
        $st = Restart-DFSRService -Target $t
        Write-Host ("Status: " + $st)
      } catch {
        Write-Host ("Fehler: " + $_.Exception.Message)
      }
    }
  }

  "2" {
    foreach ($t in $sel) {
      Write-Host ("dfsrdiag pollad auf " + $t + " ...")
      try {
        $out = Run-DFSRDIAG-PollAD -Target $t
        $out
      } catch {
        Write-Host ("Fehler: " + $_.Exception.Message)
      }
    }
  }

  "3" {
    Write-Host "WICHTIG: Vor ResumeReplication sollte die Ursache (Crash/Storage) geklärt sein. Konfliktauflösung kann Änderungen überschreiben."
    $confirm = Read-Host "Zum Fortfahren 'RESUME' tippen"
    if ($confirm -ne "RESUME") { Write-Host "Abgebrochen."; break }

    foreach ($t in $sel) {
      Write-Host ("Volumes auf " + $t + " ermitteln ...")
      try {
        $vols = Try-ResumeReplication2213 -Target $t
        if ($vols -is [string]) {
          Write-Host $vols
          continue
        }

        $vols | Format-Table -AutoSize

        $rawGuids = Read-Host "VolumeGuid(s) für ResumeReplication (kommagetrennt, oder ALL)"
        $guids = @()
        if ($rawGuids -match '^(ALL|all)$') { $guids = @($vols.VolumeGuid) }
        else { $guids = ($rawGuids -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

        if (-not $guids -or $guids.Count -eq 0) {
          Write-Host "Keine VolumeGuids gewählt, überspringe."
          continue
        }

        $msg = Invoke-ResumeReplication -Target $t -VolumeGuids $guids
        Write-Host $msg
      } catch {
        Write-Host ("Fehler: " + $_.Exception.Message)
      }
    }
  }

  default {
    Write-Host "Ungültige Auswahl."
  }
}

Write-Section "Hinweis zu Event 4012 (stale SYSVOL)"
Write-Host @"
Wenn Event ID 4012 auftritt:
- Das ist meist Content Freshness Protection (DC war zu lange offline).
- Standardvorgehen ist ein Non-Authoritative Sync (und nur in Sonderfällen authoritative) via ADSIEdit:
  DN: CN=SYSVOL Subscription,CN=Domain System Volume,CN=DFSR-LocalSettings,CN=<DC>,OU=Domain Controllers,DC=<domain>
  Attribut msDFSR-Enabled umschalten, AD Replikation erzwingen, dfsrdiag pollad, Events prüfen.
- Das ist ein kontrollierter Eingriff und sollte nach Microsoft KB durchgeführt werden.
"@