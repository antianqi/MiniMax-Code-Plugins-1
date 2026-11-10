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
 # CopyFromScreen System.Drawing Bitmap/Graphics
  Add-Type -AssemblyName System.Drawing
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
 // WDA_EXCLUDEFROMCAPTURE
  [DllImport("user32.dll")] public static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint dwAffinity);
  [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr hObject);
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
 # dark = light =
 # auto =
  materialPole = 'dark'
}
if (Test-Path $configFile) {
  try { $cfg = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json }
  catch { $cfg = $defaultConfig }
  foreach ($p in @('x','y','width','height','opacity','autostart','materialPole')) {
    if (-not (Get-Member -InputObject $cfg -Name $p -ErrorAction SilentlyContinue)) {
      Add-Member -InputObject $cfg -NotePropertyName $p -NotePropertyValue $defaultConfig.$p
    }
  }
} else {
  $cfg = $defaultConfig
  $cfg | ConvertTo-Json | Out-File -FilePath $configFile -Encoding UTF8
}

$script:glassMargin = 18
$script:glassMarginPanelBottom = 24

# XAML pill
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="mcode-island" Width="320" Height="60"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        WindowStartupLocation="Manual" UseLayoutRounding="True" SnapsToDevicePixels="True"
        Focusable="False" ShowActivated="False">
  <Grid x:Name="RootGrid">
    <Grid.RowDefinitions>
      <!-- row 0   config   height   70  -->
      <RowDefinition x:Name="PillRow" Height="70"/>
      <!-- row 1   session   0 -->
      <RowDefinition x:Name="SessionListRow" Height="0"/>
    </Grid.RowDefinitions>
  <!--
          Liquid Glass 

     Apple HIG "Materials" Liquid Glass / regular  
    WWDC25 "Meet Liquid Glass" 

      1. ** ** 
          " "
           New-GlassCapture  #232734  
          " " 
      2. **regular   =   +  ** 
          
         Apply-GlassMaterial 
      3. ** ** specular 
          " " " " 
          

     
      PillGlass.Background    +      " "
      PillTint              /  +  
      PillGrain              8bit  
      PillRim               
      PillEdge              " " 
                         

      Border   CornerRadius   Border  
    CornerRadius   Grid   Clip 
     / 
  -->
  <Border x:Name="Pill" Grid.Row="0" Padding="0" Margin="0">
    <Border.Effect>
      <DropShadowEffect x:Name="PillShadow" Color="Black" Opacity="0.45" BlurRadius="28" ShadowDepth="7"/>
    </Border.Effect>
    <Grid x:Name="PillGlass" Background="#FF16181D">
      <!--
          Canvas  Grid  

        Path   DesiredSize   Data   Bounds  Path   Data  
        " "  Grid  
          Auto  
          max( ,  )    
         

        Canvas  DesiredSize   0 
         
      -->
      <Canvas x:Name="PillMaterial">
        <Path x:Name="PillTint" Fill="Transparent" Stroke="Transparent"/>
        <Path x:Name="PillGrain" Fill="Transparent" Stroke="Transparent"/>
        <Path x:Name="PillRim" Fill="Transparent" Stroke="Transparent" StrokeThickness="1"/>
        <Path x:Name="PillEdge" Fill="Transparent" Stroke="Transparent" StrokeThickness="1"/>
      </Canvas>

      <Border Padding="15,6">
      <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>

      <Grid Grid.Column="0" Width="22" Height="22" Margin="0,0,10,0">
        <Ellipse x:Name="PulseRing" Width="22" Height="22" Fill="#FF8E8E93" Opacity="0.0">
          <Ellipse.RenderTransform>
            <ScaleTransform x:Name="PulseScale" ScaleX="1" ScaleY="1"/>
          </Ellipse.RenderTransform>
          <Ellipse.RenderTransformOrigin>0.5,0.5</Ellipse.RenderTransformOrigin>
        </Ellipse>
        <!--
           

           
           " " " 
           " 
            DropShadowEffect   +  
        -->
        <Ellipse x:Name="StatusDot" Width="11" Height="11"
                 HorizontalAlignment="Center" VerticalAlignment="Center"
                 Fill="#FF8E8E93">
          <Ellipse.Effect>
            <DropShadowEffect x:Name="StatusDotGlow" Color="#FF22D3EE" BlurRadius="9"
                              ShadowDepth="0" Opacity="0"/>
          </Ellipse.Effect>
        </Ellipse>
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
                     Foreground="#FFFFFFFF" FontSize="16" FontWeight="SemiBold"
                     TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
          <TextBlock Grid.Column="1" x:Name="ElapsedText" Text=""
                     Foreground="#4DEBEBF5" FontSize="11"
                     VerticalAlignment="Center" Margin="6,0,0,0"
                     FontFamily="Consolas, Segoe UI"/>
          <!-- 5h usage badge: filled in by the detector, -1 means unknown -->
          <TextBlock Grid.Column="2" x:Name="Usage5hText" Text=""
                     Foreground="#4DEBEBF5" FontSize="11"
                     VerticalAlignment="Center" Margin="6,0,0,0"
                     FontFamily="Consolas, Segoe UI"
                     ToolTip="mmx 5h usage"/>
        </Grid>
        <TextBlock x:Name="MessageText" Text="Waiting for task"
                   Foreground="#99EBEBF5" FontSize="13" Margin="0,1,0,0"
                   TextTrimming="CharacterEllipsis" MaxWidth="240"/>
        <!--  
             - progress=0..100 determinate  ProgressFill ScaleX  bright cyan  
             - progress=-1   state   active indeterminate  ProgressIndeterminate  cyan  
             -   -->
        <Grid x:Name="ProgressBar" Height="8" Margin="0,2,0,0" Visibility="Collapsed">
          <Border x:Name="ProgressTrack" Background="#26FFFFFF" CornerRadius="4"/>
          <Border x:Name="ProgressFill" Background="#FF0A84FF" CornerRadius="4"
                  HorizontalAlignment="Stretch" Visibility="Collapsed">
            <Border.RenderTransform>
              <ScaleTransform x:Name="ProgressScale" ScaleX="0" ScaleY="1"/>
            </Border.RenderTransform>
            <Border.RenderTransformOrigin>0,0.5</Border.RenderTransformOrigin>
          </Border>
          <Grid x:Name="ProgressIndeterminate" Visibility="Collapsed" ClipToBounds="True">
            <Rectangle x:Name="ProgressShimmer" Width="130" HorizontalAlignment="Left"
                       Fill="#FF0A84FF">
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
                 Foreground="#99EBEBF5" FontSize="15" Margin="10,0,0,0"
                 VerticalAlignment="Center"/>
      </Grid>
      </Border>
    </Grid>
  </Border>

  <!--
    session   pill   HWND 
         WindowFromPoint  
     1053   39  
      pill  
     

     row 0  
     

      Liquid Glass  +   +   +
     ** ** HIG  " " 
     

     " " 
    New-RoundedRectGeometry   Smooth  

      Border.Padding   SessionRows   Margin 
     
  -->
  <Border x:Name="SessionPanel" Grid.Row="1" Visibility="Collapsed" Margin="0,14,0,0">
    <Border.Effect>
      <DropShadowEffect x:Name="PanelShadow" Color="Black" Opacity="0.5" BlurRadius="34" ShadowDepth="10"/>
    </Border.Effect>
    <Grid x:Name="PanelGlass" Background="#FF16181D">
      <!--   Canvas  Auto 
             PillMaterial   -->
      <Canvas x:Name="PanelMaterial">
        <Path x:Name="PanelTint" Fill="Transparent" Stroke="Transparent"/>
        <Path x:Name="PanelGrain" Fill="Transparent" Stroke="Transparent"/>
        <Path x:Name="PanelRim" Fill="Transparent" Stroke="Transparent" StrokeThickness="1"/>
        <Path x:Name="PanelEdge" Fill="Transparent" Stroke="Transparent" StrokeThickness="1"/>
      </Canvas>
      <StackPanel x:Name="SessionRows" Margin="14,10"/>
    </Grid>
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
$progressTrack        = $window.FindName('ProgressTrack')
$progressFill         = $window.FindName('ProgressFill')
$progressScale        = $window.FindName('ProgressScale')
$progressIndeterminate = $window.FindName('ProgressIndeterminate')
$progressShimmer      = $window.FindName('ProgressShimmer')
$progressShimmerTransform = $window.FindName('ProgressShimmerTransform')
$elapsedText          = $window.FindName('ElapsedText')
$usage5hText          = $window.FindName('Usage5hText')
$statusDotGlow        = $window.FindName('StatusDotGlow')
# session pill
$script:sessionRowsPanel = $window.FindName('SessionPanel')
$script:sessionRows      = $window.FindName('SessionRows')
$script:sessionListRow  = $window.FindName('SessionListRow')

try {
  $pillBorder = $window.FindName('Pill')
  if ($pillBorder) { $pillBorder.Margin = New-Object System.Windows.Thickness($script:glassMargin) }
  $panelBorder = $window.FindName('SessionPanel')
  if ($panelBorder) { $panelBorder.Margin = New-Object System.Windows.Thickness($script:glassMargin, 6, $script:glassMargin, $script:glassMarginPanelBottom) }
} catch {
  Dbg "GLASS MARGIN FAIL: $($_.Exception.Message)"
}

# DrawingBrush
# - DrawingBrush WPF DPI
function New-GrainBrush {
  param([int]$Tile = 64, [int]$Seed = 7, [int]$Dots = 260, [string]$Color = '#FFFFFFFF')
  try {
    $rnd = [Random]::new($Seed)
    $geo = New-Object System.Windows.Media.GeometryGroup
    for ($i = 0; $i -lt $Dots; $i++) {
      $x = $rnd.NextDouble() * $Tile
      $y = $rnd.NextDouble() * $Tile
      $w = 0.5 + $rnd.NextDouble() * 1.1
      $rect = New-Object System.Windows.Rect $x, $y, $w, $w
      $geo.Children.Add((New-Object System.Windows.Media.RectangleGeometry $rect)) | Out-Null
    }
    $drawing = New-Object System.Windows.Media.GeometryDrawing
    $drawing.Geometry = $geo
    $drawing.Brush = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Color)))
    $brush = New-Object System.Windows.Media.DrawingBrush
    $brush.Drawing = $drawing
    $brush.TileMode = [System.Windows.Media.TileMode]::Tile
    $brush.ViewportUnits = [System.Windows.Media.BrushMappingMode]::Absolute
    $brush.Viewport = New-Object System.Windows.Rect 0, 0, $Tile, $Tile
    $brush.Stretch = [System.Windows.Media.Stretch]::None
    return $brush
  } catch {
    Dbg "GRAIN FAIL: $($_.Exception.Message)"
    return $null
  }
}

# Update-GlassInk
$script:grainBrushDark  = $null
$script:grainBrushLight = $null
try {
  $script:grainBrushDark  = New-GrainBrush -Color '#FFFFFFFF'
  $script:grainBrushLight = New-GrainBrush -Color '#FF000000'
  $grain = $script:grainBrushDark
  if ($grain) {
    foreach ($name in @('PillGrain', 'PanelGrain')) {
      $target = $window.FindName($name)
      if ($target) { $target.Fill = $grain; $target.Opacity = 0.015 }
    }
    Dbg 'GRAIN: applied'
  }
} catch {
  Dbg "GRAIN APPLY FAIL: $($_.Exception.Message)"
}

# Liquid Glass
# - Apple HIG "Materials" Liquid Glass / regular 2025-09
# - Apple HIG "Color" Liquid Glass color 2025-12
# - WWDC25 "Meet Liquid Glass" session 219
# 1. ** **
# 2. **regular = + **
# 3. ** ** specular
# 4. ** **
# HIG larger elements appear more opaque
# Windows
# - layered AllowsTransparency=True
# DWM backdrop SetWindowCompositionAttribute(ACCENT_ENABLE_BLURBEHIND)
# - layered DWMWA_SYSTEMBACKDROP_TYPE WPF
# dwm-probe
# 1. ** ** SetWindowDisplayAffinity
# WDA_EXCLUDEFROMCAPTURE
# 2. ** ** PointToScreen WPF
# Left/Top DIP 100%
# " 1/4 + BlurEffect + " " "
$script:glassBackdrop = $null
$script:glassLuminance = 0.0
$script:glassLastUpdate = [DateTime]::MinValue
$script:glassDragStamp = [DateTime]::MinValue

# r = /2
# " " Smooth=1 n=5
$script:glassRadiusPill  = 35.0
$script:glassRadiusPanel = 18.0
$script:glassSmoothPanel = 1.0

# WWDC25
$script:glassRefreshMs = 2500

function Get-WindowDeviceScale {
 # 100 DIP
  try {
    $p0 = $window.PointToScreen([System.Windows.Point]::new(0, 0))
    $p1 = $window.PointToScreen([System.Windows.Point]::new(100, 0))
    $sx = [Math]::Abs($p1.X - $p0.X) / 100.0
    $sy = [Math]::Abs($p1.Y - $p0.Y) / 100.0
    if ($sx -lt 0.1 -or $sx -gt 10) { $sx = 1.0 }
    if ($sy -lt 0.1 -or $sy -gt 10) { $sy = 1.0 }
    return @($sx, $sy)
  } catch {
    return @(1.0, 1.0)
  }
}

function New-RoundedRectGeometry {
 # Smooth " " 0 = 1 =
 # n=5 iOS squircle 24
 # 1x
 # Inset
  param([double]$W, [double]$H, [double]$R, [double]$Smooth = 0.0, [double]$Inset = 0.0, [int]$Steps = 24)
  try {
    $w2 = $W - 2 * $Inset
    $h2 = $H - 2 * $Inset
    if ($w2 -le 2 -or $h2 -le 2) { return $null }
    $r = [Math]::Min($R - $Inset, [Math]::Min($w2, $h2) / 2.0)
    if ($r -le 0.5) {
      $rect = New-Object System.Windows.Rect $Inset, $Inset, $w2, $h2
      $g = New-Object System.Windows.Media.RectangleGeometry $rect
      $g.Freeze()
      return $g
    }
 # e = 1 e = 2/n n=5 e = 0.4
    $e = 1.0
    if ($Smooth -gt 0.01) {
      $n = 2.0 + 3.0 * [Math]::Min(1.0, $Smooth)
      $e = 2.0 / $n
    }
    $half = [Math]::PI / 2.0
    $pts = New-Object 'System.Collections.Generic.List[System.Windows.Point]'
    for ($i = 0; $i -le $Steps; $i++) {
      $t = $half * $i / $Steps
      $s = [Math]::Pow([Math]::Sin($t), $e)
      $c = [Math]::Pow([Math]::Cos($t), $e)
      $pts.Add((New-Object System.Windows.Point ($Inset + $w2 - $r + $r * $s), ($Inset + $r - $r * $c)))
    }
    for ($i = 0; $i -le $Steps; $i++) {
      $t = $half * $i / $Steps
      $s = [Math]::Pow([Math]::Sin($t), $e)
      $c = [Math]::Pow([Math]::Cos($t), $e)
      $pts.Add((New-Object System.Windows.Point ($Inset + $w2 - $r + $r * $c), ($Inset + $h2 - $r + $r * $s)))
    }
    for ($i = 0; $i -le $Steps; $i++) {
      $t = $half * $i / $Steps
      $s = [Math]::Pow([Math]::Sin($t), $e)
      $c = [Math]::Pow([Math]::Cos($t), $e)
      $pts.Add((New-Object System.Windows.Point ($Inset + $r - $r * $s), ($Inset + $h2 - $r + $r * $c)))
    }
 # IsClosed
    for ($i = 0; $i -lt $Steps; $i++) {
      $t = $half * $i / $Steps
      $s = [Math]::Pow([Math]::Sin($t), $e)
      $c = [Math]::Pow([Math]::Cos($t), $e)
      $pts.Add((New-Object System.Windows.Point ($Inset + $r - $r * $c), ($Inset + $r - $r * $s)))
    }
    $fig = New-Object System.Windows.Media.PathFigure
    $fig.StartPoint = $pts[0]
    $fig.IsClosed = $true
    for ($i = 1; $i -lt $pts.Count; $i++) {
      $seg = New-Object System.Windows.Media.LineSegment $pts[$i], $pts[$i]
      $fig.Segments.Add($seg) | Out-Null
    }
    $geo = New-Object System.Windows.Media.PathGeometry
    $geo.Figures.Add($fig) | Out-Null
    $geo.Freeze()
    return $geo
  } catch {
    Dbg "ROUNDRECT FAIL: $($_.Exception.Message)"
    return $null
  }
}

function New-GlassStop {
  param([System.Windows.Media.Color]$Color, [double]$Offset, [double]$Alpha)
  $a = [int][Math]::Max(0, [Math]::Min(255, [Math]::Round($Alpha * 255)))
  $s = New-Object System.Windows.Media.GradientStop
  $s.Color = [System.Windows.Media.Color]::FromArgb($a, $Color.R, $Color.G, $Color.B)
  $s.Offset = $Offset
  return $s
}

function Measure-Luminance {
 # 0..1
  param($Bitmap)
  try {
    if (-not $Bitmap) { return 0.0 }
    $w = $Bitmap.PixelWidth
    $h = $Bitmap.PixelHeight
    if ($w -le 0 -or $h -le 0) { return 0.0 }
    $stride = $w * 4
    $buf = New-Object byte[] ($stride * $h)
    $Bitmap.CopyPixels($buf, $stride, 0)
 # 4 1 Rec.709
    $sum = 0.0
    $n = 0
    for ($i = 0; $i -lt $buf.Length; $i += 16) {
      $b = $buf[$i]; $g = $buf[$i + 1]; $r = $buf[$i + 2]
      $sum += (0.2126 * $r + 0.7152 * $g + 0.0722 * $b)
      $n++
    }
    if ($n -eq 0) { return 0.0 }
    $v = $sum / $n / 255.0
    if ($v -lt 0.0) { $v = 0.0 }
    if ($v -gt 1.0) { $v = 1.0 }
    return [double]$v
  } catch {
    return 0.0
  }
}

function New-GlassCapture {
 # @{ Brush = ImageBrush; Luminance = 0..1 } $null
  param($Element)
  try {
    if (-not $Element) { return $null }
    $w = $Element.ActualWidth
    $h = $Element.ActualHeight
    if ($w -lt 8 -or $h -lt 8) { return $null }
    $scale = Get-WindowDeviceScale
    $sx = [double]$scale[0]; $sy = [double]$scale[1]
    $origin = $Element.PointToScreen([System.Windows.Point]::new(0, 0))
    $devW = [int][Math]::Ceiling($w * $sx)
    $devH = [int][Math]::Ceiling($h * $sy)
    if ($devW -lt 8 -or $devH -lt 8) { return $null }
    if ($devW -gt 4000 -or $devH -gt 4000) { return $null }

    $bmp = $null
    $src = $null
    $ms = $null
    try {
      $bmp = New-Object System.Drawing.Bitmap $devW, $devH
      $g = [System.Drawing.Graphics]::FromImage($bmp)
 # CopyFromScreen DC
      $g.CopyFromScreen([int]$origin.X, [int]$origin.Y, 0, 0, (New-Object System.Drawing.Size $devW, $devH))
      $g.Dispose()
 # System.Drawing.Bitmap -> WPF BitmapSource
 # MemoryStream Imaging.CreateBitmapSourceFromHBitmap
 # System.Windows.Media.Imaging.Imaging .NET Framework
 # internal PowerShell [System.Windows.Media.Imaging.Imaging]
 # " " .NET Core PNG
      $ms = New-Object System.IO.MemoryStream
      $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
      $ms.Position = 0
      $src = New-Object System.Windows.Media.Imaging.BitmapImage
      $src.BeginInit()
      $src.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
      $src.StreamSource = $ms
      $src.EndInit()
      $src.Freeze()
    } finally {
      if ($ms) { $ms.Dispose() }
      if ($bmp) { $bmp.Dispose() }
    }

 # ** ** 24px 1/4 6
 # 9 70px 17px 9px
    $scaleDown = 4
    $smallW = [int][Math]::Max(4, [int]($devW / $scaleDown))
    $smallH = [int][Math]::Max(4, [int]($devH / $scaleDown))

    $img = New-Object System.Windows.Controls.Image
    $img.Source = $src
    $img.Width = $smallW
    $img.Height = $smallH
    $img.Stretch = [System.Windows.Media.Stretch]::Fill
    $blur = New-Object System.Windows.Media.Effects.BlurEffect
    $blur.Radius = 6
    $img.Effect = $blur
 # Measure + Arrange Render
 # RenderTargetBitmap.Render() " "
 # Image Render
 # 0.0 0.35
    $img.Measure((New-Object System.Windows.Size($smallW, $smallH)))
    $img.Arrange((New-Object System.Windows.Rect(0, 0, $smallW, $smallH)))

    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $smallW, $smallH, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($img)

    $brush = New-Object System.Windows.Media.ImageBrush $rtb
    $brush.Stretch = [System.Windows.Media.Stretch]::Fill
    $brush.TileMode = [System.Windows.Media.TileMode]::None
    return @{ Brush = $brush; Luminance = (Measure-Luminance $rtb) }
  } catch {
    Dbg "GLASS CAPTURE FAIL: $($_.Exception.Message)"
    return $null
  }
}

function Update-GlassGeometry {
  param([string]$Prefix, [double]$Radius, [double]$Smooth)
  try {
    $glass = $window.FindName("${Prefix}Glass")
    if (-not $glass) { return $false }
    $w = $glass.ActualWidth
    $h = $glass.ActualHeight
    if ($w -lt 8 -or $h -lt 8) { return $false }
    $geo     = New-RoundedRectGeometry $w $h $Radius $Smooth 0
    $geoRim  = New-RoundedRectGeometry $w $h $Radius $Smooth 1.25
    $geoEdge = New-RoundedRectGeometry $w $h $Radius $Smooth 3.5
    if (-not $geo) { return $false }
 # Clip Border CornerRadius
    $glass.Clip = $geo
    $tint  = $window.FindName("${Prefix}Tint");  if ($tint)  { $tint.Data  = $geo }
    $grain = $window.FindName("${Prefix}Grain"); if ($grain) { $grain.Data = $geo }
    $rim   = $window.FindName("${Prefix}Rim");   if ($rim)   { $rim.Data = $geoRim;  $rim.StrokeThickness = 1.5 }
    $edge  = $window.FindName("${Prefix}Edge");  if ($edge)  { $edge.Data = $geoEdge; $edge.StrokeThickness = 1.5 }
 # Canvas Canvas Canvas
 # Path (0,0) Path Data
    foreach ($layer in @($tint, $grain, $rim, $edge)) {
      if (-not $layer) { continue }
      [System.Windows.Controls.Canvas]::SetLeft($layer, 0)
      [System.Windows.Controls.Canvas]::SetTop($layer, 0)
    }
    return $true
  } catch {
    Dbg "GLASS GEOMETRY FAIL: $($_.Exception.Message)"
    return $false
  }
}

# HIG "Materials" Liquid Glass regular " + ** **
# " adjusts the luminosity of background content to maintain
# legibility of text
# 60% 2.7:1 "3h25m 99%" 30% 1.7:1
# " " ** ** macOS Dock
# dark + ** **
# light +
# ** dark** " " **
# 0.115 #1D1D1D macOS Dynamic Island
# ** ** auto 0.60
# 0.58
# config.json materialPole dark / light / auto
# Update-GlassInk
# $script:glassPole $script:glassPanelPole
# HIG "Materials"
$script:glassPole = 'dark'
$script:glassPanelPole = 'dark'

# smoke.mjs /
# ** ** 0..1 sRGB WCAG
# HIG "Materials" regular "blurs and **adjusts the luminosity** of
# background content to maintain legibility of text" "
# " " macOS Dynamic Island
# " " 106 #6A6A6A
# 0.115 29 #1D1D1D macOS #1C1C1E
# 16.9:1 0.90 230 #E6E6E6 12.7:1
$script:glassTargetByteDark  = 0.115
$script:glassTargetByteLight = 0.90
# = HIG: larger elements appear more opaque
$script:glassThickDark  = 0.25
$script:glassThickLight = 0.25
# ** ** auto 0.60
# 0.58
$script:glassPoleLightOn  = 0.60
$script:glassPoleLightOff = 0.58

# HIG "Color" macOS
# ** ** macOS label / secondaryLabel / tertiaryLabel
# iOS iOS "
# " iOS
# 3
$script:glassInkDark = @{
  Primary   = '#FFFFFFFF'   # label
  Secondary = '#99EBEBF5'   # secondaryLabel 60%
  Tertiary  = '#4DEBEBF5'   # tertiaryLabel 30%
  Muted     = '#FF8B93A1'
  Dim       = '#FF8E8E93'   # systemGray
  Warn      = '#FFFF9F0A'   # systemOrange
  Danger    = '#FFFF453A'   # systemRed
  Track     = '#26FFFFFF'
  Accent    = '#FF0A84FF'   # systemBlue (dark)
  Hover     = '#FFFF453A'
}

$script:glassInkLight = @{
  Primary   = '#D9000000' # macOS label: 85%
  Secondary = '#8C000000' # secondaryLabel: 55%
  Tertiary  = '#4D000000' # tertiaryLabel: 30%
  Muted     = '#FF6C6C70'
  Dim       = '#FF6C6C70'
  Warn      = '#FFC93400'   # systemOrange (light)
  Danger    = '#FFD70015'   # systemRed (light)
  Track     = '#1A000000'
  Accent    = '#FF007AFF'   # systemBlue (light)
  Hover     = '#FFFF3B30'   # systemRed (light)
}

# HIG "Color" light
# dark ** ** label
$stateMapLight = @{
  idle     = @{ dot='#FF6C6C70'; ring='#FF6C6C70'; label='mcode';             icon='' }
  thinking = @{ dot='#FFA88700'; ring='#FFA88700'; label='mcode - thinking';     icon='' }
  working  = @{ dot='#FF007AFF'; ring='#FF007AFF'; label='mcode - working';     icon='*' }
  waiting  = @{ dot='#FFC93400'; ring='#FFC93400'; label='mcode - waiting';  icon='?' }
  done     = @{ dot='#FF248A3D'; ring='#FF248A3D'; label='mcode - done';     icon='+' }
  error    = @{ dot='#FFD70015'; ring='#FFD70015'; label='mcode - error';       icon='x' }
}

$familyMapLight = @{
  shell  = '#FF248A3D' # bash / shell
  read   = '#FF007AFF' # read
  write  = '#FFA88700' # edit / write
  search = '#FF8944AB' # grep / glob
  task   = '#FF007E8A' # task
  web    = '#FFD6246D' # web_search/fetch
  plan   = '#FF8E8E93' # todowrite
}

function Get-GlassInk {
  if ($script:glassPole -eq 'light') { return $script:glassInkLight }
  return $script:glassInkDark
}

function Get-PanelInk {
  if ($script:glassPanelPole -eq 'light') { return $script:glassInkLight }
  return $script:glassInkDark
}

function Get-GlassStateMap {
  if ($script:glassPole -eq 'light') { return $stateMapLight }
  return $stateMap
}

function Get-PanelStateMap {
  if ($script:glassPanelPole -eq 'light') { return $stateMapLight }
  return $stateMap
}

function Get-GlassFamilyMap {
  if ($script:glassPole -eq 'light') { return $familyMapLight }
  return $familyMap
}

function Resolve-GlassPole {
 # auto 0.60 0.58
 # - 4.5:1 0.227
 # 0.58
 # - 0.115
 # 16.9:1
 # 0.60 / 0.58 ** **
 # $Current ** **
 # materialPole = dark / light
 # bug
  param([double]$L, [string]$Current)
  $forced = ''
  try { $forced = [string]$cfg.materialPole } catch { $forced = '' }
  if ($forced -eq 'dark' -or $forced -eq 'light') { return $forced }
  if ($Current -eq 'light') {
    if ($L -lt $script:glassPoleLightOff) { return 'dark' }
  } else {
    if ($L -gt $script:glassPoleLightOn) { return 'light' }
  }
  return $Current
}

function Update-GlassGrain {
  param([string]$Name, [string]$Pole)
  try {
    $gb = $script:grainBrushDark
    if ($Pole -eq 'light') { $gb = $script:grainBrushLight }
    if (-not $gb) { return }
    $target = $window.FindName($Name)
    if ($target) { $target.Fill = $gb }
  } catch {
    Dbg "GLASS GRAIN INK FAIL: $($_.Exception.Message)"
  }
}

function Update-GlassInk {
 # Update-SessionRowsInk
  $ink = Get-GlassInk
  try {
    if ($script:stateText)       { $script:stateText.Foreground         = C $ink.Primary }
    if ($script:messageText)     { $script:messageText.Foreground       = C $ink.Secondary }
    if ($script:actionIcon)      { $script:actionIcon.Foreground        = C $ink.Secondary }
    if ($script:elapsedText)     { $script:elapsedText.Foreground       = C $ink.Tertiary }
    if ($script:usage5hText)     { $script:usage5hText.Foreground       = C $ink.Tertiary }
    if ($script:progressTrack)   { $script:progressTrack.Background     = C $ink.Track }
    if ($script:progressFill)    { $script:progressFill.Background      = C $ink.Accent }
    if ($script:progressShimmer) { $script:progressShimmer.Fill         = C $ink.Accent }
  } catch {
    Dbg "GLASS INK FAIL: $($_.Exception.Message)"
  }
  Update-GlassGrain 'PillGrain' $script:glassPole
}

function Update-GlassPanelGrain {
  Update-GlassGrain 'PanelGrain' $script:glassPanelPole
}

function Update-SessionRowsInk {
 # pending
  try {
    if (-not $script:sessionRowsPanel) { return }
    if ($script:sessionRowsPanel.Visibility -ne [System.Windows.Visibility]::Visible) { return }
    Show-SessionList | Out-Null
  } catch {
    Dbg "GLASS ROWS REINK FAIL: $($_.Exception.Message)"
  }
}

function Apply-GlassMaterial {
 # HIG "the amount of tint shifts to keep buttons legible"
  param([string]$Prefix, [double]$Luminance, [bool]$Thick)
  try {
    $L = [Math]::Max(0.0, [Math]::Min(1.0, $Luminance))

    $isPanel = ($Prefix -eq 'Panel')
    $curPole = $script:glassPole
    if ($isPanel) { $curPole = $script:glassPanelPole }
    $pole = Resolve-GlassPole $L $curPole
    if ($isPanel) {
      if ($pole -ne $script:glassPanelPole) {
        $script:glassPanelPole = $pole
        Update-GlassPanelGrain
 # Show-SessionList Update-GlassBackdrop
 # Update-GlassBackdrop
        $script:glassRowsNeedReink = $true
      }
    } else {
      if ($pole -ne $script:glassPole) {
        $script:glassPole = $pole
        Update-GlassInk
      }
    }

    $dark  = [System.Windows.Media.Color]::FromArgb(255, 0, 0, 0)
    $white = [System.Windows.Media.Color]::FromArgb(255, 255, 255, 255)

 # HIG "Materials" regular "blurs and **adjusts the luminosity**
 # of background content to maintain legibility of text" "
 # -> veil = 1 - target / L
 # -> lift = (target - L) / (1 - L)
 # " " macOS Dynamic Island
 # " " 106 #6A6A6A
 # ** ** $thick [bool]$Thick PowerShell
 # $thick = 0.25
 # $true (1.0 - $thick) 0 0
 # veil 1 "
 # " $thickMix
    $target = $script:glassTargetByteDark
    $thickMix = $script:glassThickDark
    if ($pole -eq 'light') {
      $target = $script:glassTargetByteLight
      $thickMix = $script:glassThickLight
    }
 # = HIG larger elements appear more opaque
    if ($Thick) {
      if ($pole -eq 'light') { $target = $target + (1.0 - $target) * $thickMix }
      else { $target = $target * (1.0 - $thickMix) }
    }
    $veil = 0.0
    $lift = 0.0
    if ($L -gt $target) {
      $veil = 1.0 - ($target / $L)
    } else {
      $lift = ($target - $L) / (1.0 - $L)
    }

    $tintBrush = New-Object System.Windows.Media.LinearGradientBrush
    $tintBrush.StartPoint = New-Object System.Windows.Point 0, 0
    $tintBrush.EndPoint   = New-Object System.Windows.Point 0, 1
    if ($veil -gt 0.0) {
 # rim
      $tintBrush.GradientStops.Add((New-GlassStop $dark  0.00 ($veil * 0.98))) | Out-Null
      $tintBrush.GradientStops.Add((New-GlassStop $dark  0.34 ($veil))) | Out-Null
      $tintBrush.GradientStops.Add((New-GlassStop $dark  0.70 ($veil * 1.03))) | Out-Null
      $tintBrush.GradientStops.Add((New-GlassStop $dark  1.00 ($veil * 1.06))) | Out-Null
    } else {
      $tintBrush.GradientStops.Add((New-GlassStop $white 0.00 ($lift * 1.00))) | Out-Null
      $tintBrush.GradientStops.Add((New-GlassStop $white 0.30 ($lift * 0.88))) | Out-Null
      $tintBrush.GradientStops.Add((New-GlassStop $white 0.68 ($lift * 0.76))) | Out-Null
      $tintBrush.GradientStops.Add((New-GlassStop $white 1.00 ($lift * 0.64))) | Out-Null
    }
    $tintPath = $window.FindName("${Prefix}Tint")
    if ($tintPath) { $tintPath.Fill = $tintBrush }

 # specular
    $rimBrush = New-Object System.Windows.Media.RadialGradientBrush
    $rimBrush.Center = New-Object System.Windows.Point 0.5, 0
    $rimBrush.RadiusX = 0.70
    $rimBrush.RadiusY = 1.30
    if ($pole -eq 'light') {
      $rimBrush.GradientStops.Add((New-GlassStop $dark 0.00 0.22)) | Out-Null
      $rimBrush.GradientStops.Add((New-GlassStop $dark 0.45 0.07)) | Out-Null
      $rimBrush.GradientStops.Add((New-GlassStop $dark 0.80 0.02)) | Out-Null
      $rimBrush.GradientStops.Add((New-GlassStop $dark 1.00 0.00)) | Out-Null
    } else {
      $rimBrush.GradientStops.Add((New-GlassStop $white 0.00 0.55)) | Out-Null
      $rimBrush.GradientStops.Add((New-GlassStop $white 0.35 0.24)) | Out-Null
      $rimBrush.GradientStops.Add((New-GlassStop $white 0.75 0.07)) | Out-Null
      $rimBrush.GradientStops.Add((New-GlassStop $white 1.00 0.02)) | Out-Null
    }
    $rimPath = $window.FindName("${Prefix}Rim")
    if ($rimPath) { $rimPath.Stroke = $rimBrush }

    $edgeBottom = 0.46
    if ($pole -eq 'light') { $edgeBottom = 0.30 }
    $edgeBrush = New-Object System.Windows.Media.LinearGradientBrush
    $edgeBrush.StartPoint = New-Object System.Windows.Point 0, 0
    $edgeBrush.EndPoint   = New-Object System.Windows.Point 0, 1
    $edgeBrush.GradientStops.Add((New-GlassStop $dark 0.00 0.00)) | Out-Null
    $edgeBrush.GradientStops.Add((New-GlassStop $dark 0.58 0.00)) | Out-Null
    $edgeBrush.GradientStops.Add((New-GlassStop $dark 1.00 $edgeBottom)) | Out-Null
    $edgePath = $window.FindName("${Prefix}Edge")
    if ($edgePath) { $edgePath.Stroke = $edgeBrush }

 # WWDC25
    $shadow = $window.FindName("${Prefix}Shadow")
    if ($shadow) {
      if ($pole -eq 'light') {
        if ($Thick) { $shadow.Opacity = [Math]::Min(0.46, 0.20 + 0.18 * $L); $shadow.BlurRadius = 44; $shadow.ShadowDepth = 12 }
        else { $shadow.Opacity = [Math]::Min(0.38, 0.16 + 0.16 * $L); $shadow.BlurRadius = 32; $shadow.ShadowDepth = 8 }
      } else {
        if ($Thick) { $shadow.Opacity = [Math]::Min(0.72, 0.36 + 0.32 * $L) }
        else { $shadow.Opacity = [Math]::Min(0.62, 0.30 + 0.28 * $L) }
      }
    }
 # 2.5s
    if ($script:glassLoggedPoles[$Prefix] -ne $pole) {
      $script:glassLoggedPoles[$Prefix] = $pole
      Dbg ("GLASS " + $Prefix.ToUpper() + " POLE -> " + $pole)
    }
    if ($null -eq $script:glassLoggedLum[$Prefix] -or [Math]::Abs($L - $script:glassLoggedLum[$Prefix]) -gt 0.12) {
      $script:glassLoggedLum[$Prefix] = $L
      Dbg ("GLASS " + $Prefix + " L=" + [Math]::Round($L, 3) + " veil=" + [Math]::Round($veil, 3) + " lift=" + [Math]::Round($lift, 3) + " pole=" + $pole)
    }
    return $true
  } catch {
    Dbg "GLASS MATERIAL FAIL: $($_.Exception.Message)"
    return $false
  }
}

function Update-GlassBackdrop {
  try {
    $pillGlass = $window.FindName('PillGlass')
    if (-not $pillGlass) { return $false }
    $panelGlass = $window.FindName('PanelGlass')

    $hwnd = [IntPtr]::Zero
    $excluded = $false
    try {
      $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
      if ($hwnd -and [WinAPI]::SetWindowDisplayAffinity($hwnd, 0x00000011)) { $excluded = $true }
    } catch {}

    try {
      $pillCap = New-GlassCapture $pillGlass
      if ($pillCap) {
        $pillGlass.Background = $pillCap.Brush
        $script:glassBackdrop = $pillCap.Brush
        $script:glassLuminance = $pillCap.Luminance
        [void](Apply-GlassMaterial 'Pill' $pillCap.Luminance $false)
      }
      if ($panelGlass -and $panelGlass.Visibility -eq [System.Windows.Visibility]::Visible) {
        $panelCap = New-GlassCapture $panelGlass
        if ($panelCap) {
          $panelGlass.Background = $panelCap.Brush
          [void](Apply-GlassMaterial 'Panel' $panelCap.Luminance $true)
        }
      }
    } finally {
      if ($excluded -and $hwnd) { try { [void][WinAPI]::SetWindowDisplayAffinity($hwnd, 0) } catch {} }
    }
    $script:glassLastUpdate = [DateTime]::UtcNow
 # Show-SessionList Show-SessionList
 # Update-GlassBackdrop " "
    if ($script:glassRowsNeedReink) {
      $script:glassRowsNeedReink = $false
      Update-SessionRowsInk
    }
    return $true
  } catch {
    Dbg "GLASS UPDATE FAIL: $($_.Exception.Message)"
    return $false
  }
}

# Clip
# ActualWidth/ActualHeight
# 400ms
$script:glassGeomSize = @{}
# 0.12
$script:glassLoggedLum = @{}
$script:glassLoggedPoles = @{}
$script:glassRowsNeedReink = $false

function Sync-GlassGeometry {
  try {
    $specs = @(
      @{ P = 'Pill';  R = $script:glassRadiusPill;  S = 0.0 },
      @{ P = 'Panel'; R = $script:glassRadiusPanel; S = $script:glassSmoothPanel }
    )
    foreach ($sp in $specs) {
      $glass = $window.FindName("$($sp.P)Glass")
      if (-not $glass) { continue }
      if ($sp.P -eq 'Panel' -and $glass.Visibility -ne [System.Windows.Visibility]::Visible) { continue }
      $w = [int]$glass.ActualWidth
      $h = [int]$glass.ActualHeight
      if ($w -lt 8 -or $h -lt 8) { continue }
      $key = "$($sp.P)"
      if ($script:glassGeomSize[$key] -eq "$w x $h") { continue }
      if (Update-GlassGeometry $sp.P $sp.R $sp.S) {
        $script:glassGeomSize[$key] = "$w x $h"
      }
    }
    return $true
  } catch {
    Dbg "GLASS GEOM SYNC FAIL: $($_.Exception.Message)"
    return $false
  }
}
$script:pillHeight      = 70
$script:listHideTimer   = $null

# Apple HIG "Color" dark
# Tailwind
$stateMap = @{
  idle     = @{ dot='#FF8E8E93'; ring='#FF8E8E93'; label='mcode';             icon='' }
  thinking = @{ dot='#FFFFD60A'; ring='#FFFFD60A'; label='mcode - thinking';     icon='' }
  working  = @{ dot='#FF0A84FF'; ring='#FF0A84FF'; label='mcode - working';     icon='*' }
  waiting  = @{ dot='#FFFF9F0A'; ring='#FFFF9F0A'; label='mcode - waiting';  icon='?' }
  done     = @{ dot='#FF30D158'; ring='#FF30D158'; label='mcode - done';     icon='+' }
  error    = @{ dot='#FFFF453A'; ring='#FFFF453A'; label='mcode - error';       icon='x' }
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

# " detector "
# detector 1 ack
# sessions.json
# widget Show-SessionList detector
# id sessions.json pending
# Show-SessionList
$script:pendingDismiss = @{}

# Windows
# MouseEnter MouseDown MouseEnter
$script:foregroundBeforeAction = [IntPtr]::Zero

function Get-WidgetHwnd {
  try {
    $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
    return $helper.Handle
  } catch {
    return [IntPtr]::Zero
  }
}

function Save-ForegroundBeforeAction {
  try {
    $fg = [WinAPI]::GetForegroundWindow()
    if ($fg -eq [IntPtr]::Zero) { return }
    $self = Get-WidgetHwnd
    if ($self -ne [IntPtr]::Zero -and $fg -eq $self) { return }
    $script:foregroundBeforeAction = $fg
  } catch {
  }
}

# SetForegroundWindow " " z-order
# SetForegroundWindow Windows
function Restore-ForegroundAfterAction {
  $target = $script:foregroundBeforeAction
  if ($target -eq [IntPtr]::Zero) { return }
  try {
    if (-not [WinAPI]::IsWindow($target)) { return }
    [WinAPI]::SetForegroundWindow($target) | Out-Null
    $now = [WinAPI]::GetForegroundWindow()
    if ($now -eq $target) {
      Dbg ("foreground restored to hwnd=" + $target)
    } else {
      Dbg ("foreground NOT restored (wanted hwnd=" + $target + ", now=" + $now + ")")
    }
  } catch {
    Dbg ("FOREGROUND RESTORE FAIL: " + $_.Exception.Message)
  }
}

# ack.signal detector
# id
# " id" detector ack.signal
# detector ack.signal
function Write-AckSignal([string]$id) {
  if (-not $id) { return $false }
  $ackFile = Join-Path $configDir 'ack.signal'
  $tmp = $ackFile + '.tmp'
  try {
    $existing = ''
    if (Test-Path -LiteralPath $ackFile) {
      try { $existing = [System.IO.File]::ReadAllText($ackFile) } catch { $existing = '' }
    }
    $text = $existing
    if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text = $text + "`n" }
    $text = $text + $id + "`n"
    [System.IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $ackFile -Force
    return $true
  } catch {
    Dbg "SESSION ACK FAIL: $($_.Exception.Message)"
    try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch {}
    return $false
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

# detector $script:MAX_SESSIONS 20 20 48px
# 960px
# " N "
$script:MAX_SESSION_ROWS = 12

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
 # pill
 # Tailwind #3B82F6 pill Apple
 # #0A84FF " pill "
  $stateTextMap = @{
    'working'  = @{ text = 'Running';   state = 'working' }
    'thinking' = @{ text = 'Thinking';   state = 'thinking' }
    'waiting'  = @{ text = 'Waiting for approval'; state = 'waiting' }
    'idle'     = @{ text = 'Awaiting reply';   state = 'idle' }
    'done'     = @{ text = 'Done';   state = 'done' }
    'error'    = @{ text = 'Error';     state = 'error' }
    'stopped'  = @{ text = 'Stopped';   state = 'idle' }
    'running'  = @{ text = 'Running';   state = 'working' }
  }
  $stateInfo = $stateTextMap[[string]$phase]
  if (-not $stateInfo) { $stateInfo = $stateTextMap['idle'] }
  $phaseText = $stateInfo.text
  $smap = Get-PanelStateMap
  $dotHex = $smap[$stateInfo.state].dot
  if (-not $dotHex) { $dotHex = $smap['idle'].dot }

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
 # Star
  $colX = New-Object System.Windows.Controls.ColumnDefinition
  $colX.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
  $grid.ColumnDefinitions.Add($colDot) | Out-Null
  $grid.ColumnDefinitions.Add($colTitle) | Out-Null
  $grid.ColumnDefinitions.Add($colTag) | Out-Null
  $grid.ColumnDefinitions.Add($colX) | Out-Null

  $rowTop = New-Object System.Windows.Controls.RowDefinition
  $rowTop.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
  $rowBot = New-Object System.Windows.Controls.RowDefinition
  $rowBot.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
  $grid.RowDefinitions.Add($rowTop) | Out-Null
  $grid.RowDefinitions.Add($rowBot) | Out-Null

  $dot = New-Object System.Windows.Shapes.Ellipse
  $dot.Width = 8; $dot.Height = 8
  $dot.Fill = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($dotHex)))
  $dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $dot.Margin = New-Object System.Windows.Thickness(0,0,10,0)

  $ink = Get-PanelInk

  $txt = New-Object System.Windows.Controls.TextBlock
  $txt.Text = if ($title) { $title } else { $id }
  $txt.Foreground = C $ink.Primary
  $txt.FontSize = 13
  $txt.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
  $txt.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

  $sub = New-Object System.Windows.Controls.TextBlock
  $sub.Text = $subText
  $sub.Foreground = C $ink.Secondary
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
  $time.Foreground = C $ink.Tertiary
  $time.FontSize = 11
  $time.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right

  $tag = New-Object System.Windows.Controls.TextBlock
  $tag.Text = $phaseText
  $tag.Foreground = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($dotHex)))
  $tag.FontSize = 11
  $tag.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right

  $right.Children.Add($time) | Out-Null
  $right.Children.Add($tag) | Out-Null

 # TextBlock Button Button
 # TextBlock
 # Tab
  $xMark = New-Object System.Windows.Controls.TextBlock
  $xMark.Text = 'x'
  $xMark.FontSize = 15
  $xMark.Foreground = C $ink.Tertiary
  $xMark.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $xMark.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
  $xMark.Margin = New-Object System.Windows.Thickness(10,0,2,0)
  $xMark.Cursor = [System.Windows.Input.Cursor]::Hand
  $xMark.ToolTip = 'Remove from the list (no switch)'
 # TextBlock Tab Enter/Space
  $xMark.Focusable = $true

 # hover " "
  $xIdleBrush = $xMark.Foreground
  $xHotBrush = (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#FFFF453A')))
 # $args[0] sender TextBlock MouseLeftButtonDown
 # $args[1]
  $xMark.Add_MouseEnter({ $args[0].Foreground = $xHotBrush }.GetNewClosure())
  $xMark.Add_MouseLeave({ $args[0].Foreground = $xIdleBrush }.GetNewClosure())

 # Handled = true Border MouseLeftButtonDown
 # Border Border +
 # Invoke-SessionDismiss Restore-ForegroundAfterAction
  $xMark.Add_MouseLeftButtonDown({
    $args[1].Handled = $true
    Invoke-SessionDismiss $id
  }.GetNewClosure())

 # Enter / Space
 # Tab
  $xMark.Add_KeyDown({
    $key = [string]$args[1].Key
 # WPF Enter Return Enter
    if ($key -ne 'Return' -and $key -ne 'Enter' -and $key -ne 'Space') { return }
    $args[1].Handled = $true
    Dbg ("session dismissed by keyboard: " + $key + " " + $id)
    Invoke-SessionDismiss $id
  }.GetNewClosure())

  $grid.Children.Add($dot)   | Out-Null
  $grid.Children.Add($txt)   | Out-Null
  $grid.Children.Add($right) | Out-Null
  $grid.Children.Add($sub)   | Out-Null
  $grid.Children.Add($xMark) | Out-Null
  [System.Windows.Controls.Grid]::SetColumn($dot, 0)
  [System.Windows.Controls.Grid]::SetColumn($txt, 1)
  [System.Windows.Controls.Grid]::SetColumn($right, 2)
  [System.Windows.Controls.Grid]::SetColumn($sub, 1)
  [System.Windows.Controls.Grid]::SetColumn($xMark, 3)
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
 # Handled
 # " " WPF
    if ($args[1].OriginalSource -eq $xMark) { return }
    Invoke-SessionClick $id
  }.GetNewClosure())

  $script:sessionRows.Children.Add($border) | Out-Null
}

# 12 5
function Add-SessionOverflowRow([int]$hidden) {
  if (-not $script:sessionRows) { return }
  if ($hidden -le 0) { return }
  $tb = New-Object System.Windows.Controls.TextBlock
  $tb.Text = '' + $hidden + ' more'
  $tb.Foreground = C (Get-PanelInk).Muted
  $tb.FontSize = 10.5
  $tb.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
  $tb.Margin = New-Object System.Windows.Thickness(0,6,0,2)
  $script:sessionRows.Children.Add($tb) | Out-Null
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
 # " detector "
 # detector ack sessions.json
 # id sessions.json detector
 # pending pending
 # " sessions.json " detector id
 # Show-SessionList
 # id pending
 # pending 4 detector ack 4
 # id
  if ($script:pendingDismiss.Count -gt 0) {
    $present = @{}
    foreach ($s in $items) { $present[[string]$s.id] = $true }
    $now = [DateTime]::UtcNow
    foreach ($pid_ in @($script:pendingDismiss.Keys)) {
      $stamp = $script:pendingDismiss[$pid_]
      $gone = (-not $present.ContainsKey($pid_))
      $expired = $false
      if ($stamp -is [datetime]) { $expired = (($now - $stamp).TotalSeconds -gt 4) }
      if ($gone -or $expired) { $script:pendingDismiss.Remove($pid_) }
    }
    $items = @($items | Where-Object { -not $script:pendingDismiss.ContainsKey([string]$_.id) })
    if (-not $items -or $items.Count -eq 0) { Hide-SessionList; return }
  }
  Clear-SessionRows
 # lastAtMs sinceMs
  $stateOrder = @{
    'working' = 0; 'thinking' = 0; 'waiting' = 1; 'idle' = 2
    'done' = 3; 'error' = 4; 'stopped' = 5; 'running' = 0
  }
  $sorted = @($items | Sort-Object @{ Expression = { $k = [string]$_.phase; if ($stateOrder.ContainsKey($k)) { $stateOrder[$k] } else { 2 } } }, @{ Expression = { if ($_.lastAtMs) { [int64]$_.lastAtMs } else { [int64]$_.sinceMs } }; Descending = $true })
 # " N "
  $total = $sorted.Count
  $hidden = 0
  if ($total -gt $script:MAX_SESSION_ROWS) {
    $hidden = $total - $script:MAX_SESSION_ROWS
    $sorted = @($sorted | Select-Object -First $script:MAX_SESSION_ROWS)
  }
  $i = 0
  foreach ($s in $sorted) {
    Add-SessionRow ([string]$s.id) ([string]$s.title) ([string]$s.phase) ([string]$s.preview) ([string]$s.lastTool) ([int64]$s.lastAtMs) ($i -lt ($sorted.Count - 1) -and $hidden -eq 0)
    $i++
  }
  if ($hidden -gt 0) { Add-SessionOverflowRow $hidden }
 # SessionPanel
 # Margin 106px row 94px
 # 14px
 # row 1 Auto Grid
 # DesiredSize " "
  $script:sessionRowsPanel.Visibility = [System.Windows.Visibility]::Visible
  $script:sessionListRow.Height = [System.Windows.GridLength]::Auto
  $script:sessionRowsPanel.UpdateLayout()
 # DesiredSize Margin (6)
  $listH = [int][Math]::Ceiling($script:sessionRowsPanel.DesiredSize.Height) + 6 + $script:glassMarginPanelBottom
  if ($listH -le 0) { $listH = ($sorted.Count * $script:sessionRowHeight) + 26 }
 # /DIP
  try {
    $wa = [WinAPI]::GetWorkAreaForWindow($window)
    if ($wa.Left -ne -1) {
      $maxH = ($wa.Bottom - $wa.Top) - $window.Top
      $chrome = $script:pillHeight + 2 * $script:glassMargin
      if ($maxH -gt $chrome -and ($chrome + $listH) -gt $maxH) {
        $listH = [int][Math]::Floor($maxH) - $chrome
        Dbg ("session list clamped to the work area: listH=" + $listH)
      }
    }
  } catch {}
  $window.Height = $script:pillHeight + 2 * $script:glassMargin + $listH
 # Height ** **
  try { Sync-GlassGeometry } catch {}
  try { [void](Update-GlassBackdrop) } catch {}
  Dbg ("session list shown: " + $sorted.Count + " hidden=" + $hidden + " winH=" + $window.Height + " listH=" + $listH)
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
  if ($window) { $window.Height = $script:pillHeight + 2 * $script:glassMargin }
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
 # id sessions.json
 # ** ** id
 # ack
 # scripts/lib/Session-Tracker.ps1 $script:SESSION_ID_PATTERN
 # detector widget
  if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$') {
    Dbg "session click: refused an id that is not shaped like a session id"
    return
  }
 # ack.signal detector
 # session
  try {
    if (Write-AckSignal $id) {
      Dbg "session ack written: $id"
    }
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
 # `Start-SessionTerminal $id` "mcode --session <id>"
 # 1. id powershell -Command
 # `x; Set-Content ...` id PowerShell
 # 2. id ** **
 # app
  Dbg ("session click: no target for " + $id + " (no matching tab, no app window) -- not opening a new terminal")
}

# detector ack agent
function Invoke-SessionDismiss([string]$id) {
  if (-not $id) { return }
 # Invoke-SessionClick id sessions.json
  if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$') {
    Dbg "session dismiss: refused an id that is not shaped like a session id"
    return
  }
  if (-not (Write-AckSignal $id)) { return }
 # detector 1 ack
 # sessions.json
 # true Show-SessionList " pending
  $script:pendingDismiss[$id] = [DateTime]::UtcNow
  Dbg ("session dismissed without switching: " + $id)
  try { Show-SessionList } catch { Dbg "SESSION LIST REFRESH FAIL: $($_.Exception.Message)" }
  Restore-ForegroundAfterAction
}

# app ** **
function Get-AppConversationList([IntPtr]$hwnd, [string[]]$knownTitles) {
  if (-not $knownTitles -or $knownTitles.Count -eq 0) { return $null }
  try {
    if (-not $script:uiaReady) {
      Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
      Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
      $script:uiaReady = $true
    }
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
    if (-not $root) { return $null }

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($n in $knownTitles) {
      $nn = ([string]$n).Trim()
      if (-not $nn) { continue }
      $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, $nn)
      $hits = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
      for ($i = 0; $i -lt $hits.Count; $i++) { $candidates.Add($hits.Item($i)) }
    }
    if ($candidates.Count -lt 2) {
      Dbg ("app conversation list: only " + $candidates.Count + " candidate(s) for " + $knownTitles.Count + " known title(s)")
      return $null
    }

    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $best = $null
    $bestDepth = 99
    foreach ($c in $candidates) {
      $node = $c
      $depth = 0
      while ($node -ne $null -and $depth -lt 12) {
        $inside = 0
        try {
          $sub = $node.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                  [System.Windows.Automation.Condition]::TrueCondition)
          foreach ($e in $sub) {
            try {
              $nm = $e.Current.Name
              if ($knownTitles -contains $nm) { $inside++ }
            } catch {}
          }
        } catch { $inside = 0 }
        if ($inside -ge 2 -and $depth -lt $bestDepth) { $best = $node; $bestDepth = $depth }
        try { $node = $walker.GetParent($node) } catch { break }
        $depth++
      }
    }
    Dbg ("app conversation list: " + $candidates.Count + " candidate(s), container depth=" + $bestDepth)
    return $best
  } catch {
    Dbg ("APP CONVERSATION LIST FAIL: " + $_.Exception.Message)
    return $null
  }
}

# Get-AppConversationList
# null
function Get-AppConversationButton([IntPtr]$hwnd, [string]$name, [string[]]$knownTitles) {
  if (-not $name) { return $null }
  try {
    if (-not $script:uiaReady) {
      Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
      Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
      $script:uiaReady = $true
    }
    $list = Get-AppConversationList $hwnd $knownTitles
    if (-not $list) { Dbg 'app conversation list not found'; return $null }
    $cond = New-Object System.Windows.Automation.AndCondition(
      (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, $name)),
      (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button)))
    $hits = $list.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
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
  $known = @()
  try {
    foreach ($s in @(Read-SessionsFile)) {
      if ($s.title) { $known += [string]$s.title }
      foreach ($x in @($s.titles)) { if ($x) { $known += [string]$x } }
    }
  } catch {}
  $known = @($known | Select-Object -Unique)
  if ($known.Count -lt 2) { return $false }
 # UIA 47ms
  $tried = 0
  foreach ($n in $names) {
    if ($tried -ge 4) { break }
    $nn = ([string]$n).Trim()
    if (-not $nn) { continue }
    $tried++
    $el = Get-AppConversationButton ([IntPtr]$app.Hwnd) $nn $known
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

# ** ** Start-SessionTerminal
# "mcode --session <id>"
# review
# 1. id `powershell -Command` id
# base64 sessions.json
# `x; Set-Content ...` id PowerShell "
# 2. ** **
# smoke.mjs

# working family state " " " "
# dot/ring stateText
# family detector $TOOL_FAMILIES family state
# (shell) / (read) / (write) / (search) / (task) /
# (web) / (plan) Apple CIE76 dE
# 20 " " plan
# search
$familyMap = @{
  shell  = '#FF30D158' # bash / shell
  read   = '#FF0A84FF' # read
  write  = '#FFFFD60A' # edit / write
  search = '#FFBF5AF2' # grep / glob
  task   = '#FF40C8E0' # task
  web    = '#FFFF375F' # web_search/fetch
  plan   = '#FF8E8E93' # todowrite
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
 # Apple
  $smap = Get-GlassStateMap
  $fmap = Get-GlassFamilyMap
  $s = $smap[$State]
  if (!$s) { $s = $smap['idle'] }
 # active thinking/working/waiting done / error
  $dotHex  = $s.dot
  $ringHex = $s.ring
  if ($Family -and $State -in @('thinking','working','waiting')) {
    $famHex = $fmap[$Family]
    if ($famHex) { $dotHex = $famHex; $ringHex = $famHex }
  }
  $script:statusDot.Fill = C $dotHex
  $script:pulseRing.Fill = C $ringHex
 # " " done / error
  if ($State -in @('thinking','working','waiting')) {
 # Effect.Color Color Brush C() Brush
    $script:statusDotGlow.Color = [System.Windows.Media.ColorConverter]::ConvertFromString($dotHex)
    $script:statusDotGlow.Opacity = 0.85
  } else {
    $script:statusDotGlow.Opacity = 0.0
  }
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
    $ink = Get-GlassInk
    $col = if ($Usage5h -ge 50) { $ink.Dim } # >= 50%
           elseif ($Usage5h -ge 20) { $ink.Warn } # 20-50%
           else { $ink.Danger } # < 20%
    $script:usage5hText.Foreground = C $col
  } else {
    $script:usage5hText.Text = ''
    $script:usage5hText.Foreground = C (Get-GlassInk).Dim
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

# DropShadowEffect
# layered alpha
# cfg.x/cfg.y ** **
$screen = [System.Windows.SystemParameters]::WorkArea
if ($cfg.x -lt 0) {
  $window.Left = [Math]::Floor(($screen.Width - $cfg.width) / 2) + $screen.Left - $script:glassMargin
  $window.Top  = $screen.Top + 14 - $script:glassMargin
} else {
  $window.Left = $cfg.x - $script:glassMargin
  $window.Top  = $cfg.y - $script:glassMargin
}
$window.Width  = $cfg.width + 2 * $script:glassMargin
$window.Height = $cfg.height + 2 * $script:glassMargin
# row 0 " + " session
$script:pillHeight = $cfg.height
try {
  $pillRow = $window.FindName('PillRow')
  if ($pillRow) { $pillRow.Height = New-Object System.Windows.GridLength($script:pillHeight + 2 * $script:glassMargin) }
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
 # MouseEnter widget
    Save-ForegroundBeforeAction
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
 # + MouseMove 250ms
  try {
    $now2 = [DateTime]::UtcNow
    if (($now2 - $script:glassDragStamp).TotalMilliseconds -ge 250) {
      $script:glassDragStamp = $now2
      [void](Update-GlassBackdrop)
    }
  } catch {}
})
$window.Add_MouseLeftButtonUp({
  try { $window.ReleaseMouseCapture() } catch {}
  $wasDrag = $script:didDrag
  try {
    if ($script:dragStart -and -not $script:didDrag) {
      Dbg 'CLICK detected'
      Flash-Click
      Invoke-ClickTarget
    }
  } catch {
    Dbg "CLICK FAIL: $($_.Exception.Message)"
  }
  if ($wasDrag) {
    try { [void](Update-GlassBackdrop) } catch {}
  }
  $script:dragStart = $null
  $script:didDrag = $false
})

# session /
# pill -> ->
# pill " "
$window.Add_MouseEnter({
  if ($script:listHideTimer) { try { $script:listHideTimer.Stop() } catch {} ; $script:listHideTimer = $null }
  Save-ForegroundBeforeAction
  try { Show-SessionList } catch { Dbg "SESSION LIST SHOW FAIL: $($_.Exception.Message)" }
})
$window.Add_MouseLeave({
  Schedule-SessionListHide
})


# ContentRendered Loaded Loaded
# ActualWidth/ActualHeight
# XAML
$window.Add_ContentRendered({
  try {
    Sync-GlassGeometry
    [void](Apply-GlassMaterial 'Pill' 0.25 $false)
    [void](Update-GlassBackdrop)
    Dbg 'glass material initialized'
  } catch {
    Dbg "GLASS INIT FAIL: $($_.Exception.Message)"
  }
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
 # 1) Liquid Glass
 # WWDC25
 # return status.json
  try {
    if ($window.Visibility -eq [System.Windows.Visibility]::Visible -and
        ([DateTime]::UtcNow - $script:glassLastUpdate).TotalMilliseconds -ge $script:glassRefreshMs) {
      Sync-GlassGeometry
      [void](Update-GlassBackdrop)
    }
  } catch {}
 # 2) "show" "mcode-island show"
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
    $cur.x = $window.Left + $script:glassMargin
    $cur.y = $window.Top + $script:glassMargin
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
