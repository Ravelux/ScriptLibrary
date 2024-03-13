# Define the program name as a variable
$ProgramName = "PROGRAM NAME"

# Get the application using the program name
$MyApp = Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -eq $ProgramName }

# Check if the application was found before uninstalling
if ($MyApp) {
    $MyApp.Uninstall()
} else {
    Write-Host "Application not found: $ProgramName"
}