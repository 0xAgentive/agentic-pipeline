<#
.SYNOPSIS
  Guaranteed Visible Desktop Launcher for Google Antigravity IDE.
  Eliminates phantom headless/background processes, kills orphan child trees,
  clears stale Chromium locks, resets runInBackground, and activates the window
  on the user's interactive desktop.
#>
param(
  [switch]$Restart,
  [string[]]$WorkspacePaths
)

$ErrorActionPreference = 'SilentlyContinue'

$AppDataAntigravity = Join-Path $env:APPDATA 'Antigravity'
$AppDataAntigravityIDE = Join-Path $env:APPDATA 'Antigravity IDE'
$ExePath = Join-Path $env:LOCALAPPDATA 'Programs\antigravity\Antigravity.exe'

# 0. Clean environment: scrub any leaked ELECTRON_OZONE_PLATFORM_HINT
[System.Environment]::SetEnvironmentVariable('ELECTRON_OZONE_PLATFORM_HINT', $null, 'Process')
$env:ELECTRON_OZONE_PLATFORM_HINT = $null
try {
  [System.Environment]::SetEnvironmentVariable('ELECTRON_OZONE_PLATFORM_HINT', $null, 'User')
} catch {}

# 1. Terminate running processes if requested
if ($Restart) {
  Write-Host "[Launch] Performing clean process-tree termination..."
  taskkill /F /T /IM Antigravity.exe 2>$null | Out-Null
  taskkill /F /T /IM language_server.exe 2>$null | Out-Null
  
  $killDeadline = (Get-Date).AddSeconds(10)
  while ((Get-Date) -lt $killDeadline) {
    $procs = Get-Process -Name Antigravity, language_server -ErrorAction SilentlyContinue
    if (-not $procs) { break }
    Start-Sleep -Milliseconds 300
  }
  # Additional grace period for kernel file handle release
  Start-Sleep -Seconds 1
}

# 2. Reset runInBackground in app_storage.json so Antigravity never launches invisible
$AppStorage = Join-Path $AppDataAntigravity 'app_storage.json'
if (Test-Path -LiteralPath $AppStorage) {
  try {
    $content = Get-Content -LiteralPath $AppStorage -Raw -Encoding UTF8
    if ($content -match '"runInBackground"\s*:\s*"true"' -or $content -match '"runInBackground"\s*:\s*true') {
      $updated = $content -replace '"runInBackground"\s*:\s*"true"', '"runInBackground": "false"'
      $updated = $updated -replace '"runInBackground"\s*:\s*true', '"runInBackground": "false"'
      Set-Content -LiteralPath $AppStorage -Value $updated -Encoding UTF8
      Write-Host "[Launch] Reset runInBackground to false in app_storage.json"
    }
  } catch {}
}

# 3. Clear ALL stale Chromium lockfiles ONLY if NO Antigravity processes are running
$activeProcs = Get-Process -Name Antigravity, language_server -ErrorAction SilentlyContinue
if (-not $activeProcs) {
  $LockDirs = @($AppDataAntigravity, $AppDataAntigravityIDE)
  $LockNames = @('lockfile', 'DevToolsActivePort', 'SingletonLock', 'SingletonSocket', 'SingletonCookie')
  foreach ($ld in $LockDirs) {
    if (Test-Path -LiteralPath $ld) {
      foreach ($ln in $LockNames) {
        $lp = Join-Path $ld $ln
        if (Test-Path -LiteralPath $lp) {
          for ($r = 0; $r -lt 5; $r++) {
            try {
              [System.IO.File]::Delete($lp)
              Write-Host "[Launch] Removed stale lockfile: $lp"
              break
            } catch {
              Start-Sleep -Milliseconds 200
            }
          }
        }
      }
    }
  }
} else {
  Write-Host "[Launch] Antigravity processes currently active ($($activeProcs.Count) found). Skipping lockfile deletion to protect active profile."
}

# 4. Add Win32 Helper for window activation and foreground grant
$Win32Code = @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class Win32Window {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    public static extern bool AllowSetForegroundWindow(int dwProcessId);

    [DllImport("user32.dll")]
    public static extern IntPtr OpenDesktop(string lpszDesktop, int dwFlags, bool fInherit, uint dwDesiredAccess);

    [DllImport("user32.dll")]
    public static extern bool CloseDesktop(IntPtr hDesktop);

    [DllImport("user32.dll")]
    public static extern bool EnumDesktopWindows(IntPtr hDesktop, EnumWindowsProc lpfn, IntPtr lParam);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    public static extern IntPtr GetThreadDesktop(uint dwThreadId);

    [DllImport("user32.dll")]
    public static extern bool SetThreadDesktop(IntPtr hDesktop);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    public static IntPtr FindAntigravityWindow(IntPtr hDesktop) {
        IntPtr found = IntPtr.Zero;
        IntPtr hOrig = GetThreadDesktop(GetCurrentThreadId());
        bool switched = false;
        if (hDesktop != IntPtr.Zero) {
            switched = SetThreadDesktop(hDesktop);
        }
        try {
            EnumDesktopWindows(hDesktop, delegate(IntPtr hwnd, IntPtr lParam) {
                uint wPid = 0;
                GetWindowThreadProcessId(hwnd, out wPid);
                if (wPid != 0) {
                    try {
                        System.Diagnostics.Process p = System.Diagnostics.Process.GetProcessById((int)wPid);
                        if (p.ProcessName.Equals("Antigravity", StringComparison.OrdinalIgnoreCase)) {
                            RECT rect;
                            GetWindowRect(hwnd, out rect);
                            int w = rect.Right - rect.Left;
                            int h = rect.Bottom - rect.Top;
                            bool isMin = IsIconic(hwnd);
                            // Check if it's the main editor window (either visible or hidden due to parent STARTUPINFO)
                            if (isMin || (w > 200 && h > 200)) {
                                // If it was hidden by parent STARTUPINFO, unhide and show immediately!
                                ShowWindow(hwnd, 9); // SW_RESTORE
                                ShowWindow(hwnd, 5); // SW_SHOW
                                SetWindowPos(hwnd, IntPtr.Zero, 0, 0, 0, 0, 0x0043);
                                SetForegroundWindow(hwnd);
                                found = hwnd;
                                return false; // Stop enumeration
                            }
                        }
                    } catch {}
                }
                return true;
            }, IntPtr.Zero);
        } finally {
            if (switched && hOrig != IntPtr.Zero) {
                SetThreadDesktop(hOrig);
            }
        }
        return found;
    }
}
"@

try {
  Add-Type -TypeDefinition $Win32Code -ErrorAction SilentlyContinue
} catch {}

# Grant permission to set foreground window
try {
  [Win32Window]::AllowSetForegroundWindow(-1) | Out-Null
} catch {}

# 4.5. If not restarting, check if Antigravity already has an active GUI window on Default desktop
if (-not $Restart) {
  try {
    $hDesk = [Win32Window]::OpenDesktop("Default", 0, $false, 0x0041)
    if ($hDesk -ne [IntPtr]::Zero) {
      $alreadyHwnd = [Win32Window]::FindAntigravityWindow($hDesk)
      [Win32Window]::CloseDesktop($hDesk) | Out-Null
      if ($alreadyHwnd -ne [IntPtr]::Zero) {
        Write-Host "[Launch] Antigravity already running with visible window (HWND: $alreadyHwnd). Bringing to foreground..."
        if ([Win32Window]::IsIconic($alreadyHwnd)) {
          [Win32Window]::ShowWindow($alreadyHwnd, 9) | Out-Null
        }
        [Win32Window]::ShowWindow($alreadyHwnd, 5) | Out-Null
        [Win32Window]::SetWindowPos($alreadyHwnd, [IntPtr]::Zero, 0, 0, 0, 0, 0x0043) | Out-Null
        [Win32Window]::SetForegroundWindow($alreadyHwnd) | Out-Null
        exit 0
      }
    }
  } catch {}
}

# 5. Launch interactive process with visible window and anti-throttling args
if (-not (Test-Path -LiteralPath $ExePath)) {
  Write-Error "[Launch] Antigravity executable not found at $ExePath"
  exit 1
}

Write-Host "[Launch] Launching Antigravity with visible window on interactive desktop..."
$BaseArgs = @(
  '--disable-features=UseEcoQoSForBackgroundProcess',
  '--disable-renderer-backgrounding',
  '--disable-background-timer-throttling',
  '--disable-backgrounding-occluded-windows',
  '--new-window'
)
if ($WorkspacePaths -and $WorkspacePaths.Count -gt 0) {
  foreach ($w in $WorkspacePaths) {
    if (Test-Path -LiteralPath $w) {
      $BaseArgs += "`"$w`""
    }
  }
}

# Launch main instance via Windows Shell (Shell.Application COM) to ensure it runs
# under interactive explorer.exe desktop shell with SW_SHOWNORMAL (1)
$launched = $false
try {
  $shellApp = New-Object -ComObject Shell.Application
  $argStr = ($BaseArgs -join ' ')
  $shellApp.ShellExecute($ExePath, $argStr, "", "open", 1) # 1 = SW_SHOWNORMAL
  Write-Host "[Launch] Initiated launch via Shell.Application (SW_SHOWNORMAL)..."
  $launched = $true
} catch {
  Write-Host "[Launch] Shell.Application failed: $_"
}

if (-not $launched) {
  try {
    $wsh = New-Object -ComObject WScript.Shell
    $wsh.Run("`"$ExePath`" " + ($BaseArgs -join ' '), 1, $false)
    $launched = $true
    Write-Host "[Launch] Initiated launch via WScript.Shell..."
  } catch {
    Write-Host "[Launch] WScript.Shell failed: $_"
  }
}

if (-not $launched) {
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ExePath
    $psi.Arguments = ($BaseArgs -join ' ')
    $psi.UseShellExecute = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal
    [System.Diagnostics.Process]::Start($psi) | Out-Null
    Write-Host "[Launch] Initiated launch via Process::Start..."
  } catch {
    Write-Host "[Launch] Process::Start failed, falling back to explorer.exe shell launch..."
    Start-Process -FilePath "explorer.exe" -ArgumentList "`"$ExePath`""
  }
}

# 6. Wait for window and bring to foreground using compiled C# helper on Default desktop (up to 60s)
$Deadline = (Get-Date).AddSeconds(60)
$FoundHwnd = [IntPtr]::Zero

while ((Get-Date) -lt $Deadline) {
  try {
    $hDesk = [Win32Window]::OpenDesktop("Default", 0, $false, 0x0041)
    if ($hDesk -ne [IntPtr]::Zero) {
      $FoundHwnd = [Win32Window]::FindAntigravityWindow($hDesk)
      [Win32Window]::CloseDesktop($hDesk) | Out-Null
      if ($FoundHwnd -ne [IntPtr]::Zero) {
        break
      }
    }
  } catch {}
  Start-Sleep -Milliseconds 1000
}

# 7. Bring window to foreground and restore if minimized
if ($FoundHwnd -ne [IntPtr]::Zero) {
  try {
    if ([Win32Window]::IsIconic($FoundHwnd)) {
      [Win32Window]::ShowWindow($FoundHwnd, 9) | Out-Null # SW_RESTORE = 9
    }
    [Win32Window]::ShowWindow($FoundHwnd, 5) | Out-Null # SW_SHOW = 5
    [Win32Window]::SetWindowPos($FoundHwnd, [IntPtr]::Zero, 0, 0, 0, 0, 0x0043) | Out-Null # SWP_SHOWWINDOW | SWP_NOMOVE | SWP_NOSIZE
    [Win32Window]::SetForegroundWindow($FoundHwnd) | Out-Null
    Write-Host "[Launch] Antigravity successfully activated with visible window (HWND: $FoundHwnd)"
    exit 0
  } catch {}
} else {
  Write-Host "[Launch] ERROR: No visible Antigravity window detected on interactive desktop after 60s!"
  exit 1
}
