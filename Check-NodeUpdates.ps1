<#
.SYNOPSIS
    Weekly check for outdated global npm packages, Node.js patch and security
    releases, and an approaching end of life for the installed Node.js line.

.DESCRIPTION
    Shows a Windows toast notification only when something needs action or a
    check fails, so silence means everything is current. Every run is logged to
    %LOCALAPPDATA%\NodeUpdateCheck\check.log, including the commands to fix
    anything it finds.

    Toasts need Windows PowerShell 5.1 (powershell.exe). If launched from
    PowerShell 7, the script relaunches itself under 5.1 automatically.

.PARAMETER AlwaysNotify
    Show a toast even when everything is up to date. Use this for testing.

.EXAMPLE
    .\Check-NodeUpdates.ps1 -AlwaysNotify
#>
[CmdletBinding()]
param([switch]$AlwaysNotify)

# Relaunch under Windows PowerShell 5.1 when run from PowerShell 7, because the
# WinRT toast APIs are only available in 5.1.
if ($PSVersionTable.PSEdition -eq 'Core') {
    $winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $fwd = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($AlwaysNotify) { $fwd += '-AlwaysNotify' }
    & $winPs @fwd
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$logDir  = Join-Path $env:LOCALAPPDATA 'NodeUpdateCheck'
$logFile = Join-Path $logDir 'check.log'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

# Days before a Node.js line's end of life at which to start warning.
$EolWarningDays = 90

function Write-Log {
    param([string]$Message)
    Add-Content -Path $logFile -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
}

# Runs a native command and returns stdout as one string. stderr is discarded
# and errors are non-terminating here, because npm writes warnings to stderr
# and exits 1 whenever anything is outdated.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    (& $Exe @Arguments 2>$null) -join "`n"
}

# Invoke-RestMethod returns a string rather than objects when a server sends
# JSON as text/plain (raw.githubusercontent.com does), so parse it if needed.
function Get-Json {
    param([string]$Uri)
    $result = Invoke-RestMethod -Uri $Uri -TimeoutSec 60
    if ($result -is [string]) { $result = ConvertFrom-Json $result }
    $result
}

function Show-Toast {
    param([string]$Title, [string[]]$Body)
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    # A generic toast shows a title plus at most two body lines.
    $texts = (@($Title) + @($Body | Select-Object -First 2)) |
        ForEach-Object { '<text>{0}</text>' -f [Security.SecurityElement]::Escape($_) }
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml('<toast><visual><binding template="ToastGeneric">' + ($texts -join '') + '</binding></visual></toast>')
    # Windows PowerShell's own application ID, so no app registration is needed.
    $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
}

$issues  = @()   # short lines for the toast
$details = @()   # full lines for the log

Write-Log '--- Run started'

# 1. Global npm packages
try {
    $null = Get-Command 'npm.cmd' -ErrorAction Stop
    $json = Invoke-Native 'npm.cmd' @('outdated', '-g', '--json')
    $names = @()
    if ($json.Trim()) {
        $obj = ConvertFrom-Json $json
        if ($obj.PSObject.Properties.Name -contains 'error') {
            throw ('npm reported an error: {0}' -f $obj.error.summary)
        }
        foreach ($p in $obj.PSObject.Properties) {
            $names   += $p.Name
            $details += 'npm: {0} {1} -> {2}' -f $p.Name, $p.Value.current, $p.Value.latest
        }
    }
    if ($names.Count -gt 0) {
        $issues  += '{0} global package(s) outdated: {1}' -f $names.Count, ($names -join ', ')
        $details += 'npm fix: npm install -g ' + (($names | ForEach-Object { "$_@latest" }) -join ' ')
    }
    else {
        $details += 'npm: all global packages are current'
    }
}
catch {
    $issues += 'npm check failed: ' + $_.Exception.Message
}

# 2. Node.js patch level and end of life
try {
    $null = Get-Command 'node.exe' -ErrorAction Stop
    $current = (Invoke-Native 'node.exe' @('-v')).Trim()
    if ($current -notmatch '^v(\d+)\.') { throw "unexpected 'node -v' output: '$current'" }
    $major = $Matches[1]

    # index.json lists every release, newest first, with a security flag.
    $index = Get-Json 'https://nodejs.org/dist/index.json'
    $line  = @($index | Where-Object { $_.version -like "v$major.*" })
    $pos   = [array]::IndexOf(@($line | ForEach-Object { $_.version }), $current)

    if ($pos -gt 0) {
        $latest   = $line[0].version
        $security = @($line[0..($pos - 1)] | Where-Object { $_.security }).Count -gt 0
        $tag      = if ($security) { ' (security release)' } else { '' }
        $issues  += "Node $current -> $latest$tag"
        $details += "node: $current installed, $latest available$tag"
        $details += "node fix: install https://nodejs.org/dist/$latest/node-$latest-x64.msi"
    }
    elseif ($pos -eq 0) {
        $details += "node: $current is the latest v$major release"
    }
    else {
        $details += "node: $current not found in the official release index, patch check skipped"
    }

    # schedule.json gives start, LTS, maintenance and end dates per major line.
    $schedule = Get-Json 'https://raw.githubusercontent.com/nodejs/Release/main/schedule.json'
    $entry    = $schedule."v$major"
    if ($entry -and $entry.end) {
        $end      = [datetime]::ParseExact($entry.end, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        $daysLeft = ($end - (Get-Date)).Days
        if ($daysLeft -lt 0) {
            $issues += "Node v$major is past end of life (ended $($entry.end))"
        }
        elseif ($daysLeft -le $EolWarningDays) {
            $issues += "Node v$major reaches end of life on $($entry.end) ($daysLeft days)"
        }
        else {
            $details += "node: v$major supported until $($entry.end)"
        }
    }
}
catch {
    $issues += 'Node check failed: ' + $_.Exception.Message
}

# 3. Log and notify
foreach ($d in $details) { Write-Log $d }
foreach ($i in $issues)  { Write-Log "ACTION: $i" }

try {
    if ($issues.Count -gt 0) {
        $body = if ($issues.Count -gt 2) {
            @($issues[0], ('+{0} more. Details in {1}' -f ($issues.Count - 1), $logFile))
        }
        else { $issues }
        Show-Toast -Title 'Node and npm updates needed' -Body $body
    }
    elseif ($AlwaysNotify) {
        Show-Toast -Title 'Node and npm check' -Body @('Everything is up to date.', "Log: $logFile")
    }
}
catch {
    Write-Log ('Toast failed: ' + $_.Exception.Message)
}

Write-Log '--- Run finished'
exit 0
