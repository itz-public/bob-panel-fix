# bob-panel-fix

Diagnosis and fix for the IBM Bob desktop app on Windows opening with a **blank Bob chat
pane**: the window loads, but the chat pane is empty, Bob's menu items are greyed out and
its commands are missing from the command palette.

## The fix

In PowerShell, as the user who uses Bob (no administrator rights needed):

```powershell
irm https://ibm.biz/bob-pane-fix | iex
```

Then close every Bob window and start Bob again.

`Fix-BobPane.ps1` turns workspace trust off for that user, in Bob's `settings.json`:
`"security.workspace.trust.enabled": false`. It is safe to run more than once, and saves the
original as `settings.json.bobpanefix-backup`.

**Trade-off:** Bob no longer opens folders in Restricted Mode, so it gives no warning before
running code from a folder you open. Open only code you trust.

## Cause

The window is *untrusted* (VS Code workspace trust, which Bob is built on), and Bob's built-in
extension does not run in an untrusted window, so its chat pane never loads. Nothing is
logged. Proven on a test machine: choosing **Don't Trust** in *Workspaces: Manage Workspace
Trust* reproduces the fault exactly, and the setting above cures it with that decision still
saved. The working directory Bob starts in is not the cause: starting it from
`C:\Windows\System32` did not break it.

## Test-BobTrust.ps1

Run on a **spare test machine**, as the user who uses Bob (not as administrator), with
Bob closed for every mode except `-Check`:

```powershell
powershell -ExecutionPolicy Bypass -File .\Test-BobTrust.ps1 -Check
```

| Mode | What it does |
|---|---|
| `-Check` | Read-only. Whether Bob's extension runs in an untrusted window, the trust settings, any stored trust decision, and each Bob shortcut's "Start in". |
| `-Break 1` | Starts Bob with `C:\Windows\System32` as its working directory. |
| `-Break 2` | Starts Bob; you choose **Don't Trust** in *Workspaces: Manage Workspace Trust*. |
| `-Break 3` | Sets `"security.workspace.trust.emptyWindow": false` in Bob's `settings.json`. |
| `-Fix` | Sets `"security.workspace.trust.enabled": false`. Run it while a break is in place. |
| `-Undo` | Removes both settings. Add `-ClearWorkspaceStorage` to undo `-Break 2`. |

After each break or fix it starts Bob from the Start Menu (`-NoLaunch` skips that). Look at
the chat pane, and at the left end of the status bar: it says **Restricted Mode** when the
window is untrusted.

`-Break 2` persists across restarts until undone. The first edit to `settings.json` saves
the original as `settings.json.bobtrust-backup`.
