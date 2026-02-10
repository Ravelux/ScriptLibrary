# 13_DC_ThirdParty_Apps.ps1
[CmdletBinding()]
param(
  [string]$ComputerName = $env:COMPUTERNAME,
  [string]$ReportPath = ".\reports\13_ThirdParty_Apps.csv"
)

$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Path (Split-Path $ReportPath) -Force | Out-Null

$sb = {
  $paths = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
  )

  $apps = foreach ($p in $paths) {
    Get-ItemProperty $p -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } | ForEach-Object {
      [pscustomobject]@{
        Computer     = $env:COMPUTERNAME
        DisplayName  = $_.DisplayName
        DisplayVersion = $_.DisplayVersion
        Publisher    = $_.Publisher
        InstallDate  = $_.InstallDate
      }
    }
  }

  $apps | Sort-Object DisplayName -Unique
}

$result = if ($ComputerName -eq $env:COMPUTERNAME) { & $sb } else { Invoke-Command -ComputerName $ComputerName -ScriptBlock $sb }
$result | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportPath
$result
