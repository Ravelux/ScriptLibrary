# 06_SYSVOL_FileExtensions.ps1

$ErrorActionPreference = "Stop"

function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)][string]$Question,
        [bool]$DefaultNo = $true
    )
    $suffix = if ($DefaultNo) { " (j/N)" } else { " (J/n)" }
    $a = Read-Host ($Question + $suffix)
    if ([string]::IsNullOrWhiteSpace($a)) { return (-not $DefaultNo) }
    return ($a -match '^(j|ja|y|yes)$')
}

function Read-Choice {
    param(
        [Parameter(Mandatory = $true)][string]$Question,
        [Parameter(Mandatory = $true)][string[]]$Choices,
        [string]$Default = $null
    )

    $choicesText = ($Choices -join "/")
    $prompt = if ($Default) { "$Question [$choicesText] (Default: $Default)" } else { "$Question [$choicesText]" }

    do {
        $answer = Read-Host $prompt
        if ([string]::IsNullOrWhiteSpace($answer) -and $Default) {
            return $Default
        }
    } until ($Choices -contains $answer)

    return $answer
}

Import-Module ActiveDirectory -ErrorAction Stop

$DomainDns = if ($env:USERDNSDOMAIN) { $env:USERDNSDOMAIN } else { (Get-ADDomain).DNSRoot }

$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$BaseReportDir = "C:\Temp\AD-Healthcheck-Reports\$DomainDns\$ts"
New-Item -ItemType Directory -Path $BaseReportDir -Force | Out-Null

$ReportPath = Join-Path $BaseReportDir "06_SYSVOL_FileExtensions.csv"
$QuarantinePath = Join-Path $BaseReportDir "quarantine_sysvol"
New-Item -ItemType Directory -Path $QuarantinePath -Force | Out-Null

$AllowedExtensions = @(
    ".bat",".exe",".nix",".vbs",".pol",".reg",".xml",".admx",".adml",
    ".inf",".ini",".adm",".kix",".msi",".ps1",".cmd",".ico"
)

$sysvol = "\\$DomainDns\SYSVOL\$DomainDns\Policies"
if (-not (Test-Path $sysvol)) {
    throw "SYSVOL path not reachable: $sysvol"
}

Write-Host ""
Write-Host "Prüfe SYSVOL-Pfad: $sysvol" -ForegroundColor Cyan
Write-Host "Erlaubte Extensions: $($AllowedExtensions -join ', ')" -ForegroundColor DarkGray
Write-Host ""

$files = Get-ChildItem -Path $sysvol -Recurse -File -ErrorAction Stop

$suspiciousFiles = $files | Where-Object {
    $ext = $_.Extension.ToLowerInvariant()
    [string]::IsNullOrWhiteSpace($ext) -or ($AllowedExtensions -notcontains $ext)
}

if (-not $suspiciousFiles -or $suspiciousFiles.Count -eq 0) {
    Write-Host "Keine unzulässigen oder unbekannten Dateiendungen in SYSVOL gefunden." -ForegroundColor Green

    [pscustomobject]@{
        Domain       = $DomainDns
        Path         = ""
        FileName     = ""
        Extension    = ""
        SizeKB       = ""
        LastWrite    = ""
        Status       = "No findings"
        Action       = "None"
        Note         = "No unauthorized file extensions found in SYSVOL"
    } | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportPath

    return
}

Write-Host "Auffällige Dateien in SYSVOL ($($suspiciousFiles.Count)):" -ForegroundColor Yellow
$suspiciousFiles | Select-Object FullName, Name, Extension, Length, LastWriteTime | Format-Table -AutoSize

Write-Host ""
$globalAction = Read-Choice -Question "Wie soll mit den gefundenen Dateien verfahren werden?" -Choices @("report","quarantine","delete","ask") -Default "report"
Write-Host ""

$rows = foreach ($f in $suspiciousFiles) {
    $relativePath = $f.FullName.Substring($sysvol.Length).TrimStart("\")
    $action = $globalAction

    if ($globalAction -eq "ask") {
        $action = Read-Choice -Question "Datei '$($f.Name)' verarbeiten?" -Choices @("report","quarantine","delete","skip") -Default "report"
    }

    $row = [pscustomobject]@{
        Domain       = $DomainDns
        Path         = $f.FullName
        FileName     = $f.Name
        Extension    = $f.Extension
        SizeKB       = [math]::Round($f.Length / 1KB, 2)
        LastWrite    = $f.LastWriteTime
        Status       = "Detected"
        Action       = $action
        Note         = ""
    }

    try {
        switch ($action) {
            "report" {
                $row.Status = "Reported only"
                $row.Note = "File not changed"
            }
            "skip" {
                $row.Status = "Skipped"
                $row.Note = "Skipped by operator"
            }
            "quarantine" {
                $dst = Join-Path $QuarantinePath $relativePath
                New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null
                Copy-Item -Path $f.FullName -Destination $dst -Force
                Remove-Item -Path $f.FullName -Force
                $row.Status = "Remediated"
                $row.Note = "Copied to quarantine and removed from SYSVOL"
            }
            "delete" {
                Remove-Item -Path $f.FullName -Force
                $row.Status = "Remediated"
                $row.Note = "Removed from SYSVOL"
            }
        }
    }
    catch {
        $row.Status = "Error"
        $row.Note = $_.Exception.Message
    }

    $row
}

$rows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportPath

Write-Host ""
Write-Host "Report gespeichert unter: $ReportPath" -ForegroundColor Green
if (Test-Path $QuarantinePath) {
    Write-Host "Quarantänepfad: $QuarantinePath" -ForegroundColor Green
}
$rows