# Anota el pid de claude.exe de una sesión y abre el monitor según los ajustes.
# El estado de la sesión lo escribe el propio mod (hooks/register.ts); este script solo corre cuando hace falta.
param(
  [string]$Session = '',
  [string]$State = 'busy',
  [string]$First = '0',
  # Lo que pasan las sesiones abiertas antes de esta versión del mod (escriben su estado aquí)
  [string]$Cwd = '-',
  [string]$Prompt = '-',
  [string]$Model = '-',
  [long]$Context = 0,
  [long]$Output = 0,
  [long]$Duration = 0
)
$ErrorActionPreference = 'SilentlyContinue'

$root = Join-Path $env:USERPROFILE '.claude\task-monitor'
$dir = Join-Path $root 'sessions'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

if ($State -in 'busy', 'idle' -and $Cwd -ne '-') {
  $file = Join-Path $dir "$Session.json"
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $old = $null
  if (Test-Path -LiteralPath $file) { $old = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json }
  function Old($name, $default) { if ($old -and $null -ne $old.$name) { $old.$name } else { $default } }
  $tasks = [int](Old 'tasks' 0); $workMs = [long](Old 'workMs' 0); $lastMs = [long](Old 'lastMs' 0)
  if ($State -eq 'idle' -and $old -and $old.state -eq 'busy') {
    $lastMs = if ($Duration -gt 0) { $Duration } else { $now - [long]$old.since }
    $tasks += 1; $workMs += $lastMs
  }
  [ordered]@{
    session = $Session; state = $State; cwd = $Cwd
    prompt = $(if ($Prompt -ne '-') { $Prompt } else { Old 'prompt' '' })
    since = $(if ($old -and $old.state -eq $State) { $old.since } else { $now }); updated = $now; firstSeen = Old 'firstSeen' $now
    tasks = $tasks; workMs = $workMs; lastMs = $lastMs
    model = $(if ($Model -ne '-') { $Model } else { Old 'model' '' })
    context = $(if ($Context -gt 0) { $Context } else { Old 'context' 0 })
    output = $(if ($State -eq 'idle') { $Output } else { Old 'output' 0 })
    opened = $true
  } | ConvertTo-Json -Compress | Set-Content -LiteralPath $file -Encoding UTF8
  if (-not $old) { $First = '1' }
}

function Open-Monitor {
  $m = $null
  if (-not [System.Threading.Mutex]::TryOpenExisting('Local\ClaudeTaskMonitor', [ref]$m)) {
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
      '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSScriptRoot\monitor.ps1`""
    )
  }
}

if ($State -eq 'open') { Open-Monitor; exit 0 }

if ($State -eq 'ended') {
  Remove-Item -LiteralPath (Join-Path $dir "$Session.json"), (Join-Path $dir "$Session.pid") -Force
  exit 0
}

# Sube por la cadena de procesos padre hasta el claude.exe que ejecutó este script (una sola consulta).
$pidFile = Join-Path $dir "$Session.pid"
if (-not (Test-Path -LiteralPath $pidFile)) {
  $parents = @{}; $names = @{}
  foreach ($p in Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name) { $parents[[int]$p.ProcessId] = [int]$p.ParentProcessId; $names[[int]$p.ProcessId] = $p.Name }
  $id = $PID
  for ($i = 0; $i -lt 8 -and $id; $i++) {
    $id = $parents[$id]
    if ($names[$id] -eq 'claude.exe') { Set-Content -LiteralPath $pidFile -Value $id -Encoding ASCII; break }
  }
}

if ($State -ne 'busy') { exit 0 }

$settings = $null
$settingsFile = Join-Path $root 'settings.json'
if (Test-Path -LiteralPath $settingsFile) { $settings = Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json }
$mode = if ($settings -and $settings.openMode) { [string]$settings.openMode } else { 'always' }
$open = switch ($mode) {
  'never' { $false }
  'session' { $First -eq '1' }
  'ram' {
    $os = Get-CimInstance Win32_OperatingSystem -Property TotalVisibleMemorySize, FreePhysicalMemory
    $threshold = if ($settings.ramThreshold) { [double]$settings.ramThreshold } else { 80 }
    (1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100 -ge $threshold
  }
  default { $true }
}
if ($open) { Open-Monitor }
