# 15_NTP_Configured.ps1
# === Common Header ===
$ErrorActionPreference = "Stop"

function Read-YesNo {
  param(
    [Parameter(Mandatory=$true)][string]$Question,
    [bool]$DefaultNo = $true
  )
  $suffix = if ($DefaultNo) { " (j/N)" } else { " (J/n)" }
  $a = Read-Host ($Question + $suffix)
  if ([string]::IsNullOrWhiteSpace($a)) { return (-not $DefaultNo) }
  return ($a -match '^(j|ja|y|yes)$')
}

# Domain automatisch (falls AD Module später gebraucht werden)
$DomainDns = if ($env:USERDNSDOMAIN) { $env:USERDNSDOMAIN } else { $null }

# Report-Basis
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$BaseReportDir = if ($DomainDns) {
  "C:\Temp\AD-Healthcheck-Reports\$DomainDns\$ts"
} else {
  "C:\Temp\AD-Healthcheck-Reports\_nodomain_\$ts"
}
New-Item -ItemType Directory -Path $BaseReportDir -Force | Out-Null

Import-Module ActiveDirectory -ErrorAction Stop
if (-not $DomainDns) { $DomainDns = (Get-ADDomain).DNSRoot }

$ReportPath = Join-Path $BaseReportDir "15_NTP_Configured.csv"

$domain = Get-ADDomain -Identity $DomainDns -ErrorAction Stop

# PDC sauber ermitteln (robuster als $domain.PDCEmulator, wenn AD cmdlet nicht sauber bindet)
$pdcFqdn = (Get-ADDomainController -Discover -Service PrimaryDC -DomainName $DomainDns -ErrorAction Stop).HostName

if ([string]::IsNullOrWhiteSpace($pdcFqdn)) {
  throw "PDC Emulator konnte nicht ermittelt werden. Prüfe DNS/Domain-Join/ADWS-Erreichbarkeit."
}

$pdcName = $pdcFqdn.Split(".")[0]
$isPdc = ($env:COMPUTERNAME -ieq $pdcName)

Write-Host "PDC Emulator: $pdcFqdn | Dieser DC: $env:COMPUTERNAME | IsPDC: $isPdc"
Write-Host (w32tm /query /status)

$NtpPeers = "0.pool.ntp.org,0x8 1.pool.ntp.org,0x8"

$rem = $false
$note = "No change"

if (Read-YesNo "NTP jetzt korrekt konfigurieren?") {
  try {
    if ($isPdc) {
      w32tm /config /manualpeerlist:$NtpPeers /syncfromflags:manual /reliable:yes /update | Out-Null
    } else {
      w32tm /config /syncfromflags:domhier /reliable:no /update | Out-Null
    }
    w32tm /resync /force | Out-Null
    $rem = $true
    $note = "Configured"
  } catch { $note = $_.Exception.Message }
}

$out = [pscustomobject]@{
  Computer=$env:COMPUTERNAME
  Domain=$DomainDns
  PDCEmulator=$pdcFqdn
  IsPDC=$isPdc
  Remediated=$rem
  Note=$note
  Timestamp=(Get-Date)
}
$out | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportPath
$out
