# Troubleshooting

Two logs in the game folder answer most questions: **`sh2nr_addon.log`** (the game side) and
**`sh2nr_feeder.log`** (the network side). `ReShade.log` covers ReShade itself. Attach all three to an
issue.

## The game crashes at startup, or closes after a few seconds

Almost always the DirectX 8 chain. Check in this order:

1. **`d3d8.dll` in the game root must be the Enhanced Edition's**, not dgVoodoo's. This is the single most
   common mistake: dgVoodoo's `D3D8.dll` goes in **`scripts\`**, never in the root. If you overwrote the
   root one, reinstall the Enhanced Edition or restore it from its own download.
2. **`d3d8.ini`** must have `d3d8to9=0` and `LoadD3d8FromScriptsFolder=1`.
3. **ReShade must be the add-on build.** A normal ReShade loads but silently ignores `sh2nr.addon32`.
   `sh2nr_addon.log` not existing at all is the tell.

## Neural rendering never starts

`sh2nr_addon.log` says which step failed.

- `LoadLibrary ... error 126` — `LmxxfNrRuntime.dll` or `.pak` is missing. Note that AMDNR's own uninstall
  removes them; re-copy from AMDNR and run `install.cmd` again.
- `motion texture 'MotionVectorsTex' ... not found` — Launchpad isn't enabled. Press Home, switch
  `MartysMods_Launchpad` on, drag it to the top.
- `no answer within 120 ms` on the first few frames is normal: the network is loading. Hundreds of them
  means the feeder died — check `sh2nr_feeder.log`.
- `feeder started` but no `feeder ready` — the feeder failed on the GPU side. Its log says why. A current
  Adrenalin driver matters here; the runtime talks to HIP through it.

## Render target creation fails, or crashes at high resolution

dgVoodoo needs enough addressable video memory. In `dgVoodoo.conf` (or `dgVoodooCpl.exe`) set
`VideoCard` memory to 4096 MB. The shipped `dgVoodoo.conf` already does this.

## Ghosting, smearing, trails

In order: raise `FsrReactive` toward 0.8, lower `TemporalSmoothing`, then try `Upscaler=native`. If
`native` is clean and `fsr4` is not, it's FSR's history and `FsrReactive` is your dial. See
[TUNING.md](TUNING.md).

## Dark screen, black patches, or strange halos with MXAO on

MXAO needs ReShade's depth buffer, and depth through dgVoodoo on a DirectX 8 game is sometimes reversed or
upside down. Press Home and untick `MartysMods_MXAO`. If you want it, ReShade's add-on tab has
*Copy depth buffer before clear* and the `RESHADE_DEPTH_INPUT_IS_REVERSED` /
`RESHADE_DEPTH_INPUT_IS_UPSIDE_DOWN` preprocessor definitions — one of the four combinations will be right.

Or run `install.cmd -NoMXAO` and skip it. It is a quality improvement, not a requirement.

## Adrenalin says frame generation can't be applied, FSR 3.1 not detected

Expected. That option drives a game's own FSR 3.1 implementation, which Silent Hill 2 does not have. Use
**AMD Fluid Motion Frames** instead, and turn that option off for `sh2pc.exe`.

## It runs but looks the same as before

Press **F10**. If the two halves are identical, nothing is reaching the network — check the logs as above.
If they differ but only slightly, raise `CharacterStructure` and `SceneStructure`, or set `Passes=2`.

## Everything is slow

`sh2nr_feeder.log` gives you the real number. If frames are 13–18 ms, that's expected and ~65 fps is
correct. If they're 25 ms or more, check `passes` is 1, and lower `FsrQuality` or `NetworkHeight`.

## Starting over

`uninstall.cmd` restores every backup and removes the added files. Add `-RemoveRuntime` and
`-RemoveReShade` to clear those too. Your saves are never touched.
