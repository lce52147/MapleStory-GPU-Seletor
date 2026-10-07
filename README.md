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
- dynamic in-.text trampoline generation without fixed offsets
- dynamic patch-plan generation
- original DLL backup and stale-patch recovery
- mapped-patched image hash verification
- immediate restoration of the original signed DLL
- cleanup watcher architecture
- local test case with NVIDIA GeForce RTX 4070 Ti + Intel UHD Graphics 770
- end-to-end validation on two different `Gr2D_DX11.dll` builds with different compiler code generation, including a system with NVIDIA GeForce RTX 5080 + AMD Radeon(TM) Graphics

The generalized "select any DXGI adapter index" backend has now passed end-to-end testing on two distinct DLL builds and two different GPU combinations. Broader compatibility across additional MapleStory regions/builds and hardware still needs more real-world testing.

## Why this exists

MapleStory may ignore normal Windows per-app GPU selection. This project works at the game's DX11 adapter-selection path instead of relying on Windows Graphics Settings.

The current build detects active physical adapters at runtime. It does not hard-code Intel, NVIDIA, AMD, a fixed LUID, a fixed GPU count, a fixed DLL hash, or fixed patch offsets.

The DLL backend now locates MapleStory's DXGI adapter-selection loop semantically at runtime. It pairs the initial and looped `EnumAdapterByGpuPreference` COM calls by their shared IID reference and forward/backward HRESULT control flow, finds executable `0xCC` padding inside the PE `.text` section, and builds a small per-run trampoline there. This avoids depending on one compiler's exact argument-setup bytes. The next enumeration call is converted to `DXGI_ERROR_NOT_FOUND`, so Maple's candidate list contains only the selected adapter.

The scanner still fails closed when it cannot uniquely identify the expected control-flow structure or a safe code cave. In that case no patch bytes are written.

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