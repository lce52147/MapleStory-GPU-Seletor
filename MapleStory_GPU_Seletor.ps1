param(
    [ValidateSet('Select','Probe','DryRunPatch','Launch','Cleanup')]
    [string]$Mode = 'Launch',

    [int]$GpuIndex = 0,

    [int]$TargetPid,
    [long]$StartTicks,
    [string]$Backup,
    [string]$Target,
    [string]$MappedPatched,
    [string]$CleanupExpectedHash,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

$AppName = 'MapleStoryGPUSeletor'
$StateRoot = Join-Path $env:LOCALAPPDATA $AppName
$ConfigPath = Join-Path $StateRoot 'config.json'
$LogRoot = Join-Path $StateRoot 'logs'
$TempRoot = Join-Path $StateRoot 'temp'

function Ensure-StateDirectories {
    foreach ($dir in @($StateRoot,$LogRoot,$TempRoot)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
}

function Hash([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Read-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return $null
    }
    try {
        Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $null
    }
}

function Save-Config([string]$MapleStoryPath) {
    Ensure-StateDirectories
    [pscustomobject]@{
        MapleStoryPath = $MapleStoryPath
        UpdatedAt = (Get-Date).ToString('o')
    } |
        ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

function Get-ShortcutTargets {
    $roots = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        [Environment]::GetFolderPath('StartMenu'),
        [Environment]::GetFolderPath('CommonStartMenu')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

    $targets = [System.Collections.Generic.List[string]]::new()
    try {
        $shell = New-Object -ComObject WScript.Shell
        foreach ($root in $roots) {
            Get-ChildItem -LiteralPath $root -Filter '*.lnk' -File -Recurse -ErrorAction SilentlyContinue |
                ForEach-Object {
                    try {
                        $target = $shell.CreateShortcut($_.FullName).TargetPath
                        if ($target -and ([IO.Path]::GetFileName($target) -ieq 'MapleStory.exe')) {
                            $targets.Add($target)
                        }
                    }
                    catch {}
                }
        }
    }
    catch {}

    @($targets | Select-Object -Unique)
}

function Get-RegistryMapleCandidates {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $out = [System.Collections.Generic.List[string]]::new()

    foreach ($key in $keys) {
        Get-ItemProperty $key -ErrorAction SilentlyContinue |
            Where-Object {
                ($_.DisplayName -match 'MapleStory') -or
                ($_.InstallLocation -match 'MapleStory') -or
                ($_.DisplayIcon -match 'MapleStory')
            } |
            ForEach-Object {
                if ($_.InstallLocation) {
                    $out.Add((Join-Path ([string]$_.InstallLocation) 'MapleStory.exe'))
                }
                if ($_.DisplayIcon) {
                    $icon = ([string]$_.DisplayIcon).Split(',')[0].Trim('"')
                    if ([IO.Path]::GetFileName($icon) -ieq 'MapleStory.exe') {
                        $out.Add($icon)
                    }
                }
            }
    }

    @($out | Select-Object -Unique)
}

function Get-UserSearchRoots {
    $roots = [System.Collections.Generic.List[string]]::new()

    foreach ($folder in @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        [Environment]::GetFolderPath('MyDocuments')
    )) {
        if ($folder -and (Test-Path -LiteralPath $folder -PathType Container)) {
            $roots.Add($folder)
        }
    }

    try {
        $shellFolders = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop
        $downloads = [Environment]::ExpandEnvironmentVariables(
            [string]$shellFolders.'{374DE290-123F-4565-9164-39C4925E467B}'
        )
        if ($downloads -and (Test-Path -LiteralPath $downloads -PathType Container)) {
            $roots.Add($downloads)
        }
    }
    catch {
        $downloads = Join-Path $env:USERPROFILE 'Downloads'
        if (Test-Path -LiteralPath $downloads -PathType Container) {
            $roots.Add($downloads)
        }
    }

    @($roots | Select-Object -Unique)
}

function Get-UserFolderMapleCandidates {
    $found = [System.Collections.Generic.List[string]]::new()

    foreach ($root in @(Get-UserSearchRoots)) {
        try {
            Get-ChildItem -LiteralPath $root -Filter 'MapleStory.exe' -File -Recurse -ErrorAction SilentlyContinue |
                ForEach-Object { $found.Add($_.FullName) }
        }
        catch {}
    }

    @($found | Select-Object -Unique)
}

function Get-SteamLibraryRoots {
    $roots = [System.Collections.Generic.List[string]]::new()
    $steamPaths = [System.Collections.Generic.List[string]]::new()

    foreach ($key in @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )) {
        try {
            $p = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            foreach ($value in @($p.SteamPath,$p.InstallPath)) {
                if ($value -and (Test-Path -LiteralPath $value -PathType Container)) {
                    $steamPaths.Add([string]$value)
                }
            }
        }
        catch {}
    }

    foreach ($steamRoot in @($steamPaths | Select-Object -Unique)) {
        $roots.Add($steamRoot)
        $vdf = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        if (-not (Test-Path -LiteralPath $vdf -PathType Leaf)) {
            continue
        }

        try {
            $raw = Get-Content -LiteralPath $vdf -Raw -ErrorAction Stop
            foreach ($m in [regex]::Matches($raw,'"path"\s+"([^"]+)"')) {
                $path = $m.Groups[1].Value -replace '\\\\','\'
                if ($path -and (Test-Path -LiteralPath $path -PathType Container)) {
                    $roots.Add($path)
                }
            }
        }
        catch {}
    }

    @($roots | Select-Object -Unique)
}

function Get-SteamMapleCandidates {
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($root in @(Get-SteamLibraryRoots)) {
        $out.Add((Join-Path $root 'steamapps\common\MapleStory\MapleStory.exe'))
    }
    @($out | Select-Object -Unique)
}

function Get-MapleInstallLabel([string]$Path) {
    if ($Path -match '(?i)\\gamania(?: Games)?\\MapleStory\\') {
        return 'TMS'
    }
    if ($Path -match '(?i)\\Nexon\\Maple\\') {
        return 'KMS'
    }
    if ($Path -match '(?i)\\Nexon\\Library\\maplestory\\') {
        return 'GMS/Nexon'
    }
    if ($Path -match '(?i)\\steamapps\\common\\MapleStory\\') {
        return 'Steam'
    }
    if ($Path -match '(?i)\\Wizet\\MapleStorySEA\\') {
        return 'MSEA'
    }
    return 'MapleStory'
}

function Get-FastMapleCandidates {
    $out = [System.Collections.Generic.List[string]]::new()

    if ($PSScriptRoot) {
        $out.Add((Join-Path $PSScriptRoot 'MapleStory.exe'))
    }

    foreach ($p in @(Get-UserFolderMapleCandidates)) {
        $out.Add($p)
    }

    foreach ($p in @(Get-ShortcutTargets)) {
        $out.Add($p)
    }

    foreach ($p in @(Get-RegistryMapleCandidates)) {
        $out.Add($p)
    }

    foreach ($p in @(Get-SteamMapleCandidates)) {
        $out.Add($p)
    }

    $drives = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty DeviceID

    $knownRelativePaths = @(
        # Taiwan MapleStory (TMS)
        'Program Files\gamania Games\MapleStory\MapleStory.exe',
        'Program Files (x86)\gamania Games\MapleStory\MapleStory.exe',
        'Program Files\Gamania\MapleStory\MapleStory.exe',
        'Program Files (x86)\Gamania\MapleStory\MapleStory.exe',
        'Gamania\MapleStory\MapleStory.exe',

        # Korea MapleStory (KMS)
        'Nexon\Maple\MapleStory.exe',

        # Global MapleStory (GMS / Nexon Launcher)
        'Nexon\Library\maplestory\MapleStory.exe',
        'Nexon\Library\maplestory\appdata\MapleStory.exe',
        'Program Files (x86)\Nexon\maplestory\appdata\MapleStory.exe',

        # MapleStorySEA (MSEA)
        'Program Files (x86)\Wizet\MapleStorySEA\MapleStory.exe',
        'Program Files\Wizet\MapleStorySEA\MapleStory.exe',
        'Wizet\MapleStorySEA\MapleStory.exe',

        # Generic/manual layouts
        'Games\MapleStory\MapleStory.exe',
        'MapleStory\MapleStory.exe',
        'Program Files\MapleStory\MapleStory.exe',
        'Program Files (x86)\MapleStory\MapleStory.exe'
    )

    foreach ($drive in $drives) {
        foreach ($relative in $knownRelativePaths) {
            $out.Add((Join-Path ($drive + '\') $relative))
        }
    }

    @(
        $out |
            Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
            ForEach-Object { (Resolve-Path -LiteralPath $_).Path } |
            Select-Object -Unique
    )
}

function Find-MapleStoryOnLocalDrives {
    $found = [System.Collections.Generic.List[string]]::new()
    $drives = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty DeviceID

    foreach ($drive in $drives) {
        try {
            Get-ChildItem -LiteralPath ($drive + '\') -Filter 'MapleStory.exe' -File -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $found.Add($_.FullName) }
        }
        catch {}
    }

    @($found | Select-Object -Unique)
}

function Resolve-MapleStoryPath {
    $config = Read-Config
    if ($config -and $config.MapleStoryPath -and (Test-Path -LiteralPath $config.MapleStoryPath -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $config.MapleStoryPath).Path
    }

    $candidates = @(Get-FastMapleCandidates)
    if ($candidates.Count -eq 0) {
        $candidates = @(Find-MapleStoryOnLocalDrives)
    }

    if ($candidates.Count -eq 0) {
        throw 'MapleStory.exe was not found on local fixed drives.'
    }

    if ($candidates.Count -eq 1) {
        Save-Config -MapleStoryPath $candidates[0]
        return $candidates[0]
    }

    if ($Mode -in @('Probe','DryRunPatch')) {
        return $candidates[0]
    }

    Write-Host ''
    Write-Host 'Multiple MapleStory installations found:' -ForegroundColor Cyan
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $label = Get-MapleInstallLabel -Path $candidates[$i]
        Write-Host ('[{0}] [{1}] {2}' -f ($i + 1),$label,$candidates[$i])
    }

    while ($true) {
        $raw = Read-Host ('Select MapleStory installation [1-{0}]' -f $candidates.Count)
        $index = 0
        if ([int]::TryParse($raw,[ref]$index) -and $index -ge 1 -and $index -le $candidates.Count) {
            $selected = $candidates[$index - 1]
            Save-Config -MapleStoryPath $selected
            return $selected
        }
    }
}

function Initialize-DxgiProbe {
    if ('MapleStoryGpuSeletor.DxgiProbe' -as [type]) {
        return
    }

    $source = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace MapleStoryGpuSeletor
{
    [StructLayout(LayoutKind.Sequential)]
    public struct Luid
    {
        public uint LowPart;
        public int HighPart;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct AdapterDesc1
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string Description;
        public uint VendorId;
        public uint DeviceId;
        public uint SubSysId;
        public uint Revision;
        public UIntPtr DedicatedVideoMemory;
        public UIntPtr DedicatedSystemMemory;
        public UIntPtr SharedSystemMemory;
        public Luid AdapterLuid;
        public uint Flags;
    }

    public sealed class AdapterRecord
    {
        public int DxgiIndex { get; set; }
        public string Name { get; set; }
        public string Luid { get; set; }
        public ulong AdapterLuid { get; set; }
        public uint VendorId { get; set; }
        public uint DeviceId { get; set; }
        public uint SubSysId { get; set; }
        public ulong DedicatedVideoMemory { get; set; }
        public ulong SharedSystemMemory { get; set; }
    }

    public static class DxgiProbe
    {
        private const int DXGI_ERROR_NOT_FOUND = unchecked((int)0x887A0002);
        private const uint DXGI_ADAPTER_FLAG_SOFTWARE = 2;

        private static readonly Guid IID_IDXGIFactory6 =
            new Guid("C1B6694F-FF09-44A9-B03C-77900A0A1D17");
        private static readonly Guid IID_IDXGIAdapter1 =
            new Guid("29038F61-3839-4626-91FD-086879011A05");

        [DllImport("dxgi.dll")]
        private static extern int CreateDXGIFactory2(
            uint Flags,
            ref Guid riid,
            out IntPtr ppFactory);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int EnumAdapterByGpuPreferenceDelegate(
            IntPtr self,
            uint Adapter,
            int GpuPreference,
            ref Guid riid,
            out IntPtr ppvAdapter);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int GetDesc1Delegate(
            IntPtr self,
            out AdapterDesc1 desc);

        private static IntPtr GetVtableSlot(IntPtr instance, int slot)
        {
            IntPtr vtable = Marshal.ReadIntPtr(instance);
            return Marshal.ReadIntPtr(vtable, slot * IntPtr.Size);
        }

        private static string LuidString(Luid value)
        {
            return string.Format(
                "luid_0x{0:X8}_0x{1:X8}",
                unchecked((uint)value.HighPart),
                value.LowPart);
        }

        private static ulong LuidRaw(Luid value)
        {
            return ((ulong)unchecked((uint)value.HighPart) << 32) | value.LowPart;
        }

        public static AdapterRecord[] EnumerateUnspecified()
        {
            IntPtr factory = IntPtr.Zero;
            var result = new List<AdapterRecord>();
            Guid factoryIid = IID_IDXGIFactory6;

            int hr = CreateDXGIFactory2(0, ref factoryIid, out factory);
            if (hr < 0)
                Marshal.ThrowExceptionForHR(hr);

            try
            {
                var enumAdapter = (EnumAdapterByGpuPreferenceDelegate)
                    Marshal.GetDelegateForFunctionPointer(
                        GetVtableSlot(factory, 29),
                        typeof(EnumAdapterByGpuPreferenceDelegate));

                for (uint index = 0; ; index++)
                {
                    IntPtr adapter = IntPtr.Zero;
                    Guid adapterIid = IID_IDXGIAdapter1;
                    hr = enumAdapter(factory, index, 0, ref adapterIid, out adapter);

                    if (hr == DXGI_ERROR_NOT_FOUND)
                        break;
                    if (hr < 0)
                        Marshal.ThrowExceptionForHR(hr);

                    try
                    {
                        var getDesc1 = (GetDesc1Delegate)
                            Marshal.GetDelegateForFunctionPointer(
                                GetVtableSlot(adapter, 10),
                                typeof(GetDesc1Delegate));

                        AdapterDesc1 desc;
                        hr = getDesc1(adapter, out desc);
                        if (hr < 0)
                            Marshal.ThrowExceptionForHR(hr);

                        if ((desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0)
                            continue;

                        result.Add(new AdapterRecord
                        {
                            DxgiIndex = (int)index,
                            Name = desc.Description,
                            Luid = LuidString(desc.AdapterLuid),
                            AdapterLuid = LuidRaw(desc.AdapterLuid),
                            VendorId = desc.VendorId,
                            DeviceId = desc.DeviceId,
                            SubSysId = desc.SubSysId,
                            DedicatedVideoMemory = desc.DedicatedVideoMemory.ToUInt64(),
                            SharedSystemMemory = desc.SharedSystemMemory.ToUInt64()
                        });
                    }
                    finally
                    {
                        if (adapter != IntPtr.Zero)
                            Marshal.Release(adapter);
                    }
                }
            }
            finally
            {
                if (factory != IntPtr.Zero)
                    Marshal.Release(factory);
            }

            return result.ToArray();
        }

        public static int[] FindAll(byte[] data, byte[] pattern)
        {
            var offsets = new List<int>();
            if (data == null || pattern == null || pattern.Length == 0 || data.Length < pattern.Length)
                return offsets.ToArray();

            for (int i = 0; i <= data.Length - pattern.Length; i++)
            {
                if (data[i] != pattern[0])
                    continue;

                bool match = true;
                for (int j = 1; j < pattern.Length; j++)
                {
                    if (data[i + j] != pattern[j])
                    {
                        match = false;
                        break;
                    }
                }

                if (match)
                    offsets.Add(i);
            }

            return offsets.ToArray();
        }
    }
}
'@

    Add-Type -TypeDefinition $source -Language CSharp
}

function Get-DxgiAdapterOrder {
    Initialize-DxgiProbe
    @([MapleStoryGpuSeletor.DxgiProbe]::EnumerateUnspecified())
}

function Get-AvailableGpuAdapters {
    $dxgi = @(Get-DxgiAdapterOrder)
    if ($dxgi.Count -eq 0) {
        throw 'DXGI returned no physical GPU adapters.'
    }

    $perf = @(
        Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory -ErrorAction Stop
    )

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($adapter in $dxgi) {
        $counter = $perf |
            Where-Object { $_.Name -like "$($adapter.Luid)_phys_*" } |
            Select-Object -First 1

        if (-not $counter) {
            continue
        }

        $result.Add([pscustomobject]@{
            Index = $result.Count + 1
            DxgiIndex = [int]$adapter.DxgiIndex
            Name = [string]$adapter.Name
            Luid = [string]$adapter.Luid
            AdapterLuid = [uint64]$adapter.AdapterLuid
            VendorId = ('{0:X4}' -f [uint32]$adapter.VendorId)
            DeviceId = ('{0:X4}' -f [uint32]$adapter.DeviceId)
            SubSysId = ('{0:X8}' -f [uint32]$adapter.SubSysId)
            DedicatedMemoryMiB = [math]::Round(([double]$adapter.DedicatedVideoMemory / 1MB),1)
            SharedMemoryMiB = [math]::Round(([double]$adapter.SharedSystemMemory / 1MB),1)
            DedicatedUsageMiB = [math]::Round(([double]$counter.DedicatedUsage / 1MB),1)
            SharedUsageMiB = [math]::Round(([double]$counter.SharedUsage / 1MB),1)
        })
    }

    if ($result.Count -eq 0) {
        throw 'No DXGI adapter could be matched to GPU performance counters.'
    }

    @($result)
}

function Select-GpuAdapter([object[]]$Adapters) {
    if ($GpuIndex -gt 0) {
        if ($GpuIndex -gt $Adapters.Count) {
            throw "GpuIndex=$GpuIndex is out of range; available adapters=$($Adapters.Count)."
        }
        return $Adapters[$GpuIndex - 1]
    }

    Write-Host ''
    Write-Host 'Available GPUs:' -ForegroundColor Cyan
    foreach ($gpu in $Adapters) {
        Write-Host ('[{0}] {1}' -f $gpu.Index,$gpu.Name)
        Write-Host ('    DXGI index={0}; LUID={1}' -f $gpu.DxgiIndex,$gpu.Luid) -ForegroundColor DarkGray
    }

    while ($true) {
        $raw = Read-Host ('Select GPU [1-{0}]' -f $Adapters.Count)
        $index = 0
        if ([int]::TryParse($raw,[ref]$index) -and $index -ge 1 -and $index -le $Adapters.Count) {
            return $Adapters[$index - 1]
        }
    }
}

function Find-UniquePatternOffset([byte[]]$Data,[byte[]]$Pattern,[string]$Name) {
    Initialize-DxgiProbe
    $hits = @([MapleStoryGpuSeletor.DxgiProbe]::FindAll($Data,$Pattern))
    if ($hits.Count -ne 1) {
        throw "Patch signature '$Name' expected exactly once, found $($hits.Count)."
    }
    [int]$hits[0]
}

function Bytes-ToHex([byte[]]$Bytes) {
    (($Bytes | ForEach-Object { $_.ToString('X2') }) -join ' ')
}

function Build-DllPatchPlan([string]$DllPath,[object]$Adapter) {
    if ($Adapter.DxgiIndex -lt 0 -or $Adapter.DxgiIndex -gt 127) {
        throw "DXGI index $($Adapter.DxgiIndex) is outside the supported 0..127 test-build range."
    }

    $sig = Get-AuthenticodeSignature -LiteralPath $DllPath
    if ($sig.Status -ne 'Valid') {
        throw "Gr2D_DX11.dll signature is $($sig.Status), expected Valid."
    }

    $data = [IO.File]::ReadAllBytes($DllPath)

    $firstSignature = [byte[]](
        0x33,0xD2,0x41,0xB8,0x02,0x00,0x00,0x00,
        0xFF,0x90,0xE8,0x00,0x00,0x00
    )
    $loopSignature = [byte[]](
        0x41,0xB8,0x02,0x00,0x00,0x00,
        0x8B,0xD3,0xFF,0x90,0xE8,0x00,0x00,0x00
    )
    $finalSignature = [byte[]](
        0x48,0x8B,0xCF,0x48,0x85,0xDB,
        0x48,0x0F,0x45,0xCB,
        0x48,0x8B,0x74,0x24,0x70
    )

    $firstOffset = Find-UniquePatternOffset $data $firstSignature 'first EnumAdapterByGpuPreference'
    $loopOffset = Find-UniquePatternOffset $data $loopSignature 'adapter enumeration loop'
    $finalOffset = Find-UniquePatternOffset $data $finalSignature 'final adapter fallback'

    $selectedIndex = [byte]$Adapter.DxgiIndex

    # Existing Maple code calls:
    # EnumAdapterByGpuPreference(AdapterIndex, DXGI_GPU_PREFERENCE, ...)
    # This 8-byte replacement loads the selected DXGI index into RDX and
    # DXGI_GPU_PREFERENCE_UNSPECIFIED (0) into R8 without changing code size.
    $firstReplacement = [byte[]](
        0x33,0xD2,           # xor edx, edx
        0x83,0xC2,$selectedIndex, # add edx, AdapterIndex
        0x45,0x33,0xC0      # xor r8d, r8d (UNSPECIFIED)
    )

    $patches = @(
        [pscustomobject]@{
            Name = 'Selected adapter index + unspecified preference'
            Offset = $firstOffset
            OriginalBytes = [byte[]]$data[$firstOffset..($firstOffset + 7)]
            NewBytes = $firstReplacement
        },
        [pscustomobject]@{
            Name = 'Enumeration loop preference = unspecified'
            Offset = $loopOffset
            OriginalBytes = [byte[]]$data[$loopOffset..($loopOffset + 5)]
            NewBytes = [byte[]](0x41,0xB8,0x00,0x00,0x00,0x00)
        },
        [pscustomobject]@{
            Name = 'Keep primary selected adapter; disable final fallback overwrite'
            Offset = $finalOffset + 6
            OriginalBytes = [byte[]]$data[($finalOffset + 6)..($finalOffset + 9)]
            NewBytes = [byte[]](0x90,0x90,0x90,0x90)
        }
    )

    [pscustomobject]@{
        DllPath = $DllPath
        OriginalHash = Hash $DllPath
        SelectedAdapter = $Adapter
        Patches = $patches
    }
}

function Apply-DllPatchPlan([object]$Plan) {
    $fs = [IO.File]::Open(
        $Plan.DllPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::Read
    )

    try {
        foreach ($patch in $Plan.Patches) {
            $fs.Position = [int64]$patch.Offset
            $current = New-Object byte[] $patch.OriginalBytes.Length
            [void]$fs.Read($current,0,$current.Length)

            if ((Bytes-ToHex $current) -ne (Bytes-ToHex $patch.OriginalBytes)) {
                throw "Patch precondition failed at 0x$('{0:X}' -f $patch.Offset) ($($patch.Name))."
            }

            $fs.Position = [int64]$patch.Offset
            $fs.Write($patch.NewBytes,0,$patch.NewBytes.Length)
        }
        $fs.Flush($true)
    }
    finally {
        $fs.Dispose()
    }

    $verify = [IO.File]::ReadAllBytes($Plan.DllPath)
    foreach ($patch in $Plan.Patches) {
        $actual = [byte[]]$verify[$patch.Offset..($patch.Offset + $patch.NewBytes.Length - 1)]
        if ((Bytes-ToHex $actual) -ne (Bytes-ToHex $patch.NewBytes)) {
            throw "Patch verification failed at 0x$('{0:X}' -f $patch.Offset) ($($patch.Name))."
        }
    }
}

function Verify-ProcessGpu([System.Diagnostics.Process]$Process,[object]$Adapter) {
    $deadline = (Get-Date).AddSeconds(30)
    $selectedUsage = 0L
    $selectedDedicated = 0L
    $selectedShared = 0L
    $lastRows = @()

    do {
        Start-Sleep -Milliseconds 750
        if ($Process.HasExited) {
            throw "MapleStory exited during GPU verification, ExitCode=$($Process.ExitCode)"
        }

        $lastRows = @(
            Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUProcessMemory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "pid_$($Process.Id)_*" }
        )

        $selectedRows = @($lastRows | Where-Object { $_.Name -like "*$($Adapter.Luid)*" })
        $selectedDedicated = [int64](($selectedRows | Measure-Object -Property DedicatedUsage -Sum).Sum)
        $selectedShared = [int64](($selectedRows | Measure-Object -Property SharedUsage -Sum).Sum)
        $selectedUsage = $selectedDedicated + $selectedShared
    }
    until ($selectedUsage -ge 64MB -or (Get-Date) -ge $deadline)

    if ($selectedUsage -lt 64MB) {
        $seen = @($lastRows | Select-Object -ExpandProperty Name)
        throw "GPU verification failed for '$($Adapter.Name)' ($($Adapter.Luid)): selected usage=$selectedUsage bytes; rows=$($seen -join ', ')"
    }

    [pscustomobject]@{
        DedicatedUsage = $selectedDedicated
        SharedUsage = $selectedShared
        TotalUsage = $selectedUsage
    }
}

function Invoke-CleanupWatcher {
    $ErrorActionPreference = 'SilentlyContinue'

    function Log([string]$Message) {
        Add-Content -LiteralPath $LogPath -Value ("{0:o} {1}" -f (Get-Date),$Message) -Encoding UTF8
    }

    Log "watch start pid=$TargetPid mapped=$MappedPatched"

    while ($true) {
        $p = Get-Process -Id $TargetPid -ErrorAction SilentlyContinue
        if (-not $p) {
            break
        }
        try {
            if ($p.StartTime.Ticks -ne $StartTicks) {
                break
            }
        }
        catch {
            break
        }
        Start-Sleep -Seconds 1
    }

    for ($i = 0; $i -lt 60; $i++) {
        try {
            if (-not (Test-Path -LiteralPath $Target) -or (Hash $Target) -ne $CleanupExpectedHash) {
                Copy-Item -LiteralPath $Backup -Destination $Target -Force -ErrorAction Stop
            }
            if ((Hash $Target) -ne $CleanupExpectedHash) {
                throw 'canonical hash mismatch'
            }
            if (Test-Path -LiteralPath $MappedPatched) {
                Remove-Item -LiteralPath $MappedPatched -Force -ErrorAction Stop
            }
            Log "cleanup PASS canonical=$CleanupExpectedHash"
            exit 0
        }
        catch {
            Log "cleanup retry $i : $($_.Exception.Message)"
        }
        Start-Sleep -Milliseconds 500
    }

    Log 'cleanup FAILED after retries'
    exit 2
}

if ($Mode -eq 'Cleanup') {
    foreach ($required in @('TargetPid','StartTicks','Backup','Target','MappedPatched','CleanupExpectedHash','LogPath')) {
        if (-not (Get-Variable -Name $required -ValueOnly -ErrorAction SilentlyContinue)) {
            throw "Cleanup mode missing parameter: $required"
        }
    }
    Invoke-CleanupWatcher
    exit $LASTEXITCODE
}

function Wait-ForGr2DMapping([System.Diagnostics.Process]$Process) {
    Write-Host "MapleStory PID=$($Process.Id) started; waiting for login and Gr2D_DX11.dll mapping..." -ForegroundColor Cyan

    while ($true) {
        Start-Sleep -Milliseconds 200
        if ($Process.HasExited) {
            throw "MapleStory exited before graphics initialization, ExitCode=$($Process.ExitCode)"
        }

        try {
            $Process.Refresh()
            if (@($Process.Modules | Where-Object { $_.ModuleName -ieq 'Gr2D_DX11.dll' }).Count -gt 0) {
                return
            }
        }
        catch {}
    }
}

function Assert-GameWriteAccess([string]$GameDir,[string]$DllPath,[string]$BackupDir) {
    $probePaths = [System.Collections.Generic.List[string]]::new()
    $dllStream = $null

    try {
        if (-not (Test-Path -LiteralPath $BackupDir -PathType Container)) {
            New-Item -ItemType Directory -Path $BackupDir -Force -ErrorAction Stop | Out-Null
        }

        foreach ($dir in @($GameDir,$BackupDir)) {
            $token = [guid]::NewGuid().ToString('N')
            $source = Join-Path $dir ('.MapleStoryGPUSeletor_write_test_{0}.tmp' -f $token)
            $renamed = Join-Path $dir ('.MapleStoryGPUSeletor_write_test_{0}.renamed.tmp' -f $token)
            $probePaths.Add($source)
            $probePaths.Add($renamed)

            [IO.File]::WriteAllText($source,'write-test',[Text.Encoding]::ASCII)
            Move-Item -LiteralPath $source -Destination $renamed -ErrorAction Stop
            Remove-Item -LiteralPath $renamed -Force -ErrorAction Stop
        }

        $dllInfo = Get-Item -LiteralPath $DllPath -ErrorAction Stop
        if (($dllInfo.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) {
            throw 'Gr2D_DX11.dll is marked read-only.'
        }

        # Opening the existing DLL for ReadWrite verifies that the current token
        # can modify it without changing any bytes.
        $dllStream = [IO.File]::Open(
            $DllPath,
            [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::Read
        )
        $dllStream.Dispose()
        $dllStream = $null
    }
    catch {
        $reason = $_.Exception.Message
        throw @"
MapleStory folder is not writable by the current user.

Path:
$GameDir

The selector must temporarily modify, rename, and restore Gr2D_DX11.dll before MapleStory starts using it.

Reason:
$reason

Run the selector with the same privilege level as the login/launcher tool, or install MapleStory in a user-writable game folder such as D:\Games\MapleStory.
"@
    }
    finally {
        if ($dllStream) {
            $dllStream.Dispose()
        }
        foreach ($p in $probePaths) {
            if (Test-Path -LiteralPath $p) {
                Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Restore-LatestOriginal([string]$BackupDir,[string]$DllPath) {
    $cand = Get-ChildItem -LiteralPath $BackupDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'Gr2D_DX11.dll.*.launch-original' } |
        Sort-Object LastWriteTime -Descending

    foreach ($f in $cand) {
        try {
            $sig = Get-AuthenticodeSignature -LiteralPath $f.FullName
            if ($sig.Status -eq 'Valid') {
                Copy-Item -LiteralPath $f.FullName -Destination $DllPath -Force -ErrorAction Stop
                if ((Get-AuthenticodeSignature -LiteralPath $DllPath).Status -eq 'Valid') {
                    return $f.FullName
                }
            }
        }
        catch {}
    }

    throw 'No verified original Gr2D_DX11.dll backup found.'
}

function Invoke-DllAdapterSelectionBackend([string]$MapleStoryPath,[object]$Adapter) {
    if (Get-Process MapleStory -ErrorAction SilentlyContinue) {
        throw 'MapleStory is already running.'
    }

    $gameDir = Split-Path -Parent $MapleStoryPath
    $dll = Join-Path $gameDir 'Gr2D_DX11.dll'
    if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {
        throw "Gr2D_DX11.dll not found: $dll"
    }

    Ensure-StateDirectories
    $backupDir = Join-Path $gameDir '_gpu_seletor_backup'
    Assert-GameWriteAccess -GameDir $gameDir -DllPath $dll -BackupDir $backupDir

    $currentSignature = Get-AuthenticodeSignature -LiteralPath $dll
    if ($currentSignature.Status -ne 'Valid') {
        $from = Restore-LatestOriginal -BackupDir $backupDir -DllPath $dll
        Write-Host "Recovered stale patched DLL from $from" -ForegroundColor Yellow
    }

    $plan = Build-DllPatchPlan -DllPath $dll -Adapter $Adapter

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmssfff'
    $backup = Join-Path $backupDir ("Gr2D_DX11.dll.{0}.launch-original" -f $stamp)
    Copy-Item -LiteralPath $dll -Destination $backup -ErrorAction Stop
    if ((Hash $backup) -ne $plan.OriginalHash) {
        throw 'Backup verification failed.'
    }
    if ((Get-AuthenticodeSignature -LiteralPath $backup).Status -ne 'Valid') {
        throw 'Backup signature verification failed.'
    }

    $proc = $null
    $mappedPatched = $null
    $canonicalRestored = $false

    try {
        Apply-DllPatchPlan $plan
        $patchedHash = Hash $dll
        if ($patchedHash -eq $plan.OriginalHash) {
            throw 'Patched DLL hash did not change.'
        }

        $proc = Start-Process -FilePath $MapleStoryPath -WorkingDirectory $gameDir -PassThru
        Wait-ForGr2DMapping -Process $proc

        $mappedPatched = Join-Path $backupDir ("Gr2D_DX11.dll.{0}.mapped-patched" -f $stamp)
        Move-Item -LiteralPath $dll -Destination $mappedPatched -ErrorAction Stop
        if ((Hash $mappedPatched) -ne $patchedHash) {
            throw 'Mapped patched image hash mismatch.'
        }

        Copy-Item -LiteralPath $backup -Destination $dll -ErrorAction Stop
        if ((Hash $dll) -ne $plan.OriginalHash) {
            throw 'Immediate restore hash mismatch.'
        }

        $signature = Get-AuthenticodeSignature -LiteralPath $dll
        if ($signature.Status -ne 'Valid') {
            throw "Immediate restore signature is $($signature.Status), expected Valid."
        }

        $canonicalRestored = $true
        Write-Host 'Original signed Gr2D_DX11.dll restored immediately while Maple remains running.' -ForegroundColor Green

        $gpu = Verify-ProcessGpu -Process $proc -Adapter $Adapter

        $startTicks = $proc.StartTime.Ticks
        $log = Join-Path $backupDir 'MapleStory_GPU_Seletor_cleanup.log'
        $shell = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
        if (-not $shell) {
            $shell = (Get-Command pwsh.exe -ErrorAction Stop).Source
        }

        $args = @(
            '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass',
            '-File',$PSCommandPath,
            '-Mode','Cleanup',
            '-TargetPid',[string]$proc.Id,
            '-StartTicks',[string]$startTicks,
            '-Backup',$backup,
            '-Target',$dll,
            '-MappedPatched',$mappedPatched,
            '-CleanupExpectedHash',$plan.OriginalHash,
            '-LogPath',$log
        )

        $watch = Start-Process -FilePath $shell -ArgumentList $args -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 200
        if ($watch.HasExited) {
            throw 'Cleanup watcher failed to stay running.'
        }

        Write-Host (
            "PASS: MapleStory is using '{0}'. DXGI index={1}; dedicated={2:N1} MiB; shared={3:N1} MiB." -f
            $Adapter.Name,
            $Adapter.DxgiIndex,
            ($gpu.DedicatedUsage / 1MB),
            ($gpu.SharedUsage / 1MB)
        ) -ForegroundColor Green

        Write-Host "Canonical Gr2D: SHA256=$(Hash $dll); Signature=$((Get-AuthenticodeSignature $dll).Status)" -ForegroundColor Green

        $proc = $null
    }
    catch {
        $err = $_

        if ($proc -and -not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 800
        }

        if (-not $canonicalRestored -or -not (Test-Path -LiteralPath $dll) -or (Hash $dll) -ne $plan.OriginalHash) {
            Copy-Item -LiteralPath $backup -Destination $dll -Force -ErrorAction SilentlyContinue
        }

        if ($mappedPatched -and (Test-Path -LiteralPath $mappedPatched)) {
            Remove-Item -LiteralPath $mappedPatched -Force -ErrorAction SilentlyContinue
        }

        throw $err
    }
}

Ensure-StateDirectories

$gamePath = Resolve-MapleStoryPath
$gameDir = Split-Path -Parent $gamePath
$dllPath = Join-Path $gameDir 'Gr2D_DX11.dll'
$adapters = @(Get-AvailableGpuAdapters)

if ($Mode -eq 'Probe') {
    [pscustomobject]@{
        App = $AppName
        GamePath = $gamePath
        ConfigPath = $ConfigPath
        AdapterCount = $adapters.Count
        Adapters = @(
            $adapters |
                Select-Object Index,DxgiIndex,Name,Luid,AdapterLuid,VendorId,DeviceId,SubSysId,DedicatedMemoryMiB,SharedMemoryMiB,DedicatedUsageMiB,SharedUsageMiB
        )
    } | ConvertTo-Json -Depth 7
    exit 0
}

$selected = Select-GpuAdapter -Adapters $adapters

if ($Mode -eq 'DryRunPatch') {
    $plan = Build-DllPatchPlan -DllPath $dllPath -Adapter $selected
    [pscustomobject]@{
        GamePath = $gamePath
        SelectedAdapter = $selected
        OriginalHash = $plan.OriginalHash
        Patches = @(
            $plan.Patches | ForEach-Object {
                [pscustomobject]@{
                    Name = $_.Name
                    Offset = ('0x{0:X}' -f $_.Offset)
                    Original = Bytes-ToHex $_.OriginalBytes
                    Replacement = Bytes-ToHex $_.NewBytes
                }
            }
        )
    } | ConvertTo-Json -Depth 7
    exit 0
}

Write-Host 'MapleStory GPU Seletor - TEST BUILD' -ForegroundColor Cyan
Write-Host ('Game: {0}' -f $gamePath)
Write-Host ('Selected: [{0}] {1}' -f $selected.Index,$selected.Name) -ForegroundColor Green
Write-Host ('DXGI index={0}; LUID={1}' -f $selected.DxgiIndex,$selected.Luid)

if ($Mode -eq 'Select') {
    Write-Host 'Selection resolved. Default mode launches MapleStory.exe directly.' -ForegroundColor Yellow
    exit 0
}

Invoke-DllAdapterSelectionBackend -MapleStoryPath $gamePath -Adapter $selected