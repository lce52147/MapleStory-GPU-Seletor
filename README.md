# MapleStory GPU Seletor

Experimental Windows launcher that lets the user choose which physical GPU MapleStory should use before the game starts.

Normal use is intentionally simple:

1. Keep `MapleStory_GPU_Seletor.cmd` and `MapleStory_GPU_Seletor.ps1` together.
2. Double-click `MapleStory_GPU_Seletor.cmd`.
3. The launcher finds the local MapleStory installation, enumerates available physical GPUs, and asks which GPU to use.
4. It temporarily patches `Gr2D_DX11.dll`, starts `MapleStory.exe`, waits for graphics initialization, immediately restores the original signed DLL on disk, and verifies the selected GPU by LUID.

No EXE installer is required. The CMD launcher uses Windows PowerShell 5.1 (`powershell.exe`) by default, which is built into Windows 11, and falls back to PowerShell 7 (`pwsh.exe`) only when needed. It launches with `-ExecutionPolicy Bypass` for the script process.

## Status

**Test build.**

Verified so far:

- automatic MapleStory path discovery and caching
- DXGI physical-GPU enumeration
- GPU name / LUID / DXGI index mapping
- semantic DXGI call-pair discovery across multiple compiler code-generation forms
- exact adapter targeting by DXGI LUID through `IDXGIFactory4::EnumAdapterByLuid`
- dynamic patch-plan generation without fixed DLL hashes or patch offsets
- original DLL backup and stale-patch recovery
- mapped-patched image hash verification
- immediate restoration of the original signed DLL
- cleanup watcher architecture
- local test case with NVIDIA GeForce RTX 4070 Ti + Intel UHD Graphics 770
- semantic DLL discovery and launch-path validation on two different `Gr2D_DX11.dll` builds with different compiler code generation, including a system with NVIDIA GeForce RTX 5080 + AMD Radeon(TM) Graphics

The current exact-LUID backend was introduced after a non-default GPU test exposed that index-based selection could still fall back to the discrete GPU. Static / dry-run regression tests now cover both GPUs on the local NVIDIA GeForce RTX 4070 Ti + Intel UHD Graphics 770 system. Additional end-to-end testing is still required before broader compatibility is claimed.

## Why this exists

MapleStory may ignore normal Windows per-app GPU selection. This project works at the game's DX11 adapter-selection path instead of relying on Windows Graphics Settings.

The current build detects active physical adapters at runtime. It does not hard-code Intel, NVIDIA, AMD, a fixed LUID, a fixed GPU count, a fixed DLL hash, or fixed patch offsets.

The DLL backend locates MapleStory's DXGI adapter-selection loop semantically at runtime. It pairs the initial and looped `EnumAdapterByGpuPreference` COM calls by their shared IID reference and forward/backward HRESULT control flow, detects the first call's argument-setup block, and rewrites that block to call `IDXGIFactory4::EnumAdapterByLuid` with the exact LUID of the GPU selected by the user. The following preference-ordered enumeration call is converted to `DXGI_ERROR_NOT_FOUND`, leaving only the exact requested adapter in Maple's candidate list.

The scanner fails closed when it cannot uniquely identify the expected control-flow and argument-setup structure. In that case no patch bytes are written.

## MapleStory discovery

The launcher does not assume MapleStory is installed on C:, D:, or E:. It searches in this order:

1. cached path from the previous successful discovery
2. the folder containing the launcher
3. Desktop, Public Desktop, Documents, and Downloads
4. Desktop / Start Menu shortcuts
5. Windows uninstall registry entries
6. Steam libraries from `steamapps\libraryfolders.vdf`
7. common regional install layouts across every local fixed drive
8. full fixed-drive search only as a final fallback

Known layouts currently include:

- TMS: Gamania / gamania Games
- KMS: `Nexon\Maple`
- GMS: Nexon Library / Nexon Launcher layouts
- GMS Steam: `steamapps\common\MapleStory`
- MSEA: `Wizet\MapleStorySEA`

If multiple installations are found, the selection list adds a region/source hint such as `TMS`, `KMS`, `GMS/Nexon`, `Steam`, or `MSEA`.

## Files

- `MapleStory_GPU_Seletor.cmd` — user entry point
- `MapleStory_GPU_Seletor.ps1` — main implementation
- `tests/MapleStory_GPU_Seletor.Tests.ps1` — architecture / probe / dry-run regression checks

## Runtime behavior

The discovered MapleStory executable path is cached at:

`%LOCALAPPDATA%\MapleStoryGPUSeletor\config.json`

Per-launch DLL backups and cleanup logs are stored next to the game under:

`_gpu_seletor_backup\`

If a previous run left a modified `Gr2D_DX11.dll`, the launcher attempts to restore the newest verified signed backup before continuing.

The cleanup watcher is armed immediately after the original signed DLL is restored. A later GPU-verification failure therefore no longer force-closes MapleStory; the running game is left alone and the mapped patched residual is cleaned after normal game exit.

## Permissions

Before patching anything, the launcher runs a write-access preflight against both the MapleStory folder and `_gpu_seletor_backup`. It verifies that the current Windows user can create, rename, and delete temporary files and can open the existing `Gr2D_DX11.dll` for write access without changing its bytes.

If the installation is under a protected location such as `Program Files`, the current user may not have enough NTFS permissions. In that case the launcher stops before patching and reports the permission problem.

The selector does not automatically elevate itself. If elevation is required, run the selector and the external login/launcher tool at the same privilege level. A normal-user selector paired with a normal-user login tool is preferred when the game directory is already writable.

## Compatibility

Designed for Windows 10/11 systems with DXGI 1.6 / `IDXGIFactory6::EnumAdapterByGpuPreference`.

The current build does not depend on one fixed `Gr2D_DX11.dll` hash or patch offset. It discovers the expected DXGI adapter-selection control-flow structure at runtime. If a future game update changes that structure enough that it cannot be identified uniquely, the script fails closed before writing patch bytes.

## Warning

This is an experimental third-party tool that temporarily modifies a game DLL on disk during startup. The original signed DLL is restored immediately after the patched image is mapped, but no claim is made that this is accepted or safe under any game's anti-cheat or terms of service.

Use it at your own risk.

## Testing

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\MapleStory_GPU_Seletor.Tests.ps1
```

Probe only:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\MapleStory_GPU_Seletor.ps1 -Mode Probe
```

Dry-run a selected GPU index without launching the game:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\MapleStory_GPU_Seletor.ps1 -Mode DryRunPatch -GpuIndex 1
```