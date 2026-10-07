param(
    [string]$Target
)

$ErrorActionPreference = 'Stop'

if (-not $Target) {
    $Target = Join-Path (Split-Path -Parent $PSScriptRoot) 'MapleStory_GPU_Seletor.ps1'
}

if (-not (Test-Path -LiteralPath $Target)) {
    throw "RED: target script does not exist: $Target"
}

$text = Get-Content -LiteralPath $Target -Raw

foreach ($forbidden in @(
    '$IntelAdapterName',
    '$NvidiaAdapterName',
    "0x0001716B",
    "0x00015EF5",
    'UserGpuPreferences',
    'SpecificAdapter',
    'WaitForExternalLaunch',
    'Timed out waiting for Gr2D_DX11.dll to map.',
    'Find-UniquePatternOffset',
    'final adapter fallback'
)) {
    if ($text -match [regex]::Escape($forbidden)) {
        throw "FAIL: forbidden machine/OS-specific backend remains: $forbidden"
    }
}

foreach ($required in @(
    'MapleStoryGPUSeletor',
    'Resolve-MapleStoryPath',
    'Get-UserSearchRoots',
    'Get-UserFolderMapleCandidates',
    'Get-SteamLibraryRoots',
    'Get-SteamMapleCandidates',
    'Get-MapleInstallLabel',
    'libraryfolders.vdf',
    'gamania Games\MapleStory\MapleStory.exe',
    'Nexon\Maple\MapleStory.exe',
    'Nexon\Library\maplestory\MapleStory.exe',
    'Wizet\MapleStorySEA\MapleStory.exe',
    'Get-AvailableGpuAdapters',
    'Get-DxgiAdapterOrder',
    'EnumAdapterByGpuPreference',
    'DxgiIndex',
    'Select-GpuAdapter',
    'Build-DllPatchPlan',
    'Find-EnumAdapterByGpuPreferenceSites',
    'Get-R9RipTargetKey',
    'Get-PostCallBranchDirection',
    'Get-OutputPointerSetup',
    'semantic-call-pair + inline-EnumAdapterByLuid',
    'EnumAdapterByLuid',
    'AdapterLuid',
    'DXGI_ERROR_NOT_FOUND',
    'No patch bytes were written.',
    'Rewrite first adapter selection as EnumAdapterByLuid',
    'Stop preference enumeration after exact-LUID adapter',
    'GPU verification failed after the signed DLL was restored. MapleStory was left running',
    'Invoke-DllAdapterSelectionBackend',
    'DryRunPatch',
    'Wait-ForGr2DMapping',
    'Start-Process -FilePath $MapleStoryPath',
    '[string]$Mode = ''Launch''',
    'Assert-GameWriteAccess',
    'MapleStory folder is not writable by the current user.',
    'Run the selector with the same privilege level as the login/launcher tool',
    'Restore-LatestOriginal',
    'Mapped patched image hash mismatch',
    "'_gpu_seletor_backup'",
    'Verify-ProcessGpu',
    'Probe'
)) {
    if ($text -notmatch [regex]::Escape($required)) {
        throw "FAIL: missing architecture marker: $required"
    }
}

$preflightCall = 'Assert-GameWriteAccess -GameDir $gameDir -DllPath $dll -BackupDir $backupDir'
$preflightIndex = $text.IndexOf($preflightCall,[StringComparison]::Ordinal)
$patchPlanIndex = $text.IndexOf('$plan = Build-DllPatchPlan -DllPath $dll -Adapter $Adapter',[StringComparison]::Ordinal)
if ($preflightIndex -lt 0 -or $patchPlanIndex -lt 0 -or $preflightIndex -gt $patchPlanIndex) {
    throw 'FAIL: write-access preflight must run before patch-plan construction.'
}

$json = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Target -Mode Probe
if ($LASTEXITCODE -ne 0) {
    throw "FAIL: Probe mode exit code $LASTEXITCODE"
}

$data = ($json | Out-String) | ConvertFrom-Json
if (-not $data.GamePath -or -not (Test-Path -LiteralPath $data.GamePath)) {
    throw "FAIL: Probe did not resolve a valid MapleStory.exe"
}
if (-not $data.Adapters -or @($data.Adapters).Count -lt 1) {
    throw "FAIL: Probe found no active GPU adapters"
}
foreach ($gpu in @($data.Adapters)) {
    if (-not $gpu.Name -or -not $gpu.Luid -or $null -eq $gpu.AdapterLuid -or $null -eq $gpu.DxgiIndex) {
        throw "FAIL: adapter lacks Name/Luid/AdapterLuid/DxgiIndex"
    }
}

$planJson = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Target -Mode DryRunPatch -GpuIndex 1
if ($LASTEXITCODE -ne 0) {
    throw "FAIL: DryRunPatch exit code $LASTEXITCODE"
}
$plan = ($planJson | Out-String) | ConvertFrom-Json
if ($null -eq $plan.SelectedAdapter.DxgiIndex -or -not $plan.Patches -or @($plan.Patches).Count -ne 2) {
    throw "FAIL: DryRunPatch did not produce the two-patch exact-LUID plan"
}
if (-not $plan.Detector -or $plan.Detector.Strategy -ne 'semantic-call-pair + inline-EnumAdapterByLuid' -or -not $plan.Detector.SelectedAdapterLuid -or -not $plan.Detector.SetupStartOffset -or -not $plan.Detector.FirstCallOffset -or -not $plan.Detector.LoopCallOffset) {
    throw "FAIL: DryRunPatch did not report exact-LUID semantic detector evidence"
}

if ($plan.Patches[0].Replacement -notmatch 'FF 90 D0 00 00 00') {
    throw "FAIL: exact-LUID plan does not call IDXGIFactory4::EnumAdapterByLuid (vtable +0xD0)"
}

if (@($data.Adapters).Count -gt 1) {
    $plan2Json = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Target -Mode DryRunPatch -GpuIndex 2
    if ($LASTEXITCODE -ne 0) {
        throw "FAIL: second-adapter DryRunPatch exit code $LASTEXITCODE"
    }
    $plan2 = ($plan2Json | Out-String) | ConvertFrom-Json
    $expectedLuid2 = ('0x{0:X16}' -f [uint64]$data.Adapters[1].AdapterLuid)
    if ($plan2.Detector.SelectedAdapterLuid -ne $expectedLuid2) {
        throw "FAIL: second-adapter exact LUID mismatch: expected=$expectedLuid2 actual=$($plan2.Detector.SelectedAdapterLuid)"
    }
}

Write-Host ("PASS: path={0}; adapters={1}; selectedDxgiIndex={2}; backend=DLL" -f $data.GamePath,@($data.Adapters).Count,$plan.SelectedAdapter.DxgiIndex)

$watcherIndex = $text.IndexOf('$cleanupStarted = $true',[StringComparison]::Ordinal)
$verifyIndex = $text.IndexOf('$gpu = Verify-ProcessGpu -Process $proc -Adapter $Adapter',[StringComparison]::Ordinal)
if ($watcherIndex -lt 0 -or $verifyIndex -lt 0 -or $watcherIndex -gt $verifyIndex) {
    throw 'FAIL: cleanup watcher must be armed before GPU verification.'
}