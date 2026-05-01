param(
    [string] $CodexExe = (Join-Path $env:LOCALAPPDATA "CodexSessionLimitPatch\electron_packaged\resources\codex.exe"),
    [int] $Limit = 1000,
    [int] $MaxPages = 20
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $CodexExe)) {
    $officialPackage = Get-ChildItem -LiteralPath "C:\Program Files\WindowsApps" -Directory -Filter "OpenAI.Codex_*_x64__2p2nqsd0c76g0" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $officialPackage) {
        throw "Could not find patched or official codex.exe"
    }
    $CodexExe = Join-Path $officialPackage.FullName "app\resources\codex.exe"
}

$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $CodexExe
$psi.Arguments = "app-server --analytics-default-enabled"
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true

$proc = [System.Diagnostics.Process]::Start($psi)
$nextId = 1

function Send-JsonRpc($Method, $Params) {
    $script:nextId += 1
    $id = $script:nextId
    $request = [ordered]@{
        jsonrpc = "2.0"
        id = $id
        method = $Method
    }
    if ($null -ne $Params) {
        $request.params = $Params
    }
    $line = ($request | ConvertTo-Json -Depth 20 -Compress)
    $script:proc.StandardInput.WriteLine($line)
    $script:proc.StandardInput.Flush()

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline) {
        $responseLine = $script:proc.StandardOutput.ReadLine()
        if ([string]::IsNullOrWhiteSpace($responseLine)) {
            continue
        }
        $response = $responseLine | ConvertFrom-Json
        if ($response.id -eq $id) {
            return $response
        }
    }
    throw "Timed out waiting for $Method"
}

try {
    Send-JsonRpc "initialize" @{
        clientInfo = @{
            name = "codex-session-limit-patch-probe"
            version = "0.1.0"
        }
        capabilities = @{}
    } | Out-Null

    $cursor = $null
    $total = 0
    $pages = 0
    do {
        $response = Send-JsonRpc "thread/list" @{
            limit = $Limit
            cursor = $cursor
            sortKey = "updated_at"
            modelProviders = $null
            archived = $false
            sourceKinds = $null
        }
        if ($null -ne $response.error) {
            throw ($response.error | ConvertTo-Json -Compress)
        }
        $count = @($response.result.data).Count
        $total += $count
        $pages += 1
        $cursor = $response.result.nextCursor
        Write-Host ("page={0} count={1} hasNext={2}" -f $pages, $count, ($null -ne $cursor))
    } while ($null -ne $cursor -and $pages -lt $MaxPages)

    Write-Host "total=$total pages=$pages exhausted=$($null -eq $cursor)"
}
finally {
    if ($proc -and -not $proc.HasExited) {
        $proc.Kill()
    }
}
