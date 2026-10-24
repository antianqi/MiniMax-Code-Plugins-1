# mcode v1 - WPF + PowerShell
# PowerShell start-island.ps1


# mcode-island runs on Windows only: the status pill is a WPF window and the
# autostart entry is a value under HKCU\Software\Microsoft\Windows\CurrentVersion\Run.
# On any other platform fail with a clear message instead of a cryptic WPF or
# registry error.
if ($env:OS -ne 'Windows_NT') {
  Write-Output 'mcode-island supports Windows only (this host is not Windows).'
  exit 1
}
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# %APPDATA%\mcode-island\widget.log 1MB
# 2026-08-22 Add-Content " 1KB "
# 38 37MB 3.6MB/ POLL
# Add-Content O(1) 1/4
# stat 400ms
$script:dbg         = Join-Path $env:APPDATA 'mcode-island\widget.log'
$script:dbgMaxBytes = 1MB
$script:dbgKeepLines = 300
$script:dbgPending  = 0
function Dbg($msg) {
  $ts = (Get-Date).ToString('HH:mm:ss.fff')
  $line = "[$ts] $msg"
  Add-Content -Path $script:dbg -Value $line -Encoding UTF8
  $script:dbgPending += $line.Length + 2
  if ($script:dbgPending -ge [int]($script:dbgMaxBytes / 4)) {
    $script:dbgPending = 0
    try {
      $fi = Get-Item -LiteralPath $script:dbg -ErrorAction Stop
      if ($fi.Length -gt $script:dbgMaxBytes) {
        $keep = @(Get-Content -LiteralPath $script:dbg -Tail $script:dbgKeepLines -Encoding UTF8)
        [System.IO.File]::WriteAllLines(
          $script:dbg, $keep, (New-Object System.Text.UTF8Encoding($false)))
      }
    } catch {
 # widget
    }
  }
}
Dbg "PID=$PID APART=$([System.Threading.Thread]::CurrentThread.ApartmentState)"

# WPF STA STA
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
  Dbg 'relaunching in STA'
  $args2 = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath) + $args
  $psi2 = New-Object System.Diagnostics.ProcessStartInfo
  $psi2.FileName = 'powershell.exe'
  $psi2.Arguments = $args2 -join ' '
  $psi2.UseShellExecute = $false
  $psi2.CreateNoWindow = $true
  [void][System.Diagnostics.Process]::Start($psi2)
  exit
}

# Start-Process
# GetConsoleWindow() 0 ShowWindow no-op
Dbg 'hiding any stray console window'
$hideSig = @'
using System;
using System.Runtime.InteropServices;
public class IslandHide {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
}
'@
if (-not ('IslandHide' -as [type])) { Add-Type $hideSig -ErrorAction SilentlyContinue }
$hwnd = [IslandHide]::GetConsoleWindow()
if ($hwnd -ne [IntPtr]::Zero) {
  [void][IslandHide]::ShowWindow($hwnd, 0)  # SW_HIDE
}

# WPF
Dbg 'loading WPF assemblies'
try {
  Add-Type -AssemblyName PresentationFramework
  Add-Type -AssemblyName PresentationCore
  Add-Type -AssemblyName WindowsBase
  Add-Type -AssemblyName System.Xaml
  Dbg 'WPF loaded'
} catch {
  Dbg "WPF LOAD FAIL: $($_.Exception.Message)"
  throw
}

# P/Invoke mcode
Dbg 'loading WinAPI'
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinAPI {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(uint dwProcessId);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT pt);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint dwFlags);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool GetMonitorInfoW(IntPtr hMonitor, ref MONITORINFO lpmi);
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)]
  public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct MONITORINFO {
    public int cbSize;
    public RECT rcMonitor;
    public RECT rcWork;
    public uint dwFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
  }
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
  public static readonly IntPtr HWND_TOP = new IntPtr(0);
  public const uint SWP_NOACTIVATE = 0x0010;
  public const uint SWP_NOZORDER = 0x0004;
  public const uint SWP_NOSIZE = 0x0001;
  public const uint SWP_NOMOVE = 0x0002;
  public const uint MONITOR_DEFAULTTONEAREST = 0x00000002;
  public const uint SWP_SHOWWINDOW = 0x0040;

 // True when a window owned by another process sits on top of the pill's centre
 // pixel. Menus / tooltips / tray balloons are exempt so we never fight
 // transient UI that is supposed to be above the pill anyway.
  public static bool IsPillCovered(IntPtr self) {
    RECT r;
    if (!GetWindowRect(self, out r)) return false;
    var pt = new POINT { X = (r.Left + r.Right) / 2, Y = (r.Top + r.Bottom) / 2 };
    IntPtr hit = WindowFromPoint(pt);
    if (hit == IntPtr.Zero || hit == self) return false;
    var sb = new System.Text.StringBuilder(256);
    GetClassNameW(hit, sb, 256);
    string cls = sb.ToString();
    if (cls.StartsWith("#32768")) return false;           // menu / tooltip
    if (cls == "NotifyIconTooltipWindow") return false;  // tray balloon
    if (cls == "Windows.UI.Core.CoreWindow") return false;
    uint p;
    GetWindowThreadProcessId(hit, out p);
    return p != (uint)System.Diagnostics.Process.GetCurrentProcess().Id;
  }

 // monitor work area (-1,-1)-(-1,-1)
  public static RECT GetWorkAreaForWindow(IntPtr hWnd) {
    var bad = new RECT { Left = -1, Top = -1, Right = -1, Bottom = -1 };
    IntPtr hMon = MonitorFromWindow(hWnd, MONITOR_DEFAULTTONEAREST);
    if (hMon == IntPtr.Zero) return bad;
    var mi = new MONITORINFO();
    mi.cbSize = System.Runtime.InteropServices.Marshal.SizeOf(mi);
    if (!GetMonitorInfoW(hMon, ref mi)) return bad;
    return mi.rcWork;
  }

 // pid
  public static IntPtr FindVisibleWindowForPid(uint targetPid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p == targetPid && IsWindowVisible(h)) {
        int len = GetWindowTextLength(h);
        if (len > 0) { found = h; return false; }
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
"@ -ErrorAction SilentlyContinue
Dbg 'WinAPI loaded'

$configDir = Join-Path $env:APPDATA 'mcode-island'
if (!(Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
$configFile = Join-Path $configDir 'config.json'
$statusFile = Join-Path $configDir 'status.json'
$logFile    = Join-Path $configDir 'island.log'

$defaultConfig = [PSCustomObject]@{
  x        = -1
  y        = -1
  width    = 320
  height   = 70
  opacity  = 0.95
  autostart = $false
}
if (Test-Path $configFile) {
  try { $cfg = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json }
  catch { $cfg = $defaultConfig }
  foreach ($p in @('x','y','width','height','opacity','autostart')) {
    if (-not (Get-Member -InputObject $cfg -Name $p -ErrorAction SilentlyContinue)) {
      Add-Member -InputObject $cfg -NotePropertyName $p -NotePropertyValue $defaultConfig.$p
    }
  }
} else {
  $cfg = $defaultConfig
  $cfg | ConvertTo-Json | Out-File -FilePath $configFile -Encoding UTF8
}

# XAML pill
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="mcode-island" Width="320" Height="60"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        WindowStartupLocation="Manual" UseLayoutRounding="True" SnapsToDevicePixels="True"
        Focusable="False" ShowActivated="False">
  <Grid>
    <Grid.RowDefinitions>
      <!-- row 0   config   height   70  -->
      <RowDefinition x:Name="PillRow" Height="70"/>
      <!-- row 1   session   0 -->
      <RowDefinition x:Name="SessionListRow" Height="0"/>
    </Grid.RowDefinitions>
  <Border x:Name="Pill" Grid.Row="0" CornerRadius="30"
          Background="#CC1A1A20" BorderBrush="#33FFFFFF" BorderThickness="1"
          Padding="22,6" Margin="0">
    <Border.Effect>
      <DropShadowEffect Color="Black" Opacity="0.45" BlurRadius="22" ShadowDepth="3"/>
    </Border.Effect>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>

      <Grid Grid.Column="0" Width="22" Height="22" Margin="0,0,14,0">
        <Ellipse x:Name="PulseRing" Width="22" Height="22" Fill="#FF6B7280" Opacity="0.0">
          <Ellipse.RenderTransform>
            <ScaleTransform x:Name="PulseScale" ScaleX="1" ScaleY="1"/>
          </Ellipse.RenderTransform>
          <Ellipse.RenderTransformOrigin>0.5,0.5</Ellipse.RenderTransformOrigin>
        </Ellipse>
        <Ellipse x:Name="StatusDot" Width="12" Height="12"
                 HorizontalAlignment="Center" VerticalAlignment="Center"
                 Fill="#FF6B7280"/>
      </Grid>

      <StackPanel Grid.Column="1" VerticalAlignment="Center">
        <!--   state   elapsed  5h  -->
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock Grid.Column="0" x:Name="StateText" Text="mcode"
                     Foreground="#FFF5F5F7" FontSize="14" FontWeight="SemiBold"
                     TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
          <TextBlock Grid.Column="1" x:Name="ElapsedText" Text=""
                     Foreground="#FF6B7280" FontSize="11"
                     VerticalAlignment="Center" Margin="8,0,0,0"
                     FontFamily="Consolas, Segoe UI"/>
          <!-- 5h usage badge: filled in by the detector, -1 means unknown -->
          <TextBlock Grid.Column="2" x:Name="Usage5hText" Text=""
                     Foreground="#FF6B7280" FontSize="11"
                     VerticalAlignment="Center" Margin="8,0,0,0"
                     FontFamily="Consolas, Segoe UI"
                     ToolTip="mmx 5h usage"/>
        </Grid>
        <TextBlock x:Name="MessageText" Text="Waiting for task"
                   Foreground="#FF9A9AA3" FontSize="11" Margin="0,1,0,0"
                   TextTrimming="CharacterEllipsis" MaxWidth="240"/>
        <!--  
             - progress=0..100 determinate  ProgressFill ScaleX  bright cyan  
             - progress=-1   state   active indeterminate  ProgressIndeterminate  cyan  
             -   -->
        <Grid x:Name="ProgressBar" Height="8" Margin="0,2,0,0" Visibility="Collapsed">
          <Border Background="#44FFFFFF" CornerRadius="4"/>
          <Border x:Name="ProgressFill" Background="#FF22D3EE" CornerRadius="4"
                  HorizontalAlignment="Stretch" Visibility="Collapsed">
            <Border.RenderTransform>
              <ScaleTransform x:Name="ProgressScale" ScaleX="0" ScaleY="1"/>
            </Border.RenderTransform>
            <Border.RenderTransformOrigin>0,0.5</Border.RenderTransformOrigin>
          </Border>
          <Grid x:Name="ProgressIndeterminate" Visibility="Collapsed" ClipToBounds="True">
            <Rectangle x:Name="ProgressShimmer" Width="130" HorizontalAlignment="Left"
                       Fill="#FF22D3EE">
              <Rectangle.OpacityMask>
                <LinearGradientBrush StartPoint="0,0.5" EndPoint="1,0.5">
                  <GradientStop Color="#00000000" Offset="0"/>
                  <GradientStop Color="#FF000000" Offset="0.5"/>
                  <GradientStop Color="#00000000" Offset="1"/>
                </LinearGradientBrush>
              </Rectangle.OpacityMask>
              <Rectangle.RenderTransform>
                <TranslateTransform x:Name="ProgressShimmerTransform" X="-130"/>
              </Rectangle.RenderTransform>
            </Rectangle>
          </Grid>
        </Grid>
      </StackPanel>

      <TextBlock Grid.Column="2" x:Name="ActionIcon" Text=""
                 Foreground="#FF9A9AA3" FontSize="13" Margin="14,0,0,0"
                 VerticalAlignment="Center"/>
    </Grid>
  </Border>

  <!--
    session   pill   HWND 
         WindowFromPoint  
     1053   39  
      pill  
     

     row 0  
     
  -->
  <Border x:Name="SessionPanel" Grid.Row="1" Visibility="Collapsed"
          CornerRadius="12" Background="#F21A1A20" BorderBrush="#33FFFFFF"
          BorderThickness="1" Padding="10,6" Margin="0,14,0,0">
    <StackPanel x:Name="SessionRows"/>
  </Border>
  </Grid>
</Window>
'@

# XAML
Dbg 'parsing XAML'
try {
  $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
  $window = [Windows.Markup.XamlReader]::Load($reader)
  Dbg 'XAML loaded'
} catch {
  Dbg "XAML FAIL: $($_.Exception.Message)"
  throw
}

$statusDot     = $window.FindName('StatusDot')
$pulseRing     = $window.FindName('PulseRing')
$pulseScale    = $window.FindName('PulseScale')
$stateText     = $window.FindName('StateText')
$messageText   = $window.FindName('MessageText')
$actionIcon    = $window.FindName('ActionIcon')
$pill          = $window.FindName('Pill')
$progressBar          = $window.FindName('ProgressBar')
$progressFill         = $window.FindName('ProgressFill')
$progressScale        = $window.FindName('ProgressScale')
$progressIndeterminate = $window.FindName('ProgressIndeterminate')
$progressShimmer      = $window.FindName('ProgressShimmer')
$progressShimmerTransform = $window.FindName('ProgressShimmerTransform')
$elapsedText          = $window.FindName('ElapsedText')
$usage5hText          = $window.FindName('Usage5hText')
# session pill
$script:sessionRowsPanel = $window.FindName('SessionPanel')
$script:sessionRows      = $window.FindName('SessionRows')
$script:sessionListRow  = $window.FindName('SessionListRow')
$script:pillHeight      = 70
$script:listHideTimer   = $null

$stateMap = @{
  idle     = @{ dot='#FF6B7280'; ring='#FF6B7280'; label='mcode';             icon='' }
  thinking = @{ dot='#FFEAB308'; ring='#FFEAB308'; label='mcode - thinking';     icon='' }
  working  = @{ dot='#FF3B82F6'; ring='#FF3B82F6'; label='mcode - working';     icon='*' }
  waiting  = @{ dot='#FFF59E0B'; ring='#FFF59E0B'; label='mcode - waiting';  icon='?' }
  done     = @{ dot='#FF22C55E'; ring='#FF22C55E'; label='mcode - done';     icon='+' }
  error    = @{ dot='#FFEF4444'; ring='#FFEF4444'; label='mcode - error';       icon='x' }
}

# session v0.5.0
# session + +
# / = ack.signal detector
# session mcode --session <id>
# WPF Popup
# - Popup HWND owner always-on-top pill
# Assert-Topmost Popup
# - Topmost=True / ShowActivated=False
# - pill XAML
# pill pill HWND
# session v0.5.0
# session +
# + / = ack.signal detector
# session mcode --session <id>
# pill
# WindowFromPoint 1053
# 39
# widget
# pill
# row 0

function Read-SessionsFile {
  $file = Join-Path $configDir 'sessions.json'
  if (!(Test-Path -LiteralPath $file)) { return @() }
  try {
    $raw = [System.IO.File]::ReadAllText($file)
    $j = $raw | ConvertFrom-Json
    return @($j.sessions)
  } catch {
    return @()
  }
}

function Clear-SessionRows {
  if (-not $script:sessionRows) { return }
  $script:sessionRows.Children.Clear()
}

# + 7px 48px
# Show-SessionList
# 12.5px 17 + 11px 15 + 2
# + 14 + 1 = 49 48
$script:sessionRowHeight = 48

# 60 "3 "
# HH:mm "3 " "13:09"
function Format-RelativeTime([int64]$tsMs) {
  if ($tsMs -le 0) { return '' }
  $diff = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $tsMs
  if ($diff -lt 0) { $diff = 0 }
  if ($diff -lt 60000) { return 'just now' }
  if ($diff -lt 3600000) { return ([int][math]::Floor($diff / 60000)).ToString() + ' min ago' }
  $t = [DateTimeOffset]::FromUnixTimeMilliseconds($tsMs).ToLocalTime()
  return $t.ToString('HH:mm')
}

# [ ] 3
function Add-SessionRow([string]$id, [string]$title, [string]$phase, [string]$preview, [string]$lastTool, [int64]$lastAtMs, [bool]$isLast) {
  if (-not $script:sessionRows) { return }
 # pill working/thinking/waiting/idle/done/error
 # pill
 # running/waiting/stopped pill
 # " " " " pill " "
 # "running" sessions.json
  $stateTextMap = @{
    'working'  = @{ text = 'Running';   dot = '#FF3B82F6' }
    'thinking' = @{ text = 'Thinking';   dot = '#FFEAB308' }
    'waiting'  = @{ text = 'Waiting for approval'; dot = '#FFF59E0B' }
    'idle'     = @{ text = 'Awaiting reply';   dot = '#FF6B7280' }
    'done'     = @{ text = 'Done';   dot = '#FF22C55E' }
    'error'    = @{ text = 'Error';     dot = '#FFEF4444' }
    'stopped'  = @{ text = 'Stopped';   dot = '#FF4B5563' }
    'running'  = @{ text = 'Running';   dot = '#FF3B82F6' }
  }
  $stateInfo = $stateTextMap[[string]$phase]
  if (-not $stateInfo) { $stateInfo = $stateTextMap['idle'] }
  $dotHex = $stateInfo.dot
  $phaseText = $stateInfo.text

 # toolCall "
  $subText = ''
  if ($preview) { $subText = $preview }
  elseif ($lastTool) { $subText = 'Running ' + $lastTool }
  if ($subText.Length -gt 48) { $subText = $subText.Substring(0, 48) + '...' }

  $grid = New-Object System.Windows.Controls.Grid
  $grid.Cursor = [System.Windows.Input.Cursor]::Hand

 # * TextTrimming
  $colDot = New-Object System.Windows.Controls.ColumnDefinition
  $colDot.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
  $colTitle = New-Object System.Windows.Controls.ColumnDefinition
  $colTitle.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
  $colTag = New-Object System.Windows.Controls.ColumnDefinition
  $colTag.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
  $grid.ColumnDefinitions.Add($colDot) | Out-Null
  $grid.ColumnDefinitions.Add($colTitle) | Out-Null
  $grid.ColumnDefinitions.Add($colTag) | Out-Null

  $rowTop = New-Object System.Windows.Controls.RowDefinition
  $rowTop.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
  $rowBot = New-Object System.Windows.Controls.RowDefinition
  $rowBot.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
  $grid.RowDefinitions.Add($rowTop) | Out-Null
  $grid.RowDefinitions.Add($rowBot) | Out-Null

  $dot = New-Object System.Windows.Shapes.Ellipse
  $dot.Width = 7; $dot.Height = 7
  $dot.Fill = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($dotHex)))
  $dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $dot.Margin = New-Object System.Windows.Thickness(0,0,9,0)

  $txt = New-Object System.Windows.Controls.TextBlock
  $txt.Text = if ($title) { $title } else { $id }
  $txt.Foreground = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#FFF5F5F7')))
  $txt.FontSize = 12.5
  $txt.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
  $txt.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

  $sub = New-Object System.Windows.Controls.TextBlock
  $sub.Text = $subText
  $sub.Foreground = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#FF8B93A1')))
  $sub.FontSize = 11
  $sub.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
  $sub.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $sub.Margin = New-Object System.Windows.Thickness(0,2,0,0)

  $right = New-Object System.Windows.Controls.StackPanel
  $right.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $right.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
  $right.Margin = New-Object System.Windows.Thickness(8,0,0,0)

  $time = New-Object System.Windows.Controls.TextBlock
  $time.Text = (Format-RelativeTime $lastAtMs)
  $time.Foreground = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#FF9CA3AF')))
  $time.FontSize = 10
  $time.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right

  $tag = New-Object System.Windows.Controls.TextBlock
  $tag.Text = $phaseText
  $tag.Foreground = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($dotHex)))
  $tag.FontSize = 10
  $tag.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right

  $right.Children.Add($time) | Out-Null
  $right.Children.Add($tag) | Out-Null

  $grid.Children.Add($dot)   | Out-Null
  $grid.Children.Add($txt)   | Out-Null
  $grid.Children.Add($right) | Out-Null
  $grid.Children.Add($sub)   | Out-Null
  [System.Windows.Controls.Grid]::SetColumn($dot, 0)
  [System.Windows.Controls.Grid]::SetColumn($txt, 1)
  [System.Windows.Controls.Grid]::SetColumn($right, 2)
  [System.Windows.Controls.Grid]::SetColumn($sub, 1)
  [System.Windows.Controls.Grid]::SetRow($dot, 0)
  [System.Windows.Controls.Grid]::SetRow($txt, 0)
  [System.Windows.Controls.Grid]::SetRow($right, 0)
  [System.Windows.Controls.Grid]::SetRow($sub, 1)
  $dot.SetValue([System.Windows.Controls.Grid]::RowSpanProperty, 2)
  $right.SetValue([System.Windows.Controls.Grid]::RowSpanProperty, 2)

  $border = New-Object System.Windows.Controls.Border
  $border.BorderBrush = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#1FFFFFFF')))
  $border.BorderThickness = $(if ($isLast) { New-Object System.Windows.Thickness(0) } else { New-Object System.Windows.Thickness(0,0,0,1) })
  $border.Padding = New-Object System.Windows.Thickness(0,7,0,7)
  $border.Child = $grid

  $tip = if ($title) { $title } else { $id }
  if ($subText) { $tip = $tip + "`n" + $subText }
  $rel = Format-RelativeTime $lastAtMs
  if ($rel) { $tip = $tip + "`n" + $phaseText + ' - ' + $rel } else { $tip = $tip + "`n" + $phaseText }
  $border.ToolTip = $tip

 # Border
 # MouseLeftButtonDown Border + Grid + TextBlock
 # handler
 # Handled=true MouseLeftButtonDown
  $border.Add_MouseLeftButtonDown({
    $args[1].Handled = $true
    Invoke-SessionClick $id
  }.GetNewClosure())

  $script:sessionRows.Children.Add($border) | Out-Null
}

function Show-SessionList {
  if (-not $script:sessionRows) { return }
 # MouseEnter MouseEnter
 # MouseMove " 300ms "
  if ($script:listHideTimer) {
    try { $script:listHideTimer.Stop() } catch {}
    $script:listHideTimer = $null
  }
  $items = Read-SessionsFile
  if (-not $items -or $items.Count -eq 0) { Hide-SessionList; return }
  Clear-SessionRows
 # lastAtMs sinceMs
  $stateOrder = @{
    'working' = 0; 'thinking' = 0; 'waiting' = 1; 'idle' = 2
    'done' = 3; 'error' = 4; 'stopped' = 5; 'running' = 0
  }
  $sorted = @($items | Sort-Object @{ Expression = { $k = [string]$_.phase; if ($stateOrder.ContainsKey($k)) { $stateOrder[$k] } else { 2 } } }, @{ Expression = { if ($_.lastAtMs) { [int64]$_.lastAtMs } else { [int64]$_.sinceMs } }; Descending = $true })
  $i = 0
  foreach ($s in $sorted) {
    Add-SessionRow ([string]$s.id) ([string]$s.title) ([string]$s.phase) ([string]$s.preview) ([string]$s.lastTool) ([int64]$s.lastAtMs) ($i -lt ($sorted.Count - 1))
    $i++
  }
 # SessionPanel
 # Margin 14 + Padding 12 + Border 2 106px row
 # 94px 14px
 # row 1 Auto Grid
 # DesiredSize " "
  $script:sessionRowsPanel.Visibility = [System.Windows.Visibility]::Visible
  $script:sessionListRow.Height = [System.Windows.GridLength]::Auto
  $script:sessionRowsPanel.UpdateLayout()
 # DesiredSize Margin SessionPanel 14px
  $listH = [int][Math]::Ceiling($script:sessionRowsPanel.DesiredSize.Height) + 14
  if ($listH -le 0) { $listH = ($sorted.Count * $script:sessionRowHeight) + 26 }
  $window.Height = $script:pillHeight + $listH
  Dbg ("session list shown: " + $sorted.Count + " winH=" + $window.Height + " listH=" + $listH)
}

function Hide-SessionList {
  if ($script:listHideTimer) {
    try { $script:listHideTimer.Stop() } catch {}
    $script:listHideTimer = $null
  }
  if ($script:sessionRowsPanel) {
    $script:sessionRowsPanel.Visibility = [System.Windows.Visibility]::Collapsed
  }
  if ($script:sessionListRow) {
    $script:sessionListRow.Height = New-Object System.Windows.GridLength(0)
  }
  if ($window) { $window.Height = $script:pillHeight }
}

function Schedule-SessionListHide {
  if (-not $script:sessionRowsPanel) { return }
  if ($script:listHideTimer) { try { $script:listHideTimer.Stop() } catch {} }
  $script:listHideTimer = New-Object System.Windows.Threading.DispatcherTimer
  $script:listHideTimer.Interval = [TimeSpan]::FromMilliseconds(300)
  $script:listHideTimer.Add_Tick({
    try { $script:listHideTimer.Stop() } catch {}
    Hide-SessionList
  })
  $script:listHideTimer.Start()
}

function Invoke-SessionClick([string]$id) {
  if (-not $id) { return }
 # ack.signal detector
 # session
  try {
    $ackFile = Join-Path $configDir 'ack.signal'
    [System.IO.File]::WriteAllText($ackFile, $id, [System.Text.Encoding]::UTF8)
    Dbg "session ack written: $id"
  } catch {
    Dbg "SESSION ACK FAIL: $($_.Exception.Message)"
  }
  Hide-SessionList
 # " tab"
 # mcode --session <id>
  $names = @()
  $cur = ''
  try {
    foreach ($s in @(Read-SessionsFile)) {
      if ([string]$s.id -eq $id) {
        if ($s.title) { $cur = [string]$s.title }
        $names = @(@($s.titles) | Where-Object { $_ })
        break
      }
    }
  } catch {}
 # tab ** ** app ** **
  if ($cur) { $names = @($cur) + @($names | Where-Object { $_ -and $_ -ne $cur }) }
  if ($names.Count -eq 0 -and $cur) { $names = @($cur) }
  if (Select-SessionTerminal $names) {
    Dbg ("session terminal switched: " + $id + " foregroundPid=" + (Get-ForegroundPid))
    return
  }
 # app app
  if (Switch-ToAppConversation $names) {
    Dbg ("app conversation switched: " + $id + " foregroundPid=" + (Get-ForegroundPid))
    return
  }
  if ($script:clickPrefers -eq 'app') {
 # app app app
    if (Activate-AppWindow) {
      Dbg ("app window activated (conversation not matched): " + $id)
      return
    }
  } else {
 # CLI " " " "
    if (Activate-TerminalWindow) {
      Dbg ("session terminal activated (tab not matched): " + $id + " foregroundPid=" + (Get-ForegroundPid))
      return
    }
  }
 # app
  Start-SessionTerminal $id
}

# app
# app " false"
function Get-AppConversationButton([IntPtr]$hwnd, [string]$name) {
  if (-not $name) { return $null }
  try {
    if (-not $script:uiaReady) {
      Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
      Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
      $script:uiaReady = $true
    }
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
    if (-not $root) { return $null }
 # 2000 500ms
 # UI 47ms
    $cond = New-Object System.Windows.Automation.AndCondition(
      (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, $name)),
      (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button)))
    $hits = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
    for ($i = 0; $i -lt $hits.Count; $i++) {
      try {
        $el = $hits.Item($i)
 # Invoke Invoke
        $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern) | Out-Null
        return $el
      } catch { continue }
    }
  } catch {
    Dbg ("APP CONVERSATION LOOKUP FAIL: " + $_.Exception.Message)
  }
  return $null
}

# app
# app Button
# UIA Invoke app Windows
# Terminal SelectionItemPattern.Select
# deep link app minimax-cn://
# action navigate URL 275
# /minimax-desktop/api/v1/... API " " URL
# false app
function Switch-ToAppConversation([string[]]$names) {
  if (-not $names -or $names.Count -eq 0) { return $false }
  $app = Find-DesktopAppWindow
  if (-not $app) { return $false }
 # UIA 47ms
  $tried = 0
  foreach ($n in $names) {
    if ($tried -ge 4) { break }
    $nn = ([string]$n).Trim()
    if (-not $nn) { continue }
    $tried++
    $el = Get-AppConversationButton ([IntPtr]$app.Hwnd) $nn
    if (-not $el) { continue }
    try {
      $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
      Dbg ("app conversation switched: " + $nn)
      return $true
    } catch {
      Dbg ("APP CONVERSATION INVOKE FAIL: " + $_.Exception.Message)
      return $false
    }
  }
  return $false
}

# app
function Activate-AppWindow {
  $app = Find-DesktopAppWindow
  if (-not $app) { return $false }
  Focus-Window -Target @{ Hwnd = $app.Hwnd; Pid = $app.Pid; Exe = $app.Exe }
  return $true
}

# tab
# pid Windows Terminal XAML
# pid WindowsTerminal.exe
function Get-ForegroundPid {
  try {
    $fg = [WinAPI]::GetForegroundWindow()
    if ($fg -eq [IntPtr]::Zero) { return 0 }
 # $pid PowerShell $PID
 # "Cannot overwrite variable PID"
 # catch " 0"
 # $HOME
    $procId = [uint32]0
    [void][WinAPI]::GetWindowThreadProcessId($fg, [ref]$procId)
    return [int]$procId
  } catch { return 0 }
}

# SetForegroundWindow ** **
# pid pid
# "switched" " "
function Test-ForegroundPid([uint32]$procId) {
  $fg = Get-ForegroundPid
  if ($fg -eq [int]$procId) { return $true }
  Dbg ("FOCUS CHECK: want pid=" + $procId + " foregroundPid=" + $fg)
  return $false
}

# pill " / "
# TOPMOST NOTOPMOST BringWindowToTop
# SetForegroundWindow
# SetForegroundWindow Windows
# tab
function Focus-TerminalWindow([IntPtr]$h) {
  if (-not $h -or $h -eq [IntPtr]::Zero) { return $false }
  try {
 # $pid $PID
 # catch " "
    $procId = [uint32]0
    [void][WinAPI]::GetWindowThreadProcessId($h, [ref]$procId)
 # Focus-Window SW_RESTORE "
 # " 0x0 -> WT min-size ->
 # 480x84 (0,0)
    Show-WindowFullScreen $h | Out-Null
    Focus-Window -Target @{ Hwnd = $h; Pid = $procId; Exe = 'WindowsTerminal' }
    if (Test-ForegroundPid $procId) {
      Dbg ("FOCUS CONFIRMED: pid=" + $procId + " hwnd=" + $h)
      return $true
    }
 # pill
 # Focus-Window SetWindowPos SWP_NOACTIVATE z-order
 # pill Toggle-Window SetWindowPos(HWND_TOP)
 # ** ** SWP_NOACTIVATE " "
 # SWP_NOSIZE / SWP_NOMOVE " 0x0 + (0,0)"
    $flags = [WinAPI]::SWP_NOSIZE -bor [WinAPI]::SWP_NOMOVE
    [WinAPI]::SetWindowPos($h, [WinAPI]::HWND_TOP, 0, 0, 0, 0, $flags) | Out-Null
    [WinAPI]::BringWindowToTop($h) | Out-Null
    [WinAPI]::SetForegroundWindow($h) | Out-Null
    if (Test-ForegroundPid $procId) {
      Dbg ("FOCUS CONFIRMED (z-order): pid=" + $procId + " hwnd=" + $h)
      return $true
    }
    Dbg ("FOCUS NOT CONFIRMED: want pid=" + $procId + " foregroundPid=" + (Get-ForegroundPid))
    return $false
  } catch {
    Dbg ("FOCUS FAIL: " + $_.Exception.Message)
    return $false
  }
}

# tab
# mcode tab
# "mcode --session <id>"
# Windows Terminal tab "< > | < > | MCode"
# mcode ANSI OSC 0 Win32 SetForegroundWindow
# ** ** tab tab UI Automation tab
# tab
# tab mcode ** **
# SQLite
# Windows Terminal app
$script:uiaReady = $false

function Select-SessionTerminal([string[]]$names) {
  if (-not $names -or $names.Count -eq 0) { return $false }
  try {
    if (-not $script:uiaReady) {
      Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
      Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
      $script:uiaReady = $true
    }
    if (-not ('IslandNative' -as [type])) {
 # here-string here-string
      Add-Type -Namespace IslandNative -Name Win -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);' -ErrorAction Stop
    }
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $winCond = New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'CASCADIA_HOSTING_WINDOW_CLASS')
    $wins = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $winCond)
    $tabCond = New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::TabItem)
    foreach ($w in $wins) {
      $tabs = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tabCond)
      for ($t = 0; $t -lt $tabs.Count; $t++) {
        $tab = $tabs.Item($t)
        $title = [string]$tab.Current.Name
        if (-not $title) { continue }
 # "< > | < > | MCode" ->
        $parts = @($title -split '\|')
        $tabName = ''
        if ($parts.Count -ge 3) { $tabName = $parts[1].Trim() } else { $tabName = $title.Trim() }
        $hit = $false
        foreach ($n in $names) {
          if (-not $n) { continue }
          $nn = ([string]$n).Trim()
          if (-not $nn) { continue }
          if ($tabName -eq $nn -or $title.Contains($nn)) { $hit = $true; break }
        }
        if (-not $hit) { continue }
        try {
          $sp = $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
          $sp.Select()
        } catch { continue }
 # tab SetForegroundWindow
 # Windows tab
 # pill TOPMOST NOTOPMOST
 # BringWindowToTop SetForegroundWindow
 # tab ** **
        if (-not (Focus-TerminalWindow ([IntPtr]$w.Current.NativeWindowHandle))) {
          Dbg ("session tab selected but foreground not confirmed: " + ($names -join ' | '))
        }
        return $true
      }
    }
  } catch {
 # UI Automation Windows Terminal
  }
  return $false
}

# tab
# mcode
function Activate-TerminalWindow {
  try {
    if (-not $script:uiaReady) {
      Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
      Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
      $script:uiaReady = $true
    }
    if (-not ('IslandNative' -as [type])) {
      Add-Type -Namespace IslandNative -Name Win -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);' -ErrorAction Stop
    }
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $winCond = New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'CASCADIA_HOSTING_WINDOW_CLASS')
    $tabCond = New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::TabItem)
    foreach ($w in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $winCond)) {
 # mcode tab "< > | < > | MCode"
      $hasMcode = $false
      $tabs = $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tabCond)
      for ($i = 0; $i -lt $tabs.Count; $i++) {
        if ([string]$tabs.Item($i).Current.Name -match '\|\s*MCode\s*$') { $hasMcode = $true; break }
      }
      if (-not $hasMcode) { continue }
      try {
 # " " ** ** $false
 # $false
        Focus-TerminalWindow ([IntPtr]$w.Current.NativeWindowHandle) | Out-Null
        return $true
      } catch {}
    }
  } catch {
  }
  return $false
}

# session mcode --session <id>
# Windows Terminal wt.exe PATH conhost start
# mcode .ps1 cmd powershell
function Start-SessionTerminal([string]$id) {
  $inner = "mcode --session $id"
  try {
    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    if ($wt) {
      Start-Process -FilePath $wt.Source -ArgumentList @(
        '-w', '0', 'new-tab', '--title', 'mcode',
        'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $inner)
    } else {
      Start-Process -FilePath 'cmd.exe' -ArgumentList @(
        '/c', 'start', '', 'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $inner)
    }
    Dbg "session jumped: $id"
  } catch {
    Dbg "SESSION JUMP FAIL: $($_.Exception.Message)"
  }
}

# working family state " " " "
# dot/ring stateText
# family detector $TOOL_FAMILIES family state
# (shell) / (read) / (write) / (search) / (task) /
# (web) / (plan) plan #8B5CF6 search #A855F7
# pill
$familyMap = @{
  shell  = '#FF22C55E' # bash / shell
  read   = '#FF3B82F6' # read
  write  = '#FFEAB308' # edit / write
  search = '#FFA855F7' # grep / glob
  task   = '#FF06B6D4' # task
  web    = '#FFEC4899' # web_search/fetch
  plan   = '#FF94A3B8' # todowrite
}

# brush
function C($hex) { return (New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.ColorConverter]::ConvertFromString($hex))) }

$hasPulse = $false
$storyboard = $null
function Start-Pulse {
  if ($script:hasPulse) { return }
  $script:hasPulse = $true
  $animX = New-Object System.Windows.Media.Animation.DoubleAnimation
  $animX.From = 1.0; $animX.To = 1.9
  $animX.Duration = [TimeSpan]::FromSeconds(1.0)
  $animX.AutoReverse = $true
  $animX.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
  [System.Windows.Media.Animation.Storyboard]::SetTarget($animX, $script:pulseScale)
  [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($animX, (New-Object System.Windows.PropertyPath('ScaleX')))
  $animY = New-Object System.Windows.Media.Animation.DoubleAnimation
  $animY.From = 1.0; $animY.To = 1.9
  $animY.Duration = [TimeSpan]::FromSeconds(1.0)
  $animY.AutoReverse = $true
  $animY.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
  [System.Windows.Media.Animation.Storyboard]::SetTarget($animY, $script:pulseScale)
  [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($animY, (New-Object System.Windows.PropertyPath('ScaleY')))

  $opacityAnim = New-Object System.Windows.Media.Animation.DoubleAnimation
  $opacityAnim.From = 0.55; $opacityAnim.To = 0.0
  $opacityAnim.Duration = [TimeSpan]::FromSeconds(1.0)
  $opacityAnim.AutoReverse = $true
  $opacityAnim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
  [System.Windows.Media.Animation.Storyboard]::SetTarget($opacityAnim, $script:pulseRing)
  [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($opacityAnim, (New-Object System.Windows.PropertyPath('Opacity')))

  $sb = New-Object System.Windows.Media.Animation.Storyboard
  $sb.Children.Add($animX) | Out-Null
  $sb.Children.Add($animY) | Out-Null
  $sb.Children.Add($opacityAnim) | Out-Null
  $script:storyboard = $sb
  $sb.Begin($window)
}
function Stop-Pulse {
  $script:hasPulse = $false
  if ($script:storyboard) { $script:storyboard.Stop($window) }
  $script:pulseScale.ScaleX = 1.0
  $script:pulseScale.ScaleY = 1.0
  $script:pulseRing.Opacity = 0.0
}

# Elapsed timer active thinking/working/waiting
# state state progress " "
$script:elapsedStopwatch = New-Object System.Diagnostics.Stopwatch
$script:elapsedStopwatch.Reset()
$script:elapsedActive = $false
$script:elapsedLastState = $null

function Format-Elapsed([TimeSpan]$t) {
  if ($t.TotalSeconds -lt 60) {
    return ("{0}s" -f [int]$t.TotalSeconds)
  } elseif ($t.TotalMinutes -lt 60) {
    return ("{0}m {1:D2}s" -f [int]$t.TotalMinutes, $t.Seconds)
  } else {
    return ("{0}h {1:D2}m" -f [int]$t.TotalHours, $t.Minutes)
  }
}

# 5h ms "4h31m" / "12m"
# PowerShell [int] cast [int]2.76 3
# [Math]::Floor [Math]::Truncate
function Format-ResetMs([int]$ms) {
  if ($ms -le 0) { return '0m' }
  $totalSec = [int][Math]::Floor($ms / 1000)
  $h = [int][Math]::Floor($totalSec / 3600)
  $m = [int][Math]::Floor(($totalSec % 3600) / 60)
  if ($h -gt 0) { return ("{0}h{1:D2}m" -f $h, $m) }
  else { return ("{0}m" -f $m) }
}

$script:elapsedTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:elapsedTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:elapsedTimer.Add_Tick({
  if (-not $script:elapsedActive) { return }
  $script:elapsedText.Text = Format-Elapsed $script:elapsedStopwatch.Elapsed
})
Dbg 'elapsed timer started (paused)'

# Indeterminate shimmer 130px 1.5s
# 240 = StackPanel 320 - 44 padding - 36 left icon - 20 right icon
$script:shimmerStoryboard = $null
function Start-IndeterminateShimmer {
  if ($script:shimmerStoryboard) { return }
  $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
  $anim.From = -130
  $anim.To = 240
  $anim.Duration = [TimeSpan]::FromSeconds(1.5)
  $anim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
  [System.Windows.Media.Animation.Storyboard]::SetTarget($anim, $script:progressShimmerTransform)
  [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($anim, (New-Object System.Windows.PropertyPath('X')))
  $sb = New-Object System.Windows.Media.Animation.Storyboard
  $sb.Children.Add($anim) | Out-Null
  $script:shimmerStoryboard = $sb
  $sb.Begin()
  Dbg 'shimmer started'
}
function Stop-IndeterminateShimmer {
  if ($script:shimmerStoryboard) {
    $script:shimmerStoryboard.Stop()
    $script:shimmerStoryboard = $null
    Dbg 'shimmer stopped'
  }
  $script:progressShimmerTransform.X = -130
}

# Sub-step "step N[/M] detail"
# Step > 0 + Total > 0 "step 3/12 fill username"
# Step > 0 + Total <= 0 "step 3 fill username"
# Step > 0 + Detail "step 3/12"
# Step <= 0 Message
# message " "("Bash ok"),detail ,
# "step 3/12 Bash ok fill username"
# "step 3/12 fill username"(detail message)
# detail ** ** message, ("Bash ok ls -la")
function Build-DisplayMessage {
  param(
    [string]$Message,
    [int]$Step,
    [int]$Total,
    [string]$Detail
  )
  $base = if ($Message) { $Message } else { '' }
  if ($Step -le 0) { return $base }

  $stepStr = if ($Total -gt 0) { "step $Step/$Total" } else { "step $Step" }
  if ($Detail) {
 # detail detail(agent " ")
    return "$stepStr - $Detail"
  }
 # detail step step, message
  return $stepStr
}

# Progress notify-island.ps1 / detector
# -1
# 0..100 0= 100= clamp
# Usage5h 0..100 -2 =
# Usage5hResetMs 5h 0 =
# TodoProgress todowrite 0..100 -2 =
# Step/Total/Detail sub-step agent Build-DisplayMessage
# - Progress > TodoProgress > shimmer
# - agent progress todo todo shimmer
# -1
# 0..100 0= 100= clamp
# Usage5h 0..100 -2 =
# Usage5hResetMs 5h 0 =
# TodoProgress todowrite 0..100 -2 =
# - Progress > TodoProgress > shimmer
# - agent progress todo todo shimmer
function Update-State {
  param(
    [string]$State,
    [string]$Message,
    [int]$Progress = -1,
    [int]$Usage5h = -2,
    [int]$Usage5hResetMs = 0,
    [int]$TodoProgress = -2,
    [int]$Step = -1,
    [int]$Total = -1,
    [string]$Detail = '',
    [string]$Family = ''
  )
  $s = $script:stateMap[$State]
  if (!$s) { $s = $script:stateMap['idle'] }
 # active thinking/working/waiting done / error
  $dotHex  = $s.dot
  $ringHex = $s.ring
  if ($Family -and $State -in @('thinking','working','waiting')) {
    $famHex = $script:familyMap[$Family]
    if ($famHex) { $dotHex = $famHex; $ringHex = $famHex }
  }
  $script:statusDot.Fill = C $dotHex
  $script:pulseRing.Fill = C $ringHex
  $script:stateText.Text = $s.label
  $script:messageText.Text = Build-DisplayMessage -Message $Message -Step $Step -Total $Total -Detail $Detail
  $script:actionIcon.Text = $s.icon

  if ($State -in @('thinking','working','waiting')) { Start-Pulse } else { Stop-Pulse }

 # + % "4h31m 84%" " "
 # < 20% 20-50% >= 50%
  $hasTime = $Usage5hResetMs -gt 0
  $hasPct  = $Usage5h -ge 0 -and $Usage5h -le 100
  if ($hasTime -or $hasPct) {
    $parts = @()
    if ($hasTime) { $parts += (Format-ResetMs $Usage5hResetMs) }
    if ($hasPct)  { $parts += ("{0}%" -f [int]$Usage5h) }
    $script:usage5hText.Text = $parts -join ' '
    $col = if ($Usage5h -ge 50) { '#FF6B7280' } # >= 50%
           elseif ($Usage5h -ge 20) { '#FFEAB308' } # 20-50%
           else { '#FFEF4444' } # < 20%
    $script:usage5hText.Foreground = C $col
  } else {
    $script:usage5hText.Text = ''
    $script:usage5hText.Foreground = C '#FF6B7280'
  }

 # Elapsed timer active / state active
  $isActive = $State -in @('thinking','working','waiting')
  if ($isActive) {
    if ($State -ne $script:elapsedLastState) {
      $script:elapsedStopwatch.Restart()
      $script:elapsedLastState = $State
    }
    $script:elapsedActive = $true
    $script:elapsedText.Text = Format-Elapsed $script:elapsedStopwatch.Elapsed
  } else {
    $script:elapsedActive = $false
    $script:elapsedStopwatch.Reset()
    $script:elapsedLastState = $State
    $script:elapsedText.Text = ''
  }

 # - active + progress 0..100 determinate Progress
 # - active + todoProgress 0..100 determinate TodoProgress
 # - active + indeterminate shimmer
 # - active
  $clamped = [Math]::Max(0, [Math]::Min(100, $Progress))
  $todoClamped = [Math]::Max(0, [Math]::Min(100, $TodoProgress))
  $isActive = $State -in @('thinking','working','waiting')
  $explicitProgress = ($Progress -ge 0 -and $Progress -le 100)
  $hasTodoProgress  = ($TodoProgress -ge 0 -and $TodoProgress -le 100)
  if ($isActive -and $explicitProgress) {
    $script:progressBar.Visibility = 'Visible'
    $script:progressFill.Visibility = 'Visible'
    $script:progressIndeterminate.Visibility = 'Collapsed'
    $script:progressScale.ScaleX = $clamped / 100.0
    $script:progressFill.Background = C $dotHex
    Stop-IndeterminateShimmer
  } elseif ($isActive -and $hasTodoProgress) {
    $script:progressBar.Visibility = 'Visible'
    $script:progressFill.Visibility = 'Visible'
    $script:progressIndeterminate.Visibility = 'Collapsed'
    $script:progressScale.ScaleX = $todoClamped / 100.0
    $script:progressFill.Background = C $dotHex
    Stop-IndeterminateShimmer
  } elseif ($isActive) {
    $script:progressBar.Visibility = 'Visible'
    $script:progressFill.Visibility = 'Collapsed'
    $script:progressIndeterminate.Visibility = 'Visible'
    $script:progressShimmer.Fill = C $dotHex
    $script:progressScale.ScaleX = 0
    Start-IndeterminateShimmer
  } else {
    $script:progressBar.Visibility = 'Collapsed'
    $script:progressFill.Visibility = 'Collapsed'
    $script:progressIndeterminate.Visibility = 'Collapsed'
    $script:progressScale.ScaleX = 0
    Stop-IndeterminateShimmer
  }

 # log
  $ts = (Get-Date).ToString('HH:mm:ss')
  $progTag = if ($Progress -ge 0) { " [$Progress%]" } else { '' }
  "[$ts] $State :: $Message$progTag" | Add-Content -Path $script:logFile -Encoding UTF8
}

# caller.json targetHwnd / targetPid
# hwnd / fallback terminal /
# hwnd [PSCustomObject]@{ Hwnd; Pid; Exe } $null
function Resolve-CallerWindow {
  $callerFile = Join-Path $env:APPDATA 'mcode-island\caller.json'
  if (!(Test-Path $callerFile)) { Dbg 'RESOLVE: no caller file'; return $null }

  $hwnd = [IntPtr]::Zero
  $targetPid = 0
  $targetExe = ''
  $targetSource = ''
  try {
    $data = Get-Content $callerFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $hwnd = [IntPtr]::new([int64]$data.targetHwnd)
    $targetPid = [int]$data.targetPid
    $targetExe = if ($data.targetExe) { [string]$data.targetExe } else { '' }
    $targetSource = if ($data.source) { [string]$data.source } else { '' }
  } catch {
    Dbg "RESOLVE: caller.json parse error"
    return $null
  }
  if ($targetPid -le 0) { Dbg 'RESOLVE: no target'; return $null }

 # 1) hwnd
  if ($hwnd -ne [IntPtr]::Zero -and -not [WinAPI]::IsWindow($hwnd)) {
    Dbg "RESOLVE: hwnd $hwnd dead, re-resolving"
    $hwnd = [IntPtr]::Zero
  }

 # 2) fallback terminal
  $proc = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
  if (-not $proc) {
    Dbg "RESOLVE: target PID $targetPid gone, finding parent (terminal)"
    $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$targetPid" -ErrorAction SilentlyContinue
    if ($parent -and $parent.ParentProcessId -and $parent.ParentProcessId -gt 0) {
      $parentProc = Get-Process -Id ([int]$parent.ParentProcessId) -ErrorAction SilentlyContinue
      if ($parentProc) {
        $targetPid = $parentProc.Id
        $targetExe = $parentProc.ProcessName
        $targetSource = 'parent-fallback'
        if ($parentProc.MainWindowHandle -ne [IntPtr]::Zero) {
          $hwnd = $parentProc.MainWindowHandle
        } else {
          $hwnd = [WinAPI]::FindVisibleWindowForPid([uint32]$targetPid)
        }
        Dbg "RESOLVE: fall back to parent $($parentProc.ProcessName) PID=$targetPid hwnd=$hwnd"
      }
    }
    if ($hwnd -eq [IntPtr]::Zero) {
      Dbg 'RESOLVE: no parent fallback available'
      return $null
    }
  }

 # 3) hwnd /
  if ($hwnd -eq [IntPtr]::Zero -or -not [WinAPI]::IsWindow($hwnd)) {
    Dbg "RESOLVE: hwnd invalid, finding new visible window for PID $targetPid ($targetExe)"
    $hwnd = [WinAPI]::FindVisibleWindowForPid([uint32]$targetPid)
    if ($hwnd -eq [IntPtr]::Zero) {
      Dbg 'RESOLVE: no visible window found for target process'
      return $null
    }
    Dbg "RESOLVE: re-resolved to hwnd $hwnd"
  }

  return [PSCustomObject]@{ Hwnd = $hwnd; Pid = $targetPid; Exe = $targetExe; Source = $targetSource }
}

# Click target resolution.
# In the desktop app (MiniMax Inside Code / MiniMax Code / Mavis) the agent
# is hosted by the app and runs in a terminal the app opened. That terminal
# belongs to the app session, so "hide the terminal" is meaningless there:
# the agent keeps running behind a static pill. "Take me back to the app
# window" is the action that matches the intent.
# The click target is therefore resolved in this order:
# 1. a manual pin (pin.json) -- the user named the target explicitly, so it
# wins. A CLI user pins their terminal and it stays the target even
# while the desktop app is open.
# 2. the desktop app main window -- found through a process-name allowlist
# and focused, never hidden.
# 3. the caller's terminal (caller.json) -- without the desktop app the
# original show/hide toggle is kept.

# Process-name allowlist of the desktop app. The app is not an ancestor of
# the agent process (the agent runs in a terminal the app opened), so the
# process tree cannot be used to locate it.
$script:desktopAppNames = @('MiniMax Inside Code', 'MiniMax Code', 'Mavis')

# Read pin.json: the click target the user pinned by hand.
# pin.json is separate from caller.json -- caller.json is rewritten by the
# agent side on every state transition, so a pin stored there would not
# survive the next notify and priority 1 would be unreachable.
function Resolve-PinnedWindow {
  $pinFile = Join-Path $env:APPDATA 'mcode-island\pin.json'
  if (!(Test-Path $pinFile)) { return $null }

  $hwnd = [IntPtr]::Zero
  $targetPid = 0
  $targetExe = ''
  try {
    $data = Get-Content $pinFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $hwnd = [IntPtr]::new([int64]$data.targetHwnd)
    $targetPid = [int]$data.targetPid
    $targetExe = if ($data.targetExe) { [string]$data.targetExe } else { '' }
  } catch {
    Dbg 'PIN: pin.json parse error'
    return $null
  }
  if ($targetPid -le 0) { return $null }

 # the hwnd died (window destroyed or recreated) -> find it again by pid
  if ($hwnd -eq [IntPtr]::Zero -or -not [WinAPI]::IsWindow($hwnd)) {
    $hwnd = [WinAPI]::FindVisibleWindowForPid([uint32]$targetPid)
  }
  if ($hwnd -eq [IntPtr]::Zero) {
    Dbg "PIN: pinned PID $targetPid is gone"
    return $null
  }
  return [PSCustomObject]@{ Hwnd = $hwnd; Pid = $targetPid; Exe = $targetExe }
}

# Find the desktop app main window: a process in the same session whose name
# hits the allowlist and that owns a main window. The app is an Electron
# multi-process (main + renderer + GPU + utility); only the main process
# reports a non-zero MainWindowHandle.
function Find-DesktopAppWindow {
  $mySession = (Get-Process -Id $PID).SessionId
  $cands = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $script:desktopAppNames -contains $_.ProcessName -and $_.SessionId -eq $mySession
  })
  if ($cands.Count -eq 0) { Dbg 'APP: no desktop app process'; return $null }

  foreach ($p in $cands) {
    if ($p.MainWindowHandle -ne [IntPtr]::Zero) {
      Dbg "APP: desktop app $($p.ProcessName) PID=$($p.Id) hwnd=$($p.MainWindowHandle)"
      return [PSCustomObject]@{ Hwnd = $p.MainWindowHandle; Pid = $p.Id; Exe = $p.ProcessName }
    }
  }
 # The main process reports no MainWindowHandle (some Electron builds) ->
 # enumerate the visible windows as a fallback.
  foreach ($p in $cands) {
    $h = [WinAPI]::FindVisibleWindowForPid([uint32]$p.Id)
    if ($h -ne [IntPtr]::Zero) {
      Dbg "APP: desktop app $($p.ProcessName) PID=$($p.Id) hwnd=$h (enumerated)"
      return [PSCustomObject]@{ Hwnd = $h; Pid = $p.Id; Exe = $p.ProcessName }
    }
  }
  Dbg 'APP: desktop app process has no visible window'
  return $null
}

# Which target a click prefers when both are available.
# 'terminal' -- the caller's terminal first. The CLI habit: one click
# hides it, the next brings it back.
# 'app' -- the desktop app window first. The Marketplace build ships
# this one: in the desktop app the agent is hosted by the
# app and the terminal belongs to the app session, so hiding
# that terminal leaves a static pill behind.
# The Marketplace package is built with 'app'. The builder flips this one
# line and FAILS the build when it cannot find it, so a renamed switch can
# never silently ship the CLI behaviour to the desktop users.
$script:clickPrefers = 'app'

# Resolve the click target. Mode = focus (raise and activate only) /
# toggle (show / hide).
function Resolve-ClickTarget {
 # 1) the manual pin -- the user's explicit choice, it always wins
  $pin = Resolve-PinnedWindow
  if ($pin) {
    return [PSCustomObject]@{ Hwnd = $pin.Hwnd; Pid = $pin.Pid; Exe = $pin.Exe; Mode = 'focus'; Origin = 'pin' }
  }
 # 2) the preferred target, then the other one
  if ($script:clickPrefers -eq 'app') {
    $app = Find-DesktopAppWindow
    if ($app) {
      return [PSCustomObject]@{ Hwnd = $app.Hwnd; Pid = $app.Pid; Exe = $app.Exe; Mode = 'focus'; Origin = 'desktop-app' }
    }
    $caller = Resolve-CallerWindow
    if ($caller) {
      return [PSCustomObject]@{ Hwnd = $caller.Hwnd; Pid = $caller.Pid; Exe = $caller.Exe; Mode = 'toggle'; Origin = 'caller' }
    }
  } else {
    $caller = Resolve-CallerWindow
    if ($caller) {
      return [PSCustomObject]@{ Hwnd = $caller.Hwnd; Pid = $caller.Pid; Exe = $caller.Exe; Mode = 'toggle'; Origin = 'caller' }
    }
    $app = Find-DesktopAppWindow
    if ($app) {
      return [PSCustomObject]@{ Hwnd = $app.Hwnd; Pid = $app.Pid; Exe = $app.Exe; Mode = 'focus'; Origin = 'desktop-app' }
    }
  }
  return $null
}

# work area
# SW_RESTORE " "
# Focus-Window cx=0/cy=0 SetWindowPos
# 0x0 Windows Terminal min-size 480x84
# (0,0)
# work area
function Show-WindowFullScreen([IntPtr]$h) {
  try {
    $wa = [WinAPI]::GetWorkAreaForWindow($h)
    if ($wa.Left -eq -1) { return $null }
    $cx = $wa.Right - $wa.Left
    $cy = $wa.Bottom - $wa.Top
 # 1) SW_RESTORE / " "
 # 2) SetWindowPos work area
 # " " work area
 # 3) SW_MAXIMIZE
 # 2 ** ** SetWindowPos Windows
 # 0x0 480x84
 # WT
 # SetWindowPlacement WT rcNormalPosition
 # 0x0
    [WinAPI]::ShowWindow($h, 9) | Out-Null                      # SW_RESTORE
    [WinAPI]::SetWindowPos($h, [IntPtr]::Zero, $wa.Left, $wa.Top, $cx, $cy, [WinAPI]::SWP_NOZORDER) | Out-Null
    [WinAPI]::ShowWindow($h, 3) | Out-Null                      # SW_MAXIMIZE
    return @{ Left = $wa.Left; Top = $wa.Top; W = $cx; H = $cy }
  } catch {
    return $null
  }
}

# Raise a window to the front: show + focus, whatever its current visible
# state is. After the desktop-app adaptation both focus and toggle take a
# resolved target object; the caller decides which one it is.
function Focus-Window {
  param([Parameter(Mandatory = $true)]$Target)

  try {
    [WinAPI]::AllowSetForegroundWindow([uint32]$Target.Pid) | Out-Null
 # minimized -> SW_RESTORE
 # hidden -> SW_SHOW
 # SW_SHOW
    if ([WinAPI]::IsIconic($Target.Hwnd)) {
      [WinAPI]::ShowWindow($Target.Hwnd, 9) | Out-Null   # SW_RESTORE
    } elseif (-not [WinAPI]::IsWindowVisible($Target.Hwnd)) {
      [WinAPI]::ShowWindow($Target.Hwnd, 5) | Out-Null   # SW_SHOW
    }
 # TOPMOST -> NOTOPMOST: it lets BringWindowToTop push the window all the
 # way up without leaving a "always on top" side effect behind.
 # SWP_NOSIZE / SWP_NOMOVE cx=0/cy=0/
 # X=0/Y=0 " " ** flag
 # ** SWP_NOSIZE Windows "resize 0x0"
 # Windows Terminal min-size 480x84
 # SWP_NOMOVE (0,0)
 # Toggle-Window Focus-Window
    $nofollow = [WinAPI]::SWP_NOACTIVATE -bor [WinAPI]::SWP_NOSIZE -bor [WinAPI]::SWP_NOMOVE
    [WinAPI]::SetWindowPos($Target.Hwnd, [WinAPI]::HWND_TOPMOST, 0, 0, 0, 0, $nofollow) | Out-Null
    [WinAPI]::SetWindowPos($Target.Hwnd, [IntPtr]::new(-2), 0, 0, 0, 0, $nofollow) | Out-Null  # HWND_NOTOPMOST
    [WinAPI]::BringWindowToTop($Target.Hwnd) | Out-Null
    [WinAPI]::SetForegroundWindow($Target.Hwnd) | Out-Null
 # "DONE" "OK"
 # Test-ForegroundPid
    Dbg ("FOCUS DONE: target=" + $Target.Exe + " PID=" + $Target.Pid + " hwnd=" + $Target.Hwnd)
  } catch {
    Dbg "FOCUS FAIL: $($_.Exception.Message)"
  }
}

# needs_input
function Focus-CallerWindow {
  $r = Resolve-CallerWindow
  if (-not $r) { return }
  Focus-Window $r
}

# pill toggle +
# (round-14+15+16):
# hide SW_HIDE ( SW_MINIMIZE)
# SW_MINIMIZE (Windows Terminal "Always show tabs on top")
# thin tab-bar strip , " "
# show SW_MAXIMIZE ( + ), SetWindowPos
# MonitorFromWindow+GetMonitorInfo work area(2560x1392
# [Screen]::PrimaryScreen 1920x1080 WinForms DPI
# 2560x1440 1920x1080 ,SW_MAXIMIZE
# 1920x1080 , WT 75%)
# SetWindowPos(HWND_TOP) + BringWindowToTop z-order,
# widget PID foreground
# : IsWindowVisible SW_HIDE SW_MINIMIZE false
# ( IsIconic:SW_HIDE false,SW_MINIMIZE true) toggle
# IsWindowVisible ,SW_MAXIMIZE case
function Toggle-Window {
  param([Parameter(Mandatory = $true)]$Target)

  try {
    $isShown = [WinAPI]::IsWindowVisible($Target.Hwnd)
    if ($isShown) {
      [WinAPI]::ShowWindow($Target.Hwnd, 0) | Out-Null   # SW_HIDE
      Dbg "TOGGLE: hid target=$($Target.Exe) PID=$($Target.Pid) hwnd=$($Target.Hwnd)"
    } else {
 # 1)+2) SW_MAXIMIZE + maximized SetWindowPos
 # monitor work area DPI/remembered-size
 # Show-WindowFullScreen
      $wa = Show-WindowFullScreen $Target.Hwnd
      if ($wa) {
 # The -f has to sit inside the parentheses: written as
 # `Dbg "..." -f a, b` the format operator binds to the command, not to
 # the string, and the log line keeps the raw {0} {1} placeholders.
        Dbg ("TOGGLE: forced to work area ({0},{1}) {2}x{3}" -f $wa.Left, $wa.Top, $wa.W, $wa.H)
      }
 # 3) z-order (SetWindowPos(HWND_TOP) foreground )
 # SWP_NOSIZE cx=0/cy=0 Windows "resize 0x0"
 # WT min-size 480x76 strip
 # SWP_NOMOVE X=0/Y=0 (0,0)
 # monitor 0
 # SWP_NOZORDER flag hWndInsertAfter
 # HWND_TOP BringWindowToTop
      [WinAPI]::AllowSetForegroundWindow([uint32]$Target.Pid) | Out-Null
      $nofollow = [WinAPI]::SWP_NOACTIVATE -bor [WinAPI]::SWP_NOSIZE -bor [WinAPI]::SWP_NOMOVE
      [WinAPI]::SetWindowPos($Target.Hwnd, [WinAPI]::HWND_TOP, 0, 0, 0, 0, $nofollow) | Out-Null
      [WinAPI]::BringWindowToTop($Target.Hwnd) | Out-Null
      [WinAPI]::SetForegroundWindow($Target.Hwnd) | Out-Null
      Dbg "TOGGLE: shown (maximized + work-area) target=$($Target.Exe) PID=$($Target.Pid) hwnd=$($Target.Hwnd)"
    }
  } catch {
    Dbg "TOGGLE FAIL: $($_.Exception.Message)"
  }
}

function Toggle-CallerWindow {
  $r = Resolve-CallerWindow
  if (-not $r) { return }
  Toggle-Window $r
}

# The single entry point for a pill click: resolve the target, then run the
# mode it resolved to. focus (manual pin / desktop app) and toggle (the
# caller's terminal) are two different semantics -- do not mix them.
function Invoke-ClickTarget {
  $t = Resolve-ClickTarget
  if (-not $t) { Dbg 'CLICK: no target resolved'; return }
  Dbg "CLICK: target=$($t.Exe) PID=$($t.Pid) hwnd=$($t.Hwnd) mode=$($t.Mode) origin=$($t.Origin)"
  if ($t.Mode -eq 'focus') {
    Focus-Window $t
  } else {
    Toggle-Window $t
  }
}

# focus target
function Set-FocusTarget-Current {
  Add-Type @"
using System;
using System.Runtime.InteropServices;
public class FG2 {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
}
"@ -ErrorAction SilentlyContinue
  $hwnd = [FG2]::GetForegroundWindow()
  if ($hwnd -eq [IntPtr]::Zero) { Dbg 'PIN: no foreground'; return }
  $ownerPid = 0
  [FG2]::GetWindowThreadProcessId($hwnd, [ref]$ownerPid) | Out-Null
  $proc = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
  if (-not $proc) { Dbg 'PIN: target process gone'; return }
  $myPid = [int](Get-Process -Id $PID).Id
  $mySession = (Get-Process -Id $myPid).SessionId
 # Write pin.json, not caller.json: a pin is the user's explicit choice and
 # must not be wiped by the agent-side caller.json on every transition.
  $pinFile = Join-Path $env:APPDATA 'mcode-island\pin.json'
  $payload = [PSCustomObject]@{
    callerPid = $myPid
    callerSession = $mySession
    targetPid = $proc.Id
    targetHwnd = [int64]$hwnd
    targetTitle = $proc.MainWindowTitle
    targetExe = $proc.ProcessName
    source = 'manual-pin'
    ts = (Get-Date).ToString('o')
  } | ConvertTo-Json -Compress
  [System.IO.File]::WriteAllText($pinFile, $payload, [System.Text.Encoding]::UTF8)
  Dbg ("PIN: target=" + $proc.ProcessName + " PID=" + $proc.Id + " hwnd=" + $hwnd)
}

# scale 1.0 -> 0.95 -> 1.0
function Flash-Click {
  $sb = New-Object System.Windows.Media.Animation.Storyboard
  $sx = New-Object System.Windows.Media.Animation.DoubleAnimation
  $sx.From = 1.0; $sx.To = 0.95; $sx.Duration = [TimeSpan]::FromMilliseconds(80)
  $sx.AutoReverse = $true
  [System.Windows.Media.Animation.Storyboard]::SetTarget($sx, $script:pill)
  [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($sx, (New-Object System.Windows.PropertyPath '(UIElement.RenderTransform).(ScaleTransform.ScaleX)'))
 # transient transform
  $sy = New-Object System.Windows.Media.Animation.DoubleAnimation
  $sy.From = 1.0; $sy.To = 0.95; $sy.Duration = [TimeSpan]::FromMilliseconds(80)
  $sy.AutoReverse = $true
  [System.Windows.Media.Animation.Storyboard]::SetTarget($sy, $script:pill)
  [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($sy, (New-Object System.Windows.PropertyPath '(UIElement.RenderTransform).(ScaleTransform.ScaleY)'))
  $sb.Children.Add($sx) | Out-Null
  $sb.Children.Add($sy) | Out-Null
  $sb.Begin($window)
}

# Keep the pill above everything else.
# Why this exists: the only thing that ever made the pill topmost is
# Topmost="True" in the XAML, evaluated once at window creation. Every other
# SetWindowPos in this file targets the *caller* window, not the pill. So once
# anything else lands above the pill -- a maximized terminal being activated, a
# fullscreen app, another always-on-top tool -- the pill stays buried forever.
# WS_EX_TOPMOST is a persistent style but only orders the pill against the
# topmost band; whichever topmost window was raised last wins, and a plain
# maximized window that got re-shown can end up painting over it too.
# Observed 2026-09-28: pill fully invisible behind Windows Terminal while
# IsWindowVisible=1, IsIconic=0, DWMWA_CLOAKED=0, widget still polling.
# Fix: hit-test the pill centre on a throttle and re-assert HWND_TOPMOST when
# something else owns that pixel. SWP_NOACTIVATE means this never steals focus
# from the user's terminal. Skipped entirely while the pill is hidden so it
# cannot undo a user-initiated hide. "mcode-island show" passes -Force because
# $window.Show() is a no-op on an already-visible WPF window and therefore
# never restored z-order on its own.
$script:lastTopmostCheck = [DateTime]::MinValue
function Assert-Topmost {
  param([switch]$Force)
  if (-not $Force -and
      [DateTime]::UtcNow - $script:lastTopmostCheck -lt [TimeSpan]::FromMilliseconds(1500)) {
    return
  }
  $script:lastTopmostCheck = [DateTime]::UtcNow
  try {
    $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
    $h = $helper.Handle
    if (-not $h -or -not [WinAPI]::IsWindow($h)) { return }
 # Never resurrect a pill the user hid.
    if (-not [WinAPI]::IsWindowVisible($h)) { return }
    if ($Force -or [WinAPI]::IsPillCovered($h)) {
      $flags = [WinAPI]::SWP_NOACTIVATE -bor [WinAPI]::SWP_NOMOVE -bor `
               [WinAPI]::SWP_NOSIZE -bor [WinAPI]::SWP_SHOWWINDOW
      [WinAPI]::SetWindowPos($h, [WinAPI]::HWND_TOPMOST, 0, 0, 0, 0, $flags) | Out-Null
      Dbg "TOPMOST: re-raised (forced=$([bool]$Force))"
    }
  } catch {
    Dbg "TOPMOST FAIL: $($_.Exception.Message)"
  }
}

$screen = [System.Windows.SystemParameters]::WorkArea
if ($cfg.x -lt 0) {
  $window.Left = [Math]::Floor(($screen.Width - $cfg.width) / 2) + $screen.Left
  $window.Top  = $screen.Top + 14
} else {
  $window.Left = $cfg.x
  $window.Top  = $cfg.y
}
$window.Width  = $cfg.width
$window.Height = $cfg.height
# row 0 session
$script:pillHeight = $window.Height
try {
  $pillRow = $window.FindName('PillRow')
  if ($pillRow) { $pillRow.Height = New-Object System.Windows.GridLength($script:pillHeight) }
} catch {}
$window.Opacity = $cfg.opacity

# CLI 'mcode-island pin'
$window.Add_MouseRightButtonDown({
  $null = $_.Handled
  Dbg 'RIGHT-CLICK ignored, use "mcode-island pin" in mcode terminal'
})

# vs
# DragMove()
# DragMove() SendMessage(WM_SYSCOMMAND, SC_MOVE) Win32
# WPF DWM
# AllowsTransparency=True per-pixel alpha
# 320x60
# DropShadowEffect
# Left/Top WPF
# DragMove()
# pill
# MouseMove GetPosition($window)
# 0 delta
# PointToScreen DPI Left/Top DIP
$script:dragStart = $null
$script:didDrag = $false
$script:dragOriginLeft = 0.0
$script:dragOriginTop = 0.0
$script:dragAnchorX = 0.0
$script:dragAnchorY = 0.0
$script:pill.RenderTransform = New-Object System.Windows.Media.ScaleTransform(1, 1)
$script:pill.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)

# -> DIP PointToScreen Window.Left/Top
# 100%
function Get-DragScale {
  $sx = 1.0
  $sy = 1.0
  try {
    $src = [System.Windows.PresentationSource]::FromVisual($window)
    if ($src -and $src.CompositionTarget) {
      $m = $src.CompositionTarget.TransformToDevice
      if ($m.M11 -gt 0) { $sx = [double]$m.M11 }
      if ($m.M22 -gt 0) { $sy = [double]$m.M22 }
    }
  } catch {}
  return @{ X = $sx; Y = $sy }
}

$window.Add_MouseLeftButtonDown({
  $script:dragStart = $_.GetPosition($window)
  $script:didDrag = $false
  $script:dragOriginLeft = $window.Left
  $script:dragOriginTop = $window.Top
  try {
    $anchor = $window.PointToScreen($script:dragStart)
    $script:dragAnchorX = $anchor.X
    $script:dragAnchorY = $anchor.Y
  } catch {
    $script:dragAnchorX = $script:dragStart.X
    $script:dragAnchorY = $script:dragStart.Y
  }
 # 320x60 MouseMove " "
  try { $window.CaptureMouse() } catch {}
})
$window.Add_MouseMove({
 # MouseEnter " " widget
 # MouseEnter
 # dragStart
  if ($null -eq $script:dragStart -and $script:sessionRowsPanel -and
      $script:sessionRowsPanel.Visibility -ne [System.Windows.Visibility]::Visible) {
    try { Show-SessionList } catch { Dbg "SESSION LIST SHOW FAIL: $($_.Exception.Message)" }
  }
  if ($null -eq $script:dragStart) { return }
 # The position is read EVERY event, not only before the threshold is
 # crossed: the window is moving, so a position read during an earlier
 # event is stale relative to where the window is now.
  $cur = $_.GetPosition($window)
 # The threshold gates the START of the drag, not the movement. The
 # previous guard returned as soon as didDrag was set, so the pill
 # followed the cursor for exactly one event and then stopped --
 # measured at 14% of the cursor movement.
  if (-not $script:didDrag) {
    $dx = [Math]::Abs($cur.X - $script:dragStart.X)
    $dy = [Math]::Abs($cur.Y - $script:dragStart.Y)
    if ($dx + $dy -le 5) { return }
    $script:didDrag = $true
  }
  try {
    $now = $window.PointToScreen($cur)
    $scale = Get-DragScale
    $window.Left = $script:dragOriginLeft + (($now.X - $script:dragAnchorX) / $scale.X)
    $window.Top  = $script:dragOriginTop  + (($now.Y - $script:dragAnchorY) / $scale.Y)
  } catch {
    Dbg "DRAG FAIL: $($_.Exception.Message)"
  }
})
$window.Add_MouseLeftButtonUp({
  try { $window.ReleaseMouseCapture() } catch {}
  try {
    if ($script:dragStart -and -not $script:didDrag) {
      Dbg 'CLICK detected'
      Flash-Click
      Invoke-ClickTarget
    }
  } catch {
    Dbg "CLICK FAIL: $($_.Exception.Message)"
  }
  $script:dragStart = $null
  $script:didDrag = $false
})

# session /
# pill -> ->
# pill " "
$window.Add_MouseEnter({
  if ($script:listHideTimer) { try { $script:listHideTimer.Stop() } catch {} ; $script:listHideTimer = $null }
  try { Show-SessionList } catch { Dbg "SESSION LIST SHOW FAIL: $($_.Exception.Message)" }
})
$window.Add_MouseLeave({
  Schedule-SessionListHide
})


# FileSystemWatcher status.json FSW WPF
$script:lastStatusMtime = $null
$script:lastStatusSig = $null
$showSignalFile = Join-Path $configDir 'show.signal'
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(400)
$timer.Add_Tick({
 # 0) 1.5s
  Assert-Topmost
 # 1) "show" "mcode-island show"
  if (Test-Path $showSignalFile) {
    try { Remove-Item $showSignalFile -Force -ErrorAction SilentlyContinue } catch {}
    $window.Dispatcher.Invoke([Action]{
      $window.Show()
      $window.WindowState = [System.Windows.WindowState]::Normal
      $window.Activate()
      Assert-Topmost -Force
      Dbg 'SHOWN via signal file'
    })
  }
 # 2) status.json
  if (!(Test-Path $statusFile)) { return }
  try {
    $fi = Get-Item $statusFile
    $mtime = $fi.LastWriteTimeUtc.Ticks
    if ($mtime -eq $script:lastStatusMtime) { return }
    $script:lastStatusMtime = $mtime
    $data = Get-Content $statusFile -Raw -Encoding UTF8 | ConvertFrom-Json
 # progress sig agent working+ message+ progress
 # step/total/detail sig, state step
    $prog = if ($data.PSObject.Properties['progress']) { [int]$data.progress } else { -1 }
    $usage = $null
    $resetMs = 0
    $todoP = -2
    $step = -1
    $total = -1
    $detail = ''
    if ($data.PSObject.Properties['usage5h'] -and $null -ne $data.usage5h) { $usage = [int]$data.usage5h }
    if ($data.PSObject.Properties['usage5hResetMs'] -and $null -ne $data.usage5hResetMs) { $resetMs = [int]$data.usage5hResetMs }
    if ($data.PSObject.Properties['todoProgress'] -and $null -ne $data.todoProgress) { $todoP = [int]$data.todoProgress }
    if ($data.PSObject.Properties['step'] -and $null -ne $data.step) { $step = [int]$data.step }
    if ($data.PSObject.Properties['total'] -and $null -ne $data.total) { $total = [int]$data.total }
    if ($data.PSObject.Properties['detail'] -and $null -ne $data.detail) { $detail = [string]$data.detail }
 # family sig working
    $family = ''
    if ($data.PSObject.Properties['family'] -and $data.family) { $family = [string]$data.family }
    $sig = "$($data.state)|$($data.message)|$family|$prog|$usage|$resetMs|$todoP|$step|$total|$detail|$($data.ts)"
    if ($sig -eq $script:lastStatusSig) { return }
    $script:lastStatusSig = $sig
    Dbg "POLL: $($data.state) :: $($data.message) family=$family step=$step/$total detail=$detail (progress=$prog usage5h=$usage resetMs=$resetMs todoProgress=$todoP)"
    Update-State -State $data.state -Message $data.message -Progress $prog -Usage5h $usage -Usage5hResetMs $resetMs -TodoProgress $todoP -Step $step -Total $total -Detail $detail -Family $family
  } catch {
    Dbg "POLL ERR: $($_.Exception.Message)"
  }
})
$timer.Start()
$script:elapsedTimer.Start()
Dbg 'poll timer + elapsed timer started'

# status.json
if (Test-Path $statusFile) {
  try {
    $init = Get-Content $statusFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $initProg = if ($init.PSObject.Properties['progress']) { [int]$init.progress } else { -1 }
    $initUsage = $null
    $initReset = 0
    $initTodo = -2
    $initStep = -1
    $initTotal = -1
    $initDetail = ''
    if ($init.PSObject.Properties['usage5h'] -and $null -ne $init.usage5h) { $initUsage = [int]$init.usage5h }
    if ($init.PSObject.Properties['usage5hResetMs'] -and $null -ne $init.usage5hResetMs) { $initReset = [int]$init.usage5hResetMs }
    if ($init.PSObject.Properties['todoProgress'] -and $null -ne $init.todoProgress) { $initTodo = [int]$init.todoProgress }
    if ($init.PSObject.Properties['step'] -and $null -ne $init.step) { $initStep = [int]$init.step }
    if ($init.PSObject.Properties['total'] -and $null -ne $init.total) { $initTotal = [int]$init.total }
    if ($init.PSObject.Properties['detail'] -and $null -ne $init.detail) { $initDetail = [string]$init.detail }
    $initFamily = ''
    if ($init.PSObject.Properties['family'] -and $init.family) { $initFamily = [string]$init.family }
    $script:lastStatusSig = "$($init.state)|$($init.message)|$initFamily|$initProg|$initUsage|$initReset|$initTodo|$initStep|$initTotal|$initDetail|$($init.ts)"
    $script:lastStatusMtime = (Get-Item $statusFile).LastWriteTimeUtc.Ticks
    Update-State -State $init.state -Message $init.message -Progress $initProg -Usage5h $initUsage -Usage5hResetMs $initReset -TodoProgress $initTodo -Step $initStep -Total $initTotal -Detail $initDetail -Family $initFamily
  } catch {}
} else {
  Update-State -State 'idle' -Message ''
}
Dbg 'initial state set'


$script:realQuit = $false
$window.Add_Closing({
  $args[1].Cancel = $true
  Dbg 'Closing event -> hide'
 # pill
  try { Hide-SessionList } catch {}
  try {
    $cur = Get-Content $script:configFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $cur.x = $window.Left
    $cur.y = $window.Top
    $cur | ConvertTo-Json | Out-File -Path $script:configFile -Encoding UTF8
  } catch {}
  $window.Hide()
})
# Application.Run Show + Hide + Show
Dbg 'starting Application.Run'
$app = New-Object System.Windows.Application
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$app.Run($window) | Out-Null
Dbg 'Application.Run returned'

# Application.Run pump hide Run
# mcode-island stop app.Shutdown()

Dbg 'realQuit set, exiting'
