$ReportedVersion = Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration" -Name "VersionToReport"
$Channel = Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration" -Name "CDNBaseUrl" | Select-Object -Last 1
$CloudVersionInfo = Invoke-RestMethod 'https://clients.config.office.net/releases/v1.0/OfficeReleases'
$UsedChannel = $cloudVersioninfo | Where-Object { $_.OfficeVersions.cdnBaseURL -eq $channel }

if ($UsedChannel.latestversion -eq $ReportedVersion) {
    Write-Host "Currently using the latest version of Office in the $($UsedChannel.Channel) Channel: $($ReportedVersion)"
    exit 0
}
else {
    Write-Host "Not using the latest version in the $($UsedChannel.Channel) Channel. Check if version is still supported"
    $OurVersion = $CloudVersionInfo.OfficeVersions | Where-Object -Property legacyVersion -EQ $ReportedVersion
    if ($OurVersion.endOfSupportDate -eq "0001-01-01T00:00:00Z") {
        Write-Host "This version does not yet have an end-of-support date. You are running a current version, but not the latest. Your version is $($ReportedVersion) and the latest version is $($UsedChannel.latestVersion)"
        exit 0
    }
    if ($OurVersion.endOfSupportDate) {
        Write-Host "this version will not be supported at $($OurVersion.endOfSupportDate). Your version is $($ReportedVersion) and the latest version is $($UsedChannel.latestVersion)"
        exit 1
    }
    else {
        Write-Host "Could not find version in the supported versions list. This version is most likely no longer support. Your version is $($ReportedVersion) and the latest version is $($UsedChannel.latestVersion). For all supported versions, see below"
        $CloudVersionInfo.OfficeVersions
        exit 1
    }
}