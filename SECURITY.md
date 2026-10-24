# Security Policy

GameLock's whole purpose is to be hard to bypass for the person being limited,
so bypasses are treated as security issues.

## Supported versions

Only the latest release is supported. Fixes are published as new releases,
not backported.

## What counts as a vulnerability

- A way for a Standard (non-administrator) Windows user to add time, raise
  the limit, stop the watcher, or edit the data folder without the admin
  password.
- A way to keep playing past the limit that the watcher does not detect, for a
  game launched through a supported launcher.
- The admin password hash being readable by non-administrators, or being
  weaker than described in the README.
- Anything that makes the scripts do something other than what the README
  says, for example contacting the network.

Things that are **not** vulnerabilities, because the README states them as
limits:

- An administrator account undoing the lock. The lock is friction for admins,
  not a wall.
- Physical-access attacks such as booting from a USB stick.
- Games that do not run through a supported launcher and are not listed in
  `extraProcesses`.

## Reporting

Please do not open a public issue for a bypass. Use GitHub's private
vulnerability reporting on this repository ("Report a vulnerability" under the
Security tab). Include the Windows version, which launcher and game, and the
exact steps.

You will get an acknowledgement within a week. If the report is confirmed, a
fix will be released and you will be credited in the release notes unless you
prefer not to be.
