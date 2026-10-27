# Radial Ring Menu

A pie-menu app switcher for macOS, in the spirit of Blender's pie menus.

Hold the hotkey and your apps fan out in a ring around the cursor. Flick toward
one and let go to switch to it.

- **Hold, flick, release**: switches to the app the cursor points at. You don't
  need to reach the icon; only the direction matters.
- **Release in the middle** cancels. The menu only stays open while the hotkey
  is held.
- **Click** while holding also switches. Right click cancels.

Running apps have a dot under their icon. Picking an app that isn't running
launches it.

## Building

Needs macOS 14 or later, a Swift 6 toolchain (Xcode or the Command Line Tools)
and [just](https://github.com/casey/just).

```bash
just install
```

This builds `build/RadialRingMenu.app`, replaces `/Applications/RadialRingMenu.app`
with it and restarts the app. The app lives in the menu bar. To start it at
login, add it under System Settings → General → Login Items.

The app doesn't need Accessibility or Input Monitoring permission.

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

**Apps**: each entry needs a `name`, `bundle_id` or `path`. To find an app's
bundle ID:

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
