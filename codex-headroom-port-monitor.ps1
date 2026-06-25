param(
  [switch]$Once,
  [string]$CodexConfig = $(if ($env:CODEX_CONFIG) { $env:CODEX_CONFIG } else { Join-Path $HOME ".codex\config.toml" }),
  [string]$HeadroomManifest = $(if ($env:HEADROOM_MANIFEST) { $env:HEADROOM_MANIFEST } else { Join-Path $HOME ".headroom\deploy\default\manifest.json" }),
  [double]$PollInterval = $(if ($env:POLL_INTERVAL) { [double]$env:POLL_INTERVAL } else { 2 }),
  [int]$DefaultHeadroomPort = $(if ($env:DEFAULT_HEADROOM_PORT) { [int]$env:DEFAULT_HEADROOM_PORT } else { 15721 })
)

$ErrorActionPreference = "Stop"

function Write-Log {
  param([string]$Message)
  Write-Host ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message)
}

function Test-ValidPort {
  param([string]$Port)

  $value = 0
  if (-not [int]::TryParse($Port, [ref]$value)) {
    return $false
  }

  return $value -ge 1 -and $value -le 65535
}

function Get-JsonPropertyValue {
  param(
    [object]$Object,
    [string]$Name
  )

  if ($null -eq $Object) {
    return $null
  }

  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $null
  }

  return $property.Value
}

function Resolve-HeadroomPort {
  $port = $env:HEADROOM_PORT

  if ([string]::IsNullOrWhiteSpace($port) -and (Test-Path -LiteralPath $HeadroomManifest)) {
    try {
      $json = Get-Content -LiteralPath $HeadroomManifest -Raw | ConvertFrom-Json
      $baseEnv = Get-JsonPropertyValue -Object $json -Name "base_env"
      $port = Get-JsonPropertyValue -Object $baseEnv -Name "HEADROOM_PORT"

      if ([string]::IsNullOrWhiteSpace($port)) {
        $port = Get-JsonPropertyValue -Object $json -Name "port"
      }
    } catch {
      Write-Log "Warning: failed to read Headroom manifest: $HeadroomManifest"
    }
  }

  if ([string]::IsNullOrWhiteSpace($port)) {
    $port = [string]$DefaultHeadroomPort
  }

  if (-not (Test-ValidPort -Port $port)) {
    throw "Invalid Headroom port: $port"
  }

  return [int]$port
}

function Remove-ManagedHeadroomBlocks {
  param([string]$Content)

  $proxyMarker = "# --- Headroom proxy (auto-injected by headroom wrap codex) ---"
  $endMarker = "# --- end Headroom ---"
  $mcpMarker = "# --- Headroom MCP server ---"
  $normalized = $Content -replace "`r`n?", "`n"
  $lines = $normalized -split "`n", -1
  $kept = New-Object System.Collections.Generic.List[string]
  $index = 0

  while ($index -lt $lines.Count) {
    $line = $lines[$index]

    if ($line -eq $proxyMarker) {
      $index++
      while ($index -lt $lines.Count -and $lines[$index] -ne $endMarker) {
        $index++
      }
      if ($index -lt $lines.Count) {
        $index++
      }
      continue
    }

    if ($line -eq $mcpMarker) {
      $index++
      if ($index -lt $lines.Count -and $lines[$index] -match '^\s*\[mcp_servers\.headroom\]\s*$') {
        $index++
        while ($index -lt $lines.Count -and
          $lines[$index] -notmatch '^\s*\[' -and
          $lines[$index] -notlike "# ---*") {
          $index++
        }
      }
      continue
    }

    if ($line -match '^\s*\[(mcp_servers|model_providers)\.headroom\]\s*$') {
      $index++
      while ($index -lt $lines.Count -and
        $lines[$index] -notmatch '^\s*\[' -and
        $lines[$index] -notlike "# ---*") {
        $index++
      }
      continue
    }

    $kept.Add($line)
    $index++
  }

  return ($kept -join "`n")
}

function Remove-TopLevelOpenAIBaseUrl {
  param([string]$Content)

  $lines = $Content -split "`n", -1
  $kept = New-Object System.Collections.Generic.List[string]
  $insideTable = $false

  foreach ($line in $lines) {
    if ($line -match '^\s*\[') {
      $insideTable = $true
    }

    if (-not $insideTable -and $line -match '^[ \t]*openai_base_url[ \t]*=') {
      continue
    }

    $kept.Add($line)
  }

  return ($kept -join "`n")
}

function Update-CodexConfig {
  if (-not (Test-Path -LiteralPath $CodexConfig)) {
    Write-Log "Waiting for Codex config: $CodexConfig"
    return
  }

  $port = Resolve-HeadroomPort
  $headroomUrl = "http://127.0.0.1:$port/v1"
  $proxyMarker = "# --- Headroom proxy (auto-injected by headroom wrap codex) ---"
  $endMarker = "# --- end Headroom ---"
  $encoding = New-Object System.Text.UTF8Encoding $false

  $original = [IO.File]::ReadAllText($CodexConfig)
  $content = Remove-ManagedHeadroomBlocks -Content $original
  $content = Remove-TopLevelOpenAIBaseUrl -Content $content

  if ($content -match '(?m)^[ \t]*model_provider[ \t]*=') {
    $content = [regex]::Replace($content, '(?m)^[ \t]*model_provider[ \t]*=.*$', 'model_provider = "headroom"', 1)
  } else {
    $content = "model_provider = `"headroom`"`n$content"
  }

  $content = [regex]::Replace($content, "`n{3,}", "`n`n").Trim()

  $updated = @(
    $proxyMarker
    "openai_base_url = `"$headroomUrl`""
    $endMarker
    ""
    $content
    ""
    "# --- Headroom MCP server ---"
    "[mcp_servers.headroom]"
    "command = `"headroom`""
    "args = [`"mcp`", `"serve`"]"
    ""
    $proxyMarker
    "[model_providers.headroom]"
    "name = `"OpenAI via Headroom proxy`""
    "base_url = `"$headroomUrl`""
    "supports_websockets = true"
    "env_http_headers = { `"X-Headroom-Project`" = `"HEADROOM_PROJECT`" }"
    $endMarker
    ""
  ) -join "`n"

  if ($original -eq $updated) {
    return
  }

  $backup = "{0}.headroom-monitor.{1}.bak" -f $CodexConfig, (Get-Date -Format "yyyyMMddHHmmss")
  Copy-Item -LiteralPath $CodexConfig -Destination $backup -Force
  [IO.File]::WriteAllText($CodexConfig, $updated, $encoding)
  Write-Log "Restored Codex Headroom provider with $headroomUrl. Backup: $backup"
}

function Get-FileSignature {
  if (-not (Test-Path -LiteralPath $CodexConfig)) {
    return "missing"
  }

  $item = Get-Item -LiteralPath $CodexConfig
  return "{0}:{1}" -f $item.LastWriteTimeUtc.Ticks, $item.Length
}

function Start-PollingMonitor {
  $previous = Get-FileSignature
  Write-Log "Start monitoring with polling (${PollInterval}s): $CodexConfig"

  while ($true) {
    Start-Sleep -Seconds $PollInterval
    $current = Get-FileSignature

    if ($current -ne $previous) {
      try {
        Update-CodexConfig
      } catch {
        Write-Log "Error: $($_.Exception.Message)"
      }

      $previous = Get-FileSignature
    }
  }
}

function Start-FileWatcherMonitor {
  $configDir = Split-Path -Parent $CodexConfig
  $configName = Split-Path -Leaf $CodexConfig

  while (-not (Test-Path -LiteralPath $configDir)) {
    Write-Log "Waiting for Codex config directory: $configDir"
    Start-Sleep -Seconds $PollInterval
  }

  $watcher = New-Object System.IO.FileSystemWatcher
  $watcher.Path = $configDir
  $watcher.Filter = $configName
  $watcher.IncludeSubdirectories = $false
  $watcher.NotifyFilter = (
    [System.IO.NotifyFilters]::FileName -bor
    [System.IO.NotifyFilters]::LastWrite -bor
    [System.IO.NotifyFilters]::Size -bor
    [System.IO.NotifyFilters]::Attributes
  )

  Write-Log "Start monitoring with FileSystemWatcher: $CodexConfig"

  try {
    while ($true) {
      $change = $watcher.WaitForChanged([System.IO.WatcherChangeTypes]::All)
      if (-not $change.TimedOut) {
        Start-Sleep -Milliseconds 200

        try {
          Update-CodexConfig
        } catch {
          Write-Log "Error: $($_.Exception.Message)"
        }
      }
    }
  } finally {
    $watcher.Dispose()
  }
}

try {
  Update-CodexConfig
} catch {
  Write-Log "Error: $($_.Exception.Message)"
  exit 1
}

if ($Once) {
  exit 0
}

try {
  Start-FileWatcherMonitor
} catch {
  Write-Log "Warning: FileSystemWatcher is unavailable; switch to polling mode."
  Start-PollingMonitor
}
