$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

Write-Host "========== Downloader Electron Build ==========" -ForegroundColor Cyan
$required = @("node", "npm")
foreach ($name in $required) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "未找到 $name，请先安装 Node.js 22 LTS。"
    }
}

Write-Host "[1/4] 安装依赖..." -ForegroundColor Yellow
npm install
if ($LASTEXITCODE -ne 0) { throw "npm install 执行失败" }

Write-Host "[2/4] 构建 Vue 和 Electron 主进程..." -ForegroundColor Yellow
npm run build
if ($LASTEXITCODE -ne 0) { throw "项目构建失败" }

Write-Host "[3/4] 构建 Windows 安装包和便携版..." -ForegroundColor Yellow
npx electron-builder --win nsis portable --x64
if ($LASTEXITCODE -ne 0) { throw "electron-builder 构建失败" }

Write-Host ""
Write-Host "[4/4] 构建完成，产物目录：$ProjectRoot\release" -ForegroundColor Green
Get-ChildItem (Join-Path $ProjectRoot "release") -File | Select-Object Name, Length
