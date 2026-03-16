# 07_Tier0_AdminGroupMembers_Remediation.ps1
# Interaktives Skript zur Analyse und Bereinigung von Tier-0-Gruppen
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Domain = (Get-ADDomain).DNSRoot,
    [string[]]$Tier0Groups = @(
        "Domain Admins",
        "Enterprise Admins",
        "Schema Admins",
        "Administrators",
        "Account Operators",
        "Backup Operators",
        "Server Operators",
        "Print Operators"
    ),
    [string]$ReportPath = ".\reports\07_Tier0_AdminGroupMembers.csv"
)

$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory
New-Item -ItemType Directory -Path (Split-Path $ReportPath) -Force | Out-Null

Write-Host "`n=== Tier 0 Admin Group Member Analysis ===" -ForegroundColor Cyan
Write-Host "Domain: $Domain`n"

$allRows = @()

foreach ($groupName in $Tier0Groups) {
    $grp = Get-ADGroup -Server $Domain -Identity $groupName -ErrorAction SilentlyContinue
    if (-not $grp) {
        Write-Host "[SKIP] Gruppe '$groupName' nicht gefunden." -ForegroundColor Yellow
        continue
    }

    $members = Get-ADGroupMember -Server $Domain -Identity $grp.DistinguishedName -Recursive -ErrorAction Stop

    Write-Host "---- $groupName ($($members.Count) Mitglieder) ----" -ForegroundColor White

    if ($members.Count -eq 0) {
        Write-Host "  (keine Mitglieder)" -ForegroundColor Green
        continue
    }

    foreach ($m in $members) {
        Write-Host "  [$($m.ObjectClass.ToUpper())] $($m.SamAccountName) - $($m.DistinguishedName)" -ForegroundColor Gray
        $allRows += [pscustomobject]@{
            Group      = $groupName
            MemberSam  = $m.SamAccountName
            MemberDN   = $m.DistinguishedName
            MemberType = $m.ObjectClass
            Action     = ""
        }
    }

    Write-Host ""
    $answer = Read-Host "Möchtest du Mitglieder aus '$groupName' entfernen? (j/n)"
    if ($answer -ieq "j") {
        foreach ($m in $members) {
            $confirm = Read-Host "  Entfernen: $($m.SamAccountName) [$($m.ObjectClass)] ? (j/n)"
            if ($confirm -ieq "j") {
                if ($PSCmdlet.ShouldProcess("$($m.SamAccountName) aus $groupName", "Entfernen")) {
                    Remove-ADGroupMember -Server $Domain -Identity $grp.DistinguishedName `
                        -Members $m.DistinguishedName -Confirm:$false
                    Write-Host "  [ENTFERNT] $($m.SamAccountName)" -ForegroundColor Red
                    # Zeile im Report als entfernt markieren
                    ($allRows | Where-Object {
                        $_.Group -eq $groupName -and $_.MemberSam -eq $m.SamAccountName
                    }) | ForEach-Object { $_.Action = "Removed" }
                }
            } else {
                Write-Host "  [BEHALTEN] $($m.SamAccountName)" -ForegroundColor Green
                ($allRows | Where-Object {
                    $_.Group -eq $groupName -and $_.MemberSam -eq $m.SamAccountName
                }) | ForEach-Object { $_.Action = "Kept" }
            }
        }
    }
    Write-Host ""
}

$allRows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportPath
Write-Host "`nReport gespeichert: $ReportPath" -ForegroundColor Cyan
Write-Host "=== Fertig ===" -ForegroundColor Cyan