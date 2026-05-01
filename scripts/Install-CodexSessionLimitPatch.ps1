param(
    [int] $PageLimit = 1000,
    [int] $MaxPages = 20,
    [string] $PatchRoot = (Join-Path $env:LOCALAPPDATA "CodexSessionLimitPatch"),
    [switch] $NoLaunch
)

$ErrorActionPreference = "Stop"

function Write-Step($Message) {
    Write-Host "[codex-session-limit-patch] $Message"
}

function Assert-UnderPath($Child, $Parent) {
    $childFull = [System.IO.Path]::GetFullPath($Child)
    $parentFull = [System.IO.Path]::GetFullPath($Parent)
    if (-not $parentFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $parentFull += [System.IO.Path]::DirectorySeparatorChar
    }
    if (-not $childFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to operate outside intended directory: $childFull"
    }
}

function Invoke-RobocopyMirror($Source, $Destination) {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    & robocopy $Source $Destination /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    $rc = $LASTEXITCODE
    if (($rc -band 8) -ne 0) {
        throw "robocopy failed with exit code $rc while copying $Source to $Destination"
    }
}

function Stop-PatchedProcesses($Root) {
    if (-not (Test-Path -LiteralPath $Root)) {
        return
    }
    $escaped = [regex]::Escape([System.IO.Path]::GetFullPath($Root))
    Get-CimInstance Win32_Process |
        Where-Object {
            ($_.ExecutablePath -and $_.ExecutablePath -match $escaped) -or
            ($_.CommandLine -and $_.CommandLine -match $escaped)
        } |
        Where-Object { $_.ProcessId -ne $PID } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

function Patch-RecentThreadFrontend($AppSource, $PageLimit, $MaxPages) {
    $asset = Get-ChildItem -LiteralPath (Join-Path $AppSource "webview\assets") -Filter "app-server-manager-signals-*.js" -File |
        Select-Object -First 1
    if ($null -eq $asset) {
        throw "Could not find app-server-manager-signals-*.js in extracted app.asar"
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    $text = [System.IO.File]::ReadAllText($asset.FullName, $encoding)

    $oldInitialFetches = @(
        "let r=await this.listRecentThreads({limit:50*this.pageCount,cursor:null});this.fetched=!0,this.nextCursor=r.nextCursor;let i=this.conversationIds;",
        "let r=await this.listRecentThreads({limit:$PageLimit*this.pageCount,cursor:null});this.fetched=!0,this.nextCursor=r.nextCursor;let i=this.conversationIds;"
    )
    $newInitialFetch = "let r={data:[],nextCursor:null},s=null,l=0;do{let e=await this.listRecentThreads({limit:$PageLimit,cursor:s});r.data.push(...e.data),s=e.nextCursor??null,l+=1}while(s!=null&&l<$MaxPages);this.fetched=!0;this.nextCursor=s;let i=this.conversationIds;"

    $patchedInitialFetch = $false
    if ($text.Contains($newInitialFetch)) {
        $patchedInitialFetch = $true
    }
    else {
        foreach ($old in $oldInitialFetches) {
            if ($text.Contains($old)) {
                $text = $text.Replace($old, $newInitialFetch)
                $patchedInitialFetch = $true
                break
            }
        }
    }
    if (-not $patchedInitialFetch) {
        throw "Could not patch initial recent-thread fetch. The Codex frontend bundle likely changed."
    }

    $replacements = @(
        @{
            Old = "listRecentThreads({limit:50,cursor:this.nextCursor})"
            New = "listRecentThreads({limit:$PageLimit,cursor:this.nextCursor})"
        },
        @{
            Old = "searchThreads({query:e,limit:t=50,conversationsById:n})"
            New = "searchThreads({query:e,limit:t=$PageLimit,conversationsById:n})"
        },
        @{
            Old = "async searchThreads({query:e,limit:t=50})"
            New = "async searchThreads({query:e,limit:t=$PageLimit})"
        }
    )

    foreach ($replacement in $replacements) {
        if ($text.Contains($replacement.Old)) {
            $text = $text.Replace($replacement.Old, $replacement.New)
        }
    }

    [System.IO.File]::WriteAllText($asset.FullName, $text, $encoding)
    return $asset.FullName
}

function Patch-AppTitle($AppSource) {
    $bootstrap = Join-Path $AppSource ".vite\build\bootstrap.js"
    if (-not (Test-Path -LiteralPath $bootstrap)) {
        throw "Could not find .vite\build\bootstrap.js"
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $text = [System.IO.File]::ReadAllText($bootstrap, $encoding)
    $old = 'n.app.setName(e.H(x)),n.app.setPath(`userData`,'
    $new = 'n.app.setName(`Codex Patched`),n.app.setPath(`userData`,'
    if ($text.Contains($old)) {
        $text = $text.Replace($old, $new)
        [System.IO.File]::WriteAllText($bootstrap, $text, $encoding)
    }
    elseif (-not $text.Contains($new)) {
        throw "Could not patch app title. The Codex bootstrap bundle likely changed."
    }

    $packageJson = Join-Path $AppSource "package.json"
    if (Test-Path -LiteralPath $packageJson) {
        $pkg = Get-Content -LiteralPath $packageJson -Raw | ConvertFrom-Json
        $pkg.productName = "Codex Patched"
        $pkg.description = "Codex Patched SessionLimit"
        $pkg | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $packageJson -Encoding utf8NoBOM
    }
}

function Get-ElectronVersion($AppSource) {
    $packageJson = Join-Path $AppSource "package.json"
    if (-not (Test-Path -LiteralPath $packageJson)) {
        return "41.2.0"
    }
    $pkg = Get-Content -LiteralPath $packageJson -Raw | ConvertFrom-Json
    $version = $pkg.devDependencies.electron
    if ([string]::IsNullOrWhiteSpace($version)) {
        return "41.2.0"
    }
    return $version.TrimStart("^")
}

function Install-ElectronRunner($RunnerRoot, $ElectronVersion) {
    New-Item -ItemType Directory -Force -Path $RunnerRoot | Out-Null
    $packageJson = Join-Path $RunnerRoot "package.json"
    if (-not (Test-Path -LiteralPath $packageJson)) {
        @"
{
  "dependencies": {
    "electron": "$ElectronVersion"
  }
}
"@ | Set-Content -LiteralPath $packageJson -Encoding utf8NoBOM
    }
    & npm install --prefix $RunnerRoot --no-audit --no-fund "electron@$ElectronVersion"
    if ($LASTEXITCODE -ne 0) {
        throw "npm install electron@$ElectronVersion failed"
    }
}

function Write-Launcher($PatchRoot, $PackagedRoot) {
    $launcher = Join-Path $PatchRoot "launch_codex_sessionlimit_patch.ps1"
    $content = @'
$ErrorActionPreference = "Stop"

$PatchRoot = Join-Path $env:LOCALAPPDATA "CodexSessionLimitPatch"
$ElectronExe = Join-Path $PatchRoot "electron_packaged\CodexPatched.exe"
$UserData = Join-Path $PatchRoot "ElectronRunnerUserData"

foreach ($path in @($ElectronExe, (Join-Path $PatchRoot "electron_packaged\resources\app.asar"))) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required path not found: $path"
    }
}

New-Item -ItemType Directory -Force -Path $UserData | Out-Null
$env:CODEX_ELECTRON_USER_DATA_PATH = $UserData

Start-Process -FilePath $ElectronExe -WorkingDirectory (Split-Path -Parent $ElectronExe) -WindowStyle Hidden
'@
    $content | Set-Content -LiteralPath $launcher -Encoding utf8NoBOM
    return $launcher
}

function Write-DesktopShortcut($Launcher, $PackagedRoot) {
    $desktop = [Environment]::GetFolderPath("Desktop")
    $shortcutPath = Join-Path $desktop "Codex Patched SessionLimit.lnk"
    $pwshCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    $pwsh = if ($null -ne $pwshCommand) { $pwshCommand.Source } else { $null }
    if ([string]::IsNullOrWhiteSpace($pwsh)) {
        $pwsh = (Get-Command powershell.exe).Source
    }

    $wshell = New-Object -ComObject WScript.Shell
    $shortcut = $wshell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $pwsh
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Launcher`""
    $shortcut.WorkingDirectory = Split-Path -Parent $Launcher
    $icon = Join-Path $PackagedRoot "resources\icon.ico"
    if (Test-Path -LiteralPath $icon) {
        $shortcut.IconLocation = "$icon,0"
    }
    $shortcut.Description = "Launch Codex patched frontend with session list auto-pagination"
    $shortcut.Save()
    return $shortcutPath
}

New-Item -ItemType Directory -Force -Path $PatchRoot | Out-Null
Assert-UnderPath $PatchRoot (Split-Path -Parent $PatchRoot)

$officialPackage = Get-ChildItem -LiteralPath "C:\Program Files\WindowsApps" -Directory -Filter "OpenAI.Codex_*_x64__2p2nqsd0c76g0" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
if ($null -eq $officialPackage) {
    throw "Official OpenAI.Codex package was not found under C:\Program Files\WindowsApps"
}

$officialApp = Join-Path $officialPackage.FullName "app"
$officialResources = Join-Path $officialApp "resources"
$officialAsar = Join-Path $officialResources "app.asar"
if (-not (Test-Path -LiteralPath $officialAsar)) {
    throw "Official app.asar not found: $officialAsar"
}

$appSource = Join-Path $PatchRoot "app_source"
$runnerRoot = Join-Path $PatchRoot "electron_runner"
$packagedRoot = Join-Path $PatchRoot "electron_packaged"
$targetResources = Join-Path $packagedRoot "resources"
$targetAsar = Join-Path $targetResources "app.asar"
$backupDir = Join-Path $PatchRoot "backups"
$tempAsar = Join-Path $PatchRoot "app.sessionlimit.tmp.asar"

Assert-UnderPath $appSource $PatchRoot
Assert-UnderPath $runnerRoot $PatchRoot
Assert-UnderPath $packagedRoot $PatchRoot

Write-Step "Using official package: $($officialPackage.FullName)"
Write-Step "Stopping existing patched app processes"
Stop-PatchedProcesses $PatchRoot
Start-Sleep -Seconds 1

if (Test-Path -LiteralPath $appSource) {
    Remove-Item -LiteralPath $appSource -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $appSource | Out-Null

Write-Step "Extracting official app.asar"
& npx --yes "@electron/asar" extract $officialAsar $appSource
if ($LASTEXITCODE -ne 0) {
    throw "asar extract failed with exit code $LASTEXITCODE"
}

Write-Step "Patching recent thread frontend"
$patchedAsset = Patch-RecentThreadFrontend -AppSource $appSource -PageLimit $PageLimit -MaxPages $MaxPages
Write-Step "Patched asset: $patchedAsset"

Write-Step "Patching app title"
Patch-AppTitle $appSource

$electronVersion = Get-ElectronVersion $appSource
Write-Step "Installing Electron runner: $electronVersion"
Install-ElectronRunner -RunnerRoot $runnerRoot -ElectronVersion $electronVersion

$electronDist = Join-Path $runnerRoot "node_modules\electron\dist"
if (-not (Test-Path -LiteralPath (Join-Path $electronDist "electron.exe"))) {
    throw "Electron dist was not found after npm install: $electronDist"
}

Write-Step "Preparing packaged runner"
Invoke-RobocopyMirror -Source $electronDist -Destination $packagedRoot
Copy-Item -LiteralPath (Join-Path $packagedRoot "electron.exe") -Destination (Join-Path $packagedRoot "CodexPatched.exe") -Force

Write-Step "Copying official resources"
Invoke-RobocopyMirror -Source $officialResources -Destination $targetResources

New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
if (Test-Path -LiteralPath $targetAsar) {
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    Copy-Item -LiteralPath $targetAsar -Destination (Join-Path $backupDir "app.asar.before_patch_$stamp.asar") -Force
}

if (Test-Path -LiteralPath $tempAsar) {
    Remove-Item -LiteralPath $tempAsar -Force
}
Write-Step "Packing patched app.asar"
& npx --yes "@electron/asar" pack $appSource $tempAsar
if ($LASTEXITCODE -ne 0) {
    throw "asar pack failed with exit code $LASTEXITCODE"
}
Move-Item -LiteralPath $tempAsar -Destination $targetAsar -Force

$launcher = Write-Launcher -PatchRoot $PatchRoot -PackagedRoot $packagedRoot
$shortcut = Write-DesktopShortcut -Launcher $launcher -PackagedRoot $packagedRoot

$manifest = [ordered]@{
    createdAt = (Get-Date).ToString("o")
    officialPackage = $officialPackage.FullName
    patchRoot = $PatchRoot
    packagedExe = (Join-Path $packagedRoot "CodexPatched.exe")
    patchedAsar = $targetAsar
    patchedAsset = $patchedAsset
    pageLimit = $PageLimit
    maxPages = $MaxPages
    launcher = $launcher
    shortcut = $shortcut
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $PatchRoot "sessionlimit_patch_manifest.json") -Encoding utf8NoBOM

if (-not $NoLaunch) {
    Write-Step "Launching Codex Patched"
    & $launcher
}

Write-Step "Done"
Write-Host "Patched executable: $(Join-Path $packagedRoot "CodexPatched.exe")"
Write-Host "Shortcut: $shortcut"
