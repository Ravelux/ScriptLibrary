<#
.SYNOPSIS
  Findet unlinked GPOs (nicht verlinkt an Site/Domain/OU), erstellt optional Backups und kann sie optional löschen.

.REQUIREMENTS
  - RSAT GroupPolicy (GroupPolicy Modul)
  - Rechte: GPO lesen; fürs Backup/Löschen entsprechende Berechtigungen

.EXAMPLES
  # Nur Report
  .\Invoke-UnlinkedGpoCleanup.ps1 -ReportOnly

  # Interaktiv: Report + pro GPO Backup + optional Löschen
  .\Invoke-UnlinkedGpoCleanup.ps1 -Interactive

  # Non-interaktiv: Backup + Delete für alle unlinked (Vorsicht!)
  .\Invoke-UnlinkedGpoCleanup.ps1 -BackupPath C:\Temp\GPO_Backups -Delete -Force
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [string]$Domain = $env:USERDNSDOMAIN,
  [string]$BackupPath = (Join-Path -Path (Get-Location) -ChildPath "GPO_Backups"),
  [switch]$ReportOnly,
  [switch]$Interactive,
  [switch]$Delete,
  [switch]$Force
)

function Get-GpoLinksFromReportXml {
  param(
    [Parameter(Mandatory)]
    [xml]$XmlDoc
  )

  # Robust: per XPath suchen, weil die Struktur je nach Version leicht variiert
  $somNodes = $XmlDoc.SelectNodes("//LinksTo/SOM")
  $links = @()

  foreach ($n in @($somNodes)) {
    # SOMPath ist in der Regel ein String-Node
    $p = $n.SOMPath
    if ($p) { $links += [string]$p }
  }

  # Duplikate entfernen
  $links | Sort-Object -Unique
}

function Get-UnlinkedGpos {
  param([string]$DomainName)

  Import-Module GroupPolicy -ErrorAction Stop

  $all = Get-GPO -All -Domain $DomainName

  foreach ($gpo in $all) {
    $xmlText = Get-GPOReport -Guid $gpo.Id -ReportType Xml -Domain $DomainName
    [xml]$xml = $xmlText

    $links = Get-GpoLinksFromReportXml -XmlDoc $xml
    $linkCount = ($links | Measure-Object).Count

    [pscustomobject]@{
      DisplayName      = $gpo.DisplayName
      Id               = $gpo.Id
      Domain           = $DomainName
      Owner            = $gpo.Owner
      CreationTime     = $gpo.CreationTime
      ModificationTime = $gpo.ModificationTime
      LinkCount        = $linkCount
      Links            = $links -join "; "
      IsUnlinked       = ($linkCount -eq 0)
    }
  }
}

function Ensure-Folder {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Backup-OneGpo {
  param(
    [string]$DomainName,
    [Guid]$GpoId,
    [string]$DestPath
  )

  Ensure-Folder -Path $DestPath

  Backup-GPO -Guid $GpoId -Domain $DomainName -Path $DestPath -ErrorAction Stop | Out-Null
}

# ---------- MAIN ----------
try {
  $results = Get-UnlinkedGpos -DomainName $Domain
} catch {
  Write-Error "Fehler beim Auslesen der GPOs: $($_.Exception.Message)"
  exit 1
}

$unlinked = $results | Where-Object { $_.IsUnlinked } | Sort-Object ModificationTime -Descending

Write-Host ""
Write-Host "Unlinked GPOs in Domain '$Domain': $($unlinked.Count)" -ForegroundColor Cyan
Write-Host ""

if ($unlinked.Count -eq 0) {
  Write-Host "Keine unlinked GPOs gefunden."
  return
}

# Ausgabe Tabelle
$unlinked |
  Select-Object DisplayName, ModificationTime, Owner, Id |
  Format-Table -AutoSize

# Nur Report gewünscht
if ($ReportOnly -and -not $Delete -and -not $Interactive) {
  return
}

# Interaktiv, wenn nicht anders angegeben
if (-not $Interactive -and -not $Delete) {
  $Interactive = $true
}

if ($Interactive) {
  Write-Host ""
  Write-Host "Optionen:" -ForegroundColor Cyan
  Write-Host "  [A] Backup für ALLE unlinked"
  Write-Host "  [S] Auswahl einzelner GPOs (Backup und optional Löschen)"
  Write-Host "  [Q] Abbrechen"
  Write-Host ""
  $choice = Read-Host "Auswahl (A/S/Q)"

  if ($choice -match '^[Qq]$') { return }

  if ($choice -match '^[Aa]$') {
    Ensure-Folder -Path $BackupPath
    foreach ($g in $unlinked) {
      Write-Host "Backup: $($g.DisplayName)"
      Backup-OneGpo -DomainName $Domain -GpoId $g.Id -DestPath $BackupPath

      if ($Delete) {
        if ($PSCmdlet.ShouldProcess($g.DisplayName, "Remove-GPO")) {
          Remove-GPO -Guid $g.Id -Domain $Domain -Confirm:$true
        }
      }
    }
    Write-Host "Fertig. Backup-Pfad: $BackupPath" -ForegroundColor Green
    return
  }

  if ($choice -match '^[Ss]$') {
    Write-Host ""
    Write-Host "Nummerierte Liste:" -ForegroundColor Cyan
    $i = 1
    $map = @{}
    foreach ($g in $unlinked) {
      $map[$i] = $g
      Write-Host ("[{0}] {1} (Modified: {2})" -f $i, $g.DisplayName, $g.ModificationTime)
      $i++
    }

    Write-Host ""
    $sel = Read-Host "Nummern kommasepariert (z.B. 1,3,5) oder Bereich (z.B. 2-4)"
    $targets = @()

    if ($sel -match '^\s*\d+\s*-\s*\d+\s*$') {
      $parts = $sel -split '-'
      $start = [int]$parts[0].Trim()
      $end   = [int]$parts[1].Trim()
      foreach ($n in $start..$end) {
        if ($map.ContainsKey($n)) { $targets += $map[$n] }
      }
    } else {
      foreach ($n in ($sel -split ',')) {
        $k = [int]($n.Trim())
        if ($map.ContainsKey($k)) { $targets += $map[$k] }
      }
    }

    if ($targets.Count -eq 0) {
      Write-Host "Keine gültige Auswahl." -ForegroundColor Yellow
      return
    }

    Ensure-Folder -Path $BackupPath

    foreach ($g in $targets) {
      Write-Host ""
      Write-Host "GPO: $($g.DisplayName)" -ForegroundColor Cyan
      Write-Host "  Owner:    $($g.Owner)"
      Write-Host "  Created:  $($g.CreationTime)"
      Write-Host "  Modified: $($g.ModificationTime)"
      Write-Host "  Links:    (keine)"

      $doBackup = Read-Host "Backup erstellen? (y/n)"
      if ($doBackup -match '^[Yy]$') {
        Backup-OneGpo -DomainName $Domain -GpoId $g.Id -DestPath $BackupPath
        Write-Host "  Backup OK: $BackupPath"
      }

      $doDelete = Read-Host "GPO löschen? (y/n)"
      if ($doDelete -match '^[Yy]$') {
        if ($PSCmdlet.ShouldProcess($g.DisplayName, "Remove-GPO")) {
          Remove-GPO -Guid $g.Id -Domain $Domain -Confirm:$true
        }
      }
    }

    Write-Host ""
    Write-Host "Fertig. Backup-Pfad: $BackupPath" -ForegroundColor Green
    return
  }

  Write-Host "Ungültige Auswahl." -ForegroundColor Yellow
  return
}

# Non-interaktiv Delete/Backup
if ($Delete) {
  Ensure-Folder -Path $BackupPath

  foreach ($g in $unlinked) {
    Write-Host "Backup: $($g.DisplayName)"
    Backup-OneGpo -DomainName $Domain -GpoId $g.Id -DestPath $BackupPath

    if ($Force -or $PSCmdlet.ShouldProcess($g.DisplayName, "Remove-GPO")) {
      # Ohne Force: Remove-GPO fragt trotzdem confirm, außer Confirm wird explizit unterdrückt
      Remove-GPO -Guid $g.Id -Domain $Domain -Confirm:(-not $Force)
    }
  }

  Write-Host "Fertig. Backup-Pfad: $BackupPath" -ForegroundColor Green
}