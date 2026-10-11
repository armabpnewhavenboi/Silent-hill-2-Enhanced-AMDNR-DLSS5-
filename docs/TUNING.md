# Tuning

`sh2nr.ini` sits in the game folder and is re-read while the game runs. Save the file and the change takes
effect on the next frame — no restart. Changing the structure controls or the network size restarts the
network's temporal history, which shows as one blink.

Press **F10** for split screen while tuning: left half original, right half neural. It is the fastest way
to tell whether a change is doing what you think.

## The ones worth touching

### `FsrQuality` — native / quality / balanced / performance / ultraperformance

How large the network's input is, and how much FSR 4 has to rebuild.

| Value | Network input at 1440p | Cost | Look |
|---|---|---|---|
| `native` | 1920x1080 | ~15 ms | most detail — the default |
| `quality` | 1706x960 | ~13 ms | very close, a little softer |
| `balanced` | 1506x847 | ~11 ms | noticeably softer |
| `performance` | 1280x720 | ~9 ms | for a frame-rate emergency |

The network's input ceiling is 1920x1080 regardless, so above 1080p `native` is really "give the network
everything it can take, then let FSR 4 do the rest".

### `CharacterStructure` and `SceneStructure` — 0 to 4, default 1.8 / 1.4

How strongly the network is allowed to restructure what it sees. `Character` covers faces, skin, hair and
clothes; `Scene` covers walls, floors and props. 1.0 is the network as shipped.

Characters are pushed harder than the scene on purpose — faces are what you look at, and over-reshaped
walls read as blotchy wallpaper faster than over-reshaped skin reads as wrong.

- 1.2 / 1.1 — subtle, closest to the original
- 1.8 / 1.4 — the default
- 2.2 / 1.6 — bold, and where faces start looking waxy

### `FsrReactive` — 0 to 1, default 0.7

How much FSR trusts the current frame over its own history. DirectX 8 gives no depth buffer, so FSR can't
work out on its own what moved; this tells it how much to doubt the past.

Higher means less ghosting and smearing, at the cost of some shimmer on fine detail. If you see trails
behind Harry or behind the camera pan, raise it. If the image sparkles while standing still, lower it.

### `TemporalSmoothing` — 0 to 0.8, default 0.3

Blends the network's answer with the previous frame's. Hides flicker, adds trailing. Lower it if motion
smears, raise it if still shots crawl.

### `ColorStrength` and `DetailStrength` — 0 to 1, default 0.85 / 1.0

How much of the network's change to keep. `ColorStrength` below 1 is what stops faces going saturated and
plastic — restraint reads as realism. Drop these before you drop the structure controls.

### `Mix` — 0 to 1, default 1.0

Final blend against the untouched frame. 0.85 keeps most of the effect while hiding artefacts. It is the
blunt instrument: reach for it last.

### `Upscaler` — fsr4 / fsr3 / fsr / native

`fsr4` is right on an RX 9000. `native` skips FSR entirely and composites the network's change onto the
full-resolution frame — the least ghosting of any setting, and a useful test: if `native` is clean and
`fsr4` is not, the problem is in the FSR path, not the network.

### `Passes` — 1 to 3, default 1

Network runs per frame. Each one costs a full pass (~15 ms at 1080p). Pass 2 is visibly stronger and
roughly doubles the cost; AFMF on a 30–40 fps cap makes it playable if you want to see it.

### `NetworkHeight` — 0, 720, 900, 1080

Caps the network's input height regardless of `FsrQuality`. `0` means "as high as it takes". The biggest
single performance lever, at the cost of sharpness.

## Motion vectors

`UseMotionVectors=1` needs iMMERSE Launchpad enabled and at the **top** of ReShade's list. The add-on
reads Launchpad's `MotionVectorsTex` after ReShade's effects have run, so the vectors belong to the frame
being shown.

`MotionScaleX` / `MotionScaleY` convert Launchpad's UV offsets to pixels. If you ever see smearing in one
direction only, try `-1.0` on one axis — that is a sign the sign convention is flipped.

With `UseMotionVectors=0` the network runs each frame with no history: no ghosting at all, considerably
more flicker.

## Keys and plumbing

| Setting | |
|---|---|
| `Enabled` | 1 = neural rendering on at startup |
| `ToggleKey` / `SplitKey` | [virtual-key codes](https://learn.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes); 120 = F9, 121 = F10 |
| `FrameTimeoutMs` | how long a frame waits for the network before being shown without it (120) |
| `LaunchFeeder` | 1 = the add-on starts `sh2nr_feeder.exe` itself |
| `FullNetwork` | 1 = all 71 network blocks; 0 = lmxxf's faster production schedule |
| `FsrSharpness` | 0 to 1. 0.25 by default; raise if soft, lower if haloed |

## Reading the logs

`sh2nr_feeder.log` writes a line every 600 frames:

```
frame 24000 done in 15.8 ms (network 1920x1080, temporal, passes 1, FSR, full network, character 1.80, scene 1.40)
```

Those lines are the ground truth for what your settings are actually doing. 600 frames divided by the gap
between two timestamps is your real frame rate. `sh2nr_addon.log` covers the game side: motion texture
lookup, shared texture generations, and frames that timed out.
