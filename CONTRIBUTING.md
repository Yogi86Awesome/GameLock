# Contributing to GameLock

Thanks for helping. GameLock is a small set of PowerShell scripts, so there is
no build step and no dependencies beyond Windows itself.

## Before you start

- Check the open issues first; someone may already be on it.
- For anything bigger than a bug fix, open an issue describing the change
  before writing code, so we can agree on the approach.
- Keep the core promise in mind: the person being limited should not be able
  to change their own allowance without the admin password. Changes that
  weaken that will not be merged.

## Setting up

1. Fork and clone the repository.
2. You do not need to install GameLock to work on most of it. Every script
   accepts a `-DataDir` parameter pointing at a scratch folder, so you can run
   the watcher, the panel and the notifier against test data without touching
   `C:\ProgramData\GameLock`:

   ```powershell
   # one-off dry run of the watcher against a scratch folder
   powershell -ExecutionPolicy Bypass -File .\GameLock.ps1 -Once -DataDir C:\Temp\gl

   # the admin panel against the same folder, skipping elevation
   powershell -sta -ExecutionPolicy Bypass -File .\Admin-Panel.ps1 -DataDir C:\Temp\gl
   ```

   The scratch folder needs a `config.json` and a `secret.json`; the easiest
   way to get both is to copy them from a real install, or run the installer
   once on a test machine.

## Code style

- Windows PowerShell 5.1 compatible. Do not use PowerShell 7 features; the
  scheduled tasks and the desktop shortcut run `powershell.exe`.
- Four-space indentation, Verb-Noun function names, comments that say why,
  not what.
- Keep each script self-contained. There is no shared module on purpose, so
  a user can read one file and understand it.
- Run a syntax check before committing:

  ```powershell
  Get-ChildItem *.ps1 | ForEach-Object { $t=$null;$e=$null; [Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$t,[ref]$e) | Out-Null; "$($_.Name): $($e.Count) errors" }
  ```

## Testing a change

- Watcher: `-Once -DataDir` dry runs for detection and lock logic. For timing
  behaviour (grace, counting) run the loop against a scratch folder with a
  harmless "game", for example a copy of `ping.exe` placed under a folder
  named `steamapps\common\Test`.
- Panel and notifier: run them against the scratch folder and check the
  screen. Screenshots in the pull request help a lot.
- If you touch the installer, test a fresh install and an upgrade over an
  existing install. Upgrades must keep the password, settings and history.

## Pull requests

- One change per pull request.
- Describe what changed and why, and how you tested it.
- Update the README if behaviour or installation changed.
- By contributing you agree your work is released under the MIT license.
