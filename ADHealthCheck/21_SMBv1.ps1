<#
.SYNOPSIS
  Interaktiv: ADHealthCheck Finding "SMBv1 Status" analysieren und optional beheben.
.DESCRIPTION
  - Interaktive Zielauswahl: Lokal, Liste, AD-Computer, manuell
  - Pro Host: Status anzeigen und Entscheidung treffen (Remediate, Skip, Exception, Quit)
  - Export: CSV + optional Transcript
.NOTES
  Remote benötigt WinRM/PowerShell Remoting und Adminrechte.
#>

[CmdletBinding()]
param()

# ---------------------------
# Helper: UI
# ---------------------------
function Read-YesNo {
  param(
    [Parameter(Mandatory)] [string]$Prompt,
    [bool]$DefaultYes = $true
  )
  $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
  while ($true) {
    $in = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($in)) { return $DefaultYes }
    switch ($in.Trim().ToLower()) {
      "y" { return $true }
      "yes" { return $true }
      "j" { return $true }
      "ja" { return $true }
      "n" { return $false }
      "no" { return $false }
      "nein" { return $false }
      default { Write-Host "Bitte y oder n eingeben." -ForegroundColor Yellow }
    }
  }
}

function Read-Choice {
  param(
    [Parameter(Mandatory)] [string]$Prompt,
    [Parameter(Mandatory)] [string[]]$Allowed,
    [string]$Default
  )
  $allowedText = ($Allowed -join "/")
  while ($true) {
    $msg = if ($Default) { "$Prompt [$allowedText] (Default: $Default)" } else { "$Prompt [$allowedText]" }
    $in = Read-Host $msg
    if ([string]::IsNullOrWhiteSpace($in) -and $Default) { return $Default }
    $val = $in.Trim()
    if ($Allowed -contains $val) { return $val }
    Write-Host "Ungültig. Erlaubt: $allowedText" -ForegroundColor Yellow
  }
}

function Ensure-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Bitte PowerShell als Administrator starten."
  }
}

# ---------------------------
# Core: Analyse und Fix (lokal und remote nutzbar)
# ---------------------------
$AnalyzeScript = {
  $res = [ordered]@{
    ComputerName         = $env:COMPUTERNAME
    Timestamp            = (Get-Date)
    Reachable            = $true
    OS                   = $null
    SMB1ServerEnabled    = $null
    SMB2ServerEnabled    = $null
    SMB1ClientEnabled    = $null
    SMB1FeatureInstalled = $null
    SMB1ServerFeature    = $null
    Notes                = ""
  }

  try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $res.OS = "$($os.Caption) ($($os.Version))"

    if (Get-Command Get-SmbServerConfiguration -ErrorAction SilentlyContinue) {
      $srv = Get-SmbServerConfiguration
      $res.SMB1ServerEnabled = [bool]$srv.EnableSMB1Protocol
      $res.SMB2ServerEnabled = [bool]$srv.EnableSMB2Protocol
    }

    if (Get-Command Get-SmbClientConfiguration -ErrorAction SilentlyContinue) {
      $cli = Get-SmbClientConfiguration
      if ($cli.PSObject.Properties.Name -contains "EnableSMB1Protocol") {
        $res.SMB1ClientEnabled = [bool]$cli.EnableSMB1Protocol
      }
    }

    # Optional Feature
    if (Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
      $features = @("SMB1Protocol","SMB1Protocol-Client","SMB1Protocol-Server")
      $installed = $false
      foreach ($f in $features) {
        try {
          $cur = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction Stop
          if ($cur.State -ne "Disabled") { $installed = $true }
        } catch { }
      }
      $res.SMB1FeatureInstalled = $installed
    }

    # Server Feature (ältere Server)
    if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
      try {
        $sf = Get-WindowsFeature -Name FS-SMB1 -ErrorAction Stop
        $res.SMB1ServerFeature = [bool]$sf.Installed
      } catch { }
    }

    # Registry Fallback für Client
    if ($null -eq $res.SMB1ClientEnabled) {
      $mrx = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\mrxsmb10" -ErrorAction SilentlyContinue
      if ($mrx) { $res.SMB1ClientEnabled = ($mrx.Start -ne 4) }
    }
  }
  catch {
    $res.Reachable = $false
    $res.Notes = $_.Exception.Message
  }

  [pscustomobject]$res
}

$RemediateScript = {
  param(
    [bool]$NoRestart = $true
  )

  $out = [ordered]@{
    ComputerName       = $env:COMPUTERNAME
    Timestamp          = (Get-Date)
    Attempted          = $true
    Changed            = $false
    RebootRecommended  = $false
    Notes              = ""
  }

  try {
    # SMB Server
    if (Get-Command Get-SmbServerConfiguration -ErrorAction SilentlyContinue) {
      $srv = Get-SmbServerConfiguration
      if ($srv.EnableSMB1Protocol) {
        Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force | Out-Null
        $out.Changed = $true
      }
      if (-not $srv.EnableSMB2Protocol) {
        Set-SmbServerConfiguration -EnableSMB2Protocol $true -Force | Out-Null
        $out.Changed = $true
      }
    }

    # SMB Client (falls Parameter existiert)
    if (Get-Command Set-SmbClientConfiguration -ErrorAction SilentlyContinue) {
      $cli = Get-SmbClientConfiguration
      if ($cli.PSObject.Properties.Name -contains "EnableSMB1Protocol") {
        if ($cli.EnableSMB1Protocol) {
          Set-SmbClientConfiguration -EnableSMB1Protocol $false | Out-Null
          $out.Changed = $true
        }
      }
    }

    # Optional Feature deaktivieren
    if (Get-Command Disable-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
      foreach ($f in @("SMB1Protocol","SMB1Protocol-Client","SMB1Protocol-Server")) {
        try {
          $cur = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction Stop
          if ($cur.State -ne "Disabled") {
            Disable-WindowsOptionalFeature -Online -FeatureName $f -NoRestart:$NoRestart -ErrorAction Stop | Out-Null
            $out.Changed = $true
            $out.RebootRecommended = $true
          }
        } catch { }
      }
    }

    # Server Feature entfernen (ältere Server)
    if (Get-Command Remove-WindowsFeature -ErrorAction SilentlyContinue) {
      try {
        $sf = Get-WindowsFeature -Name FS-SMB1 -ErrorAction Stop
        if ($sf -and $sf.Installed) {
          Remove-WindowsFeature -Name FS-SMB1 -Restart:$false | Out-Null
          $out.Changed = $true
          $out.RebootRecommended = $true
        }
      } catch { }
    }

    # Registry harte Abschaltung als Fallback
    try {
      $lanman = "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters"
      if (-not (Test-Path $lanman)) { New-Item -Path $lanman -Force | Out-Null }
      $curSmb1 = (Get-ItemProperty -Path $lanman -Name SMB1 -ErrorAction SilentlyContinue).SMB1
      if ($curSmb1 -ne 0) {
        New-ItemProperty -Path $lanman -Name SMB1 -PropertyType DWord -Value 0 -Force | Out-Null
        $out.Changed = $true
        $out.RebootRecommended = $true
      }

      $mrx = "HKLM:\SYSTEM\CurrentControlSet\Services\mrxsmb10"
      if (Test-Path $mrx) {
        $curStart = (Get-ItemProperty -Path $mrx -Name Start -ErrorAction SilentlyContinue).Start
        if ($curStart -ne 4) {
          Set-ItemProperty -Path $mrx -Name Start -Value 4 -Force | Out-Null
          $out.Changed = $true
          $out.RebootRecommended = $true
        }
      }
    } catch {
      $out.Notes += "Registry-Fallback: $($_.Exception.Message) "
    }
  }
  catch {
    $out.Notes += $_.Exception.Message
  }

  [pscustomobject]$out
}

function Invoke-Analyze {
  param([string]$Target)

  if ($Target -ieq $env:COMPUTERNAME) {
    return & $AnalyzeScript
  }

  try {
    return Invoke-Command -ComputerName $Target -ScriptBlock $AnalyzeScript -ErrorAction Stop
  } catch {
    return [pscustomobject]@{
      ComputerName         = $Target
      Timestamp            = (Get-Date)
      Reachable            = $false
      OS                   = $null
      SMB1ServerEnabled    = $null
      SMB2ServerEnabled    = $null
      SMB1ClientEnabled    = $null
      SMB1FeatureInstalled = $null
      SMB1ServerFeature    = $null
      Notes                = $_.Exception.Message
    }
  }
}

function Invoke-Remediate {
  param(
    [string]$Target,
    [bool]$NoRestart
  )

  if ($Target -ieq $env:COMPUTERNAME) {
    return & $RemediateScript -NoRestart:$NoRestart
  }

  try {
    return Invoke-Command -ComputerName $Target -ScriptBlock $RemediateScript -ArgumentList @($NoRestart) -ErrorAction Stop
  } catch {
    return [pscustomobject]@{
      ComputerName      = $Target
      Timestamp         = (Get-Date)
      Attempted         = $true
      Changed           = $false
      RebootRecommended = $false
      Notes             = $_.Exception.Message
    }
  }
}

# ---------------------------
# Target selection
# ---------------------------
function Get-TargetsInteractive {
  $mode = Read-Choice -Prompt "Targets wählen: 1=Lokal, 2=Datei, 3=AD, 4=Manuell" -Allowed @("1","2","3","4") -Default "1"
  switch ($mode) {
    "1" { return @($env:COMPUTERNAME) }
    "2" {
      $path = Read-Host "Pfad zur TXT Liste (1 Host pro Zeile)"
      if (-not (Test-Path $path)) { throw "Datei nicht gefunden: $path" }
      return (Get-Content $path | Where-Object { $_ -and $_.Trim() -ne "" } | ForEach-Object { $_.Trim() } | Sort-Object -Unique)
    }
    "3" {
      try { Import-Module ActiveDirectory -ErrorAction Stop } catch { throw "ActiveDirectory Modul fehlt. Nutze Modus 2 oder 4." }
      $serversOnly = Read-YesNo -Prompt "Nur Server aus AD?" -DefaultYes $true
      $searchBase = Read-Host "SearchBase OU DN (leer = gesamte Domain)"
      $filter = if ($serversOnly) { "OperatingSystem -like '*Server*'" } else { "*" }
      $params = @{ Filter = $filter }
      if (-not [string]::IsNullOrWhiteSpace($searchBase)) { $params.SearchBase = $searchBase }
      return (Get-ADComputer @params | Select-Object -ExpandProperty Name | Sort-Object -Unique)
    }
    "4" {
      $raw = Read-Host "ComputerNames (comma getrennt)"
      return ($raw.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique)
    }
  }
}

# ---------------------------
# Main
# ---------------------------
try {
  Ensure-Admin

  $outDir = Read-Host "Output Ordner (leer = aktueller Ordner)"
  if ([string]::IsNullOrWhiteSpace($outDir)) { $outDir = (Get-Location).Path }
  if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $csvPath = Join-Path $outDir "SMB1_Status_$stamp.csv"
  $logPath = Join-Path $outDir "SMB1_Status_$stamp.log.txt"

  $doTranscript = Read-YesNo -Prompt "Transcript mitschreiben?" -DefaultYes $true
  if ($doTranscript) { Start-Transcript -Path $logPath -Force | Out-Null }

  $noRestart = Read-YesNo -Prompt "Bei Feature-Disable keinen Restart erzwingen?" -DefaultYes $true

  $targets = Get-TargetsInteractive
  if (-not $targets -or $targets.Count -eq 0) { throw "Keine Targets." }

  Write-Host ""
  Write-Host "Targets: $($targets.Count)" -ForegroundColor Cyan
  Write-Host "CSV: $csvPath" -ForegroundColor Cyan
  if ($doTranscript) { Write-Host "Log: $logPath" -ForegroundColor Cyan }
  Write-Host ""

  $results = New-Object System.Collections.Generic.List[object]

  foreach ($t in $targets) {
    Write-Host "Analyse: $t" -ForegroundColor White
    $a = Invoke-Analyze -Target $t

    $smb1Active =
      ($a.SMB1ServerEnabled -eq $true) -or
      ($a.SMB1ClientEnabled -eq $true) -or
      ($a.SMB1FeatureInstalled -eq $true) -or
      ($a.SMB1ServerFeature -eq $true)

    $status = if (-not $a.Reachable) { "UNREACHABLE" } elseif ($smb1Active) { "SMB1_ACTIVE" } else { "OK" }

    $line = [pscustomobject]@{
      ComputerName         = $a.ComputerName
      Status               = $status
      Reachable            = $a.Reachable
      OS                   = $a.OS
      SMB1ServerEnabled    = $a.SMB1ServerEnabled
      SMB2ServerEnabled    = $a.SMB2ServerEnabled
      SMB1ClientEnabled    = $a.SMB1ClientEnabled
      SMB1FeatureInstalled = $a.SMB1FeatureInstalled
      SMB1ServerFeature    = $a.SMB1ServerFeature
      Action               = ""
      RebootRecommended    = $false
      Notes                = $a.Notes
    }

    $line | Format-List

    if (-not $a.Reachable) {
      $line.Action = "Skip (unreachable)"
      $results.Add($line)
      Write-Host ""
      continue
    }

    if (-not $smb1Active) {
      $line.Action = "No change"
      $results.Add($line)
      Write-Host ""
      continue
    }

    $choice = Read-Choice -Prompt "SMB1 ist aktiv. Aktion: R=Remediate, S=Skip, E=Exception, Q=Quit" -Allowed @("R","S","E","Q") -Default "R"
    if ($choice -eq "Q") { break }

    if ($choice -eq "S") {
      $line.Action = "Skip"
      $results.Add($line)
      Write-Host ""
      continue
    }

    if ($choice -eq "E") {
      $reason = Read-Host "Exception Grund (kurz, zB Legacy Scanner/NAS)"
      $line.Action = "Exception"
      $line.Notes = ($line.Notes + " EXCEPTION: " + $reason).Trim()
      $results.Add($line)
      Write-Host ""
      continue
    }

    # Remediate
    $confirm = Read-YesNo -Prompt "Wirklich SMB1 auf $t deaktivieren/entfernen?" -DefaultYes $true
    if (-not $confirm) {
      $line.Action = "Skip (user declined)"
      $results.Add($line)
      Write-Host ""
      continue
    }

    Write-Host "Remediation läuft: $t" -ForegroundColor Yellow
    $r = Invoke-Remediate -Target $t -NoRestart $noRestart

    $line.Action = if ($r.Changed) { "Remediated" } else { "Remediate attempted (no change)" }
    $line.RebootRecommended = [bool]$r.RebootRecommended
    if ($r.Notes) { $line.Notes = ($line.Notes + " " + $r.Notes).Trim() }

    # Re-Analyse nach Fix
    $a2 = Invoke-Analyze -Target $t
    $line.SMB1ServerEnabled    = $a2.SMB1ServerEnabled
    $line.SMB2ServerEnabled    = $a2.SMB2ServerEnabled
    $line.SMB1ClientEnabled    = $a2.SMB1ClientEnabled
    $line.SMB1FeatureInstalled = $a2.SMB1FeatureInstalled
    $line.SMB1ServerFeature    = $a2.SMB1ServerFeature

    $results.Add($line)

    if ($line.RebootRecommended -and -not $noRestart) {
      Write-Host "Hinweis: Neustart empfohlen." -ForegroundColor Yellow
    }

    Write-Host ""
  }

  $results |
    Sort-Object Status, ComputerName |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path $csvPath

  Write-Host "Fertig. CSV exportiert: $csvPath" -ForegroundColor Green

  # Kurzsummary
  $grp = $results | Group-Object Status | Sort-Object Name
  Write-Host ""
  Write-Host "Summary:" -ForegroundColor Cyan
  $grp | ForEach-Object { "{0,-15} {1,5}" -f $_.Name, $_.Count } | ForEach-Object { Write-Host $_ }

}
catch {
  Write-Host "Fehler: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
  try { Stop-Transcript | Out-Null } catch { }
}
