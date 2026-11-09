# Native production merge for wcodes.org, after Wolo's project/render-native.ps1.
# Copies the baked site (site/site/project/public) THEN the app (app/project/Root) into
# site/project/build (wcodes-org/web-public, Firebase "public": "."), so the app owns / and
# index.html. Like Wolo, nothing is deleted from the build: files are merged over it.
# Nothing is committed or pushed here; committing and pushing web-public main is the
# production deploy (console "Deploy to production").
#
#   .\render-native.ps1                      # site public + app working tree -> build
#   .\render-native.ps1 -SkipSite            # app only
#   .\render-native.ps1 -AppRef main         # app files from a git ref instead of the working tree
#   .\render-native.ps1 -OutputDir <dir>     # merge somewhere else (e.g. a scratch folder)
[CmdletBinding()]
param(
    # ...\web (this script lives in web\site\project). No drive letters.
    [string]$WebsiteRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [string]$OutputDir,
    [string]$AppRef,
    [switch]$SkipSite,
    [switch]$SkipApp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$appProject = Join-Path $WebsiteRoot 'app\project'
$appRoot = Join-Path $appProject 'Root'
$sitePublic = Join-Path $WebsiteRoot 'site\site\project\public'
$buildRoot = if ($OutputDir) { $OutputDir } else { Join-Path $WebsiteRoot 'site\project\build' }

function Copy-WcodesTree {
    param(
        [Parameter(Mandatory)] [string]$SourceDir,
        [Parameter(Mandatory)] [string]$DestDir
    )
    if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
        throw "Missing source directory: $SourceDir"
    }
    if (-not (Test-Path -LiteralPath $DestDir -PathType Container)) {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    }
    # Merge (no /MIR): Copy-Item -Recurse onto an existing folder would nest folders.
    $null = & robocopy.exe $SourceDir $DestDir /E /XD .git /NFL /NDL /NJH /NJS /nc /ns /np
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed ($LASTEXITCODE) from $SourceDir to $DestDir"
    }
    $global:LASTEXITCODE = 0
}

function Get-AppSource {
    if (-not $AppRef) {
        return $appRoot
    }
    # Export Root/ at a git ref (e.g. main) without switching the app checkout.
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('wcodes-app-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    $zip = Join-Path $temp 'root.zip'
    & git -C $appProject archive --format=zip -o $zip $AppRef Root
    if ($LASTEXITCODE -ne 0) { throw "git archive of $AppRef failed in $appProject." }
    Expand-Archive -LiteralPath $zip -DestinationPath $temp -Force
    Remove-Item -LiteralPath $zip -Force
    return (Join-Path $temp 'Root')
}

function Assert-AppEntry {
    param([Parameter(Mandatory)] [string]$Dir)
    # Firebase rewrites every unknown path to /index.html, so a missing script shows up in the
    # browser as "Unexpected token '<'". Check that every local src/href in index.html exists.
    $index = Join-Path $Dir 'index.html'
    if (-not (Test-Path -LiteralPath $index -PathType Leaf)) { throw "Missing $index after merge." }
    $html = [System.IO.File]::ReadAllText($index)
    $missing = @()
    foreach ($m in [regex]::Matches($html, '(?:src|href)=["'']([^"''#?]+)')) {
        $ref = $m.Groups[1].Value
        if ($ref -match '^(https?:|//|data:|mailto:|tel:|javascript:)' -or $ref -eq '/' -or $ref -notmatch '\.[A-Za-z0-9]+$') { continue }
        $path = Join-Path $Dir ($ref.TrimStart('/') -replace '/', '\')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $missing += $ref }
    }
    if ($missing.Count -gt 0) { throw "index.html references missing files: $($missing -join ', ')" }
}

Write-Host "=== wcodes merge into $buildRoot ===" -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath (Join-Path $buildRoot 'firebase.json') -PathType Leaf) -and -not $OutputDir) {
    throw "Missing $buildRoot\firebase.json. Clone wcodes-org/web-public into site\project\build first."
}

if (-not $SkipSite) {
    Write-Host "--- site: $sitePublic" -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath (Join-Path $sitePublic 'about.html') -PathType Leaf)) {
        throw "No site bake in $sitePublic. Run the console 'Render complete site' (Tiggu) first, or pass -SkipSite."
    }
    Copy-WcodesTree -SourceDir $sitePublic -DestDir $buildRoot
}

if (-not $SkipApp) {
    $appSource = Get-AppSource
    $label = if ($AppRef) { "$appProject @ $AppRef" } else { "$appRoot (working tree)" }
    Write-Host "--- app: $label" -ForegroundColor Cyan
    try {
        # Site first, then app: the app owns / (index.html, sw.js, manifest.json).
        Copy-WcodesTree -SourceDir $appSource -DestDir $buildRoot
    }
    finally {
        if ($AppRef) { Remove-Item -LiteralPath (Split-Path $appSource -Parent) -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Assert-AppEntry -Dir $buildRoot
}

if (Test-Path -LiteralPath (Join-Path $buildRoot '.git')) {
    Write-Host "--- web-public changes (not committed):" -ForegroundColor Cyan
    & git -C $buildRoot status --short
}
Write-Host "Merge complete. Output: $buildRoot (commit + push web-public main = production deploy)." -ForegroundColor Green
