---
name: sheet-and-settings-sizing
description: How every sheet and Settings tab in the Noodle macOS apps is sized and resized. Use whenever adding or changing a SwiftUI .sheet, a create, edit or picker sheet, a Settings tab, or anything that sets a sheet's or Settings window's frame, fixedSize or presentationSizing, in Noodle, Browser, Computer, Applet or Hub.
---

# Sheet and Settings sizing

Every window that fits its content resizes the same way: the content hides while
the window changes size, then fades back in, and the window never grows taller
than the screen; taller content scrolls. The modifiers live in `Shared/SettingsUI`.

- Every sheet ends with `.noodleSheetSizing()`, after its `.frame(width:)`.
  Never use `.fixedSize(horizontal: false, vertical: true)` or
  `.presentationSizing(.fitted)` on a sheet instead, and never resize a sheet's
  window by hand.
- Every Settings window uses `SettingsTabView`, and each tab ends with
  `.settingsContentSize(width:)` instead of `.frame(width:).fixedSize(...)`.
- A shared package that presents a sheet depends on `Shared/SettingsUI` for this.
  The one exception is `Shared/Wallpaper`, which also builds for iOS; its sheets
  have a fixed width and height and never resize.
- Create and edit windows are sheets, not new `Window` scenes or NSWindows.

Fix a sizing problem in these modifiers, for every app at once, not with a local
workaround in one sheet or tab.
