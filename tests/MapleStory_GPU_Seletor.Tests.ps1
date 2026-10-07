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
    'Timed out waiting for Gr2D_DX11.dll to map.'
)) {
    if ($text -match [regex]::Escape($forbidden)) {
        throw "FAIL: forbidden machine/OS-specific backend remains: $forbidden"
    }
}

foreach ($required in @(
    'MapleStoryGPUSeletor',
    'Resolve-MapleStoryPath',
    'Get-AvailableGpuAdapters',
    'Get-DxgiAdapterOrder',
    'EnumAdapterByGpuPreference',
    'DxgiIndex',
    'Select-GpuAdapter',
    'Build-DllPatchPlan',
    'Invoke-DllAdapterSelectionBackend',
    'DryRunPatch',
    'Wait-ForGr2DMapping',
    'Start-Process -FilePath $MapleStoryPath',
    '[string]$Mode = ''Launch''',
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

$json = & pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Target -Mode Probe
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

$planJson = & pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Target -Mode DryRunPatch -GpuIndex 1
if ($LASTEXITCODE -ne 0) {
    throw "FAIL: DryRunPatch exit code $LASTEXITCODE"
}
$plan = ($planJson | Out-String) | ConvertFrom-Json
if ($null -eq $plan.SelectedAdapter.DxgiIndex -or -not $plan.Patches -or @($plan.Patches).Count -lt 3) {
    throw "FAIL: DryRunPatch did not produce selected adapter + patch plan"
}

Write-Host ("PASS: path={0}; adapters={1}; selectedDxgiIndex={2}; backend=DLL" -f $data.GamePath,@($data.Adapters).Count,$plan.SelectedAdapter.DxgiIndex)