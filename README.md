# Radial Ring Menu

A pie-menu app switcher for macOS, in the spirit of Blender's pie menus.

Hold the hotkey and your apps fan out in a ring around the cursor. Flick toward
one and let go to switch to it.

- **Hold, flick, release**: switches to the app the cursor points at. You don't
  need to reach the icon; only the direction matters.
- **Release in the middle** cancels. The menu only stays open while the hotkey
  is held.
- **Click** while holding also switches. Right click cancels.

Picking an app that isn't running launches it. Apps show the same badge they
have in the Dock, like an unread count.

## Building

Needs macOS 14 or later, a Swift 6 toolchain (Xcode or the Command Line Tools)
and [just](https://github.com/casey/just).

```bash
just install
```

This builds `build/RadialRingMenu.app`, replaces `/Applications/RadialRingMenu.app`
with it and restarts the app. The app lives in the menu bar. To start it at
login, add it under System Settings → General → Login Items.

The app doesn't need Accessibility or Input Monitoring permission, except to
stop stray scrolling after a trackpad pick (see Configuration).

Other recipes:

- `just run`: build and run from `build/` without installing
- `just stop`: quit the running app
- `just test`: run the tests
- `just check`: validate your config and list the apps it resolves to

## Configuration

The config lives at `~/.config/radial-ring-menu/config.toml`, or under
`$XDG_CONFIG_HOME` if that's set. A default is written on first launch. Changes
are picked up when you save. The menu bar menu has *Open Config…* and
*Preview Menu*.

```toml
hotkey = "option+space"

# Distance from the cursor to the icons, and icon size, in points.
radius = 110
icon_size = 64

# Apps go clockwise, starting at 12 o'clock.
[[apps]]
name = "Safari"                  # looked up in /Applications and the system app folders

[[apps]]
bundle_id = "com.apple.Terminal" # name is optional and overrides the label

[[apps]]
path = "~/Applications/Some App.app"
name = "Some App"

[[apps]]
process = "my-app"               # a running executable that isn't an .app
icon = "~/code/my-app/icon.icns" # any entry can override its icon

[[apps]]
name = "Ghostty"
hide_cursor = true               # hide the cursor after switching to it
```

**Hotkey**: modifiers `cmd`, `shift`, `option` (or `alt`) and `ctrl`, plus one
key: `a`–`z`, `0`–`9`, `space`, `tab`, `return`, `escape`, `f1`–`f20`, arrows
(`left`, `right`, `up`, `down`) or punctuation (`` ` ``, `-`, `=`, `[`, `]`, `;`,
`'`, `,`, `.`, `/`, `\`). Letters and punctuation mean their position on a US
keyboard. Releasing any of the modifiers counts as releasing the hotkey.

A modifier can also be the whole hotkey, either side or just one:
`"option"`, `"left-option"`, `"right-cmd"`, `"left-shift"`, `"right-ctrl"` and
so on. Holding it on its own opens the menu. It stays out of the way of normal
use: pressing it while another modifier is down (like ⌘⌥Esc) doesn't open the
menu, and typing a key or adding a modifier while holding it (like ⌥E) closes
the menu without switching. A good pick is a side you rarely use for shortcuts,
like `"right-cmd"` or `"left-option"`. Left/right only works for modifiers on
their own, not in combos like `option+space`.

**Mouse button**: `mouse_button = 5` also opens the menu while that mouse button
is held, like the hotkey. Buttons count from 1: 1 is left, 2 right, 3 middle,
and 4 and 5 are usually the side buttons, but mice differ, so use *Identify
Mouse Button…* in the menu bar menu and press the button to find its number.
The button stops doing anything else, like going forward in a browser. This
needs the Accessibility permission, and catches the button at the lowest level
macOS allows, so remappers like LinearMouse don't get to change it first.

**Trackpad**: `trackpad_fingers = 3` (or 4 or 5) also opens the menu when that
many fingers rest on the trackpad. Slide them toward an app and lift to switch;
lifting without moving cancels, and adding a finger cancels too. The fingers
have to settle for a moment first, so gestures with more fingers don't flash the
menu. macOS's own gestures with the same number of fingers still fire, so move
those to another count in System Settings → Trackpad → More Gestures if they get
in the way. This reads the trackpad through Apple's private MultitouchSupport
framework, like BetterTouchTool does, since apps in the background don't get
touch events otherwise.

Unless a system gesture uses the same fingers, macOS also turns their movement
into a scroll, which would coast on into the app you just switched to. Give the
app the Accessibility permission (it asks on launch) and it drops that scroll.
Builds are signed with your Apple Development certificate when you have one, so
the permission survives rebuilds; with ad-hoc signing you'd have to grant it
again after every `just install`.

**Cursor**: after switching, the cursor moves to the middle of the app's front
window, once the app is in front. Set `move_cursor_to_window = false` to leave it
where it is. It also stays put if you move the mouse before the window shows
up, or if no window does within a couple of seconds.

Set `hide_cursor = true` on an app to hide the cursor after switching to it,
handy for a terminal where you only type. It comes back when you move the mouse
or click, when another app comes to the front, or when the menu opens. This uses
a private WindowServer setting, since apps in the background can't hide the
cursor otherwise.

**Menu bar icon**: `show_menu_bar_icon = false` hides the icon. Everything else
keeps working, and the config is still reloaded when you save it. To reach the
menu, open the app again while it's running (from Finder, Spotlight or
`open -a RadialRingMenu`): the icon comes back until the config is next
reloaded.

**Apps**: each entry needs a `name`, `bundle_id`, `path` or `process`.

`process` is for apps that aren't `.app` bundles, like a GUI app started with
`cargo run`. It matches a running process by name and switches to it, but can't
launch it, so picking it when it isn't running just beeps. These show the
generic executable icon unless you set `icon`: an app that sets its Dock icon
at runtime hands the image straight to the Dock, and nothing can read it back.

`icon` takes an image file (PNG, ICNS, PDF, ...) or an `.app` to borrow the
icon from, and works on any entry. Changes to the image file itself are picked
up the next time the config is reloaded.

To find an app's bundle ID:

```bash
osascript -e 'id of app "Safari"'
```

If there are more apps than fit around the ring, the radius grows to make room.

## Command line

```
RadialRingMenu [--config <path>] [--check] [--preview]
```

`--check` validates the config and exits. `--preview` opens the menu as soon as
the app starts.
