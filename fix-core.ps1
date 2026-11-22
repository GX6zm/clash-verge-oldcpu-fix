#requires -Version 5.1
<#
.SYNOPSIS
    修复 Clash Verge 内核在老旧 CPU / 虚拟机上“一启动就崩溃”（0xC0000005）的问题。

.DESCRIPTION
    Clash Verge 自带的 verge-mihomo.exe 是按较新的 x86-64 指令集编译的。
    在缺少 SSE4.2 / POPCNT / AVX 等指令的 CPU（老笔记本、QEMU/KVM 虚拟机、
    深信服/华为云桌面等）上，内核一启动就崩溃，表现为：

        - 界面能打开，但内核始终“未运行”
        - 没有任何端口监听（7897 等）
        - 系统代理无法开启
        - 事件日志：Application Error 1000，异常代码 0xc0000005，BEX64

    本脚本下载 MetaCubeX 官方 mihomo 的 amd64-compatible 构建替换该文件，
    保留原文件备份；替换后会实际执行一次 `-v` 校验，失败则自动回滚。

.PARAMETER ClashVergeDir
    Clash Verge 安装目录，默认 C:\Program Files\Clash Verge

.PARAMETER CoreVersion
    要使用的 mihomo 版本，默认 v1.19.34

.PARAMETER SourceFile
    可选。本地已有的 compatible 内核（.exe 或 .zip），指定后跳过下载，适合离线环境。

.EXAMPLE
    .\fix-core.ps1

.EXAMPLE
    .\fix-core.ps1 -SourceFile D:\mihomo-windows-amd64-compatible.exe
#>
[CmdletBinding()]
param(
    [string]$ClashVergeDir = 'C:\Program Files\Clash Verge',
    [string]$CoreVersion = 'v1.19.34',
    [string]$SourceFile = ''
)

$ErrorActionPreference = 'Stop'

$WorkDir = Join-Path $env:ProgramData 'ClashVergeOldCpuFix'
$LogFile = Join-Path $WorkDir 'fix.log'
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

function Write-Step {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Host $Message
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- 1. 自动提权 ----------
if (-not (Test-Admin)) {
    Write-Host '需要管理员权限，正在请求提权（会弹出 UAC 提示）...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($ClashVergeDir -ne 'C:\Program Files\Clash Verge') { $argList += @('-ClashVergeDir', "`"$ClashVergeDir`"") }
    if ($CoreVersion -ne 'v1.19.34') { $argList += @('-CoreVersion', $CoreVersion) }
    if ($SourceFile) { $argList += @('-SourceFile', "`"$SourceFile`"") }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
    return
}

Write-Step '================ 开始修复 Clash Verge 内核 ================'

$dst = Join-Path $ClashVergeDir 'verge-mihomo.exe'
$bak = Join-Path $ClashVergeDir 'verge-mihomo.exe.orig-broken'
$work = Join-Path $WorkDir 'download'

try {
    if (-not (Test-Path $ClashVergeDir)) { throw "找不到 Clash Verge 安装目录：$ClashVergeDir" }
    if (-not (Test-Path $dst)) { throw "找不到内核文件：$dst" }

    # ---------- 2. 准备新内核 ----------
    $newCore = $null

    if ($SourceFile) {
        if (-not (Test-Path $SourceFile)) { throw "指定的本地文件不存在：$SourceFile" }
        if ([IO.Path]::GetExtension($SourceFile) -eq '.zip') {
            $ext = Join-Path $work 'local'
            Remove-Item $ext -Recurse -Force -ErrorAction SilentlyContinue
            Expand-Archive -Path $SourceFile -DestinationPath $ext -Force
            $newCore = (Get-ChildItem $ext -Filter '*.exe' -Recurse | Select-Object -First 1).FullName
        } else {
            $newCore = (Resolve-Path $SourceFile).Path
        }
        Write-Step "使用本地内核文件：$newCore"
    } else {
        # 仓库目录里如果放了 exe，直接用，免下载
        $localExe = Get-ChildItem $PSScriptRoot -Filter 'mihomo-windows-amd64-compatible*.exe' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($localExe) {
            $newCore = $localExe.FullName
            Write-Step "使用脚本目录内的内核文件：$newCore"
        } else {
            $zipName = "mihomo-windows-amd64-compatible-$CoreVersion.zip"
            $rel = "/MetaCubeX/mihomo/releases/download/$CoreVersion/$zipName"
            $mirrors = @(
                "https://github.com$rel",
                "https://ghfast.top/https://github.com$rel",
                "https://ghproxy.net/https://github.com$rel"
            )
            New-Item -ItemType Directory -Force -Path $work | Out-Null
            $zipPath = Join-Path $work $zipName
            $ok = $false
            foreach ($url in $mirrors) {
                Write-Step "下载：$url"
                try {
                    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
                    & curl.exe -L --fail --retry 2 --connect-timeout 15 --max-time 600 -o $zipPath $url 2>$null
                    if ($LASTEXITCODE -eq 0 -and (Get-Item $zipPath).Length -gt 1MB) { $ok = $true; break }
                } catch {
                    Write-Step "  该源失败：$($_.Exception.Message)"
                }
            }
            if (-not $ok) { throw '所有下载源都失败了。请用 -SourceFile 指定本地 compatible 内核文件。' }

            $ext = Join-Path $work 'extract'
            Remove-Item $ext -Recurse -Force -ErrorAction SilentlyContinue
            Expand-Archive -Path $zipPath -DestinationPath $ext -Force
            $newCore = (Get-ChildItem $ext -Filter '*.exe' -Recurse | Select-Object -First 1).FullName
            if (-not $newCore) { throw '下载的压缩包里没有找到 .exe 文件' }
        }
    }

    # ---------- 3. 停掉正在运行的 Clash Verge ----------
    $appWasRunning = $false
    $app = Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue
    if ($app) {
        $appWasRunning = $true
        Write-Step '关闭 Clash Verge ...'
        $app | Stop-Process -Force
        Start-Sleep -Seconds 3
    }
    Get-Process -Name 'verge-mihomo' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1

    # ---------- 4. 备份 + 替换 ----------
    if (-not (Test-Path $bak)) {
        Copy-Item $dst $bak -Force
        Write-Step "已备份原内核：$bak"
    } else {
        Write-Step "备份已存在：$bak"
    }

    Copy-Item $newCore $dst -Force
    $h1 = (Get-FileHash $newCore -Algorithm SHA256).Hash
    $h2 = (Get-FileHash $dst -Algorithm SHA256).Hash
    if ($h1 -ne $h2) { throw '复制后校验不一致，文件可能被占用或拦截' }
    Write-Step "内核已替换，SHA256=$h2"

    # ---------- 5. 实际运行校验 ----------
    Write-Step '校验新内核能否运行 ...'
    $out = & $dst -v 2>&1 | Out-String
    $code = $LASTEXITCODE
    Write-Step ("  -v 输出：{0}" -f ($out.Trim() -replace "`r?`n", ' | '))
    if ($code -ne 0 -or $out -notmatch 'Mihomo') {
        Write-Step "新内核同样无法运行（退出码 $code），正在回滚 ..."
        Copy-Item $bak $dst -Force
        throw '新内核在本机无法运行，已恢复原文件。请换一个版本或换兼容构建重试。'
    }

    # ---------- 6. 重新启动 ----------
    if ($appWasRunning) {
        Write-Step '重新启动 Clash Verge ...'
        Start-Process (Join-Path $ClashVergeDir 'clash-verge.exe')
        Start-Sleep -Seconds 12
        $core = Get-Process -Name 'verge-mihomo' -ErrorAction SilentlyContinue
        if ($core) {
            Write-Step "完成：内核已运行（PID $($core.Id)）"
        } else {
            Write-Step '注意：Clash Verge 已启动，但内核进程尚未出现，请到界面里确认。'
        }
    }

    Write-Step '================ 修复完成 ================'
    Set-Content -Path (Join-Path $WorkDir 'ok.txt') -Value 'ok' -Encoding UTF8
    exit 0
}
catch {
    Write-Step "失败：$($_.Exception.Message)"
    Set-Content -Path (Join-Path $WorkDir 'err.txt') -Value $_.Exception.Message -Encoding UTF8
    exit 1
}
