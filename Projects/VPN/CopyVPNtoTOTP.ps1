# Importiere das Active Directory Modul
Import-Module ActiveDirectory

# Gruppennamen festlegen
$sourceGroup = "grp.vpn"
$destinationGroup = "grp.vpntotp"

# Hole die Benutzer der Quellgruppe
$users = Get-ADGroupMember -Identity $sourceGroup

# Gehe jeden Benutzer durch und füge ihn der Zielgruppe hinzu
foreach ($user in $users) {
    # Prüfe, ob das Objekt ein Benutzer ist
    if ($user.objectClass -eq "user") {
        # Füge den Benutzer zur Zielgruppe hinzu
        Add-ADGroupMember -Identity $destinationGroup -Members $user.DistinguishedName
    }
}