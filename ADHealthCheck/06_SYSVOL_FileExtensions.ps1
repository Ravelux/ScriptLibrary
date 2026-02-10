# 06_SYSVOL_FileExtensions.ps1
# Paste Common Header above this line first

Import-Module ActiveDirectory -ErrorAction Stop
if (-not $DomainDns) { $DomainDns = (Get-ADDomain).DNSRoot }

$ReportPath = Join-Path $BaseReportDir "06_SYSVOL_FileExtensions.csv"
$QuarantinePath = Join-Path $BaseReportDir "quarantine_sysvol"
New-Item -ItemType Directory -Path $QuarantinePath -Force | Out-Null

$Extensions = @(".exe",".msi",".ps1",".vbs",".js",".bat",".cmd",".zip",".rar",".7z",".iso")
$sysvol = "\\$DomainDns\SYSVOL\$DomainDns\Policies"
if (-not (Test-Path $sysvol)) { throw "SYSVOL path not reachable: $sysvol" }

$files = Get-ChildItem -Path $sysvol -Recurse -File -ErrorAction Stop |
  Where-Object { $Extensions -contains $_.Extension.ToLowerInvariant() }

Write-Host "Treffer in SYSVOL ($($files.Count)):"
$files | Select-Object FullName,Length,LastWriteTime | Format-Table -AutoSize

$doFix = $false
if ($files.Count -gt 0) {
  $doFix = Read-YesNo "Diese Dateien in Quarantäne kopieren und aus SYSVOL entfernen?"
}

$rows = foreach ($f in $files) {
  $row = [pscustomobject]@{
    Domain=$DomainDns; Path=$f.FullName; Extension=$f.Extension; SizeKB=[math]::Round($f.Length/1KB,2); LastWrite=$f.LastWriteTime; Remediated=$false; Note=""
  }

  if ($doFix) {
    try {
      $rel = $f.FullName.Substring($sysvol.Length).TrimStart("\")
      $dst = Join-Path $QuarantinePath $rel
      New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null
      Copy-Item -Path $f.FullName -Destination $dst -Force
      Remove-Item -Path $f.FullName -Force
      $row.Remediated = $true
    } catch { $row.Note = $_.Exception.Message }
  } else {
    $row.Note = "No change"
  }

  $row
}

$rows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportPath
$rows