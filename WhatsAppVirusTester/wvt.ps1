#requires -Version 5.1
<#
.SYNOPSIS
  Defensive Triage fuer die von Microsoft beschriebene WhatsApp/VBS/MSI Kampagne.
#>

[CmdletBinding()]
param(
    [string]$ProgramDataPath = "C:\ProgramData",
    [string]$LogPath = ".\wvt.log",
    [int]$LookbackDays = 30,
    [switch]$SkipEventLog,
    [switch]$SkipHashing
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "SilentlyContinue"

# ------------------------------------------------------------
# Encoding / Konsole / Logging
# ------------------------------------------------------------
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Logdatei neu anlegen
"" | Out-File -FilePath $LogPath -Encoding utf8

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Topic,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO","OK","WARN","ALERT","ERROR")][string]$Level = "INFO"
    )

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[{0}] [{1}] [{2}] {3}" -f $ts, $Level, $Topic, $Message

    $color = switch ($Level) {
        "INFO"  { "Cyan" }
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ALERT" { "Red" }
        "ERROR" { "Magenta" }
    }

    Write-Host $line -ForegroundColor $color
    $line | Out-File -FilePath $LogPath -Append -Encoding utf8
}

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)
    $line = "==== {0} ====" -f $Title
    Write-Host ""
    Write-Host $line -ForegroundColor White
    $line | Out-File -FilePath $LogPath -Append -Encoding utf8
}

# ------------------------------------------------------------
# Hilfsfunktionen
# ------------------------------------------------------------
function Test-IsAdmin {
    try {
        $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Get-FileHashSafe {
    param([Parameter(Mandatory)][string]$Path)
    try {
        return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
    }
    catch {
        return $null
    }
}

function Get-PEOriginalFileName {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        if ($null -ne $vi -and -not [string]::IsNullOrWhiteSpace($vi.OriginalFilename)) {
            return $vi.OriginalFilename.ToLower()
        }
        return $null
    }
    catch {
        return $null
    }
}

function Test-HiddenAttribute {
    param([Parameter(Mandatory)][System.IO.FileSystemInfo]$Item)
    return (($Item.Attributes -band [IO.FileAttributes]::Hidden) -ne 0)
}

function Test-SystemAttribute {
    param([Parameter(Mandatory)][System.IO.FileSystemInfo]$Item)
    return (($Item.Attributes -band [IO.FileAttributes]::System) -ne 0)
}

function Test-ReparsePoint {
    param([Parameter(Mandatory)][System.IO.FileSystemInfo]$Item)
    return (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Test-Recent {
    param([Parameter(Mandatory)][datetime]$Time)
    return $Time -ge (Get-Date).AddDays(-$LookbackDays)
}

function Search-FileText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Patterns
    )

    try {
        $content = Get-Content -Path $Path -Raw -ErrorAction Stop
        foreach ($p in $Patterns) {
            if ($content -match [regex]::Escape($p)) {
                return $true
            }
        }
        return $false
    }
    catch {
        return $false
    }
}

function Test-KnownBenignPath {
    param([Parameter(Mandatory)][string]$Path)

    $patterns = @(
        "\Package Cache\",
        "\Package Cache.unverified\",
        "\Microsoft\Windows Defender\",
        "\Microsoft\Diagnosis\",
        "\Microsoft\Windows\",
        "\Microsoft\Windows NT\",
        "\Microsoft OneDrive\",
        "\NVIDIA Corporation\",
        "\LogiOptionsPlus\",
        "\Logishrd\",
        "\Packages\",
        "\USOShared\",
        "\obs-studio-hook\"
    )

    foreach ($pattern in $patterns) {
        if ($Path -like "*$pattern*") {
            return $true
        }
    }
    return $false
}

function Test-KnownBenignHiddenDir {
    param([Parameter(Mandatory)][System.IO.DirectoryInfo]$Dir)

    $name = $Dir.Name.ToLower()

    if ($name -in @(
        "anwendungsdaten",
        "application data",
        "desktop",
        "dokumente",
        "documents",
        "templates",
        "vorlagen",
        "favorites",
        "favoriten",
        "printhood",
        "nethood",
        "sendto",
        "recent"
    )) {
        return $true
    }

    if ($name -like "start*") {
        return $true
    }

    # Standard-Windows-Kram nicht als verdaechtig melden
    if (Test-SystemAttribute $Dir) {
        return $true
    }

    if (Test-ReparsePoint $Dir) {
        return $true
    }

    return $false
}

# ------------------------------------------------------------
# IoCs / Referenzen aus Microsoft-Beitrag
# ------------------------------------------------------------
$KnownDomains = @(
    "neescil.top",
    "velthora.top",
    "bafauac.s3.ap-southeast-1.amazonaws.com",
    "yifubafu.s3.ap-southeast-1.amazonaws.com",
    "9ding.s3.ap-southeast-1.amazonaws.com",
    "f005.backblazeb2.com",
    "sinjiabo-1398259625.cos.ap-singapore.myqcloud.com"
)

$KnownHashes = @(
    "a773bf0d400986f9bcd001c84f2e1a0b614c14d9088f3ba23ddc0c75539dc9e0",
    "22b82421363026940a565d4ffbb7ce4e7798cdc5f53dda9d3229eb8ef3e0289a",
    "91ec2ede66c7b4e6d4c8a25ffad4670d5fd7ff1a2d266528548950df2a8a927a",
    "1735fcb8989c99bc8b9741f2a7dbf9ab42b7855e8e9a395c21f11450c35ebb0c",
    "5cd4280b7b5a655b611702b574b0b48cd46d7729c9bbdfa907ca0afa55971662",
    "07c6234b02017ffee2a1740c66e84d1ad2d37f214825169c30c50a0bc2904321",
    "630dfd5ab55b9f897b54c289941303eb9b0e07f58ca5e925a0fa40f12e752653",
    "df0136f1d64e61082e247ddb29585d709ac87e06136f848a5c5c84aa23e664a0",
    "1f726b67223067f6cdc9ff5f14f32c3853e7472cebe954a53134a7bae91329f0",
    "57bf1c25b7a12d28174e871574d78b4724d575952c48ca094573c19bdcbb935f",
    "5eaaf281883f01fb2062c5c102e8ff037db7111ba9585b27b3d285f416794548",
    "613ebc1e89409c909b2ff6ae21635bdfea6d4e118d67216f2c570ba537b216bd",
    "c9e3fdd90e1661c9f90735dc14679f85985df4a7d0933c53ac3c46ec170fdcfd",
    "dc3b2db1608239387a36f6e19bba6816a39c93b6aa7329340343a2ab42ccd32d",
    "a2b9e0887751c3d775adc547f6c76fea3b4a554793059c00082c1c38956badc8",
    "15a730d22f25f87a081bb2723393e6695d2aab38c0eafe9d7058e36f4f589220"
)

$SuspiciousFileNames = @(
    "auxs.vbs",
    "2009.vbs",
    "WinUpdate_KB5034231.vbs",
    "netapi.dll",
    "sc.exe"
)

$VbsPatterns = @(
    "curl.exe",
    "bitsadmin.exe",
    "netapi.dll",
    "sc.exe",
    "ProgramData",
    "https:",
    "-k",
    "-s",
    "-L",
    "-o"
)

# ------------------------------------------------------------
# Start
# ------------------------------------------------------------
Write-Section "Start"
Write-Log -Topic "System" -Level "INFO" -Message ("Triage gestartet. ProgramData='{0}' LookbackDays={1}" -f $ProgramDataPath, $LookbackDays)

$isAdmin = Test-IsAdmin
$adminLevel = if ($isAdmin) { "OK" } else { "WARN" }
$adminMessage = if ($isAdmin) {
    "Skript laeuft mit administrativen Rechten."
} else {
    "Skript laeuft NICHT als Administrator. Einige Pruefungen koennen unvollstaendig sein."
}
Write-Log -Topic "System" -Level $adminLevel -Message $adminMessage

if (-not (Test-Path $ProgramDataPath)) {
    Write-Log -Topic "System" -Level "ERROR" -Message ("Pfad nicht gefunden: {0}" -f $ProgramDataPath)
    return
}

# ------------------------------------------------------------
# 1) Versteckte Ordner in ProgramData
# ------------------------------------------------------------
Write-Section "Versteckte Ordner in ProgramData"

$hiddenDirs = Get-ChildItem -Path $ProgramDataPath -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object {
        (Test-HiddenAttribute $_) -and
        -not (Test-KnownBenignHiddenDir $_)
    }

if (-not $hiddenDirs -or $hiddenDirs.Count -eq 0) {
    Write-Log -Topic "ProgramData.HiddenDirs" -Level "OK" -Message ("Keine relevanten versteckten Ordner direkt unter {0} gefunden." -f $ProgramDataPath)
} else {
    foreach ($dir in $hiddenDirs) {
        $recentTag = if (Test-Recent $dir.CreationTime) { " [neu]" } else { "" }
        Write-Log -Topic "ProgramData.HiddenDirs" -Level "WARN" -Message ("Versteckter Ordner gefunden: {0}{1}" -f $dir.FullName, $recentTag)
    }
}

# ------------------------------------------------------------
# 2) VBS- und MSI-Funde in ProgramData
# ------------------------------------------------------------
Write-Section "VBS- und MSI-Funde in ProgramData"

$payloadFiles = Get-ChildItem -Path $ProgramDataPath -Force -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in ".vbs", ".msi" }

$payloadHits = 0

foreach ($f in $payloadFiles) {
    $isRecent = Test-Recent $f.LastWriteTime
    $isBenignPath = Test-KnownBenignPath -Path $f.FullName
    $nameHit = $SuspiciousFileNames -contains $f.Name

    if ($f.Extension -eq ".vbs") {
        $payloadHits++
        $extra = if ($nameHit) { " [Dateiname-IoC]" } else { "" }
        $recent = if ($isRecent) { " [neu]" } else { "" }
        Write-Log -Topic "ProgramData.VBS" -Level "ALERT" -Message ("VBS-Datei gefunden: {0}{1}{2}" -f $f.FullName, $extra, $recent)
        continue
    }

    if ($f.Extension -eq ".msi" -and $isRecent -and -not $isBenignPath) {
        $payloadHits++
        Write-Log -Topic "ProgramData.MSI" -Level "WARN" -Message ("Neue MSI ausserhalb bekannter Standardpfade: {0}" -f $f.FullName)
    }
}

if ($payloadHits -eq 0) {
    Write-Log -Topic "ProgramData.Payloads" -Level "OK" -Message "Keine relevanten VBS- oder MSI-Funde gefunden."
}

# ------------------------------------------------------------
# 3) Gezielte LOLBin-Umbenennungen
# ------------------------------------------------------------
Write-Section "PE-Metadaten / gezielte LOLBin-Pruefung"

$suspiciousBins = Get-ChildItem -Path $ProgramDataPath -Force -Recurse -File -Include *.exe,*.dll -ErrorAction SilentlyContinue
$binFindings = 0

foreach ($bin in $suspiciousBins) {
    if (Test-KnownBenignPath -Path $bin.FullName) {
        continue
    }

    $actualName = $bin.Name.ToLower()
    $originalName = Get-PEOriginalFileName -Path $bin.FullName

    if ([string]::IsNullOrWhiteSpace($originalName)) {
        continue
    }

    if ($actualName -eq "netapi.dll" -and $originalName -eq "curl.exe") {
        $binFindings++
        Write-Log -Topic "PE.TargetedRename" -Level "ALERT" -Message ("Verdaechtige Umbenennung: {0} -> Actual='netapi.dll' / OriginalFileName='curl.exe'" -f $bin.FullName)
        continue
    }

    if ($actualName -eq "sc.exe" -and $originalName -eq "bitsadmin.exe") {
        $binFindings++
        Write-Log -Topic "PE.TargetedRename" -Level "ALERT" -Message ("Verdaechtige Umbenennung: {0} -> Actual='sc.exe' / OriginalFileName='bitsadmin.exe'" -f $bin.FullName)
        continue
    }
}

if ($binFindings -eq 0) {
    Write-Log -Topic "PE.TargetedRename" -Level "OK" -Message "Keine gezielten Treffer fuer bekannte Rename-Muster gefunden."
}

# ------------------------------------------------------------
# 4) Hash-Abgleich
# ------------------------------------------------------------
Write-Section "Hash-Abgleich"

if ($SkipHashing) {
    Write-Log -Topic "HashCheck" -Level "INFO" -Message "Hash-Pruefung wurde uebersprungen."
} else {
    $hashTargets = Get-ChildItem -Path $ProgramDataPath -Force -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in ".vbs", ".msi", ".exe", ".dll" }

    $hashHits = 0
    foreach ($file in $hashTargets) {
        if (Test-KnownBenignPath -Path $file.FullName) {
            continue
        }

        $sha256 = Get-FileHashSafe -Path $file.FullName
        if ($sha256 -and ($KnownHashes -contains $sha256)) {
            $hashHits++
            Write-Log -Topic "HashCheck" -Level "ALERT" -Message ("Bekannter SHA256-Treffer: {0} -> {1}" -f $file.FullName, $sha256)
        }
    }

    if ($hashHits -eq 0) {
        Write-Log -Topic "HashCheck" -Level "OK" -Message "Keine bekannten SHA256-Treffer gefunden."
    }
}

# ------------------------------------------------------------
# 5) VBS-Inhaltsmuster
# ------------------------------------------------------------
Write-Section "VBS-Inhaltsmuster"

$vbsFiles = Get-ChildItem -Path $ProgramDataPath -Force -Recurse -File -Filter *.vbs -ErrorAction SilentlyContinue
$vbsFindings = 0

foreach ($vbs in $vbsFiles) {
    if (Search-FileText -Path $vbs.FullName -Patterns $VbsPatterns) {
        $vbsFindings++
        Write-Log -Topic "VBS.Content" -Level "WARN" -Message ("Verdaechtige Muster in VBS gefunden: {0}" -f $vbs.FullName)
    }
}

if ($vbsFindings -eq 0) {
    Write-Log -Topic "VBS.Content" -Level "OK" -Message "Keine verdaechtigen VBS-Inhaltsmuster unter ProgramData gefunden."
}

# ------------------------------------------------------------
# 6) UAC und Registry
# ------------------------------------------------------------
Write-Section "UAC- und Registry-Pruefung"

try {
    $uacPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    $uac = Get-ItemProperty -Path $uacPath -ErrorAction Stop

    $cpba = $uac.ConsentPromptBehaviorAdmin
    $lua  = $uac.EnableLUA

    if ($cpba -eq 0) {
        Write-Log -Topic "Registry.UAC" -Level "ALERT" -Message "ConsentPromptBehaviorAdmin = 0"
    } else {
        Write-Log -Topic "Registry.UAC" -Level "OK" -Message ("ConsentPromptBehaviorAdmin = {0}" -f $cpba)
    }

    if ($lua -eq 0) {
        Write-Log -Topic "Registry.UAC" -Level "ALERT" -Message "EnableLUA = 0"
    } else {
        Write-Log -Topic "Registry.UAC" -Level "OK" -Message ("EnableLUA = {0}" -f $lua)
    }
}
catch {
    Write-Log -Topic "Registry.UAC" -Level "ERROR" -Message "UAC-Registrywerte konnten nicht gelesen werden."
}

try {
    $weirdPath = "HKLM:\SOFTWARE\Microsoft\Win"
    if (Test-Path $weirdPath) {
        $props = (Get-ItemProperty -Path $weirdPath | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)
        $propText = if ($props) { ($props -join ", ") } else { "<keine>" }
        Write-Log -Topic "Registry.CustomPath" -Level "WARN" -Message ("Auffaelliger Pfad vorhanden: {0} ; Werte: {1}" -f $weirdPath, $propText)
    } else {
        Write-Log -Topic "Registry.CustomPath" -Level "OK" -Message ("Pfad nicht vorhanden: {0}" -f $weirdPath)
    }
}
catch {
    Write-Log -Topic "Registry.CustomPath" -Level "ERROR" -Message "Pruefung von HKLM:\SOFTWARE\Microsoft\Win fehlgeschlagen."
}

# ------------------------------------------------------------
# 7) DNS-Cache / IoC-Domains
# ------------------------------------------------------------
Write-Section "DNS-Cache / IoC-Domains"

$dnsHits = 0
try {
    $dnsCache = Get-DnsClientCache
    foreach ($d in $KnownDomains) {
        $hit = $dnsCache | Where-Object { $_.Entry -like "*$d*" }
        if ($hit) {
            $dnsHits++
            Write-Log -Topic "DNS.IoC" -Level "ALERT" -Message ("Domain im DNS-Cache gefunden: {0}" -f $d)
        }
    }

    if ($dnsHits -eq 0) {
        Write-Log -Topic "DNS.IoC" -Level "OK" -Message "Keine bekannten IoC-Domains im DNS-Cache gefunden."
    }
}
catch {
    Write-Log -Topic "DNS.IoC" -Level "WARN" -Message "DNS-Cache konnte nicht gelesen werden."
}

# ------------------------------------------------------------
# 8) Prefetch-Hinweise
# ------------------------------------------------------------
Write-Section "Prefetch-Hinweise"

$prefetchPath = "C:\Windows\Prefetch"
if (Test-Path $prefetchPath) {
    $pf = Get-ChildItem -Path $prefetchPath -Filter *.pf -ErrorAction SilentlyContinue
    $namesToCheck = @("WSCRIPT.EXE", "BITSADMIN.EXE", "CURL.EXE", "SC.EXE", "NETAPI.DLL")
    $pfHits = 0

    foreach ($name in $namesToCheck) {
        $matches = $pf | Where-Object { $_.Name -like "$name-*" }
        foreach ($m in $matches) {
            $pfHits++
            Write-Log -Topic "Prefetch" -Level "INFO" -Message ("Prefetch-Hinweis: {0}" -f $m.Name)
        }
    }

    if ($pfHits -eq 0) {
        Write-Log -Topic "Prefetch" -Level "OK" -Message "Keine relevanten Prefetch-Dateien gefunden."
    }
} else {
    Write-Log -Topic "Prefetch" -Level "WARN" -Message "Prefetch-Verzeichnis nicht verfuegbar."
}

# ------------------------------------------------------------
# 9) Eventlogs
# ------------------------------------------------------------
Write-Section "Eventlog-Pruefung"

if ($SkipEventLog) {
    Write-Log -Topic "EventLog" -Level "INFO" -Message "Eventlog-Pruefung wurde uebersprungen."
} else {
    $start = (Get-Date).AddDays(-$LookbackDays)
    $eventHits = 0

    try {
        $secEvents = Get-WinEvent -FilterHashtable @{
            LogName   = 'Security'
            Id        = 4688
            StartTime = $start
        } -MaxEvents 2000

        foreach ($evt in $secEvents) {
            $msg = $evt.Message

            if ($msg -match "wscript\.exe" -and $msg -match "\.vbs") {
                $eventHits++
                Write-Log -Topic "EventLog.4688" -Level "WARN" -Message ("4688: wscript.exe mit .vbs erkannt. Zeit={0}" -f $evt.TimeCreated)
                continue
            }

            if ($msg -match "cmd\.exe" -and $msg -match "ConsentPromptBehaviorAdmin|EnableLUA|reg add") {
                $eventHits++
                Write-Log -Topic "EventLog.4688" -Level "ALERT" -Message ("4688: moeglicher Registry-/UAC-Eingriff ueber cmd.exe. Zeit={0}" -f $evt.TimeCreated)
                continue
            }

            if ($msg -match "msiexec\.exe" -and $msg -match "ProgramData") {
                $eventHits++
                Write-Log -Topic "EventLog.4688" -Level "INFO" -Message ("4688: msiexec.exe mit ProgramData-Bezug. Zeit={0}" -f $evt.TimeCreated)
                continue
            }
        }
    }
    catch {
        Write-Log -Topic "EventLog.4688" -Level "WARN" -Message "Security-Log 4688 konnte nicht ausgewertet werden."
    }

    try {
        $psEvents = Get-WinEvent -FilterHashtable @{
            LogName   = 'Microsoft-Windows-PowerShell/Operational'
            StartTime = $start
        } -MaxEvents 1000

        foreach ($evt in $psEvents) {
            $msg = $evt.Message
            if ($msg -match "ProgramData" -and $msg -match "https:|curl|bitsadmin|Invoke-WebRequest|Start-BitsTransfer") {
                $eventHits++
                Write-Log -Topic "EventLog.PowerShell" -Level "WARN" -Message ("PowerShell-Event mit Downloader-/ProgramData-Bezug. Zeit={0}" -f $evt.TimeCreated)
            }
        }
    }
    catch {
        Write-Log -Topic "EventLog.PowerShell" -Level "WARN" -Message "PowerShell Operational Log konnte nicht ausgewertet werden."
    }

    if ($eventHits -eq 0) {
        Write-Log -Topic "EventLog" -Level "OK" -Message "Keine passenden Eventlog-Treffer gefunden."
    }
}

Write-Section "Finale Einschaetzung"

if (
    $payloadHits -eq 0 -and
    $binFindings -eq 0 -and
    $hashHits -eq 0 -and
    $vbsFindings -eq 0 -and
    $dnsHits -eq 0 -and
    $eventHits -eq 0
) {
    Write-Log -Topic "Assessment" -Level "OK" -Message "Aktuell keine belastbaren Hinweise auf die in der Microsoft-Analyse beschriebene WhatsApp/VBS/MSI-Infektionskette gefunden."
}
elseif ($hashHits -gt 0 -or $binFindings -gt 0) {
    Write-Log -Topic "Assessment" -Level "ALERT" -Message "Es gibt starke Treffer auf bekannte IoCs oder typische Umbenennungen. System sollte als verdaechtig bis kompromittiert behandelt werden."
}
else {
    Write-Log -Topic "Assessment" -Level "WARN" -Message "Es gibt einzelne Auffaelligkeiten, aber keinen eindeutigen Nachweis. Weitere manuelle Pruefung empfohlen."
}


# ------------------------------------------------------------
# Zusammenfassung
# ------------------------------------------------------------
Write-Section "Zusammenfassung"

try {
    $resolvedLog = (Resolve-Path $LogPath).Path
} catch {
    $resolvedLog = $LogPath
}

Write-Log -Topic "Summary" -Level "INFO" -Message ("Logdatei: {0}" -f $resolvedLog)
Write-Log -Topic "Summary" -Level "INFO" -Message "Pruefung abgeschlossen."