# bob-panel-fix

Diagnosis and fix for the IBM Bob desktop app on Windows opening with a **blank Bob chat
pane**: the window loads, but the chat pane is empty, Bob's menu items are greyed out and
its commands are missing from the command palette.

## Status

**Diagnosing. No fix is published yet.** The working theory is that the window is
*untrusted* (VS Code workspace trust, which Bob is built on), so Bob's built-in extension
never loads. `Test-BobTrust.ps1` checks that theory by breaking and fixing the pane on
purpose. A one-line fix will be added here once a test proves which change works.

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
