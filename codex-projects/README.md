# codex-projects

A keyboard project picker that launches Codex CLI in the current terminal.
Requires Windows PowerShell 5.1 or PowerShell 7 and `codex` on PATH.

Install from the repository root:

```powershell
.\codex-projects\Install.ps1
```

Open a new PowerShell window, anywhere, and type `codex-projects`.
To load it in an existing window, run `. $PROFILE.CurrentUserAllHosts`.
The installer adds a marked function to both Windows PowerShell and PowerShell 7
current-user, all-hosts profiles. Existing contents are preserved and backed up
when changed. It does not change your execution policy.

```text
  CODEX PROJECTS

  Preset    GPT-6.1 Terra / high

  > tether-app
    tether-app-branch
    tether-app-branch-2
    tether-content-engine

  W/S Move    A/D Preset    E Open    Esc Quit
```

- W/S or up/down arrows move through projects, wrapping at the ends.
- A/D or left/right arrows switch presets, wrapping at the ends.
- E or Enter starts a new Codex session in the highlighted folder.
- Esc or Ctrl+C exits.

Edit `projects.json` to add/reorder absolute folder paths or change presets. Display
names come from the last folder name.
Missing folders are reported when selected. On another machine, update the paths.
The first project is highlighted on each open; the last launched preset is saved
outside Git at `%LOCALAPPDATA%\codex-projects\state.json`.

The launcher passes `-C`, `-m`, and `-c model_reasoning_effort=...` directly to
Codex. Other settings come from your existing Codex configuration. Closing Codex
returns to your original PowerShell prompt and directory.

Preview without starting Codex: `codex-projects -Preview`.
Run without installing: `.\codex-projects\codex-projects.ps1`.
Remove the profile functions: `.\codex-projects\Install.ps1 -Uninstall`.
The picker is independent of the Groupy supervisor and requires no background helper.
