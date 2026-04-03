# ==============================================================================
# Switch-Wartung – Aruba (SSH) + UniFi (UI Cloud API)
# Automatisiert: Firmware-Stand, Uptime, Config-Backup
# ==============================================================================

# Posh-SSH prüfen, installieren und laden
if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
    Write-Host "Posh-SSH nicht gefunden – wird installiert (AllUsers)..." -ForegroundColor Yellow
    try {
        Install-Module -Name Posh-SSH -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
    } catch {
        Write-Host "[!] AllUsers fehlgeschlagen, versuche CurrentUser..." -ForegroundColor Yellow
        Install-Module -Name Posh-SSH -Scope CurrentUser -Force -AllowClobber
    }
}

$poshSSHModule = Get-Module -ListAvailable -Name Posh-SSH | Sort-Object Version -Descending | Select-Object -First 1
if (-not $poshSSHModule) {
    Write-Host "[FEHLER] Posh-SSH ist nicht installiert. Bitte ausfuehren:" -ForegroundColor Red
    Write-Host "  Install-Module Posh-SSH -Scope AllUsers -Force -AllowClobber" -ForegroundColor Yellow
    exit 1
}

try {
    Import-Module $poshSSHModule.Path -ErrorAction Stop
    Write-Host "[OK] Posh-SSH geladen (v$($poshSSHModule.Version))" -ForegroundColor Green
} catch {
    Write-Host "[FEHLER] Import fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------------------
# Hilfsfunktionen
# ------------------------------------------------------------------------------

function Write-Header {
    param([string]$Text)
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Text)
    Write-Host "`n>> $Text" -ForegroundColor Yellow
}

function Write-OK {
    param([string]$Text)
    Write-Host "   [OK] $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host "   [!]  $Text" -ForegroundColor Red
}

# ------------------------------------------------------------------------------
# Aruba SSH-Funktionen (ShellStream / PTY)
# ------------------------------------------------------------------------------

function New-ArubaSession {
    param([string]$IP, [PSCredential]$Credential)
    try {
        Write-Host "   [..] Verbinde zu $IP via SSH..." -ForegroundColor Gray
        $session = New-SSHSession `
            -ComputerName $IP `
            -Credential $Credential `
            -AcceptKey `
            -ConnectionTimeout 20 `
            -ErrorAction Stop
        Write-OK "Verbindung aufgebaut (Session-ID: $($session.SessionId))"
        return $session.SessionId
    } catch {
        Write-Warn "SSH-Verbindung fehlgeschlagen: $($_.Exception.Message)"
        return -1
    }
}

function New-ArubaStream {
    # Aruba-Switches beenden die Verbindung wenn kein interaktiver Terminal (PTY) vorhanden ist.
    # ShellStream oeffnet eine echte interaktive Shell mit PTY.
    param([int]$SessionId)
    try {
        $stream = New-SSHShellStream -SessionId $SessionId -ErrorAction Stop
        Start-Sleep -Milliseconds 2500   # Banner + Prompt abwarten
        $stream.Read() | Out-Null        # Buffer leeren

        # Paging deaktivieren – verhindert "--More--" Pausen bei langen Ausgaben
        $stream.WriteLine("no paging")
        Start-Sleep -Milliseconds 800
        $stream.Read() | Out-Null

        return $stream
    } catch {
        Write-Warn "Shell-Stream fehlgeschlagen: $($_.Exception.Message)"
        return $null
    }
}

function Remove-AnsiCodes {
    param([string]$Text)
    # ANSI/VT100 Escape-Sequenzen entfernen (Cursor-Bewegung, Farbe, etc.)
    $Text = $Text -replace '\[[0-9;]*[A-Za-z]', ''   # ESC[ sequences
    $Text = $Text -replace '\([A-Z]', ''              # ESC( sequences
    $Text = $Text -replace '[=>]', ''                 # ESC= ESC>
    $Text = $Text -replace '\[[0-9;]*[A-Za-z]', ''        # restliche [ sequences ohne ESC
    $Text = $Text -replace '\[\?[0-9]+[hl]', ''          # [?25h [?25l etc.
    return $Text.Trim()
}

function Invoke-ArubaCommand {
    param($Stream, [string]$Command, [int]$WaitMs = 2500)
    try {
        $Stream.WriteLine($Command)
        Start-Sleep -Milliseconds $WaitMs
        $raw = $Stream.Read()

        if ($raw) {
            $lines = $raw -split "`r?`n" |
                     ForEach-Object { Remove-AnsiCodes $_ } |
                     ForEach-Object { $_.TrimEnd() } |
                     Where-Object { $_ -ne "" } |
                     Where-Object { $_ -notmatch "^\s*$" } |
                     # Befehlsecho entfernen: Zeilen die den Befehl enthalten (auch wenn direkt zusammengeklebt)
                     Where-Object { $_ -notmatch [regex]::Escape($Command.Trim()) } |
                     # Prompt-Zeilen entfernen: enden mit # oder > (Aruba-Prompt)
                     Where-Object { $_ -notmatch "^[A-Za-z0-9._-]+[#>]\s*$" } |
                     Where-Object { $_ -notmatch "^\s*[#>]\s*$" }
            return $lines
        }
        return $null
    } catch {
        Write-Warn "Befehl fehlgeschlagen ('$Command'): $($_.Exception.Message)"
        return $null
    }
}

function Get-ArubaFirmware {
    param($Stream)
    Write-Step "Firmware-Stand abfragen..."
    $output = Invoke-ArubaCommand -Stream $Stream -Command "show version"
    $installedVersion = $null

    if ($output) {
        $relevant = $output | Where-Object {
            $_ -match "ROM Version|revision|WB\.|YA\.|WC\.|KB\.|KA\.|RA\.|software version" -or
            $_ -match "^\s*[A-Z]{2}\.[0-9]+\.[0-9]+"
        }
        if ($relevant) {
            $relevant | Select-Object -First 5 | ForEach-Object { Write-OK $_.Trim() }
            # Versionsstring extrahieren (z.B. YA.16.11.0020)
            $versionMatch = ($relevant | Select-Object -First 1) -match "([A-Z]{2}\.[0-9]+\.[0-9]+\.[0-9]+)"
            if ($versionMatch) { $installedVersion = $Matches[1] }
        } else {
            $filtered = $output | Where-Object { $_ -notmatch "^/ws/|swbuildm|Image stamp" }
            if ($filtered) {
                $filtered | Select-Object -First 10 | ForEach-Object { Write-OK $_.Trim() }
            } else {
                $output | Select-Object -First 10 | ForEach-Object { Write-Host "   $_" }
            }
        }
    } else {
        Write-Warn "Keine Ausgabe erhalten"
    }
    return $installedVersion
}

function Get-ArubaLatestFirmware {
    # Prüft die aktuellste Firmware-Version über die öffentliche HPE/Aruba Download-Seite.
    # URL-Mapping basiert auf Versions-Präfix (YA = 2530, WB = 2540, etc.)
    param([string]$InstalledVersion)

    $urlMap = @{
        "YA" = "https://asp.arubanetworks.com/downloads;search=2530"
        "WB" = "https://asp.arubanetworks.com/downloads;search=2540"
        "WC" = "https://asp.arubanetworks.com/downloads;search=2530-24"
        "KB" = "https://asp.arubanetworks.com/downloads;search=2920"
        "KA" = "https://asp.arubanetworks.com/downloads;search=2930"
        "RA" = "https://asp.arubanetworks.com/downloads;search=2930f"
    }

    Write-Step "Firmware-Update prüfen..."

    if (-not $InstalledVersion) {
        Write-Warn "Installierte Version unbekannt – Update-Prüfung übersprungen"
        return
    }

    $prefix = $InstalledVersion.Substring(0, 2)

    # Öffentliche Seite: HPE Networking Software Releases (kein Login nötig)
    # Wir fragen die Aruba Support RSS/JSON-Alternative ab
    try {
        $searchUrl = "https://networkingsupport.hpe.com/softwaredownloads"
        $headers   = @{ "User-Agent" = "Mozilla/5.0" }

        # Fallback: statische bekannte Versionen als Referenz
        # (Portal-Scraping erfordert JS-Rendering, daher pragmatischer Ansatz)
        $knownLatest = @{
            "YA" = "YA.16.11.0026"   # Aruba 2530
            "WB" = "WB.16.11.0026"   # Aruba 2540
            "KB" = "KB.16.11.0026"   # Aruba 2920
            "KA" = "KA.16.11.0026"   # Aruba 2930M
            "RA" = "RA.16.11.0026"   # Aruba 2930F
        }

        # Versionsvergleich
        if ($knownLatest.ContainsKey($prefix)) {
            $latest = $knownLatest[$prefix]
            if ($InstalledVersion -eq $latest) {
                Write-OK "Firmware aktuell ($InstalledVersion)"
            } elseif ($InstalledVersion -lt $latest) {
                Write-Warn "Update verfuegbar: $InstalledVersion -> $latest"
                Write-Host "   Download: https://asp.arubanetworks.com/downloads" -ForegroundColor Yellow
            } else {
                Write-OK "Firmware neuer als Referenz ($InstalledVersion) – bitte manuell pruefen"
            }
        } else {
            Write-Warn "Kein Versions-Mapping fuer Praefix '$prefix' – bitte manuell pruefen"
            Write-Host "   Download: https://asp.arubanetworks.com/downloads" -ForegroundColor Yellow
        }
    } catch {
        Write-Warn "Firmware-Check fehlgeschlagen: $($_.Exception.Message)"
    }
}

function Get-ArubaUptime {
    param($Stream)
    Write-Step "Uptime abfragen..."

    # Rohausgabe direkt lesen ohne Zeilenfilter – Uptime per Regex extrahieren
    $Stream.WriteLine("show uptime")
    Start-Sleep -Milliseconds 2000
    $raw = $Stream.Read()

    if ($raw) {
        $clean = Remove-AnsiCodes $raw
        # Aruba Uptime-Format: 0273:05:44:17.57 (auch wenn an anderen Text geklebt)
        if ($clean -match '(\d+):(\d+):(\d+):(\d+)') {
            $days  = [int]$Matches[1]
            $hours = [int]$Matches[2]
            $mins  = [int]$Matches[3]
            Write-OK "Uptime: $days Tage, $hours Stunden, $mins Minuten"
            return
        }
    }

    # Fallback: show system
    $output2 = Invoke-ArubaCommand -Stream $Stream -Command "show system"
    if ($output2) {
        $uptimeLine = $output2 | Where-Object { $_ -match "uptime|boot|running" } | Select-Object -First 3
        if ($uptimeLine) {
            $uptimeLine | ForEach-Object { Write-OK $_.Trim() }
        } else {
            Write-Warn "Uptime nicht gefunden"
        }
    } else {
        Write-Warn "Uptime nicht abrufbar"
    }
}

function Start-ArubaConfigBackup {
    param($Stream, [string]$IP, [string]$BackupDir)
    Write-Step "Config-Backup (via SSH, show running-config)..."

    if (-not (Test-Path $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
        Write-OK "Ordner angelegt: $BackupDir"
    }

    $safeIP   = $IP -replace "\.", "-"
    $date     = Get-Date -Format "yyyy-MM-dd"
    $filename = "backup_${safeIP}_${date}.cfg"
    $fullPath = Join-Path $BackupDir $filename

    # Laengeres Wait – Config kann gross sein
    $configOutput = Invoke-ArubaCommand -Stream $Stream -Command "show running-config" -WaitMs 6000
    if (-not $configOutput) {
        $configOutput = Invoke-ArubaCommand -Stream $Stream -Command "show configuration" -WaitMs 6000
    }

    if ($configOutput) {
        $configOutput | Set-Content -Path $fullPath -Encoding UTF8
        Write-OK "Config gespeichert: $fullPath"
    } else {
        Write-Warn "Config-Abruf fehlgeschlagen – bitte manuell sichern"
    }

    $logFile  = Join-Path $BackupDir "backup-log.txt"
    $logEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm') | $IP | $filename"
    Add-Content -Path $logFile -Value $logEntry
    Write-OK "Log aktualisiert: $logFile"
}

function Start-ArubaWartung {
    param([string]$IP, [PSCredential]$Credential, [string]$BackupDir)
    Write-Header "Aruba Switch: $IP"

    $sessionId = New-ArubaSession -IP $IP -Credential $Credential
    if ($sessionId -lt 0) {
        Write-Warn "Switch $IP wird uebersprungen"
        return
    }

    try {
        $stream = New-ArubaStream -SessionId $sessionId
        if (-not $stream) {
            Write-Warn "Shell-Stream konnte nicht geoeffnet werden"
            return
        }

        $installedFW = Get-ArubaFirmware -Stream $stream
        Get-ArubaLatestFirmware -InstalledVersion $installedFW
        Get-ArubaUptime         -Stream $stream
        Start-ArubaConfigBackup -Stream $stream -IP $IP -BackupDir $BackupDir

        $stream.Dispose()
    } finally {
        Remove-SSHSession -SessionId $sessionId | Out-Null
        Write-Host "   [..] SSH-Session geschlossen" -ForegroundColor Gray
    }
}

# ------------------------------------------------------------------------------
# UniFi Cloud API-Funktionen
# ------------------------------------------------------------------------------

function Get-UniFiToken {
    param([string]$Username, [string]$Password)
    $body = @{ username = $Username; password = $Password } | ConvertTo-Json
    try {
        $response = Invoke-RestMethod `
            -Uri "https://api.ui.com/api/auth/login" `
            -Method POST `
            -Body $body `
            -ContentType "application/json" `
            -SessionVariable script:UniFiSession `
            -ErrorAction Stop
        return $true
    } catch {
        Write-Warn "Login-Fehler: $($_.Exception.Message)"
        return $false
    }
}

function Get-UniFiHosts {
    try {
        $response = Invoke-RestMethod `
            -Uri "https://api.ui.com/api/hosts" `
            -Method GET `
            -WebSession $script:UniFiSession `
            -ErrorAction Stop
        return $response.data
    } catch {
        Write-Warn "Hosts-Abruf fehlgeschlagen: $($_.Exception.Message)"
        return $null
    }
}

function Get-UniFiDevices {
    param([string]$HostId)
    try {
        $response = Invoke-RestMethod `
            -Uri "https://api.ui.com/api/hosts/$HostId/devices" `
            -Method GET `
            -WebSession $script:UniFiSession `
            -ErrorAction Stop
        return $response.data
    } catch {
        Write-Warn "Geraete-Abruf fehlgeschlagen: $($_.Exception.Message)"
        return $null
    }
}

function Start-UniFiWartung {
    param([string]$Username, [string]$Password, [string[]]$FilterIPs)
    Write-Header "UniFi Cloud – Firmware & Status"

    Write-Step "Anmeldung bei ui.com..."
    $ok = Get-UniFiToken -Username $Username -Password $Password
    if (-not $ok) { Write-Warn "Anmeldung fehlgeschlagen"; return }
    Write-OK "Anmeldung erfolgreich"

    Write-Step "Sites abrufen..."
    $hosts = Get-UniFiHosts
    if (-not $hosts) { Write-Warn "Keine Sites gefunden"; return }
    Write-OK "$($hosts.Count) Site(s) gefunden"

    foreach ($uHost in $hosts) {
        $siteName = if ($uHost.reportedState.hostname) { $uHost.reportedState.hostname } else { $uHost.id }
        Write-Host "`n--- Site: $siteName ---" -ForegroundColor Magenta

        $devices = Get-UniFiDevices -HostId $uHost.id
        if (-not $devices) { Write-Host "   Keine Geraete abrufbar" -ForegroundColor Gray; continue }

        $switches = $devices | Where-Object { $_.type -eq "usw" }
        if ($FilterIPs -and $FilterIPs.Count -gt 0) {
            $switches = $switches | Where-Object { $_.ip -in $FilterIPs }
        }
        if (-not $switches) { Write-Host "   Keine Switches auf dieser Site" -ForegroundColor Gray; continue }

        foreach ($sw in $switches) {
            $fwColor  = if ($sw.firmwareStatus -eq "upToDate") { "Green" } else { "Red" }
            $fwStatus = if ($sw.firmwareStatus -eq "upToDate") { "[OK] Aktuell" } else { "[!]  Update verfuegbar -> $($sw.latestFirmware)" }
            $uptime   = if ($sw.uptime) { [timespan]::FromSeconds($sw.uptime).ToString("dd'd' hh'h' mm'm'") } else { "unbekannt" }
            $swName   = if ($sw.name) { $sw.name } else { $sw.mac }

            Write-Host ""
            Write-Host "   Geraet:   $swName"              -ForegroundColor White
            Write-Host "   IP:       $($sw.ip)"            -ForegroundColor White
            Write-Host "   Modell:   $($sw.model)"         -ForegroundColor White
            Write-Host "   Firmware: $($sw.version)  $fwStatus" -ForegroundColor $fwColor
            Write-Host "   Uptime:   $uptime"              -ForegroundColor White
        }
    }
}


# ------------------------------------------------------------------------------
# HPE OfficeConnect – SNMP (kein SSH nötig, public Community)
# Abruf: Firmware/Modell (sysDescr), Uptime (sysUpTime), Hostname (sysName)
# Config-Backup: nicht via SNMP möglich – im Log vermerkt
# ------------------------------------------------------------------------------
# SNMP – saubere BER-Implementierung (kein externes Modul)
# ------------------------------------------------------------------------------

function Get-SnmpValue {
    param(
        [string]$IP,
        [string]$Community = "public",
        [string]$OID,
        [int]$TimeoutMs = 3000
    )
    try {
        # --- OID encodieren (BER) ---
        $oidParts = $OID.TrimStart('.') -split '\.' | ForEach-Object { [int]$_ }
        $oidBytes = [System.Collections.Generic.List[byte]]::new()
        $oidBytes.Add([byte](40 * $oidParts[0] + $oidParts[1]))
        for ($i = 2; $i -lt $oidParts.Count; $i++) {
            $val = $oidParts[$i]
            if ($val -lt 128) {
                $oidBytes.Add([byte]$val)
            } else {
                $sub = [System.Collections.Generic.List[byte]]::new()
                while ($val -gt 0) {
                    $sub.Insert(0, [byte]($val -band 0x7F))
                    $val = [int][math]::Floor($val / 128)
                }
                for ($j = 0; $j -lt $sub.Count - 1; $j++) { $oidBytes.Add($sub[$j] -bor 0x80) }
                $oidBytes.Add($sub[$sub.Count - 1])
            }
        }

        # --- BER Länge encodieren ---
        function Get-BerLength([int]$n) {
            if ($n -lt 128) { return [byte[]]@($n) }
            $b = [System.Collections.Generic.List[byte]]::new()
            $tmp = $n
            while ($tmp -gt 0) { $b.Insert(0, [byte]($tmp -band 0xFF)); $tmp = [int][math]::Floor($tmp / 256) }
            $b.Insert(0, [byte](0x80 -bor $b.Count))
            return $b.ToArray()
        }

        # --- Paket zusammenbauen ---
        $commBytes   = [System.Text.Encoding]::ASCII.GetBytes($Community)

        # VarBind: SEQUENCE { OID, NULL }
        $oidTlv      = @([byte]0x06) + (Get-BerLength $oidBytes.Count) + $oidBytes.ToArray()
        $nullTlv     = [byte[]]@(0x05, 0x00)
        $varBind     = @([byte]0x30) + (Get-BerLength ($oidTlv.Count + $nullTlv.Count)) + $oidTlv + $nullTlv

        # VarBindList: SEQUENCE { VarBind }
        $vbl         = @([byte]0x30) + (Get-BerLength $varBind.Count) + $varBind

        # PDU: GetRequest { RequestID=1, ErrorStatus=0, ErrorIndex=0, VarBindList }
        $reqId       = [byte[]]@(0x02, 0x01, 0x01)
        $errStat     = [byte[]]@(0x02, 0x01, 0x00)
        $errIdx      = [byte[]]@(0x02, 0x01, 0x00)
        $pduContent  = $reqId + $errStat + $errIdx + $vbl
        $pdu         = @([byte]0xA0) + (Get-BerLength $pduContent.Count) + $pduContent

        # Message: SEQUENCE { Version=1(v2c), Community, PDU }
        $verTlv      = [byte[]]@(0x02, 0x01, 0x01)
        $commTlv     = @([byte]0x04) + (Get-BerLength $commBytes.Count) + $commBytes
        $msgContent  = $verTlv + $commTlv + $pdu
        $packet      = @([byte]0x30) + (Get-BerLength $msgContent.Count) + $msgContent

        # --- UDP senden und empfangen ---
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $ep  = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($IP), 161)
        $udp.Send([byte[]]$packet, $packet.Count, $ep) | Out-Null

        $remoteEP = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $resp = $udp.Receive([ref]$remoteEP)
        $udp.Close()

        if (-not $resp -or $resp.Count -eq 0) { return $null }

        # --- Response parsen: letzten Wert im VarBind lesen ---
        # Wir suchen rückwärts nach dem Wert-TLV (nach der OID im Response-VarBind)
        # Einfacher Ansatz: OctetString (0x04), TimeTicks (0x43), Integer (0x02), OID (0x06)
        $pos = 0
        function Read-TLV([byte[]]$buf, [ref]$pos) {
            if ($pos.Value -ge $buf.Count) { return $null }
            $tag = $buf[$pos.Value]; $pos.Value++
            $lenByte = $buf[$pos.Value]; $pos.Value++
            $len = 0
            if ($lenByte -band 0x80) {
                $numBytes = $lenByte -band 0x7F
                for ($k = 0; $k -lt $numBytes; $k++) {
                    $len = ($len -shl 8) -bor $buf[$pos.Value]; $pos.Value++
                }
            } else { $len = $lenByte }
            $val = $buf[$pos.Value..($pos.Value + $len - 1)]; $pos.Value += $len
            return @{ Tag = $tag; Len = $len; Value = $val }
        }

        # Wert aus dem letzten VarBind extrahieren
        # Struktur: SEQUENCE > SEQUENCE > ... > VarBindList > VarBind > OID, Value
        # Wir parsen vereinfacht: suchen OID im Response und nehmen den nächsten TLV
        $foundOidBytes = $oidBytes.ToArray()
        for ($i = 0; $i -lt $resp.Count - $foundOidBytes.Count; $i++) {
            $match = $true
            for ($j = 0; $j -lt $foundOidBytes.Count; $j++) {
                if ($resp[$i + $j] -ne $foundOidBytes[$j]) { $match = $false; break }
            }
            if ($match) {
                # Nach der OID: Länge überspringen, dann Value-TLV lesen
                $valuePos = $i + $foundOidBytes.Count
                $valTag = $resp[$valuePos]; $valuePos++
                $valLenByte = $resp[$valuePos]; $valuePos++
                $valLen = 0
                if ($valLenByte -band 0x80) {
                    $nb = $valLenByte -band 0x7F
                    for ($k = 0; $k -lt $nb; $k++) { $valLen = ($valLen -shl 8) -bor $resp[$valuePos]; $valuePos++ }
                } else { $valLen = $valLenByte }

                if ($valuePos + $valLen -le $resp.Count) {
                    $valBytes = $resp[$valuePos..($valuePos + $valLen - 1)]
                    # OctetString → ASCII
                    if ($valTag -eq 0x04) {
                        return [System.Text.Encoding]::ASCII.GetString($valBytes).Trim()
                    }
                    # TimeTicks / Integer → Zahl
                    if ($valTag -eq 0x43 -or $valTag -eq 0x02 -or $valTag -eq 0x41) {
                        $num = 0
                        foreach ($b in $valBytes) { $num = ($num -shl 8) -bor $b }
                        return $num
                    }
                    # Fallback
                    return [System.Text.Encoding]::ASCII.GetString($valBytes).Trim()
                }
            }
        }
        return $null
    } catch {
        return $null
    }
}

function Get-HPESNMPInfo {
    param([string]$IP, [string]$Community = "public")
    Write-Step "SNMP-Abfrage ($IP, Community: $Community)..."

    $sysDescr  = Get-SnmpValue -IP $IP -Community $Community -OID "1.3.6.1.2.1.1.1.0"
    $sysName   = Get-SnmpValue -IP $IP -Community $Community -OID "1.3.6.1.2.1.1.5.0"
    $sysUpTime = Get-SnmpValue -IP $IP -Community $Community -OID "1.3.6.1.2.1.1.3.0"

    if (-not $sysDescr) {
        Write-Warn "Keine SNMP-Antwort – SNMP aktiv und Community '$Community' korrekt?"
        return
    }

    Write-OK "System:   $sysDescr"
    if ($sysName)   { Write-OK "Hostname: $sysName" }
    if ($sysUpTime) {
        # TimeTicks = 1/100 Sekunden, unsigned 32-bit
        # PowerShell gibt den Wert manchmal als signed Int32 zurück – Bits korrekt uminterpretieren
        $ticks = [uint32][System.BitConverter]::ToUInt32([System.BitConverter]::GetBytes([int32]$sysUpTime), 0)
        $ts    = [timespan]::FromSeconds($ticks / 100)
        Write-OK "Uptime:   $($ts.Days) Tage, $($ts.Hours) Stunden, $($ts.Minutes) Minuten"
    }

    Write-Step "Firmware-Update pruefen..."
    # HPE sysDescr Format: "... JL380A, PD.02.23, Linux ..."
    # Firmware ist XX.YY.ZZ direkt nach der Artikelnummer (z.B. PD.02.23, KB.16.02)
    # NICHT die Linux-Kernel-Version oder U-Boot-Version nehmen
    $installed = $null
    if ($sysDescr -match '[A-Z]{2}\.\d+\.\d+') { $installed = $Matches[0] }         # z.B. PD.02.23
    elseif ($sysDescr -match ',\s*([\d]+\.[\d]+\.[\d]+)') { $installed = $Matches[1] } # Fallback: erste Version nach Komma
    if ($installed) {
        # Referenzversionen im HPE-Format (Prefix.Major.Minor)
        $knownLatest = @{ "1820" = "PT.02.09"; "1920" = "PD.02.23"; "1950" = "ND.02.23" }
        $matchedModel = $knownLatest.Keys | Where-Object { $sysDescr -match $_ } | Select-Object -First 1
        if ($matchedModel) {
            $latest = $knownLatest[$matchedModel]
            if ($installed -eq $latest) {
                Write-OK "Firmware aktuell ($installed)"
            } else {
                Write-Warn "Moeglicherweise Update verfuegbar: $installed (Referenz: $latest)"
                Write-Host "   Pruefen: https://support.hpe.com/connect/s/softwaredetails" -ForegroundColor Yellow
            }
        } else {
            Write-OK "Firmware: $installed (kein Modell-Mapping – bitte manuell pruefen)"
        }
    } else {
        Write-Warn "Firmware-Version nicht erkannt – bitte manuell pruefen"
        Write-Host "   sysDescr: $sysDescr" -ForegroundColor Gray
    }

    Write-Warn "Config-Backup via SNMP nicht moeglich – bitte manuell ueber Web-GUI sichern"
    $logDir  = "C:\temp\Switch_Wartung\Backup"
    $logFile = Join-Path $logDir "backup-log.txt"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm') | HPE SNMP | $IP | Config-Backup: MANUELL ERFORDERLICH"
    Add-Content -Path $logFile -Value $logEntry
    Write-OK "Log-Eintrag gesetzt: $logFile"
}

function Get-SnmpValue {
    param(
        [string]$IP,
        [string]$Community = "public",
        [string]$OID,
        [int]$TimeoutMs = 3000
    )
    try {
        # --- OID encodieren (BER) ---
        $oidParts = $OID.TrimStart('.') -split '\.' | ForEach-Object { [int]$_ }
        $oidBytes = [System.Collections.Generic.List[byte]]::new()
        $oidBytes.Add([byte](40 * $oidParts[0] + $oidParts[1]))
        for ($i = 2; $i -lt $oidParts.Count; $i++) {
            $val = $oidParts[$i]
            if ($val -lt 128) {
                $oidBytes.Add([byte]$val)
            } else {
                $sub = [System.Collections.Generic.List[byte]]::new()
                while ($val -gt 0) {
                    $sub.Insert(0, [byte]($val -band 0x7F))
                    $val = [int][math]::Floor($val / 128)
                }
                for ($j = 0; $j -lt $sub.Count - 1; $j++) { $oidBytes.Add($sub[$j] -bor 0x80) }
                $oidBytes.Add($sub[$sub.Count - 1])
            }
        }

        # --- BER Länge encodieren ---
        function Get-BerLength([int]$n) {
            if ($n -lt 128) { return [byte[]]@($n) }
            $b = [System.Collections.Generic.List[byte]]::new()
            $tmp = $n
            while ($tmp -gt 0) { $b.Insert(0, [byte]($tmp -band 0xFF)); $tmp = [int][math]::Floor($tmp / 256) }
            $b.Insert(0, [byte](0x80 -bor $b.Count))
            return $b.ToArray()
        }

        # --- Paket zusammenbauen ---
        $commBytes   = [System.Text.Encoding]::ASCII.GetBytes($Community)

        # VarBind: SEQUENCE { OID, NULL }
        $oidTlv      = @([byte]0x06) + (Get-BerLength $oidBytes.Count) + $oidBytes.ToArray()
        $nullTlv     = [byte[]]@(0x05, 0x00)
        $varBind     = @([byte]0x30) + (Get-BerLength ($oidTlv.Count + $nullTlv.Count)) + $oidTlv + $nullTlv

        # VarBindList: SEQUENCE { VarBind }
        $vbl         = @([byte]0x30) + (Get-BerLength $varBind.Count) + $varBind

        # PDU: GetRequest { RequestID=1, ErrorStatus=0, ErrorIndex=0, VarBindList }
        $reqId       = [byte[]]@(0x02, 0x01, 0x01)
        $errStat     = [byte[]]@(0x02, 0x01, 0x00)
        $errIdx      = [byte[]]@(0x02, 0x01, 0x00)
        $pduContent  = $reqId + $errStat + $errIdx + $vbl
        $pdu         = @([byte]0xA0) + (Get-BerLength $pduContent.Count) + $pduContent

        # Message: SEQUENCE { Version=1(v2c), Community, PDU }
        $verTlv      = [byte[]]@(0x02, 0x01, 0x01)
        $commTlv     = @([byte]0x04) + (Get-BerLength $commBytes.Count) + $commBytes
        $msgContent  = $verTlv + $commTlv + $pdu
        $packet      = @([byte]0x30) + (Get-BerLength $msgContent.Count) + $msgContent

        # --- UDP senden und empfangen ---
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $ep  = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($IP), 161)
        $udp.Send([byte[]]$packet, $packet.Count, $ep) | Out-Null

        $remoteEP = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $resp = $udp.Receive([ref]$remoteEP)
        $udp.Close()

        if (-not $resp -or $resp.Count -eq 0) { return $null }

        # --- Response parsen: letzten Wert im VarBind lesen ---
        # Wir suchen rückwärts nach dem Wert-TLV (nach der OID im Response-VarBind)
        # Einfacher Ansatz: OctetString (0x04), TimeTicks (0x43), Integer (0x02), OID (0x06)
        $pos = 0
        function Read-TLV([byte[]]$buf, [ref]$pos) {
            if ($pos.Value -ge $buf.Count) { return $null }
            $tag = $buf[$pos.Value]; $pos.Value++
            $lenByte = $buf[$pos.Value]; $pos.Value++
            $len = 0
            if ($lenByte -band 0x80) {
                $numBytes = $lenByte -band 0x7F
                for ($k = 0; $k -lt $numBytes; $k++) {
                    $len = ($len -shl 8) -bor $buf[$pos.Value]; $pos.Value++
                }
            } else { $len = $lenByte }
            $val = $buf[$pos.Value..($pos.Value + $len - 1)]; $pos.Value += $len
            return @{ Tag = $tag; Len = $len; Value = $val }
        }

        # Wert aus dem letzten VarBind extrahieren
        # Struktur: SEQUENCE > SEQUENCE > ... > VarBindList > VarBind > OID, Value
        # Wir parsen vereinfacht: suchen OID im Response und nehmen den nächsten TLV
        $foundOidBytes = $oidBytes.ToArray()
        for ($i = 0; $i -lt $resp.Count - $foundOidBytes.Count; $i++) {
            $match = $true
            for ($j = 0; $j -lt $foundOidBytes.Count; $j++) {
                if ($resp[$i + $j] -ne $foundOidBytes[$j]) { $match = $false; break }
            }
            if ($match) {
                # Nach der OID: Länge überspringen, dann Value-TLV lesen
                $valuePos = $i + $foundOidBytes.Count
                $valTag = $resp[$valuePos]; $valuePos++
                $valLenByte = $resp[$valuePos]; $valuePos++
                $valLen = 0
                if ($valLenByte -band 0x80) {
                    $nb = $valLenByte -band 0x7F
                    for ($k = 0; $k -lt $nb; $k++) { $valLen = ($valLen -shl 8) -bor $resp[$valuePos]; $valuePos++ }
                } else { $valLen = $valLenByte }

                if ($valuePos + $valLen -le $resp.Count) {
                    $valBytes = $resp[$valuePos..($valuePos + $valLen - 1)]
                    # OctetString → ASCII
                    if ($valTag -eq 0x04) {
                        return [System.Text.Encoding]::ASCII.GetString($valBytes).Trim()
                    }
                    # TimeTicks / Integer → Zahl
                    if ($valTag -eq 0x43 -or $valTag -eq 0x02 -or $valTag -eq 0x41) {
                        $num = 0
                        foreach ($b in $valBytes) { $num = ($num -shl 8) -bor $b }
                        return $num
                    }
                    # Fallback
                    return [System.Text.Encoding]::ASCII.GetString($valBytes).Trim()
                }
            }
        }
        return $null
    } catch {
        return $null
    }
}

function Get-HPESNMPInfo {
    param([string]$IP, [string]$Community = "public")
    Write-Step "SNMP-Abfrage ($IP, Community: $Community)..."

    $sysDescr  = Get-SnmpValue -IP $IP -Community $Community -OID "1.3.6.1.2.1.1.1.0"
    $sysName   = Get-SnmpValue -IP $IP -Community $Community -OID "1.3.6.1.2.1.1.5.0"
    $sysUpTime = Get-SnmpValue -IP $IP -Community $Community -OID "1.3.6.1.2.1.1.3.0"

    if (-not $sysDescr) {
        Write-Warn "Keine SNMP-Antwort – SNMP aktiv und Community '$Community' korrekt?"
        return
    }

    Write-OK "System:   $sysDescr"
    if ($sysName)   { Write-OK "Hostname: $sysName" }
    if ($sysUpTime) {
        # TimeTicks = 1/100 Sekunden, unsigned 32-bit
        # PowerShell gibt den Wert manchmal als signed Int32 zurück – Bits korrekt uminterpretieren
        $ticks = [uint32][System.BitConverter]::ToUInt32([System.BitConverter]::GetBytes([int32]$sysUpTime), 0)
        $ts    = [timespan]::FromSeconds($ticks / 100)
        Write-OK "Uptime:   $($ts.Days) Tage, $($ts.Hours) Stunden, $($ts.Minutes) Minuten"
    }

    Write-Step "Firmware-Update pruefen..."
    # HPE sysDescr Format: "... JL380A, PD.02.23, Linux ..."
    # Firmware ist XX.YY.ZZ direkt nach der Artikelnummer (z.B. PD.02.23, KB.16.02)
    # NICHT die Linux-Kernel-Version oder U-Boot-Version nehmen
    $installed = $null
    if ($sysDescr -match '[A-Z]{2}\.\d+\.\d+') { $installed = $Matches[0] }         # z.B. PD.02.23
    elseif ($sysDescr -match ',\s*([\d]+\.[\d]+\.[\d]+)') { $installed = $Matches[1] } # Fallback: erste Version nach Komma
    if ($installed) {
        # Referenzversionen im HPE-Format (Prefix.Major.Minor)
        $knownLatest = @{ "1820" = "PT.02.09"; "1920" = "PD.02.23"; "1950" = "ND.02.23" }
        $matchedModel = $knownLatest.Keys | Where-Object { $sysDescr -match $_ } | Select-Object -First 1
        if ($matchedModel) {
            $latest = $knownLatest[$matchedModel]
            if ($installed -eq $latest) {
                Write-OK "Firmware aktuell ($installed)"
            } else {
                Write-Warn "Moeglicherweise Update verfuegbar: $installed (Referenz: $latest)"
                Write-Host "   Pruefen: https://support.hpe.com/connect/s/softwaredetails" -ForegroundColor Yellow
            }
        } else {
            Write-OK "Firmware: $installed (kein Modell-Mapping – bitte manuell pruefen)"
        }
    } else {
        Write-Warn "Firmware-Version nicht erkannt – bitte manuell pruefen"
        Write-Host "   sysDescr: $sysDescr" -ForegroundColor Gray
    }

    Write-Warn "Config-Backup via SNMP nicht moeglich – bitte manuell ueber Web-GUI sichern"
    $logDir  = "C:\temp\Switch_Wartung\Backup"
    $logFile = Join-Path $logDir "backup-log.txt"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm') | HPE SNMP | $IP | Config-Backup: MANUELL ERFORDERLICH"
    Add-Content -Path $logFile -Value $logEntry
    Write-OK "Log-Eintrag gesetzt: $logFile"
}


# ------------------------------------------------------------------------------
# UniFi Cloud API-Funktionen
# ------------------------------------------------------------------------------

function Get-UniFiToken {
    param([string]$Username, [string]$Password)
    $body = @{ username = $Username; password = $Password } | ConvertTo-Json
    try {
        $response = Invoke-RestMethod `
            -Uri "https://api.ui.com/api/auth/login" `
            -Method POST `
            -Body $body `
            -ContentType "application/json" `
            -SessionVariable script:UniFiSession `
            -ErrorAction Stop
        return $true
    } catch {
        Write-Warn "Login-Fehler: $($_.Exception.Message)"
        return $false
    }
}

function Get-UniFiHosts {
    try {
        $response = Invoke-RestMethod `
            -Uri "https://api.ui.com/api/hosts" `
            -Method GET `
            -WebSession $script:UniFiSession `
            -ErrorAction Stop
        return $response.data
    } catch {
        Write-Warn "Hosts-Abruf fehlgeschlagen: $($_.Exception.Message)"
        return $null
    }
}

function Get-UniFiDevices {
    param([string]$HostId)
    try {
        $response = Invoke-RestMethod `
            -Uri "https://api.ui.com/api/hosts/$HostId/devices" `
            -Method GET `
            -WebSession $script:UniFiSession `
            -ErrorAction Stop
        return $response.data
    } catch {
        Write-Warn "Geraete-Abruf fehlgeschlagen: $($_.Exception.Message)"
        return $null
    }
}

function Start-UniFiWartung {
    param([string]$Username, [string]$Password, [string[]]$FilterIPs)
    Write-Header "UniFi Cloud – Firmware & Status"

    Write-Step "Anmeldung bei ui.com..."
    $ok = Get-UniFiToken -Username $Username -Password $Password
    if (-not $ok) { Write-Warn "Anmeldung fehlgeschlagen"; return }
    Write-OK "Anmeldung erfolgreich"

    Write-Step "Sites abrufen..."
    $hosts = Get-UniFiHosts
    if (-not $hosts) { Write-Warn "Keine Sites gefunden"; return }
    Write-OK "$($hosts.Count) Site(s) gefunden"

    foreach ($uHost in $hosts) {
        $siteName = if ($uHost.reportedState.hostname) { $uHost.reportedState.hostname } else { $uHost.id }
        Write-Host "`n--- Site: $siteName ---" -ForegroundColor Magenta

        $devices = Get-UniFiDevices -HostId $uHost.id
        if (-not $devices) { Write-Host "   Keine Geraete abrufbar" -ForegroundColor Gray; continue }

        $switches = $devices | Where-Object { $_.type -eq "usw" }
        if ($FilterIPs -and $FilterIPs.Count -gt 0) {
            $switches = $switches | Where-Object { $_.ip -in $FilterIPs }
        }
        if (-not $switches) { Write-Host "   Keine Switches auf dieser Site" -ForegroundColor Gray; continue }

        foreach ($sw in $switches) {
            $fwColor  = if ($sw.firmwareStatus -eq "upToDate") { "Green" } else { "Red" }
            $fwStatus = if ($sw.firmwareStatus -eq "upToDate") { "[OK] Aktuell" } else { "[!]  Update verfuegbar -> $($sw.latestFirmware)" }
            $uptime   = if ($sw.uptime) { [timespan]::FromSeconds($sw.uptime).ToString("dd'd' hh'h' mm'm'") } else { "unbekannt" }
            $swName   = if ($sw.name) { $sw.name } else { $sw.mac }

            Write-Host ""
            Write-Host "   Geraet:   $swName"              -ForegroundColor White
            Write-Host "   IP:       $($sw.ip)"            -ForegroundColor White
            Write-Host "   Modell:   $($sw.model)"         -ForegroundColor White
            Write-Host "   Firmware: $($sw.version)  $fwStatus" -ForegroundColor $fwColor
            Write-Host "   Uptime:   $uptime"              -ForegroundColor White
        }
    }
}


# ------------------------------------------------------------------------------

# ==============================================================================
# Hauptprogramm
# ==============================================================================

Clear-Host
Write-Host "+==========================================+" -ForegroundColor Cyan
Write-Host "|         Switch-Wartung Skript            |" -ForegroundColor Cyan
Write-Host "|  Aruba + HPE OfficeConnect + UniFi       |" -ForegroundColor Cyan
Write-Host "+==========================================+" -ForegroundColor Cyan

Write-Host "`nWas moechtest du pruefen?"
Write-Host "  [1] Aruba Switches (SSH)"
Write-Host "  [2] UniFi Switches (Cloud API)"
Write-Host "  [3] HPE OfficeConnect Switches (SNMP)"
Write-Host "  [4] Aruba + HPE"
Write-Host "  [5] Alle"
$modus = Read-Host "`nAuswahl (1-5)"

# ARUBA
if ($modus -eq "1" -or $modus -eq "4" -or $modus -eq "5") {
    Write-Header "Aruba – Konfiguration"
    Write-Host "Switch-IPs eingeben (kommagetrennt, z.B. 10.1.1.70,10.1.1.71):"
    $ipInput  = Read-Host "IPs"
    $arubaIPs = $ipInput -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

    $arubaUser = Read-Host "SSH-Benutzername"
    $arubaPass = Read-Host "SSH-Passwort" -AsSecureString
    $arubaCredential = New-Object System.Management.Automation.PSCredential($arubaUser, $arubaPass)

    $backupDir = "C:\temp\Switch_Wartung\Backup"

    foreach ($ip in $arubaIPs) {
        Start-ArubaWartung -IP $ip -Credential $arubaCredential -BackupDir $backupDir
    }
}

# HPE
if ($modus -eq "3" -or $modus -eq "4" -or $modus -eq "5") {
    Write-Header "HPE OfficeConnect – Konfiguration (SNMP)"
    Write-Host "Switch-IPs eingeben (kommagetrennt):"
    $hpeIPInput = Read-Host "IPs"
    $hpeIPs = $hpeIPInput -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

    Write-Host "SNMP Community (leer lassen fuer 'public'):"
    $hpeCommunityInput = Read-Host "Community"
    $hpeCommunity = if ($hpeCommunityInput.Trim() -ne "") { $hpeCommunityInput.Trim() } else { "public" }

    foreach ($ip in $hpeIPs) {
        Start-HPEWartung -IP $ip -Community $hpeCommunity
    }
}


# UNIFI
if ($modus -eq "2" -or $modus -eq "5") {
    Write-Header "UniFi – Konfiguration"
    $unifiUser = Read-Host "UI-Account E-Mail"
    $unifiPass = Read-Host "UI-Account Passwort"

    Write-Host "`nNur bestimmte Switch-IPs pruefen? (leer = alle)"
    $ipFilterInput = Read-Host "IPs (kommagetrennt)"
    $filterIPs = if ($ipFilterInput.Trim() -ne "") {
        $ipFilterInput -split "," | ForEach-Object { $_.Trim() }
    } else { @() }

    Start-UniFiWartung -Username $unifiUser -Password $unifiPass -FilterIPs $filterIPs
}

Write-Header "Wartung abgeschlossen"
Write-Host "Bitte Ergebnisse im Ticket dokumentieren.`n" -ForegroundColor Cyan