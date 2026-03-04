<# 
.SYNOPSIS
  Interaktives AD Cleanup für ADHealthCheck Finding "Computer accounts with OS version End of Life".

.DESCRIPTION
  - Input ist die Geräteliste aus dem ADHealthCheck Report (Returned Value).
  - Pro Gerät wird angezeigt: LastLogonDate (letzte AD-Kommunikation), Inaktiv-Tage, OS, OU/DN.
  - Entscheidungen sind immer interaktiv, damit nicht zu viel bereinigt wird.
  - Vor Move/Delete muss manuell in Ninja geprüft werden (online/zuletzt online, Lager-Gerät).
    Lager-Gerät ist nur in Ninja definiert und nicht per PowerShell auslesbar.

.NOTES
  - Benötigt RSAT ActiveDirectory Modul und passende Berechtigungen.
  - Unterstützt -WhatIf.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Mandatory = $false)]
  [string]$InputFile,

  [Parameter(Mandatory = $false)]
  [string[]]$ComputerName,

  [Parameter(Mandatory = $false)]
  [ValidateSet(60,90)]
  [int]$StaleDaysToDelete = 90,

  [Parameter(Mandatory = $false)]
  [int]$InactiveDaysToMove = 28,

  [Parameter(Mandatory = $false)]
  [int]$RecentOnlineWindowDays = 7,

  [Parameter(Mandatory = $false)]
  [string]$DeactivatedOUName = "Deactivated_Devices",

  [Parameter(Mandatory = $false)]
  [string]$ExportCsvPath = ".\ADHC_EOL_Computer_Summary.csv"
)

function Assert-ActiveDirectoryModule {
  if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    throw "ActiveDirectory Modul nicht gefunden. Installiere RSAT (AD DS Tools) und starte die Shell neu."
  }
  Import-Module ActiveDirectory -ErrorAction Stop
}

function Read-YesNo {
  param(
    [Parameter(Mandatory=$true)][string]$Prompt,
    [bool]$DefaultYes = $false
  )
  while ($true) {
    $suffix = if ($DefaultYes) { "[J/n]" } else { "[j/N]" }
    $in = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($in)) { return $DefaultYes }
    switch ($in.Trim().ToLower()) {
      "j" { return $true }
      "ja" { return $true }
      "y" { return $true }
      "yes" { return $true }
      "n" { return $false }
      "nein" { return $false }
      "no" { return $false }
      default { Write-Host "Bitte nur J oder N eingeben." }
    }
  }
}

function Read-Choice {
  param(
    [Parameter(Mandatory=$true)][string]$Prompt,
    [Parameter(Mandatory=$true)][string[]]$Allowed
  )
  $allowedLower = $Allowed | ForEach-Object { $_.ToLower() }
  while ($true) {
    $in = Read-Host "$Prompt ($($Allowed -join '/'))"
    if (-not $in) { continue }
    $v = $in.Trim().ToLower()
    if ($allowedLower -contains $v) { return $v }
    Write-Host "Ungültig. Erlaubt: $($Allowed -join ', ')"
  }
}

function Get-DeactivatedOU {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param(
    [Parameter(Mandatory=$true)]
    [string]$OUName
  )

  $domain = Get-ADDomain
  $baseDn = $domain.DistinguishedName

  $ou = Get-ADOrganizationalUnit -LDAPFilter "(ou=$OUName)" -SearchBase $baseDn -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($ou) { return $ou.DistinguishedName }

  if ($PSCmdlet.ShouldProcess($baseDn, "Create OU '$OUName'")) {
    New-ADOrganizationalUnit -Name $OUName -Path $baseDn -ProtectedFromAccidentalDeletion $true | Out-Null
  }

  $ou = Get-ADOrganizationalUnit -LDAPFilter "(ou=$OUName)" -SearchBase $baseDn -ErrorAction Stop | Select-Object -First 1
  return $ou.DistinguishedName
}

function Get-TargetComputers {
  param([string]$InputFile, [string[]]$ComputerName)

  $names = @()

  if ($ComputerName -and $ComputerName.Count -gt 0) {
    $names += $ComputerName
  }

  if ($InputFile) {
    if (-not (Test-Path $InputFile)) { throw "InputFile nicht gefunden: $InputFile" }
    $names += (Get-Content -LiteralPath $InputFile | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  }

  if (-not $names -or $names.Count -eq 0) {
    Write-Host "Keine Computerliste übergeben."
    Write-Host "Option 1: -InputFile .\eol.txt (ein Name pro Zeile)"
    Write-Host "Option 2: -ComputerName PC1,PC2,PC3"
    $paste = Read-Host "Oder hier Namen kommagetrennt einfügen"
    $names += ($paste -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  }

  $names | Sort-Object -Unique
}

function Read-NinjaGate {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][int]$RecentWindowDays
  )

  Write-Host ""
  Write-Host "Ninja Pflicht-Check für: $Name"
  Write-Host "Bitte in Ninja prüfen:"
  Write-Host "  1) Ist das Gerät aktuell online oder war in den letzten $RecentWindowDays Tagen online?"
  Write-Host "  2) Ist das Gerät als Lager-Gerät markiert?"
  Write-Host ""

  $recentOnline = Read-YesNo -Prompt "Ist das Gerät aktuell online oder war in den letzten $RecentWindowDays Tagen online?" -DefaultYes $false
  if ($recentOnline) {
    return [pscustomobject]@{ Allowed = $false; Reason = "Ninja: online oder kürzlich online" ; RecentOnline=$true; Storage=$false }
  }

  $storage = Read-YesNo -Prompt "Ist das Gerät als Lager-Gerät markiert (Ninja)?" -DefaultYes $false
  if ($storage) {
    return [pscustomobject]@{ Allowed = $false; Reason = "Ninja: Lager-Gerät" ; RecentOnline=$false; Storage=$true }
  }

  return [pscustomobject]@{ Allowed = $true; Reason = $null ; RecentOnline=$false; Storage=$false }
}

Assert-ActiveDirectoryModule

# Sicherheitsgurt: Ticket-Prüfung erzwingen
$checkedTicket = Read-YesNo -Prompt "Hast du das letzte AD HealthCheck Ticket geprüft (Hinweise/Ausnahmen zu EOL Computer)?" -DefaultYes $false
if (-not $checkedTicket) {
  Write-Host "Abbruch. Erst Ticket prüfen, dann weiter."
  return
}

$targets = Get-TargetComputers -InputFile $InputFile -ComputerName $ComputerName
if (-not $targets -or $targets.Count -eq 0) { throw "Keine Computer gefunden/übergeben." }

$deactivatedOuDn = Get-DeactivatedOU -OUName $DeactivatedOUName
$now = Get-Date

$summary = New-Object System.Collections.Generic.List[object]

Write-Host ""
Write-Host "Start. Geräte: $($targets.Count). Move ab $InactiveDaysToMove Tagen. Delete ab $StaleDaysToDelete Tagen."
Write-Host ""

foreach ($name in $targets) {
  Write-Host ""
  Write-Host "================================================================="
  Write-Host "Gerät: $name"

  $ad = Get-ADComputer -Identity $name -Properties LastLogonDate,OperatingSystem,OperatingSystemVersion,Enabled,DistinguishedName,WhenCreated -ErrorAction SilentlyContinue
  if (-not $ad) {
    Write-Host "Nicht im AD gefunden. Skip."
    $summary.Add([pscustomobject]@{
      Computer = $name
      FoundInAD = $false
      LastLogonDate = $null
      InactiveDays = $null
      OperatingSystem = $null
      OSVersion = $null
      Suggested = "SKIP"
      Action = "SKIP"
      Reason = "Nicht im AD gefunden"
      NinjaRecentOnline = $null
      NinjaStorage = $null
    })
    continue
  }

  $lastLogon = $ad.LastLogonDate
  $inactiveDays = if ($lastLogon) { [int]($now - $lastLogon).TotalDays } else { 99999 }
  $lastLogonText = if ($lastLogon) { $lastLogon.ToString("yyyy-MM-dd HH:mm") } else { "nie/unknown" }

  $suggested = "NONE"
  if ($inactiveDays -ge $StaleDaysToDelete) { $suggested = "DELETE_CANDIDATE" }
  elseif ($inactiveDays -ge $InactiveDaysToMove) { $suggested = "MOVE_CANDIDATE" }

  Write-Host ("Last AD Kontakt (LastLogonDate): {0}" -f $lastLogonText)
  Write-Host ("Inaktiv (Tage): {0}" -f $inactiveDays)
  Write-Host ("OS: {0} | Version: {1}" -f $ad.OperatingSystem, $ad.OperatingSystemVersion)
  Write-Host ("Enabled: {0}" -f $ad.Enabled)
  Write-Host ("DN: {0}" -f $ad.DistinguishedName)
  Write-Host ("Vorschlag: {0}" -f $suggested)
  Write-Host ""

  Write-Host "Aktion wählen:"
  Write-Host "  s = Skip (nichts machen)"
  Write-Host "  m = In OU '$DeactivatedOUName' verschieben (nur wenn Ninja OK)"
  Write-Host "  d = Aus AD entfernen (nur wenn Ninja OK, zusätzlich Bestätigung)"
  Write-Host "  x = Als Ausnahme markieren (manuell in ITGlue: ADHealth_Excluded_Computeraccounts)"
  $choice = Read-Choice -Prompt "Deine Auswahl" -Allowed @("s","m","d","x")

  if ($choice -eq "s") {
    $summary.Add([pscustomobject]@{
      Computer = $name
      FoundInAD = $true
      LastLogonDate = $lastLogon
      InactiveDays = $inactiveDays
      OperatingSystem = $ad.OperatingSystem
      OSVersion = $ad.OperatingSystemVersion
      Suggested = $suggested
      Action = "SKIP"
      Reason = "Manuell übersprungen"
      NinjaRecentOnline = $null
      NinjaStorage = $null
    })
    continue
  }

  if ($choice -eq "x") {
    Write-Host "Hinweis: Ausnahme wird nicht automatisch gesetzt. Bitte manuell in ITGlue unter 'ADHealth_Excluded_Computeraccounts' eintragen."
    $reason = Read-Host "Kurzbegründung für die Ausnahme (für Ticket/CSV)"
    $summary.Add([pscustomobject]@{
      Computer = $name
      FoundInAD = $true
      LastLogonDate = $lastLogon
      InactiveDays = $inactiveDays
      OperatingSystem = $ad.OperatingSystem
      OSVersion = $ad.OperatingSystemVersion
      Suggested = $suggested
      Action = "EXCEPTION"
      Reason = $reason
      NinjaRecentOnline = $null
      NinjaStorage = $null
    })
    continue
  }

  # Für Move/Delete: Ninja Gate
  $gate = Read-NinjaGate -Name $name -RecentWindowDays $RecentOnlineWindowDays
  if (-not $gate.Allowed) {
    Write-Host ("Blockiert. Grund: {0}" -f $gate.Reason)
    $summary.Add([pscustomobject]@{
      Computer = $name
      FoundInAD = $true
      LastLogonDate = $lastLogon
      InactiveDays = $inactiveDays
      OperatingSystem = $ad.OperatingSystem
      OSVersion = $ad.OperatingSystemVersion
      Suggested = $suggested
      Action = "BLOCKED"
      Reason = $gate.Reason
      NinjaRecentOnline = $gate.RecentOnline
      NinjaStorage = $gate.Storage
    })
    continue
  }

  if ($choice -eq "m") {
    # Extra Sicherheitsfrage
    $confirm = Read-YesNo -Prompt "Wirklich verschieben? ($name -> OU '$DeactivatedOUName')" -DefaultYes $false
    if (-not $confirm) {
      $summary.Add([pscustomobject]@{
        Computer = $name
        FoundInAD = $true
        LastLogonDate = $lastLogon
        InactiveDays = $inactiveDays
        OperatingSystem = $ad.OperatingSystem
        OSVersion = $ad.OperatingSystemVersion
        Suggested = $suggested
        Action = "SKIP"
        Reason = "Verschieben abgelehnt"
        NinjaRecentOnline = $gate.RecentOnline
        NinjaStorage = $gate.Storage
      })
      continue
    }

    if ($PSCmdlet.ShouldProcess($ad.DistinguishedName, "Move-ADObject -> $deactivatedOuDn")) {
      try {
        Move-ADObject -Identity $ad.DistinguishedName -TargetPath $deactivatedOuDn -ErrorAction Stop
        Write-Host "Verschoben."
        $summary.Add([pscustomobject]@{
          Computer = $name
          FoundInAD = $true
          LastLogonDate = $lastLogon
          InactiveDays = $inactiveDays
          OperatingSystem = $ad.OperatingSystem
          OSVersion = $ad.OperatingSystemVersion
          Suggested = $suggested
          Action = "MOVED"
          Reason = "Manuell verschoben"
          NinjaRecentOnline = $gate.RecentOnline
          NinjaStorage = $gate.Storage
        })
      } catch {
        Write-Host "Fehler beim Verschieben: $($_.Exception.Message)"
        $summary.Add([pscustomobject]@{
          Computer = $name
          FoundInAD = $true
          LastLogonDate = $lastLogon
          InactiveDays = $inactiveDays
          OperatingSystem = $ad.OperatingSystem
          OSVersion = $ad.OperatingSystemVersion
          Suggested = $suggested
          Action = "ERROR"
          Reason = "Verschieben fehlgeschlagen: $($_.Exception.Message)"
          NinjaRecentOnline = $gate.RecentOnline
          NinjaStorage = $gate.Storage
        })
      }
    }
    continue
  }

  if ($choice -eq "d") {
    # Härtere Bestätigung: Name eintippen
    Write-Host "ACHTUNG: Löschen entfernt das Computerobjekt endgültig aus dem AD."
    $typed = Read-Host "Zum Bestätigen den Computernamen exakt eintippen"
    if ($typed -ne $name) {
      Write-Host "Bestätigung falsch. Löschen abgebrochen."
      $summary.Add([pscustomobject]@{
        Computer = $name
        FoundInAD = $true
        LastLogonDate = $lastLogon
        InactiveDays = $inactiveDays
        OperatingSystem = $ad.OperatingSystem
        OSVersion = $ad.OperatingSystemVersion
        Suggested = $suggested
        Action = "SKIP"
        Reason = "Lösch-Bestätigung nicht korrekt"
        NinjaRecentOnline = $gate.RecentOnline
        NinjaStorage = $gate.Storage
      })
      continue
    }

    if ($PSCmdlet.ShouldProcess($ad.DistinguishedName, "Remove-ADComputer")) {
      try {
        Remove-ADComputer -Identity $ad.DistinguishedName -Confirm:$false -ErrorAction Stop
        Write-Host "Gelöscht."
        $summary.Add([pscustomobject]@{
          Computer = $name
          FoundInAD = $true
          LastLogonDate = $lastLogon
          InactiveDays = $inactiveDays
          OperatingSystem = $ad.OperatingSystem
          OSVersion = $ad.OperatingSystemVersion
          Suggested = $suggested
          Action = "DELETED"
          Reason = "Manuell gelöscht"
          NinjaRecentOnline = $gate.RecentOnline
          NinjaStorage = $gate.Storage
        })
      } catch {
        Write-Host "Fehler beim Löschen: $($_.Exception.Message)"
        $summary.Add([pscustomobject]@{
          Computer = $name
          FoundInAD = $true
          LastLogonDate = $lastLogon
          InactiveDays = $inactiveDays
          OperatingSystem = $ad.OperatingSystem
          OSVersion = $ad.OperatingSystemVersion
          Suggested = $suggested
          Action = "ERROR"
          Reason = "Löschen fehlgeschlagen: $($_.Exception.Message)"
          NinjaRecentOnline = $gate.RecentOnline
          NinjaStorage = $gate.Storage
        })
      }
    }
    continue
  }
}

Write-Host ""
Write-Host "====================== ABSCHLUSS / ZUSAMMENFASSUNG ======================"
$summary | Sort-Object Action, Computer | Format-Table -AutoSize

try {
  $summary | Export-Csv -Path $ExportCsvPath -NoTypeInformation -Encoding UTF8
  Write-Host "CSV exportiert: $ExportCsvPath"
} catch {
  Write-Host "CSV Export fehlgeschlagen: $($_.Exception.Message)"
}

$deleted = ($summary | Where-Object { $_.Action -eq "DELETED" } | Select-Object -ExpandProperty Computer)
$moved = ($summary | Where-Object { $_.Action -eq "MOVED" } | Select-Object -ExpandProperty Computer)
$exceptions = ($summary | Where-Object { $_.Action -eq "EXCEPTION" } | Select-Object -ExpandProperty Computer)

# BLOCKED + SKIP gemeinsam (inkl. "nicht im AD gefunden", "manuell übersprungen", "Verschieben abgelehnt", etc.)
$blockedOrSkipped = (
  $summary |
  Where-Object { $_.Action -in @("BLOCKED","SKIP") } |
  Select-Object -ExpandProperty Computer
)

Write-Host ""
Write-Host "EOL Geräte (Input-Liste):"
$targets | ForEach-Object { Write-Host "  - $_" }

Write-Host ""
Write-Host "Aus AD entfernt:"
if ($deleted.Count -gt 0) { $deleted | ForEach-Object { Write-Host "  - $_" } } else { Write-Host "  - (keine)" }

Write-Host ""
Write-Host "In OU '$DeactivatedOUName' verschoben:"
if ($moved.Count -gt 0) { $moved | ForEach-Object { Write-Host "  - $_" } } else { Write-Host "  - (keine)" }

Write-Host ""
Write-Host "Als Ausnahme markiert (manuell in ITGlue eintragen):"
if ($exceptions.Count -gt 0) { $exceptions | ForEach-Object { Write-Host "  - $_" } } else { Write-Host "  - (keine)" }

Write-Host ""
Write-Host "Blockiert/übersprungene Geräte (Ninja online, vor kurzem Online oder Lager-Gerät):"
if ($blockedOrSkipped.Count -gt 0) { $blockedOrSkipped | Sort-Object -Unique | ForEach-Object { Write-Host "  - $_" } } else { Write-Host "  - (keine)" }