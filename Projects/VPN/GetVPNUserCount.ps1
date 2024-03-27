# Dieses PowerShell-Skript gibt die Anzahl der aktiven Benutzer in der AD-Gruppe "grp.vpn" aus.

# Gruppenname
$groupName = "grp.vpn"

# Abfrage der Gruppenmitglieder
$groupMembers = Get-ADGroupMember -Identity $groupName

# Filtern der aktiven Benutzer aus den Gruppenmitgliedern
$activeUsers = $groupMembers | Where-Object { $_.objectClass -eq "user" } | ForEach-Object {
    # Abfrage des Benutzerkontos, um den Status zu überprüfen
    $user = Get-ADUser -Identity $_.distinguishedName -Properties userAccountControl
    
    # Überprüfung, ob das Konto aktiv ist (das ACCOUNTDISABLE Flag ist nicht gesetzt)
    if (($user.userAccountControl -band 2) -eq 0) {
        return $user
    }
}

# Anzahl der aktiven Benutzer in der Gruppe
$numberOfActiveUsers = $activeUsers.Count

# Ausgabe der Anzahl der aktiven Benutzer
Write-Host "Anzahl der aktiven Benutzer in der Gruppe '$groupName': $numberOfActiveUsers"