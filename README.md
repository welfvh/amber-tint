# Amber Tint

Full-screen amber color filter for macOS. Uses CoreGraphics gamma tables — the same technique f.lux uses — to tint all displays warm amber. No overlay windows, no private APIs, doesn't appear in screenshots.

Single Swift file. ~250 lines.

## Install

```bash
brew install welfvh/tap/amber-tint
```

Or build from source:

```bash
./build.sh
open "Amber Tint.app"
```

## What it does

Menu bar app with a single slider:

- **~54%** — warm, round amber (candlelight)
- **~70%** — deep amber
- **100%** — embers (zero blue, for late night)

Toggle on/off from anywhere with **⌃F6**.

Handles multi-monitor, sleep/wake recovery, and display hotplug. Restores gamma on quit.

## How it works

`CGSetDisplayTransferByFormula` modifies the GPU's gamma lookup tables. Every pixel passing through the display pipeline gets its RGB channels clamped:

```
red   = 1.0                    // untouched
green = 1.0 - intensity × 0.65 // at max: 35%
blue  = 1.0 - intensity × 1.0  // at max: 0%
```

Because this happens at the GPU level, it's invisible to screenshots and screen recordings.

## Crash recovery

If the app crashes and your screen stays amber:

```bash
./reset-gamma
```

Or just reboot — macOS restores ColorSync defaults on restart.

## License

MIT
