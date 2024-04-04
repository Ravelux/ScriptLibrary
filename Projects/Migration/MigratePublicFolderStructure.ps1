##############################
## IN EXCHANGE SHELL AUSFÜHREN
##############################

# Exportieren der Public Folder Struktur in eine CSV-Datei
Get-PublicFolder -Recurse | Export-Csv -Path C:\Pfad\zur\Datei.csv -NoTypeInformation

# Importieren der Public Folder Struktur aus der CSV-Datei in Exchange Online
$Session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri https://outlook.office365.com/powershell-liveid/ -Credential $UserCredential -Authentication Basic -AllowRedirection
Import-PSSession $Session
Import-Csv -Path C:\Pfad\zur\Datei.csv | ForEach-Object {New-PublicFolder -Name $_.Name -Path $_.ParentPath}