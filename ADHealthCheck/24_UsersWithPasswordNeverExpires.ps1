Import-Module ActiveDirectory

$timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
$exportPath = "C:\Temp\AD_PasswordNeverExpires_Export_$timestamp.csv"

$users = Get-ADUser -Filter {
    Enabled -eq $true -and PasswordNeverExpires -eq $true
} -Properties `
    DisplayName,
    GivenName,
    Surname,
    SamAccountName,
    UserPrincipalName,
    PasswordNeverExpires,
    PasswordLastSet,
    LastLogonDate,
    Description,
    DistinguishedName,
    MemberOf,
    whenCreated

if (-not $users) {
    Write-Host "Keine aktiven Konten mit 'Kennwort läuft nie ab' gefunden." -ForegroundColor Green
    return
}

$results = foreach ($user in $users) {
    $groups = @($user.MemberOf | ForEach-Object {
        try {
            (Get-ADGroup $_).Name
        }
        catch {
            $_
        }
    }) -join "; "

    [PSCustomObject]@{
        DisplayName              = $user.DisplayName
        GivenName                = $user.GivenName
        Surname                  = $user.Surname
        SamAccountName           = $user.SamAccountName
        UserPrincipalName        = $user.UserPrincipalName
        Enabled                  = $true
        PasswordNeverExpires     = $user.PasswordNeverExpires
        PasswordLastSet          = $user.PasswordLastSet
        LastLogonDate            = $user.LastLogonDate
        Description              = $user.Description
        WhenCreated              = $user.whenCreated
        DistinguishedName        = $user.DistinguishedName
        GroupMembership          = $groups
        StartsWithSvc            = if ($user.SamAccountName -match '^(?i)svc') { "Yes" } else { "No" }
        InternalCheck_Admin      = ""
        InternalCheck_Service    = ""
        InternalCheck_Comment    = ""
        CustomerDecision         = ""
        CustomerComment          = ""
    }
}

$results |
    Sort-Object DisplayName |
    Export-Csv -Path $exportPath -NoTypeInformation -Encoding UTF8

$svcUsers = $results | Where-Object { $_.SamAccountName -match '^(?i)svc' } | Sort-Object SamAccountName

Write-Host ""
Write-Host "Export abgeschlossen:" -ForegroundColor Green
Write-Host $exportPath -ForegroundColor Cyan
Write-Host ""

Write-Host "Hinweis:" -ForegroundColor Yellow
Write-Host "1. Export intern auf Administratoren und Servicekonten prüfen."
Write-Host "2. Danach bereinigte Liste an den Kunden zur Entscheidung senden."
Write-Host ""

Write-Host "Auswertung potenzieller Service-User (SamAccountName beginnt mit 'svc'):" -ForegroundColor Yellow
Write-Host "Anzahl: $($svcUsers.Count)"
if ($svcUsers.Count -gt 0) {
    $svcUsers | Select-Object SamAccountName, DisplayName, UserPrincipalName |
        Format-Table -AutoSize
}
else {
    Write-Host "Keine Konten gefunden, deren SamAccountName mit 'svc' beginnt." -ForegroundColor Gray
}