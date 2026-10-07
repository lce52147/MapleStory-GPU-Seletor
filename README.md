# MapleStory GPU Seletor

Experimental Windows launcher that lets the user choose which physical GPU MapleStory should use before the game starts.

Normal use is intentionally simple:

1. Keep `MapleStory_GPU_Seletor.cmd` and `MapleStory_GPU_Seletor.ps1` together.
2. Double-click `MapleStory_GPU_Seletor.cmd`.
3. The launcher finds the local MapleStory installation, enumerates available physical GPUs, and asks which GPU to use.
4. It temporarily patches `Gr2D_DX11.dll`, starts `MapleStory.exe`, waits for graphics initialization, immediately restores the original signed DLL on disk, and verifies the selected GPU by LUID.

No EXE installer is required. The CMD launcher prefers PowerShell 7 when available and falls back to Windows PowerShell with `-ExecutionPolicy Bypass`.

## Status

**Test build.**

Verified so far:

- automatic MapleStory path discovery and caching
- DXGI physical-GPU enumeration
- GPU name / LUID / DXGI index mapping
- dynamic patch-plan generation
- original DLL backup and stale-patch recovery
- mapped-patched image hash verification
- immediate restoration of the original signed DLL
- cleanup watcher architecture
- local test case with NVIDIA GeForce RTX 4070 Ti + Intel UHD Graphics 770

The generalized "select any DXGI adapter index" backend still needs additional end-to-end testing on more systems and GPU combinations.

## Why this exists

MapleStory may ignore normal Windows per-app GPU selection. This project works at the game's DX11 adapter-selection path instead of relying on Windows Graphics Settings.

The current build detects active physical adapters at runtime. It does not hard-code Intel, NVIDIA, AMD, a fixed LUID, or a fixed number of GPUs.

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

## Compatibility

Designed for Windows 10/11 systems with DXGI 1.6 / `IDXGIFactory6::EnumAdapterByGpuPreference`.

The current build expects MapleStory's `Gr2D_DX11.dll` to contain the adapter-selection signatures used by this test build. If the game updates and those signatures change, the script is designed to fail instead of blindly patching unknown bytes.

## Warning

This is an experimental third-party tool that temporarily modifies a game DLL on disk during startup. The original signed DLL is restored immediately after the patched image is mapped, but no claim is made that this is accepted or safe under any game's anti-cheat or terms of service.

Use it at your own risk.

## Testing

```powershell
pwsh -NoProfile -File .\tests\MapleStory_GPU_Seletor.Tests.ps1
```

Probe only:

```powershell
pwsh -NoProfile -File .\MapleStory_GPU_Seletor.ps1 -Mode Probe
```

Dry-run a selected GPU index without launching the game:

```powershell
pwsh -NoProfile -File .\MapleStory_GPU_Seletor.ps1 -Mode DryRunPatch -GpuIndex 1
```