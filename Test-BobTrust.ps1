<#
.SYNOPSIS
    Breaks and fixes the IBM Bob desktop app's blank chat pane on purpose, to
    prove which cause is real before a fix is shipped. For a spare test box.

.DESCRIPTION
    The working theory is that Bob's window is UNTRUSTED,
    so VS Code's workspace trust keeps the bob-code extension from loading and
    the chat pane stays blank. This script reproduces each candidate cause, then
    applies the candidate fix against it.

      -Check       Read-only. Whether bob-code runs in untrusted windows, the
                   trust settings, the stored trust state, and each shortcut's
                   "Start in". Run this first, and on any box that is broken.
      -Break 1     Starts Bob with C:\Windows\System32 as its working directory.
                   Tests the theory that the Start Menu shortcut's directory is the cause.
      -Break 2     Starts Bob; you then choose Don't Trust by hand. Matches what
                   the broken box actually stored (isEmptyWorkspaceTrusted:false).
      -Break 3     settings.json: "security.workspace.trust.emptyWindow": false.
                   The same cause as 2, set from the settings file.
      -Fix         settings.json: "security.workspace.trust.enabled": false.
                   The candidate fix. Run it while a break is still in place.
      -Undo        Removes both settings this script adds.
      -Undo -ClearWorkspaceStorage
                   Also deletes workspaceStorage, which is what undoes -Break 2.

    Run as the user who uses Bob, not as admin. Close Bob before every mode
    except -Check. Each mode except -Check and -Undo then starts Bob so you can
    look; -NoLaunch skips that.

    -Break 2 PERSISTS: it is stored in workspaceStorage, which survives restarts
    and any reset tool that keeps that folder. Always finish with
    -Undo -ClearWorkspaceStorage.

    settings.json is edited as text, not parsed: it may hold comments, which
    Windows PowerShell's JSON parser rejects. The first edit saves a copy as
    settings.json.bobtrust-backup.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Test-BobTrust.ps1 -Check
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Test-BobTrust.ps1 -Break 3
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Test-BobTrust.ps1 -Undo -ClearWorkspaceStorage
#>
[CmdletBinding(DefaultParameterSetName = 'Check')]
param(
    [Parameter(ParameterSetName = 'Check')]
    [switch]$Check,

    [Parameter(ParameterSetName = 'Break', Mandatory)]
    [ValidateSet(1, 2, 3)]
    [int]$Break,

    [Parameter(ParameterSetName = 'Fix', Mandatory)]
    [switch]$Fix,

    [Parameter(ParameterSetName = 'Undo', Mandatory)]
    [switch]$Undo,

    [Parameter(ParameterSetName = 'Undo')]
    [switch]$ClearWorkspaceStorage,

    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'

$UserDir      = Join-Path $env:APPDATA 'IBM Bob\User'
$SettingsPath = Join-Path $UserDir 'settings.json'
$BackupPath   = "$SettingsPath.bobtrust-backup"
$WsStorage    = Join-Path $UserDir 'workspaceStorage'
$GlobalDb     = Join-Path $UserDir 'globalStorage\state.vscdb'
$StartMenuLnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\IBM Bob.lnk'
$KeyEmpty     = 'security.workspace.trust.emptyWindow'
$KeyEnabled   = 'security.workspace.trust.enabled'

function Write-Head([string]$Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Write-Note([string]$Text) { Write-Host "   $Text" }
function Write-Good([string]$Text) { Write-Host "   $Text" -ForegroundColor Green }
function Write-Bad([string]$Text)  { Write-Host "   $Text" -ForegroundColor Yellow }

# --- Finding Bob ----------------------------------------------------------
function Get-BobUninstallEntry {
    $hives = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty $hives -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'IBM Bob*' } |
        Select-Object -First 1
}

function Get-BobInstallDir {
    $default = Join-Path $env:LOCALAPPDATA 'Programs\IBM Bob'
    if (Test-Path (Join-Path $default 'IBM Bob.exe')) { return $default }
    $entry = Get-BobUninstallEntry
    if ($entry -and $entry.InstallLocation -and (Test-Path $entry.InstallLocation)) {
        return $entry.InstallLocation.TrimEnd('\')
    }
    throw "IBM Bob is not installed for this user (looked in $default and the uninstall entries)."
}

function Assert-BobClosed {
    if (Get-Process -Name 'IBM Bob' -ErrorAction SilentlyContinue) {
        throw 'IBM Bob is running. Close every Bob window, then run this again.'
    }
}

function Start-Bob {
    param([ValidateSet('StartMenu', 'System32')][string]$Via)
    if ($NoLaunch) { return }
    $exe = Join-Path (Get-BobInstallDir) 'IBM Bob.exe'
    if ($Via -eq 'System32') {
        Write-Note "Starting Bob with working directory C:\Windows\System32"
        Start-Process -FilePath $exe -WorkingDirectory "$env:SystemRoot\System32"
    } elseif (Test-Path $StartMenuLnk) {
        # Launching the .lnk itself, so its own "Start in" applies - exactly
        # what a user clicking the Start Menu gets.
        Write-Note "Starting Bob from the Start Menu shortcut"
        Start-Process -FilePath $StartMenuLnk
    } else {
        Write-Bad "No Start Menu shortcut at $StartMenuLnk; starting the exe directly"
        Start-Process -FilePath $exe
    }
    Write-Note 'Look at: the Bob chat pane (blank or not), and the left end of the status bar'
    Write-Note '(it says "Restricted Mode" when the window is untrusted).'
}

# --- settings.json, edited as text ---------------------------------------
function Read-Settings {
    if (Test-Path $SettingsPath) { return [IO.File]::ReadAllText($SettingsPath) }
    return "{`r`n}`r`n"
}

function Write-Settings([string]$Text) {
    New-Item -ItemType Directory -Force -Path $UserDir | Out-Null
    if ((Test-Path $SettingsPath) -and -not (Test-Path $BackupPath)) {
        Copy-Item $SettingsPath $BackupPath
        Write-Note "Saved the original as $BackupPath"
    }
    # No BOM. Windows PowerShell's -Encoding UTF8 would add one.
    [IO.File]::WriteAllText($SettingsPath, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Get-SettingPattern([string]$Key) { '"' + [regex]::Escape($Key) + '"\s*:\s*(true|false)' }

function Get-SettingValue([string]$Key) {
    $m = [regex]::Match((Read-Settings), (Get-SettingPattern $Key))
    if ($m.Success) { return $m.Groups[1].Value }
    return '(not set)'
}

function Set-SettingBool([string]$Key, [bool]$Value) {
    $text = Read-Settings
    $v = $Value.ToString().ToLower()
    $pattern = Get-SettingPattern $Key
    if ($text -match $pattern) {
        $new = [regex]::Replace($text, $pattern, ('"{0}": {1}' -f $Key, $v))
    } else {
        $i = $text.IndexOf('{')
        if ($i -lt 0) { throw "settings.json has no opening brace; fix it by hand: $SettingsPath" }
        $rest  = $text.Substring($i + 1)
        $comma = if ($rest -match '^\s*\}') { '' } else { ',' }
        $new = $text.Substring(0, $i + 1) + "`r`n    `"$Key`": $v$comma" + $rest
    }
    if ($new -ne $text) { Write-Settings $new }
    Write-Good "settings.json: `"$Key`": $v"
}

function Remove-Setting([string]$Key) {
    $text = Read-Settings
    $pattern = Get-SettingPattern $Key
    if ($text -notmatch $pattern) { Write-Note "settings.json: $Key was not set"; return }
    $new = [regex]::Replace($text, '(?m)^[ \t]*' + $pattern + '[ \t]*,?[ \t]*\r?\n', '')
    $new = [regex]::Replace($new, $pattern + '\s*,?', '')
    # A removed last entry can leave "x": 1,} behind.
    $new = [regex]::Replace($new, ',(\s*\})', '$1')
    Write-Settings $new
    Write-Good "settings.json: removed $Key"
}

# --- -Check helpers ------------------------------------------------------
function Read-SharedText([string]$Path) {
    # Bob may hold the database open; read it without locking it.
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::GetEncoding(28591))
        return $sr.ReadToEnd()
    } finally { $fs.Dispose() }
}

function Show-Extension {
    Write-Head 'Does bob-code run in an untrusted window?'
    $extRoot = Join-Path (Get-BobInstallDir) 'resources\app\extensions'
    $found = $false
    foreach ($dir in Get-ChildItem $extRoot -Directory -ErrorAction SilentlyContinue) {
        $pjPath = Join-Path $dir.FullName 'package.json'
        if (-not (Test-Path $pjPath)) { continue }
        try { $pj = Get-Content $pjPath -Raw | ConvertFrom-Json } catch { continue }
        if ("$($pj.name)" -notlike '*bob*') { continue }
        $found = $true
        Write-Note ("{0}.{1}  version {2}  ({3})" -f $pj.publisher, $pj.name, $pj.version, $dir.Name)
        Write-Note ("activationEvents: {0}" -f (($pj.activationEvents | ForEach-Object { "$_" }) -join ', '))
        $support = $null
        if ($pj.capabilities -and $pj.capabilities.untrustedWorkspaces) {
            $support = $pj.capabilities.untrustedWorkspaces.supported
        }
        if ($null -eq $support) {
            Write-Bad 'untrustedWorkspaces: not declared, so it is DISABLED in an untrusted window.'
            Write-Bad 'The trust theory is possible: run the -Break tests.'
        } elseif ("$support" -eq 'True') {
            Write-Good 'untrustedWorkspaces: supported. It runs untrusted, so trust is NOT the cause.'
        } else {
            Write-Bad "untrustedWorkspaces: supported = $support. Limited or no support untrusted."
        }
    }
    if (-not $found) { Write-Bad "No extension named *bob* under $extRoot" }
}

function Show-Settings {
    Write-Head "Trust settings in $SettingsPath"
    if (-not (Test-Path $SettingsPath)) { Write-Note '(no settings.json yet)' }
    Write-Note ("{0} = {1}   (false turns trust off: everything trusted)" -f $KeyEnabled, (Get-SettingValue $KeyEnabled))
    Write-Note ("{0} = {1}   (false makes no-folder windows untrusted)" -f $KeyEmpty, (Get-SettingValue $KeyEmpty))
    if (Test-Path $BackupPath) { Write-Note "Original saved at $BackupPath" }
}

function Show-StoredTrust {
    Write-Head 'Stored trust decisions'
    # Raw text search of SQLite files: a deleted row can still be in a free
    # page, so more than one value per file means "seen", not "current".
    $hits = 0
    foreach ($db in Get-ChildItem $WsStorage -Recurse -Include 'state.vscdb', 'state.vscdb-wal' -File -ErrorAction SilentlyContinue) {
        $ms = [regex]::Matches((Read-SharedText $db.FullName), '"isEmptyWorkspaceTrusted"\s*:\s*(true|false)')
        if ($ms.Count -eq 0) { continue }
        $hits++
        $vals = ($ms | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique) -join ', '
        $line = "{0}\{1}: isEmptyWorkspaceTrusted = {2}" -f $db.Directory.Name, $db.Name, $vals
        if ($vals -match 'false') { Write-Bad $line } else { Write-Note $line }
    }
    if ($hits -eq 0) { Write-Note 'No no-folder window has a stored trust decision (default: trusted).' }

    if (Test-Path $GlobalDb) {
        $text = Read-SharedText $GlobalDb
        if ($text -match '(?i)/c:/windows/system32') {
            Write-Note 'Trusted-folder list mentions C:\Windows\System32 (a trust-System32 fix was applied).'
        } else {
            Write-Note 'Trusted-folder list does not mention C:\Windows\System32.'
        }
    }
}

function Show-Shortcuts {
    Write-Head 'Shortcuts and their "Start in"'
    $sh = New-Object -ComObject WScript.Shell
    $paths = @(
        $StartMenuLnk,
        (Join-Path $env:PROGRAMDATA 'Microsoft\Windows\Start Menu\Programs\IBM Bob.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'IBM Bob.lnk'),
        (Join-Path $env:PUBLIC 'Desktop\IBM Bob.lnk')
    )
    foreach ($p in $paths) {
        if (-not (Test-Path $p)) { continue }
        $s = $sh.CreateShortcut($p)
        $wd = if ($s.WorkingDirectory) { $s.WorkingDirectory } else { '(empty)' }
        Write-Note $p
        Write-Note "    Start in: $wd"
    }
}

# --- Modes ----------------------------------------------------------------
switch ($PSCmdlet.ParameterSetName) {
    'Check' {
        $entry = Get-BobUninstallEntry
        Write-Head 'IBM Bob'
        Write-Note ("Installed: {0}  {1}" -f (Get-BobInstallDir), $(if ($entry) { $entry.DisplayVersion } else { '' }))
        if (Get-Process -Name 'IBM Bob' -ErrorAction SilentlyContinue) {
            Write-Note 'Bob is running (fine for -Check; close it before any other mode).'
        }
        Show-Extension
        Show-Settings
        Show-StoredTrust
        Show-Shortcuts
    }
    'Break' {
        Assert-BobClosed
        switch ($Break) {
            1 {
                Write-Head 'Break 1: start from System32'
                Start-Bob -Via System32
                Write-Note 'Pane blank: the starting directory matters. Pane fine: it does not.'
            }
            2 {
                Write-Head 'Break 2: distrust the no-folder window by hand'
                Start-Bob -Via StartMenu
                Write-Note 'In Bob: Ctrl+Shift+P > "Workspaces: Manage Workspace Trust" > Don''t Trust.'
                Write-Note 'Then close Bob and start it again from the Start Menu.'
                Write-Bad 'This persists until undone. Undo with: -Undo -ClearWorkspaceStorage'
            }
            3 {
                Write-Head 'Break 3: no-folder windows untrusted by setting'
                Set-SettingBool $KeyEmpty $false
                Start-Bob -Via StartMenu
            }
        }
    }
    'Fix' {
        Assert-BobClosed
        Write-Head 'Fix: turn workspace trust off'
        Set-SettingBool $KeyEnabled $false
        Start-Bob -Via StartMenu
        Write-Note 'Pane back while a -Break is still in place: the fix works against that cause.'
    }
    'Undo' {
        Assert-BobClosed
        Write-Head 'Undo'
        Remove-Setting $KeyEmpty
        Remove-Setting $KeyEnabled
        if ($ClearWorkspaceStorage) {
            if (Test-Path $WsStorage) {
                $n = @(Get-ChildItem $WsStorage -Directory).Count
                Remove-Item $WsStorage -Recurse -Force
                Write-Good "Deleted workspaceStorage ($n window/folder states). Undoes -Break 2."
            } else {
                Write-Note 'No workspaceStorage to delete.'
            }
        } else {
            Write-Note 'A -Break 2 choice is still stored; add -ClearWorkspaceStorage to remove it.'
        }
    }
}
Write-Host ''
