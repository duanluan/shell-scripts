<# : >nul 2>&1
@echo off
chcp 65001 >nul
title SynologyDrive Ignore Monitor

:: ===============================================================
:: title:         synology_ignore_monitor.bat
:: description:   监控并自动为 SynologyDrive 注入全局忽略目录规则
:: author:        duanluan<duanluan@outlook.com> (Windows Port)
:: date:          2026-04-04
:: version:       v1.1-win
:: ===============================================================

powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Command -ScriptBlock ([Scriptblock]::Create((Get-Content -LiteralPath '%~f0' -Raw)))"
goto :EOF
#>

# 强制 PowerShell 控制台使用 UTF-8 输出
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 定义 SynologyDrive 的 session 基础目录
$sessionDir = [Environment]::ExpandEnvironmentVariables("%LOCALAPPDATA%\SynologyDrive\data\session")

# 轮询模式间隔（秒）
$pollInterval = 5

# 定义需要注入的忽略规则
$ignoreRule = 'black_name = ".git", "node_modules", "venv", ".venv", "vendor", "Pods", "target", "build", "dist", "generator", "bin", "obj", ".idea", ".vscode", "__pycache__", ".pytest_cache", ".cache", ".mvn", ".bundle", ".local", ".mvn", ".gradle", ".fleet", ".kotlin", "checkpoints", "temp", "tmp"'

# 定义无 BOM 的 UTF-8 编码，防止 SynologyDrive 读取异常
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

# 查找所有包含 blacklist.filter 的文件
$files = Get-ChildItem -Path $sessionDir -Filter "blacklist.filter" -Recurse -ErrorAction SilentlyContinue

# 如果找不到任何目录则退出脚本
if (-not $files -or $files.Count -eq 0) {
  Write-Host "Error: Cannot find any blacklist.filter in $sessionDir" -ForegroundColor Red
  exit 1
}

# 提取并去重目录路径存入数组
$confDirs = @()
foreach ($file in $files) {
  if ($confDirs -notcontains $file.DirectoryName) {
    $confDirs += $file.DirectoryName
  }
}

Write-Host "Found $($confDirs.Count) session directories."

# 定义更新配置文件的函数，接收目录路径作为参数
function Update-Filter {
  param (
    [string]$TargetDir
  )
  
  $targetFile = Join-Path -Path $TargetDir -ChildPath "blacklist.filter"
  
  if (-not (Test-Path $targetFile)) {
    return
  }
  
  try {
    $content = Get-Content -Path $targetFile -Raw
    
    # 检查文件中是否已经包含我们自定义的规则，防止无限循环触发
    if (-not $content.Contains($ignoreRule)) {
      Write-Host "Changes detected or missing rules in $targetFile. Injecting custom blacklist rules..." -ForegroundColor Yellow
      
      # 使用正则表达式在 [Directory] 这一行的下一行追加我们的忽略规则
      $newContent = $content -replace '(?m)^\[Directory\]\s*$', "`$0`r`n$ignoreRule"
      
      [IO.File]::WriteAllText($targetFile, $newContent, $utf8NoBom)
      Write-Host "Rules injected successfully for $TargetDir." -ForegroundColor Green
    }
  } catch {
    # 忽略由于文件被占用锁定时产生的读取异常，等待下一次轮询
  }
}

# 脚本启动时，先主动遍历所有找到的目录执行一次检查和更新
foreach ($dir in $confDirs) {
  Update-Filter -TargetDir $dir
}

Write-Host "Start monitoring with polling (${pollInterval}s): $($confDirs -join ', ')"

# 持续轮询监控
while ($true) {
  foreach ($dir in $confDirs) {
    Update-Filter -TargetDir $dir
  }
  Start-Sleep -Seconds $pollInterval
}