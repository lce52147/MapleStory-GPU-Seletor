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
    'Find-CodeCave',
    'semantic-call-pair + dynamic-code-cave',
    'DXGI_ERROR_NOT_FOUND',
    'No patch bytes were written.',
    'Redirect selected-adapter call through dynamic trampoline',
    'Stop adapter enumeration after selected adapter',
    'Dynamic adapter-selection trampoline',
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
    if (-not $gpu.Name -or -not $gpu.Luid -or $null -eq $gpu.DxgiIndex) {
        throw "FAIL: adapter lacks Name/Luid/DxgiIndex"
    }
}

$planJson = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Target -Mode DryRunPatch -GpuIndex 1
if ($LASTEXITCODE -ne 0) {
    throw "FAIL: DryRunPatch exit code $LASTEXITCODE"
}
$plan = ($planJson | Out-String) | ConvertFrom-Json
if ($null -eq $plan.SelectedAdapter.DxgiIndex -or -not $plan.Patches -or @($plan.Patches).Count -ne 3) {
    throw "FAIL: DryRunPatch did not produce the three-patch semantic trampoline plan"
}
if (-not $plan.Detector -or $plan.Detector.Strategy -ne 'semantic-call-pair + dynamic-code-cave' -or -not $plan.Detector.FirstCallOffset -or -not $plan.Detector.LoopCallOffset -or -not $plan.Detector.CodeCaveOffset) {
    throw "FAIL: DryRunPatch did not report semantic detector + code-cave evidence"
}

Write-Host ("PASS: path={0}; adapters={1}; selectedDxgiIndex={2}; backend=DLL" -f $data.GamePath,@($data.Adapters).Count,$plan.SelectedAdapter.DxgiIndex)