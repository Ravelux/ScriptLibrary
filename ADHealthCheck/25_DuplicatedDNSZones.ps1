<#
.SYNOPSIS
Analysiert mögliche doppelte DNS-Zonen auf einem Windows DNS-/AD-Umfeld.

.DESCRIPTION
- Liest lokale DNS-Zonen über den DNS-Server aus
- Prüft zusätzlich AD-Objekte im Partition-Bereich MicrosoftDNS
- Zeigt potenzielle Dubletten, Zonentypen und Replikationsinfos
- Optional kann nach manueller Prüfung eine lokale Zone entfernt werden

.HINWEIS
Das Skript sollte mit administrativen Rechten auf einem DNS-Server / DC ausgeführt werden.
Das Entfernen einer Zone darf nur nach fachlicher Prüfung erfolgen.
#>

[CmdletBinding()]
param(
    [switch]$IncludeForestDnsZones,
    [switch]$IncludeDomainDnsZones,
    [switch]$OfferRemoval
)

function Write-Section {
    param([string]$Text)
    Write-Host "`n==== $Text ====" -ForegroundColor Cyan
}

$dnsZones = @()
$adZones  = @()

Write-Section "Lokale DNS-Zonen auslesen"

try {
    $dnsZones = Get-DnsServerZone -ErrorAction Stop | Select-Object `
        ZoneName,
        ZoneType,
        IsDsIntegrated,
        IsReverseLookupZone,
        ReplicationScope,
        DirectoryPartitionName,
        DynamicUpdate
}
catch {
    Write-Warning "Lokale DNS-Zonen konnten nicht ausgelesen werden: $($_.Exception.Message)"
}

if ($dnsZones) {
    $dnsZones | Sort-Object ZoneName | Format-Table -AutoSize
} else {
    Write-Host "Keine lokalen DNS-Zonen gefunden oder Zugriff fehlgeschlagen."
}

Write-Section "AD-DNS-Zonenobjekte prüfen"

try {
    Import-Module ActiveDirectory -ErrorAction Stop

    $rootDse = Get-ADRootDSE
    $searchBases = @()

    if ($IncludeDomainDnsZones) {
        $searchBases += "CN=MicrosoftDNS,DC=DomainDnsZones,$($rootDse.rootDomainNamingContext)"
    }

    if ($IncludeForestDnsZones) {
        $searchBases += "CN=MicrosoftDNS,DC=ForestDnsZones,$($rootDse.rootDomainNamingContext)"
    }

    if (-not $searchBases) {
        # Standardmäßig beide versuchen
        $searchBases += "CN=MicrosoftDNS,DC=DomainDnsZones,$($rootDse.rootDomainNamingContext)"
        $searchBases += "CN=MicrosoftDNS,DC=ForestDnsZones,$($rootDse.rootDomainNamingContext)"
    }

    foreach ($base in $searchBases) {
        try {
            $zones = Get-ADObject -SearchBase $base -LDAPFilter "(objectClass=dnsZone)" -Properties name, distinguishedName |
                Select-Object @{Name='ZoneName';Expression={$_.Name}},
                              @{Name='DistinguishedName';Expression={$_.DistinguishedName}},
                              @{Name='SearchBase';Expression={$base}}

            $adZones += $zones
        }
        catch {
            Write-Warning "AD-Suchbasis nicht lesbar: $base -- $($_.Exception.Message)"
        }
    }
}
catch {
    Write-Warning "ActiveDirectory-Modul konnte nicht geladen werden: $($_.Exception.Message)"
}

if ($adZones) {
    $adZones | Sort-Object ZoneName | Format-Table -AutoSize
} else {
    Write-Host "Keine AD-Zonenobjekte gefunden oder Zugriff fehlgeschlagen."
}

Write-Section "Potenzielle Dubletten ermitteln"

$combined = @()

foreach ($zone in $dnsZones) {
    $combined += [PSCustomObject]@{
        ZoneName               = $zone.ZoneName
        Source                 = "LocalDNS"
        ZoneType               = $zone.ZoneType
        IsDsIntegrated         = $zone.IsDsIntegrated
        ReplicationScope       = $zone.ReplicationScope
        DirectoryPartitionName = $zone.DirectoryPartitionName
        DistinguishedName      = $null
    }
}

foreach ($zone in $adZones) {
    $combined += [PSCustomObject]@{
        ZoneName               = $zone.ZoneName
        Source                 = "ActiveDirectory"
        ZoneType               = $null
        IsDsIntegrated         = $null
        ReplicationScope       = $null
        DirectoryPartitionName = $zone.SearchBase
        DistinguishedName      = $zone.DistinguishedName
    }
}

$duplicates = $combined |
    Group-Object ZoneName |
    Where-Object { $_.Count -gt 1 } |
    Sort-Object Name

if ($duplicates) {
    foreach ($dup in $duplicates) {
        Write-Host "`nMögliche doppelte Zone: $($dup.Name)" -ForegroundColor Yellow
        $dup.Group | Format-Table Source, ZoneName, ZoneType, IsDsIntegrated, ReplicationScope, DirectoryPartitionName, DistinguishedName -AutoSize
    }
}
else {
    Write-Host "Keine offensichtlichen Dubletten gefunden." -ForegroundColor Green
}

Write-Section "Bewertungshinweis"

Write-Host @"
Prüfen Sie bei jeder gefundenen Dublette:
- Ist die Zone produktiv erforderlich?
- Existiert sie lokal und zusätzlich AD-integriert?
- Ist eine davon eine Altlast?
- Ist der Replikationsbereich korrekt?
- Welche Instanz ist die fachlich gültige authoritative Zone?
"@

if ($OfferRemoval -and $dnsZones) {
    Write-Section "Optionale Entfernung einer lokalen Zone"

    $removeName = Read-Host "Name der lokal zu entfernenden Zone eingeben (leer = abbrechen)"
    if ([string]::IsNullOrWhiteSpace($removeName)) {
        Write-Host "Keine Entfernung durchgeführt."
        return
    }

    $matching = $dnsZones | Where-Object { $_.ZoneName -eq $removeName }

    if (-not $matching) {
        Write-Warning "Die Zone '$removeName' wurde lokal nicht gefunden."
        return
    }

    $matching | Format-Table ZoneName, ZoneType, IsDsIntegrated, ReplicationScope, DirectoryPartitionName -AutoSize

    $confirm = Read-Host "Zone wirklich entfernen? Bitte JA eingeben"
    if ($confirm -eq "JA") {
        try {
            Remove-DnsServerZone -Name $removeName -Force -ErrorAction Stop
            Write-Host "Zone '$removeName' wurde entfernt." -ForegroundColor Green
        }
        catch {
            Write-Error "Entfernung fehlgeschlagen: $($_.Exception.Message)"
        }
    }
    else {
        Write-Host "Entfernung abgebrochen."
    }
}