# Accessibility

GameLock aims to be usable by people who rely on keyboards, screen readers,
high contrast or large text. This is where it stands today.

## Supported environments

- Windows 10 and 11, any display scaling. The admin panel is WPF and scales
  with the system DPI setting; the badge and banners scale with it too.
- Keyboard: every control on the admin panel can be reached with Tab and
  operated with Space, Enter and the arrow keys. The per-day timeline markers
  can be dragged with a mouse, but the same values are always available in
  the adjacent dropdowns, so dragging is never required.
- Screen readers: the panel uses standard WPF controls (buttons, check boxes,
  combo boxes, text boxes), which expose names and states through UI
  Automation. Labels sit next to their controls.
- Colour: status is never conveyed by colour alone. The badge and panel pair
  red, amber and green with words (LOCKED, PLAYING, OPEN) and the chart
  legend names each colour.

## Known limitations

- The on-screen badge and the warning banners are drawn, not read; a screen
  reader will not announce them. The same information is on the Dashboard of
  the admin panel, and the remaining time is in the watcher's dry-run output.
- The timeline bars on the Settings page are a visual aid only and have no
  accessible name of their own. Use the dropdowns beside them.
- The panel's dark theme is fixed; it does not follow Windows high-contrast
  themes yet.
- Text in the badge is not resizable independently of system scaling.

## Reporting barriers

Open an issue using the bug report template and mention accessibility in the
title. Say which assistive technology you use and what you expected to happen.
Barriers are treated as bugs, not as feature requests.
