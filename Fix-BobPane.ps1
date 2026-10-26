<#
.SYNOPSIS
    Fixes the IBM Bob desktop app opening with a blank Bob chat pane, in
    Restricted Mode. Run it in PowerShell as the user who uses Bob:

        irm https://ibm.biz/bob-pane-fix | iex

.DESCRIPTION
    Cause: the Bob window is untrusted (VS Code workspace trust, which Bob is
    built on). Bob's built-in extension does not run in an untrusted window, so
    its chat pane never loads, and nothing is logged. Proven on a test machine
    with Test-BobTrust.ps1: choosing Don't Trust reproduces the fault exactly,
    and this setting cures it with that decision still saved.

    Fix: turns workspace trust off for this user, in Bob's settings.json:

        "security.workspace.trust.enabled": false

    Trade-off: Bob no longer opens folders in Restricted Mode, so it gives no
    warning before running code from a folder you open. Open only code you
    trust.

    Per user, no administrator rights. Safe to run more than once. The original
    settings.json is saved beside it as settings.json.bobpanefix-backup.

    Written for `irm | iex`: it takes no parameters, keeps its variables out of
    your session, and never closes your PowerShell window on an error.
#>
& {
    $appDir   = Join-Path $env:APPDATA 'IBM Bob'
    $userDir  = Join-Path $appDir 'User'
    $settings = Join-Path $userDir 'settings.json'
    $backup   = "$settings.bobpanefix-backup"
    $key      = 'security.workspace.trust.enabled'
    $pattern  = '"' + [regex]::Escape($key) + '"\s*:\s*(true|false)'

    try {
        if (-not (Test-Path $appDir)) {
            Write-Host "IBM Bob has not been started as this user yet ($appDir is missing)." -ForegroundColor Yellow
            Write-Host 'Start Bob once, close it, then run this again.'
            return
        }

        # settings.json is edited as text, not parsed: it may hold comments,
        # which Windows PowerShell's JSON parser rejects.
        $text = if (Test-Path $settings) { [IO.File]::ReadAllText($settings) } else { "{`r`n}`r`n" }

        $m = [regex]::Match($text, $pattern)
        if ($m.Success -and $m.Groups[1].Value -eq 'false') {
            Write-Host 'Already fixed: workspace trust is off for IBM Bob.' -ForegroundColor Green
        } else {
            if ($m.Success) {
                $new = [regex]::Replace($text, $pattern, ('"{0}": false' -f $key))
            } else {
                $i = $text.IndexOf('{')
                if ($i -lt 0) {
                    Write-Host "Could not fix: $settings is not a settings file (no opening brace)." -ForegroundColor Red
                    Write-Host "Add this line inside its braces by hand:  `"$key`": false,"
                    return
                }
                $rest  = $text.Substring($i + 1)
                $comma = if ($rest -match '^\s*\}') { '' } else { ',' }
                $new = $text.Substring(0, $i + 1) + "`r`n    `"$key`": false$comma" + $rest
            }

            New-Item -ItemType Directory -Force -Path $userDir | Out-Null
            if ((Test-Path $settings) -and -not (Test-Path $backup)) {
                Copy-Item $settings $backup
                Write-Host "Saved the original settings as $backup"
            }
            # No BOM. Windows PowerShell's -Encoding UTF8 would add one.
            [IO.File]::WriteAllText($settings, $new, (New-Object Text.UTF8Encoding($false)))

            $check = [regex]::Match([IO.File]::ReadAllText($settings), $pattern)
            if (-not ($check.Success -and $check.Groups[1].Value -eq 'false')) {
                Write-Host "Could not fix: the setting did not stick in $settings" -ForegroundColor Red
                return
            }
            Write-Host 'Fixed: workspace trust is now off for IBM Bob.' -ForegroundColor Green
        }

        if (Get-Process -Name 'IBM Bob' -ErrorAction SilentlyContinue) {
            Write-Host 'Close every IBM Bob window, then start Bob again. The chat pane will be back.'
        } else {
            Write-Host 'Start IBM Bob. The chat pane will be back.'
        }
    } catch {
        Write-Host "Could not fix: $($_.Exception.Message)" -ForegroundColor Red
    }
}
