# 19_GPOs_DisabledLinks.ps1
# Finding: GPOs with disabled Link (low)
# Zweck: Listet alle GPO-Links, die deaktiviert sind (Enabled = false), inkl. Ziel (Domain/OU).
# Optional: Löscht GPOs, die NUR deaktivierte Links haben (keinen einzigen aktiven Link irgendwo).
# Hinweis: Löschen nur nach Operator-Entscheidung, inkl. optionalem Backup je GPO.

[CmdletBinding()]
param(
    [string]$ReportDir = "",
    [switch]$ExcludeOUs
)

$ErrorActionPreference = "Stop"

function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)][string]$Question,
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
    }
    else {
        "C:\Temp\AD-Healthcheck-Reports\_nodomain_\$ts"
    }
}
else {
    $BaseReportDir = Join-Path $ReportDir $ts
}
New-Item -ItemType Directory -Path $BaseReportDir -Force | Out-Null

# === Modules ===
Import-Module GroupPolicy    -ErrorAction Stop
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

# === Alle GPOs via XML auslesen ===
Write-Host "Lese alle GPOs aus..." -ForegroundColor Cyan
$allGpos = Get-GPO -All -Domain $DomainDns

$rows       = New-Object System.Collections.Generic.List[object]
$candidates = New-Object System.Collections.Generic.List[object]

foreach ($gpo in $allGpos) {
    [xml]$report = Get-GPOReport -Guid $gpo.Id -ReportType XML -Domain $DomainDns

    # SelectNodes gibt immer eine XmlNodeList zurueck -- auch bei 0 oder 1 Treffer
    $ns = New-Object System.Xml.XmlNamespaceManager($report.NameTable)
    $ns.AddNamespace("gp", "http://www.microsoft.com/GroupPolicy/Settings")
    $linksArray    = $report.GPO.SelectNodes("gp:LinksTo", $ns)
    $disabledLinks = $linksArray | Where-Object { $_.Enabled -eq "false" }
    $enabledLinks  = $linksArray | Where-Object { $_.Enabled -eq "true" }

    if ($disabledLinks.Count -eq 0) { continue }

    # Alle deaktivierten Links als Row speichern
    foreach ($link in $disabledLinks) {
        $rows.Add([pscustomobject]@{
            Domain           = $DomainDns
            DisplayName      = $gpo.DisplayName
            GpoId            = $gpo.Id.ToString()
            LinkTarget       = $link.SOMPath
            LinkTargetName   = $link.SOMName
            LinkEnabled      = $false
            CreationTime     = $gpo.CreationTime
            ModificationTime = $gpo.ModificationTime
            Owner            = $gpo.Owner
        })
    }

    # Kandidat: GPO hat deaktivierte Links aber KEINEN einzigen aktiven Link
    if ($enabledLinks.Count -eq 0) {
        $candidates.Add([pscustomobject]@{
            Domain               = $DomainDns
            DisplayName          = $gpo.DisplayName
            GpoId                = $gpo.Id.ToString()
            DisabledLinkCount    = $disabledLinks.Count
            CreationTime         = $gpo.CreationTime
            ModificationTime     = $gpo.ModificationTime
            Owner                = $gpo.Owner
            CandidateForDeletion = $true
            Note                 = "Kein aktiver Link gefunden. Nur deaktivierte Links."
        })
    }
}

$rowsSorted       = @($rows       | Sort-Object DisplayName, LinkTarget)
$candidatesSorted = @($candidates | Sort-Object @{Expression = 'DisabledLinkCount'; Descending = $true },
    @{Expression = 'DisplayName'; Descending = $false })

$rowsSorted       | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportDisabledLinks
$candidatesSorted | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportCandidates

# === Ausgabe ===
Write-Host "Ergebnis:"
Write-Host "- Disabled Links gefunden         : $($rowsSorted.Count)"
Write-Host "- GPO Kandidaten (nur deaktiviert): $($candidatesSorted.Count)"
Write-Host ""
Write-Host "CSV Reports:"
Write-Host "- $ReportDisabledLinks"
Write-Host "- $ReportCandidates"
Write-Host ""

if ($candidatesSorted.Count -gt 0) {
    $candidatesSorted |
        Select-Object DisplayName, GpoId, DisabledLinkCount, ModificationTime, Owner, Note |
        Format-Table -AutoSize
    Write-Host ""

    if (Read-YesNo "Sollen GPOs geloescht werden, die nur deaktivierte Links haben?") {
        $doBackup  = Read-YesNo "Vor dem Loeschen je GPO ein Backup erstellen?"
        $backupDir = Join-Path $BaseReportDir "GPO-Backups"
        if ($doBackup) {
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        }

        $remRows = New-Object System.Collections.Generic.List[object]

        foreach ($c in $candidatesSorted) {
            if ([string]::IsNullOrWhiteSpace($c.GpoId)) { continue }

            if (-not (Read-YesNo ("GPO loeschen: '$($c.DisplayName)' ($($c.GpoId))?"))) {
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

            $ok = $false; $note = ""
            try {
                if ($doBackup) {
                    Backup-GPO -Guid $c.GpoId -Path $backupDir `
                        -Comment "Backup before deletion (disabled links finding)" | Out-Null
                }
                Remove-GPO -Guid $c.GpoId -Confirm:$false
                $ok   = $true
                $note = if ($doBackup) { "Deleted. Backup created." } else { "Deleted." }
            }
            catch {
                $ok   = $false
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
}
else {
    Write-Host "Keine GPOs mit ausschliesslich deaktivierten Links gefunden."
}
