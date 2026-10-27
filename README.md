# OBSBOT Camera for Omarchy

An [Omarchy](https://omarchy.org) bar widget for the **OBSBOT Meet SE** webcam.
OBSBOT doesn't ship a Linux app, so this plugin puts the camera's controls in your bar.

[![GitHub](https://img.shields.io/badge/GitHub-ulfendk-181717?logo=github)](https://github.com/ulfendk)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20me%20a%20coffee-ulfendk-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/ulfendk)

## Features

- **Framing**: zoom, plus pan/tilt via a pad or sliders. Pan and tilt only move the picture when you're zoomed in, because the Meet SE has no gimbal and moves a crop of the full frame instead.
- **AI**: auto-framing (off, single person or group) and HDR.
- **Focus, exposure and white balance**: each has an auto/manual switch. Manual sliders are greyed out while the auto mode is on.
- **Image**: brightness, contrast, saturation, hue, sharpness and anti-flicker (50/60 Hz).
- **Presets**: save the current look under a name and recall it later.
- **Replug restore**: the camera forgets its settings when it loses power, so your last settings are re-applied when it's plugged back in.
- **Bar icon**: scroll to zoom, right-click to recenter. The icon dims when the camera is unplugged.
- **Keyboard** (with the panel open): arrows or `hjkl` pan and tilt, `+`/`-` zoom, and `0` recenters.

When the panel is closed, the widget only checks `/dev/v4l/by-id` for the camera and never opens it. Changing settings is safe during a call; the camera keeps streaming to Teams, Meet or Zoom.

## Install

```bash
omarchy plugin add https://github.com/ulfendk/omarchy-obsbot --enable
```

Requirements: `python3` and `v4l-utils` (`omarchy pkg add v4l-utils`). Your user needs access to `/dev/video*`, which a logged-in desktop session already has.

Update with `omarchy plugin update ulfendk.obsbot`.

### Command line

The plugin bundles the `obsbot-ctl` helper, which prints JSON for every command. To use it from a terminal or Hyprland keybinds, link it onto your `PATH`:

```bash
ln -s ~/.config/omarchy/plugins/ulfendk.obsbot/bin/obsbot-ctl ~/.local/bin/obsbot-ctl

obsbot-ctl state                                  # every control, plus AI status
obsbot-ctl set zoom_absolute=6 brightness=55
obsbot-ctl nudge zoom_absolute -1
obsbot-ctl set focus_automatic_continuous=0 focus_absolute=40
obsbot-ctl ai framing group                       # off | single | group
obsbot-ctl ai hdr on
obsbot-ctl preset save Desk && obsbot-ctl preset load Desk
obsbot-ctl reset
```

Presets are stored in `~/.config/obsbot/presets.json`.

### Widget settings

Change a setting with `omarchy-shell shell setBarWidget ulfendk.obsbot <key> '<json>' '{}'`:

| Key | Default | Meaning |
|---|---|---|
| `panStepDegrees` | `5` | how far each click on the pan/tilt pad moves |
| `restoreOnReplug` | `true` | re-apply your last settings when the camera reconnects |
| `demoFixture` | `""` | path to a saved `v4l2-ctl -L` dump; the panel then runs without a camera |

## How it works

- **Standard controls** (zoom, pan/tilt, focus, exposure, white balance, image) are plain UVC controls, set with `v4l2-ctl`. The helper switches auto modes before setting the values they unlock, keeps values within the camera's ranges, and resets only to defaults the camera actually supports.
- **AI framing and HDR** go through OBSBOT's vendor UVC extension unit (unit 2, selector 6), which takes 60-byte commands and returns a 60-byte status block:

  | | command | status byte |
  |---|---|---|
  | HDR | `01 01 <0/1>` | `0x06` |
  | Auto-framing | `16 02 <mode> <style>` (mode 0 = off, 1 = group, 2 = single) | `0x18` (mode), `0x1c` (style) |

  These offsets were mapped on a Meet SE (firmware 0x0510) by sending each command and comparing the status block before and after.

The protocol was first worked out for the OBSBOT Tiny 2 by [meet4k](https://github.com/samliddicott/meet4k), [tiny2](https://github.com/cgevans/tiny2), [Tiny4Linux](https://github.com/OpenFoxes/Tiny4Linux) and [obsbot_tiny_reversing](https://github.com/taxfromdk/obsbot_tiny_reversing). Thanks to them. This plugin is a separate implementation and contains none of their code.

Other OBSBOT UVC cameras will likely work for the standard controls. The AI controls are only verified on the Meet SE. Issues and PRs for other models are welcome.

## Development

```bash
python3 -I tests/test_obsbot_ctl.py      # offline tests; never opens a camera
omarchy plugin validate .
```

## Support

If this is useful to you, you can [buy me a coffee](https://buymeacoffee.com/ulfendk) ☕. You can also find me on [GitHub](https://github.com/ulfendk).

## License

MIT. OBSBOT is a trademark of Remo Tech Co., Ltd.; this project is not affiliated with or endorsed by OBSBOT.
