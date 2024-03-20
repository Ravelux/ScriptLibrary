# Dieses PowerShell-Skript gibt die Anzahl der Benutzer in der AD-Gruppe "grp.vpn" aus.

# Gruppenname
$groupName = "grp.vpn"

# Abfrage der Gruppenmitglieder
$groupMembers = Get-ADGroupMember -Identity $groupName

# Filtern der Benutzer aus den Gruppenmitgliedern
$users = $groupMembers | Where-Object { $_.objectClass -eq "user" }

# Anzahl der Benutzer in der Gruppe
$numberOfUsers = $users.Count

# Ausgabe der Anzahl
Write-Host "Anzahl der Benutzer in der Gruppe '$groupName': $numberOfUsers"