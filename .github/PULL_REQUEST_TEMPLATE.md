**What this changes**

**Why**

**How I tested it**
- [ ] Syntax check passes on every `.ps1` (see CONTRIBUTING.md)
- [ ] Ran the affected script against a scratch `-DataDir`
- [ ] If the installer changed: tested a fresh install and an upgrade over an existing one; password, settings and history survived
- [ ] If anything visual changed: screenshot attached

**Checklist**
- [ ] Windows PowerShell 5.1 compatible (no PowerShell 7-only syntax)
- [ ] README updated if behaviour or installation changed
- [ ] Does not let the limited user change their own allowance without the admin password
