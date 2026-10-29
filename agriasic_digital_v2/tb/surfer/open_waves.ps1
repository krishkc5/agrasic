# Open a regression waveform in Surfer with one of the signal lists in this
# folder already loaded, so nothing has to be picked by hand.
#
#   .\tb\surfer\open_waves.ps1                 # list the views
#   .\tb\surfer\open_waves.ps1 e2e             # e2e_overview.surfer on waves\e2e.fst
#   .\tb\surfer\open_waves.ps1 detail          # measurement_detail.surfer on waves\smoke.fst
#   .\tb\surfer\open_waves.ps1 jtag            # jtag_debug.surfer on waves\jtag.fst
#   .\tb\surfer\open_waves.ps1 e2e -Wave waves\e2e_ref.fst
#
# Works from any directory: paths resolve from this script's location. The
# traces come from the regression stages with WAVES=1 (tb/rv32i_regression/
# waves.sh). A new view is one more entry in $Views plus its .surfer file here.

param(
  [Parameter(Position = 0)] [string] $View,
  # Any trace with the same hierarchy as the view's default, e.g. a copy kept
  # for reference. Relative paths resolve from the current directory first,
  # then from the repo root.
  [string] $Wave
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

# name -> signal list in this folder, its default trace, and the stage that writes it
$Views = [ordered]@{
  e2e    = @{ Commands = 'e2e_overview.surfer';       Wave = 'waves\e2e.fst';   Stage = 'e2e.sh' }
  detail = @{ Commands = 'measurement_detail.surfer'; Wave = 'waves\smoke.fst'; Stage = 'smoke.sh' }
  jtag   = @{ Commands = 'jtag_debug.surfer';         Wave = 'waves\jtag.fst';  Stage = 'jtag.sh' }
}

if (-not $View) {
  'Usage: open_waves.ps1 <view> [-Wave <trace>]'
  foreach ($name in $Views.Keys) {
    '  {0,-8} {1} on {2}' -f $name, $Views[$name].Commands, $Views[$name].Wave
  }
  return
}
if (-not $Views.Contains($View)) {
  throw "Unknown view '$View'. Known views: $($Views.Keys -join ', ')"
}
$v = $Views[$View]

$surfer = (Get-Command surfer -ErrorAction SilentlyContinue).Source
if (-not $surfer) { $surfer = Join-Path $env:LOCALAPPDATA 'Programs\Surfer\surfer.exe' }
if (-not (Test-Path -LiteralPath $surfer)) {
  throw "Surfer not found on PATH or at $surfer"
}

$commands = Join-Path $PSScriptRoot $v.Commands
if (-not (Test-Path -LiteralPath $commands)) { throw "Signal list missing: $commands" }

if ($Wave) {
  $trace = if (Test-Path -LiteralPath $Wave) { $Wave } else { Join-Path $Root $Wave }
  if (-not (Test-Path -LiteralPath $trace)) { throw "Trace not found: $Wave" }
} else {
  $trace = Join-Path $Root $v.Wave
  if (-not (Test-Path -LiteralPath $trace)) {
    throw "$($v.Wave) not found. Generate it from the repo root in WSL with:  WAVES=1 bash tb/rv32i_regression/$($v.Stage)"
  }
}
$trace = (Resolve-Path -LiteralPath $trace).Path

# Absolute paths, so a state saved from this window (File > Save state as...)
# reopens from anywhere. Windows PowerShell does not quote -ArgumentList
# entries itself, and the repo path has spaces.
$p = Start-Process -FilePath $surfer -WorkingDirectory $Root -PassThru `
  -ArgumentList '-c', "`"$commands`"", "`"$trace`""

'Surfer (PID {0}): {1} on {2}, trace written {3:yyyy-MM-dd HH:mm}' -f `
  $p.Id, $v.Commands, $trace, (Get-Item -LiteralPath $trace).LastWriteTime
