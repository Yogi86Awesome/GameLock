---
name: Bug report
about: Something does not work as the README says
title: ''
labels: bug
assignees: ''
---

**What happened**
A clear description of the problem.

**What you expected**

**Steps to reproduce**
1.
2.
3.

**Environment**
- Windows version (Settings > System > About):
- GameLock version (Releases page, or the "v" shown in the panel header):
- Launcher and game involved, if any:
- Is the limited account an Administrator or a Standard user?

**Watcher dry run**
Paste the output of this command (it changes nothing):

```
powershell -ExecutionPolicy Bypass -File C:\ProgramData\GameLock\GameLock.ps1 -Once
```

**Notifier log**
If the badge or banners are involved, paste the last lines of
`%LOCALAPPDATA%\GameLock\notifier.log`.

**Screenshots**
If it is visual, a screenshot helps.

> Found a way to bypass the lock? Please do not post it here. Use "Report a
> vulnerability" under the Security tab instead.
