# Silent Hill 2 (2001) Enhanced Edition — AMD Neural Rendering

DLSS 5 style neural rendering, running on a Radeon, inside a 25-year-old 32-bit DirectX 8 game.

![status](https://img.shields.io/badge/tested-RX%209070%20XT-red) ![api](https://img.shields.io/badge/game-DirectX%208%20(32--bit)-blue) ![license](https://img.shields.io/badge/licence-GPL--3.0--or--later-green)

The neural renderer AMDNR brought to Radeon cards only works in 64-bit Direct3D 12 games. Silent Hill 2
is 32-bit DirectX 8 from 2001, so it was never a candidate. This project bridges the two: the game stays
32-bit and untouched, while a small 64-bit helper runs the network on your GPU and hands each frame back.

Faces, skin, clothing and wall materials get reconstructed detail that the original assets never had, and
AMD FSR 4 does the anti-aliasing and the lift to your display resolution.

**Measured on a 9070 XT at 1440p:** 1920x1080 network input, ~15 ms per frame, a steady ~65 fps over 37,800
logged frames.

---

## How it works

```
sh2pc.exe (32-bit, DirectX 8)
  └─ d3d8.dll            Enhanced Edition  (d3d8to9 = 0, LoadD3d8FromScriptsFolder = 1)
     └─ scripts\D3D8.dll dgVoodoo2         DirectX 8 → Direct3D 11
        └─ dxgi.dll      ReShade 6.8 (32-bit, add-on build)
           ├─ iMMERSE Launchpad            motion vectors for temporal history
           └─ sh2nr.addon32                shares the frame + motion over shared NT handles
              └─ sh2nr_feeder.exe (64-bit)
                 ├─ LmxxfNrRuntime.dll     the neural network, HIP on the GPU
                 └─ amd_fidelityfx_*.dll   FSR 4 upscale and anti-aliasing
```

The 32-bit game and the 64-bit network can't share an address space, so they share textures instead:
shared D3D11 NT-handle textures plus shared fences on one side, `OpenSharedHandleByName` in D3D12 on the
other. The add-on runs at ReShade's `finish_effects` point so the motion vectors it sends belong to the
frame being rendered, not the one before it — that detail is the difference between a clean image and a
smeared one.

## What you need

| | |
|---|---|
| **GPU** | Radeon RX 9000 (RDNA 4). Built and tested on a 9070 XT. Nothing else is supported. |
| **OS** | Windows 10 or 11, current Adrenalin driver |
| **Game** | Silent Hill 2 (2001) PC, with the [Enhanced Edition](https://enhanced.townofsilenthill.com) installed |
| **Runtime** | `LmxxfNrRuntime.dll` + `LmxxfNrRuntime.pak` from [AMDNR](https://github.com/3zwr1/AMD-NR---OptiScaler) 0.3.5.4 or newer |

### Why the runtime isn't included

The network weights are derived from NVIDIA's DLSS files and belong to NVIDIA — AMDNR's own notice says so
plainly, and the `.pak` is 500 MB besides, five times GitHub's file limit. Download AMDNR (it's free),
unzip it anywhere, and the installer will find and copy the two files for you.

## Install

1. Download this repository (green **Code** button → **Download ZIP**) and extract it anywhere.
2. Double-click **`install.cmd`**.
3. Answer at most two prompts: where AMDNR is, and the dgVoodoo2 download.

The installer finds the game, verifies the Enhanced Edition, checks your GPU, copies the runtime, installs
dgVoodoo2 and ReShade with the iMMERSE shaders, writes the config and prints a checklist of anything left
to do. Every file it changes gets a `.bak-sh2nr-<date>` copy beside it. It's safe to run again — it only
redoes what's missing.

Then start the game and press **Home**: `MartysMods_Launchpad` must be **on** and at the **top** of the
effect list. Without it there are no motion vectors and the image will shimmer.

The first frame takes a few seconds while the network loads.

| Key | |
|---|---|
| **F9** | neural rendering on / off |
| **F10** | split screen — left original, right neural |
| **Home** | ReShade menu |

To undo everything: **`uninstall.cmd`**.

## Tuning

Everything lives in `sh2nr.ini` in the game folder and **reloads while the game is running** — save the
file and the change is immediate. The shipped defaults are the ones that looked best to me.

Start here, in this order:

- **Too slow?** `FsrQuality=quality` buys back about 4 ms. `NetworkHeight=900` buys more.
- **Ghosting or smearing?** Raise `FsrReactive` toward 0.8, lower `TemporalSmoothing`.
- **Looks artificial or plastic?** Lower `CharacterStructure` and `SceneStructure` to 1.2 / 1.1, and
  `ColorStrength` to 0.8.
- **Not different enough?** Raise `CharacterStructure` to 2.0+, or set `Passes=2` (double the cost).

[docs/TUNING.md](docs/TUNING.md) explains every setting. [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
covers crashes, black screens and the logs.

## Frame generation

Use **AMD Fluid Motion Frames** (AFMF) in Adrenalin, with the game capped at 60 fps.

Leave Adrenalin's separate *FSR frame generation* option **off** — it needs the game to implement FSR 3.1
itself, which is why the overlay says "FSR 3.1 not detected". That message is expected and harmless.

## Trade-offs

- With `d3d8to9 = 0` the Enhanced Edition's DirectX 9-only extras are off: its SMAA, the brightness
  selector, and anything else marked "requires DirectX 9" in `d3d8.ini`. Everything else in EE still works.
- The network costs 13–18 ms per frame, so expect 60-ish fps, not 144.
- The network's input ceiling is 1920x1080. Above that the frame is scaled down for the network and FSR 4
  rebuilds the full resolution, which is why 1440p with `FsrQuality=native` is the sweet spot.
- Launchpad estimates motion vectors from the picture rather than reading them from the engine (DirectX 8
  has none to read), so very fast motion can still shimmer.
- The game's own film grain is turned off during install. The network reads grain as skin and wall texture
  and amplifies it.

## Building from source

`source/sh2nr-source.zip` holds the add-on and feeder sources plus the build script. It cross-compiles
from Linux or WSL with MinGW:

```bash
sudo apt install g++-mingw-w64-x86-64-posix g++-mingw-w64-i686-posix
./build.sh        # -> build/sh2nr.addon32 (32-bit), build/sh2nr_feeder.exe (64-bit)
```

One warning for anyone touching the add-on: never call a ReShade API method that returns a struct by
value. ReShade's headers are built for MSVC and MinGW returns small structs differently, so those calls
corrupt the stack and crash the game. The add-on deliberately uses native D3D11 and DXGI calls instead.

## Credits

This is glue code. Everything that makes the picture is someone else's work.

- **[AMDNR](https://github.com/3zwr1/AMD-NR---OptiScaler) by 3zwr1** — the AMD neural rendering build this
  depends on: the `LmxxfNrRuntime.dll` / `.pak` runtime, the `.pak` format, its network passes and the
  host interface in `LmxxfNrApi.h`. GPL-3.0 with AMDNR's additional terms; see `Licenses/`.
- **[lmxxf (Kien)](https://github.com/lmxxf/dlss5-on-amd-9070xt-porting)** — the network port, HIP kernels
  and runtime. MIT.
- **[dgVoodoo2](https://dege.freeweb.hu/dgVoodoo2/) by Dege** — DirectX 8 to Direct3D 11.
- **[ReShade](https://reshade.me) by crosire (Patrick Mours)** — the add-on API this plugs into. BSD-3.
- **[iMMERSE](https://github.com/martymcmodding/iMMERSE) by Pascal Gilcher (Marty McFly)** — Launchpad's
  optical flow and MXAO.
- **AMD** — FidelityFX / FSR 4.
- **The idea:** TheChadSurvivor's *TCS K1-2 DLSS 5* for KOTOR, on clshortfuse's
  [RenoDX](https://github.com/clshortfuse/renodx) DLSS 5 add-on. This is the same trick aimed at an AMD card.
- **NVIDIA** — DLSS and the network's design and weights are theirs.

Please don't open support tickets with any of those projects about this one. Issues belong
[here](../../issues).

## Licence

GPL-3.0-or-later. See [LICENSE](LICENSE), and `Licenses/` for the third-party notices that travel with the
runtime. Not affiliated with or endorsed by NVIDIA, AMD, Konami, Team Silent, or any project above.
