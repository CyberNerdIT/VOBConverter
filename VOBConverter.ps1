<#
.SYNOPSIS
  VOB Converter - a WinUtil-style GUI for ripping DVD-Video discs to MP4 with VLC.

.DESCRIPTION
  WPF menu (dark WinUtil theme) with an always-on disc watcher:
    - Optical drives are polled continuously in the background; every disc
      inserted into the Windows machine shows up as a card in the menu the
      moment it is ready, and disappears when ejected.
    - Each DVD-Video disc card lists every title set on the disc with size
      and part count; the largest is auto-selected as the main movie, and
      when two title sets are close in size and the auto-select picked the
      wrong one you can tick the right one instead - or manually add VOB
      file(s) to the merge list via 'Add VOB file...'. The card also has an
      editable output name box and Preview / Convert / Test Output buttons.
    - Preview plays a short snippet of the selected files in VLC so you can
      confirm it is the right content.
    - Convert stages the disc to the local machine first: the selected
      VOB files are merged (binary concat) straight off the disc into ONE
      local file under the staging folder (default: Downloads\VOB) - copy
      and merge combined in a single pass. The merged VOB is kept, then
      transcoded to MP4 via VLC CLI (H.264 CRF 18, AAC 256k 48kHz) in a
      background runspace, so the watcher and the UI stay responsive.
    - Test Output plays a snippet of the converted MP4 so you can verify
      the result without hunting for the file.
    - Optional Auto-Convert toggle: when on, every new DVD-Video disc is
      converted automatically on insertion, no clicks needed.

.REQUIREMENTS
  - Windows PowerShell 5.1+ (WPF), VLC installed. No ffmpeg needed.

.USAGE
  powershell -ExecutionPolicy Bypass -File .\VOBConverter.ps1
  Optional: -OutputDir "D:\Rips" -SnippetStart 30 -SnippetLength 15 -PollSeconds 3
#>

param(
    [string]$OutputDir     = "$env:USERPROFILE\Videos\DVD-Rips",
    [string]$StagingDir    = "$env:USERPROFILE\Downloads\VOB",
    [string]$VlcPath       = "C:\Program Files\VideoLAN\VLC\vlc.exe",
    [int]$SnippetStart     = 30,   # seconds into the title to start preview
    [int]$SnippetLength    = 15,   # seconds of preview
    [int]$PollSeconds      = 3
)

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# Shared state between the UI thread and conversion runspaces (WinUtil pattern)
$sync = [hashtable]::Synchronized(@{})
$sync.Seen          = @{}     # driveLetter -> disc id already announced
$sync.Converting    = $false
$sync.ConvertingId  = ''
$sync.LastSignature = $null
$sync.Runspaces     = New-Object System.Collections.ArrayList
$sync.NameOverrides = @{}     # discId -> output name the user typed (survives menu rebuilds)
$sync.TitleSelections = @{}   # discId -> hashtable of VTS number -> $true/$false (checkbox state)
$sync.ExtraFiles      = @{}   # discId -> ArrayList of manually added VOB paths
# Background runspaces enqueue log lines here; the UI timer drains the queue
$sync.LogQueue      = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))

# --- XAML (WinUtil dark theme) ----------------------------------------------
$inputXML = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="VOB Converter"
    WindowStartupLocation="CenterScreen"
    UseLayoutRounding="True"
    WindowStyle="None"
    ResizeMode="CanResizeWithGrip"
    AllowsTransparency="True"
    Background="Transparent"
    Width="820" Height="640" MinWidth="700" MinHeight="520">
    <Window.Resources>
        <!-- WinUtil dark theme palette -->
        <SolidColorBrush x:Key="MainBackgroundColor" Color="#232629"/>
        <SolidColorBrush x:Key="MainForegroundColor" Color="#F7F7F7"/>
        <SolidColorBrush x:Key="LabelboxForegroundColor" Color="#0567ff"/>
        <SolidColorBrush x:Key="BorderColor" Color="#2F373D"/>
        <SolidColorBrush x:Key="CardBackgroundColor" Color="#2E3135"/>
        <SolidColorBrush x:Key="ButtonBackgroundColor" Color="#1E3747"/>
        <SolidColorBrush x:Key="ButtonBackgroundMouseoverColor" Color="#3B4252"/>
        <SolidColorBrush x:Key="ButtonBackgroundPressedColor" Color="#F7F7F7"/>
        <SolidColorBrush x:Key="ButtonForegroundColor" Color="#F7F7F7"/>
        <SolidColorBrush x:Key="ToggleButtonOnColor" Color="#2e77ff"/>
        <SolidColorBrush x:Key="ToggleButtonOffColor" Color="#707070"/>
        <SolidColorBrush x:Key="AccentColor" Color="#2e77ff"/>

        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource MainForegroundColor}"/>
            <Setter Property="FontFamily" Value="Arial"/>
            <Setter Property="FontSize" Value="12"/>
        </Style>

        <Style TargetType="TextBox">
            <Setter Property="Foreground" Value="{StaticResource MainForegroundColor}"/>
            <Setter Property="Background" Value="{StaticResource CardBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="4,2"/>
            <Setter Property="FontFamily" Value="Arial"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="CaretBrush" Value="{StaticResource MainForegroundColor}"/>
        </Style>

        <Style x:Key="WinUtilButton" TargetType="Button">
            <Setter Property="Foreground" Value="{StaticResource ButtonForegroundColor}"/>
            <Setter Property="Background" Value="{StaticResource ButtonBackgroundColor}"/>
            <Setter Property="FontFamily" Value="Arial"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Height" Value="25"/>
            <Setter Property="MinWidth" Value="90"/>
            <Setter Property="Margin" Value="1"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                BorderBrush="{StaticResource BorderColor}"
                                BorderThickness="1" CornerRadius="2">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="8,0"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="{StaticResource ButtonBackgroundMouseoverColor}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="{StaticResource ButtonBackgroundPressedColor}"/>
                                <Setter Property="Foreground" Value="#232629"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="bd" Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="TitleBarButton" TargetType="Button" BasedOn="{StaticResource WinUtilButton}">
            <Setter Property="MinWidth" Value="34"/>
            <Setter Property="Width" Value="34"/>
            <Setter Property="Height" Value="26"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Background" Value="Transparent"/>
        </Style>

        <!-- WinUtil-style pill toggle -->
        <Style x:Key="ToggleSwitch" TargetType="CheckBox">
            <Setter Property="Foreground" Value="{StaticResource MainForegroundColor}"/>
            <Setter Property="FontFamily" Value="Arial"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <StackPanel Orientation="Horizontal">
                            <Border x:Name="track" Width="38" Height="18" CornerRadius="9"
                                    Background="{StaticResource ToggleButtonOffColor}" VerticalAlignment="Center">
                                <Ellipse x:Name="dot" Width="12" Height="12" Fill="#F7F7F7"
                                         HorizontalAlignment="Left" Margin="3,0,0,0"/>
                            </Border>
                            <ContentPresenter VerticalAlignment="Center" Margin="8,0,0,0"/>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="track" Property="Background" Value="{StaticResource ToggleButtonOnColor}"/>
                                <Setter TargetName="dot" Property="HorizontalAlignment" Value="Right"/>
                                <Setter TargetName="dot" Property="Margin" Value="0,0,3,0"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Border Background="{StaticResource MainBackgroundColor}"
            BorderBrush="{StaticResource BorderColor}" BorderThickness="1" CornerRadius="10">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="40"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="150"/>
            </Grid.RowDefinitions>

            <!-- Title bar -->
            <Grid Grid.Row="0" Name="TitleBar" Background="Transparent">
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="12,0,0,0">
                    <TextBlock Text="&#128191;" FontSize="18" VerticalAlignment="Center"/>
                    <TextBlock Text="VOB Converter" FontFamily="Consolas, Monaco" FontSize="16"
                               FontWeight="Bold" VerticalAlignment="Center" Margin="8,0,0,0"/>
                    <TextBlock Name="WatcherStateText" Text="  watcher: ON" FontFamily="Consolas, Monaco"
                               FontSize="12" VerticalAlignment="Center" Margin="10,2,0,0"
                               Foreground="{StaticResource ToggleButtonOnColor}"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,8,0">
                    <Button Name="MinimizeButton" Style="{StaticResource TitleBarButton}" Content="&#x2500;"/>
                    <Button Name="CloseButton" Style="{StaticResource TitleBarButton}" Content="&#x2715;"/>
                </StackPanel>
            </Grid>

            <!-- Settings -->
            <Border Grid.Row="1" Margin="10,0,10,8" Padding="10"
                    Background="{StaticResource CardBackgroundColor}"
                    BorderBrush="{StaticResource BorderColor}" BorderThickness="1" CornerRadius="5">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <TextBlock Grid.Row="0" Grid.Column="0" Text="Output folder" VerticalAlignment="Center" Margin="0,0,8,4"
                               Foreground="{StaticResource LabelboxForegroundColor}"/>
                    <TextBox   Grid.Row="0" Grid.Column="1" Name="OutputDirBox" Margin="0,0,14,4"/>
                    <TextBlock Grid.Row="0" Grid.Column="2" Text="VLC path" VerticalAlignment="Center" Margin="0,0,8,4"
                               Foreground="{StaticResource LabelboxForegroundColor}"/>
                    <TextBox   Grid.Row="0" Grid.Column="3" Name="VlcPathBox" Margin="0,0,14,4"/>
                    <CheckBox  Grid.Row="0" Grid.Column="4" Grid.RowSpan="2" Name="AutoConvertToggle"
                               Style="{StaticResource ToggleSwitch}" Content="Auto-Convert on insert"
                               VerticalAlignment="Center"/>

                    <TextBlock Grid.Row="1" Grid.Column="0" Text="Staging folder (copy + merge)" VerticalAlignment="Center" Margin="0,0,8,0"
                               Foreground="{StaticResource LabelboxForegroundColor}"/>
                    <TextBox   Grid.Row="1" Grid.Column="1" Name="StagingDirBox" Margin="0,0,14,0"/>
                    <StackPanel Grid.Row="1" Grid.Column="2" Grid.ColumnSpan="2" Orientation="Horizontal">
                        <TextBlock Text="Preview start (s)" VerticalAlignment="Center" Margin="0,0,8,0"
                                   Foreground="{StaticResource LabelboxForegroundColor}"/>
                        <TextBox Name="SnippetStartBox" Width="50" Margin="0,0,14,0"/>
                        <TextBlock Text="Preview length (s)" VerticalAlignment="Center" Margin="0,0,8,0"
                                   Foreground="{StaticResource LabelboxForegroundColor}"/>
                        <TextBox Name="SnippetLengthBox" Width="50"/>
                    </StackPanel>
                </Grid>
            </Border>

            <!-- Disc menu -->
            <Border Grid.Row="2" Margin="10,0,10,8" Padding="6"
                    BorderBrush="{StaticResource BorderColor}" BorderThickness="1" CornerRadius="5">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel Name="DiscPanel"/>
                </ScrollViewer>
            </Border>

            <!-- Progress -->
            <Grid Grid.Row="3" Margin="10,0,10,6">
                <ProgressBar Name="BusyBar" Height="6" IsIndeterminate="True" Visibility="Collapsed"
                             Foreground="{StaticResource AccentColor}" Background="Transparent" BorderThickness="0"/>
            </Grid>

            <!-- Log -->
            <Border Grid.Row="4" Margin="10,0,10,10" Padding="4"
                    Background="#1A1A1A" BorderBrush="{StaticResource BorderColor}" BorderThickness="1" CornerRadius="5">
                <TextBox Name="LogBox" IsReadOnly="True" TextWrapping="Wrap" BorderThickness="0"
                         Background="Transparent" FontFamily="Consolas, Monaco" FontSize="11"
                         VerticalScrollBarVisibility="Auto"/>
            </Border>
        </Grid>
    </Border>
</Window>
'@

try {
    $sync.Form = [Windows.Markup.XamlReader]::Parse($inputXML)
} catch {
    Write-Host "Failed to parse XAML: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Grab named controls into $sync (WinUtil pattern)
foreach ($name in @('TitleBar','WatcherStateText','MinimizeButton','CloseButton',
                    'OutputDirBox','StagingDirBox','VlcPathBox','AutoConvertToggle',
                    'SnippetStartBox','SnippetLengthBox','DiscPanel','BusyBar','LogBox')) {
    $sync[$name] = $sync.Form.FindName($name)
}

$sync.OutputDirBox.Text     = $OutputDir
$sync.StagingDirBox.Text    = $StagingDir
$sync.VlcPathBox.Text       = $VlcPath
$sync.SnippetStartBox.Text  = "$SnippetStart"
$sync.SnippetLengthBox.Text = "$SnippetLength"

# --- helpers -----------------------------------------------------------------
function Write-VCLog {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message
    $sync.LogBox.AppendText($line + [Environment]::NewLine)
    $sync.LogBox.ScrollToEnd()
}

function Get-VCTitleSets {
    param([string]$VideoTsPath)

    # Group VTS_xx_1..9.VOB by title set number; skip VTS_xx_0.VOB (menus)
    $groups = Get-ChildItem -Path $VideoTsPath -Filter 'VTS_*.VOB' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^VTS_(\d\d)_([1-9])\.VOB$' } |
        Group-Object { $_.Name.Substring(4,2) }

    if (-not $groups) { return @() }

    $sets = foreach ($g in $groups) {
        [pscustomobject]@{
            Number = $g.Name
            Vobs   = @($g.Group | Sort-Object Name)   # part order: VTS_xx_1, _2, ...
            Size   = ($g.Group | Measure-Object Length -Sum).Sum
        }
    }

    # Largest first: [0] is the auto-selected "main movie" candidate
    return @($sets | Sort-Object Size -Descending)
}

function Get-VCSelectedVobPaths {
    # The files that will actually be merged: the title sets ticked on the disc
    # card (defaults to the largest set), plus any manually added VOB files.
    param([string]$VideoTsPath, [string]$DiscId)

    $sets  = Get-VCTitleSets -VideoTsPath $VideoTsPath
    $sel   = $sync.TitleSelections[$DiscId]
    $paths = New-Object System.Collections.Generic.List[string]

    if ($sets.Count -gt 0) {
        if (-not $sel) {
            foreach ($v in $sets[0].Vobs) { $paths.Add($v.FullName) }   # auto: largest title set
        } else {
            foreach ($s in ($sets | Sort-Object Number)) {
                if ($sel[$s.Number]) { foreach ($v in $s.Vobs) { $paths.Add($v.FullName) } }
            }
        }
    }

    $extras = $sync.ExtraFiles[$DiscId]
    if ($extras) {
        foreach ($p in $extras) {
            if (Test-Path $p) { $paths.Add($p) }
            else { Write-VCLog "Added file no longer found, skipping: $p" }
        }
    }

    return ,$paths
}

function Invoke-VCPreview {
    param([string]$VobPath, [string]$Label)

    $vlc = $sync.VlcPathBox.Text
    if (-not (Test-Path $vlc)) { Write-VCLog "VLC not found at $vlc - fix the VLC path."; return }

    $start  = 30; [void][int]::TryParse($sync.SnippetStartBox.Text,  [ref]$start)
    $length = 15; [void][int]::TryParse($sync.SnippetLengthBox.Text, [ref]$length)

    Write-VCLog "Previewing '$Label' ($([System.IO.Path]::GetFileName($VobPath)))..."
    $vlcArgs = @(
        "`"$VobPath`"",
        "--start-time=$start",
        "--run-time=$length",
        "--play-and-exit",
        "--no-video-title-show"
    )
    # Not -Wait: the watcher and UI stay live while VLC plays the snippet
    Start-Process -FilePath $vlc -ArgumentList $vlcArgs
}

function Invoke-VCTestOutput {
    param([string]$OutputName, [string]$Label)

    $vlc = $sync.VlcPathBox.Text
    if (-not (Test-Path $vlc)) { Write-VCLog "VLC not found at $vlc - fix the VLC path."; return }

    $safeName = Get-VCSafeName -Name $OutputName -Fallback $Label
    $outDir   = $sync.OutputDirBox.Text

    # Newest MP4 matching the name (conversions of an existing name get a timestamp suffix)
    $candidate = Get-ChildItem -Path $outDir -Filter "$safeName*.mp4" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $candidate) {
        Write-VCLog "No converted output named '$safeName*.mp4' in $outDir yet - run Convert first."
        return
    }

    $start  = 30; [void][int]::TryParse($sync.SnippetStartBox.Text,  [ref]$start)
    $length = 15; [void][int]::TryParse($sync.SnippetLengthBox.Text, [ref]$length)

    Write-VCLog "Testing output: $($candidate.FullName) ($([math]::Round($candidate.Length/1MB,1)) MB)..."
    $vlcArgs = @(
        "`"$($candidate.FullName)`"",
        "--start-time=$start",
        "--run-time=$length",
        "--play-and-exit",
        "--no-video-title-show"
    )
    Start-Process -FilePath $vlc -ArgumentList $vlcArgs
}

function Get-VCSafeName {
    param([string]$Name, [string]$Fallback)
    $safe = ($Name -replace '[^\w\-]', '_').Trim('_')
    if (-not $safe) { $safe = ($Fallback -replace '[^\w\-]', '_').Trim('_') }
    if (-not $safe) { $safe = "dvd_$(Get-Date -Format yyyyMMdd_HHmmss)" }
    return $safe
}

function Start-VCConversion {
    param([string]$VideoTsPath, [string]$Label, [string]$DiscId, [string]$OutputName)

    if ($sync.Converting) {
        Write-VCLog "A conversion is already running - wait for it to finish."
        return
    }

    $vlc = $sync.VlcPathBox.Text
    if (-not (Test-Path $vlc)) { Write-VCLog "VLC not found at $vlc - fix the VLC path."; return }

    $outDir     = $sync.OutputDirBox.Text
    $stagingDir = $sync.StagingDirBox.Text
    foreach ($dir in @($outDir, $stagingDir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        catch { Write-VCLog "Cannot create folder '$dir': $($_.Exception.Message)"; return }
    }

    $vobPaths = Get-VCSelectedVobPaths -VideoTsPath $VideoTsPath -DiscId $DiscId
    if ($vobPaths.Count -eq 0) {
        Write-VCLog "Nothing selected on '$Label' - tick at least one title set or add a VOB file."
        return
    }

    $safeName = Get-VCSafeName -Name $OutputName -Fallback $Label
    $mergedVob = Join-Path $stagingDir "$safeName.vob"
    $outFile   = Join-Path $outDir "$safeName.mp4"
    if (Test-Path $outFile) {
        $outFile = Join-Path $outDir ("{0}_{1}.mp4" -f $safeName, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    }

    $sync.Converting    = $true
    $sync.ConvertingId  = $DiscId
    $sync.LastSignature = $null   # force disc menu rebuild so buttons reflect busy state
    $sync.BusyBar.Visibility = 'Visible'
    Write-VCLog "Converting '$Label' as '$safeName' ($($vobPaths.Count) VOB file(s)) -> $outFile"
    Write-VCLog ("Merge list: " + (($vobPaths | ForEach-Object { [System.IO.Path]::GetFileName($_) }) -join ', '))

    $convertScript = {
        param([string[]]$VobPaths, [string]$Vlc, [string]$MergedVob, [string]$OutFile)

        function Send-Log([string]$Message) {
            # UI timer drains this queue on its next tick (thread-safe, no dispatcher needed)
            $sync.LogQueue.Enqueue($Message)
        }

        try {
            # Copy + merge in one pass: read the title's VOB parts straight off
            # the disc and binary-concat them into ONE local file in the staging
            # folder. The merged file is kept as the local copy of the disc.
            Send-Log "Copying + merging $($VobPaths.Count) VOB part(s) from disc -> $MergedVob ..."
            $out = [System.IO.File]::Create($MergedVob)
            try {
                foreach ($v in $VobPaths) {
                    $in = [System.IO.File]::OpenRead($v)
                    try { $in.CopyTo($out) } finally { $in.Dispose() }
                }
            } finally { $out.Dispose() }
            $mergedMb = [math]::Round((Get-Item $MergedVob).Length / 1MB, 1)
            Send-Log "Merged VOB staged locally: $MergedVob ($mergedMb MB). Disc is no longer needed."

            Send-Log "Transcoding with VLC (H.264 CRF 18, AAC 256k) - this can take a while..."
            $sout = "#transcode{vcodec=h264,venc=x264{crf=18,preset=slow},acodec=mp4a,ab=256,channels=2,samplerate=48000}:std{access=file,mux=mp4,dst='$OutFile'}"
            $vlcArgs = @(
                '--intf', 'dummy',
                '--no-repeat', '--no-loop',
                "`"$MergedVob`"",
                "--sout=$sout",
                'vlc://quit'
            )
            Start-Process -FilePath $Vlc -ArgumentList $vlcArgs -Wait -WindowStyle Hidden

            if (Test-Path $OutFile) {
                $mb = [math]::Round((Get-Item $OutFile).Length / 1MB, 1)
                Send-Log "Done: $OutFile ($mb MB). Use 'Test Output' on the disc card to verify it."
            } else {
                Send-Log "WARNING: output file not created - VLC transcode failed. The merged VOB is still at $MergedVob."
            }
        } catch {
            Send-Log "ERROR during conversion: $($_.Exception.Message)"
        } finally {
            $sync.Converting    = $false
            $sync.ConvertingId  = ''
            $sync.LastSignature = $null   # force menu rebuild -> re-enable buttons
        }
    }

    $initialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $varEntry = New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'sync', $sync, $null
    $initialSessionState.Variables.Add($varEntry)
    $runspace = [runspacefactory]::CreateRunspace($initialSessionState)
    $runspace.Open()

    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript($convertScript).
        AddArgument([string[]]$vobPaths).
        AddArgument($vlc).
        AddArgument($mergedVob).
        AddArgument($outFile)
    [void]$ps.BeginInvoke()
    [void]$sync.Runspaces.Add(@{ PowerShell = $ps; Runspace = $runspace })
}

# --- disc menu ---------------------------------------------------------------
function New-VCDiscCard {
    param($Drive)

    $letter  = $Drive.Name.TrimEnd('\')
    $ready   = $Drive.IsReady
    $label   = if ($ready) { $Drive.VolumeLabel } else { '' }
    $discId  = "$letter|$label"
    $videoTs = Join-Path $Drive.Name 'VIDEO_TS'
    $isDvd   = $ready -and (Test-Path $videoTs)

    $card = New-Object System.Windows.Controls.Border
    $card.CornerRadius    = New-Object System.Windows.CornerRadius 5
    $card.Margin          = New-Object System.Windows.Thickness 4
    $card.Padding         = New-Object System.Windows.Thickness 10
    $card.Background      = $sync.Form.Resources['CardBackgroundColor']
    $card.BorderBrush     = $sync.Form.Resources['BorderColor']
    $card.BorderThickness = New-Object System.Windows.Thickness 1

    $grid = New-Object System.Windows.Controls.Grid
    $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = [System.Windows.GridLength]::Auto
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = New-Object System.Windows.GridLength(1, 'Star')
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::Auto
    [void]$grid.ColumnDefinitions.Add($c0)
    [void]$grid.ColumnDefinitions.Add($c1)
    [void]$grid.ColumnDefinitions.Add($c2)

    $icon = New-Object System.Windows.Controls.TextBlock
    $icon.Text = [char]::ConvertFromUtf32(0x1F4BF)   # optical disc emoji
    $icon.FontSize = 26
    $icon.VerticalAlignment = 'Center'
    $icon.Margin = New-Object System.Windows.Thickness 0,0,12,0
    if (-not $ready) { $icon.Opacity = 0.35 }
    [System.Windows.Controls.Grid]::SetColumn($icon, 0)
    [void]$grid.Children.Add($icon)

    $info = New-Object System.Windows.Controls.StackPanel
    $info.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($info, 1)

    $title = New-Object System.Windows.Controls.TextBlock
    $title.FontSize = 14
    $title.FontWeight = 'Bold'
    $title.Foreground = $sync.Form.Resources['MainForegroundColor']
    $detail = New-Object System.Windows.Controls.TextBlock
    $detail.FontSize = 11
    $detail.Opacity = 0.75
    $detail.Foreground = $sync.Form.Resources['MainForegroundColor']

    $sets = @()
    if (-not $ready) {
        $title.Text  = "$letter  -  no disc"
        $title.Opacity = 0.5
        $detail.Text = "Insert a DVD and it will show up here automatically."
    } elseif (-not $isDvd) {
        $title.Text  = "$letter  -  '$label'"
        $detail.Text = "No VIDEO_TS folder - not a DVD-Video disc."
    } else {
        $sets = Get-VCTitleSets -VideoTsPath $videoTs
        if ($sets.Count -gt 0) {
            $title.Text  = "$letter  -  '$label'"
            $detail.Text = "DVD-Video - $($sets.Count) title set(s). Largest is auto-selected; untick/tick to correct it."
        } else {
            $title.Text  = "$letter  -  '$label'"
            $detail.Text = "DVD-Video, but no title VOBs found."
            $isDvd = $false
        }
    }
    [void]$info.Children.Add($title)
    [void]$info.Children.Add($detail)

    if ($isDvd) {
        # Remembered selection (survives menu rebuilds); default = largest title set
        if (-not $sync.TitleSelections.ContainsKey($discId)) {
            $init = @{}
            $init[$sets[0].Number] = $true
            $sync.TitleSelections[$discId] = $init
        }
        $sel = $sync.TitleSelections[$discId]

        $setPanel = New-Object System.Windows.Controls.StackPanel
        $setPanel.Margin = New-Object System.Windows.Thickness 0,6,0,0
        foreach ($s in ($sets | Sort-Object Number)) {
            $auto = if ($s.Number -eq $sets[0].Number) { '   (auto-selected: largest)' } else { '' }
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content    = 'VTS_{0} - {1} part(s) - {2} GB{3}' -f $s.Number, $s.Vobs.Count, [math]::Round($s.Size/1GB, 2), $auto
            $cb.Foreground = $sync.Form.Resources['MainForegroundColor']
            $cb.FontSize   = 11
            $cb.Margin     = New-Object System.Windows.Thickness 0,1,0,1
            $cb.IsChecked  = [bool]$sel[$s.Number]
            $cb.Tag        = @{ DiscId = $discId; Vts = $s.Number }
            $cb.Add_Checked({   param($cbSender, $e) $sync.TitleSelections[$cbSender.Tag.DiscId][$cbSender.Tag.Vts] = $true })
            $cb.Add_Unchecked({ param($cbSender, $e) $sync.TitleSelections[$cbSender.Tag.DiscId][$cbSender.Tag.Vts] = $false })
            [void]$setPanel.Children.Add($cb)
        }
        [void]$info.Children.Add($setPanel)

        # Manually add VOB files if the auto-selection got it wrong
        if (-not $sync.ExtraFiles.ContainsKey($discId)) {
            $sync.ExtraFiles[$discId] = New-Object System.Collections.ArrayList
        }
        $extraRow = New-Object System.Windows.Controls.StackPanel
        $extraRow.Orientation = 'Horizontal'
        $extraRow.Margin = New-Object System.Windows.Thickness 0,4,0,0

        $extraLabel = New-Object System.Windows.Controls.TextBlock
        $extraLabel.FontSize = 11
        $extraLabel.Opacity  = 0.75
        $extraLabel.VerticalAlignment = 'Center'
        $extraLabel.Margin = New-Object System.Windows.Thickness 8,0,0,0
        $extraLabel.Foreground = $sync.Form.Resources['MainForegroundColor']
        if ($sync.ExtraFiles[$discId].Count -gt 0) {
            $extraLabel.Text = "$($sync.ExtraFiles[$discId].Count) added file(s)"
        }

        $extraTag = @{ DiscId = $discId; VideoTs = $videoTs; Label = $extraLabel }

        $addBtn = New-Object System.Windows.Controls.Button
        $addBtn.Style   = $sync.Form.Resources['WinUtilButton']
        $addBtn.Content = 'Add VOB file...'
        $addBtn.ToolTip = 'Manually add VOB file(s) to the merge list, e.g. when the auto-selected title set is wrong'
        $addBtn.Tag     = $extraTag
        $addBtn.Add_Click({
            param($btnSender, $e)
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Title  = 'Add VOB file(s) to the merge list'
            $dlg.Filter = 'VOB files (*.vob)|*.vob|All files (*.*)|*.*'
            $dlg.Multiselect = $true
            if (Test-Path $btnSender.Tag.VideoTs) { $dlg.InitialDirectory = $btnSender.Tag.VideoTs }
            if ($dlg.ShowDialog()) {
                $list = $sync.ExtraFiles[$btnSender.Tag.DiscId]
                foreach ($f in $dlg.FileNames) {
                    if (-not $list.Contains($f)) {
                        [void]$list.Add($f)
                        Write-VCLog "Added to merge list: $f"
                    }
                }
                $btnSender.Tag.Label.Text = "$($list.Count) added file(s)"
            }
        })

        $clearBtn = New-Object System.Windows.Controls.Button
        $clearBtn.Style   = $sync.Form.Resources['WinUtilButton']
        $clearBtn.Content = 'Clear added'
        $clearBtn.ToolTip = 'Remove all manually added files from the merge list'
        $clearBtn.Tag     = $extraTag
        $clearBtn.Add_Click({
            param($btnSender, $e)
            $list = $sync.ExtraFiles[$btnSender.Tag.DiscId]
            if ($list.Count -gt 0) {
                $list.Clear()
                Write-VCLog 'Cleared manually added files from the merge list.'
            }
            $btnSender.Tag.Label.Text = ''
        })

        [void]$extraRow.Children.Add($addBtn)
        [void]$extraRow.Children.Add($clearBtn)
        [void]$extraRow.Children.Add($extraLabel)
        [void]$info.Children.Add($extraRow)
    }
    [void]$grid.Children.Add($info)

    if ($isDvd) {
        $actions = New-Object System.Windows.Controls.StackPanel
        $actions.Orientation = 'Vertical'
        $actions.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($actions, 2)

        $busy = [bool]$sync.Converting
        $isThisConverting = $busy -and ($sync.ConvertingId -eq $discId)

        # Output name row: type a new name for the converted file
        $nameRow = New-Object System.Windows.Controls.StackPanel
        $nameRow.Orientation = 'Horizontal'
        $nameRow.Margin = New-Object System.Windows.Thickness 0,0,0,4
        $nameLabel = New-Object System.Windows.Controls.TextBlock
        $nameLabel.Text = 'Output name'
        $nameLabel.VerticalAlignment = 'Center'
        $nameLabel.Margin = New-Object System.Windows.Thickness 0,0,8,0
        $nameLabel.Foreground = $sync.Form.Resources['LabelboxForegroundColor']
        $nameBox = New-Object System.Windows.Controls.TextBox
        $nameBox.Width = 220
        $nameBox.Style = $null
        $nameBox.Foreground  = $sync.Form.Resources['MainForegroundColor']
        $nameBox.Background  = $sync.Form.Resources['MainBackgroundColor']
        $nameBox.BorderBrush = $sync.Form.Resources['BorderColor']
        $nameBox.CaretBrush  = $sync.Form.Resources['MainForegroundColor']
        $nameBox.Padding = New-Object System.Windows.Thickness 4,2,4,2
        $nameBox.Text = if ($sync.NameOverrides.ContainsKey($discId)) { $sync.NameOverrides[$discId] }
                        else { Get-VCSafeName -Name '' -Fallback $label }
        $nameBox.Tag = $discId
        $nameBox.Add_TextChanged({
            param($boxSender, $e)
            $sync.NameOverrides[$boxSender.Tag] = $boxSender.Text   # survives menu rebuilds
        })
        [void]$nameRow.Children.Add($nameLabel)
        [void]$nameRow.Children.Add($nameBox)
        [void]$actions.Children.Add($nameRow)

        $buttons = New-Object System.Windows.Controls.StackPanel
        $buttons.Orientation = 'Horizontal'
        $buttons.HorizontalAlignment = 'Right'

        $discInfo = @{ VideoTs = $videoTs; Label = $label; DiscId = $discId; NameBox = $nameBox }

        $previewBtn = New-Object System.Windows.Controls.Button
        $previewBtn.Style   = $sync.Form.Resources['WinUtilButton']
        $previewBtn.Content = 'Preview'
        $previewBtn.ToolTip = 'Play a short snippet of the selected files from the disc'
        $previewBtn.Tag     = $discInfo
        $previewBtn.Add_Click({
            param($btnSender, $e)
            $info = $btnSender.Tag
            $paths = Get-VCSelectedVobPaths -VideoTsPath $info.VideoTs -DiscId $info.DiscId
            if ($paths.Count -gt 0) { Invoke-VCPreview -VobPath $paths[0] -Label $info.Label }
            else { Write-VCLog "Nothing selected on '$($info.Label)' - tick a title set or add a VOB file." }
        })

        $testBtn = New-Object System.Windows.Controls.Button
        $testBtn.Style   = $sync.Form.Resources['WinUtilButton']
        $testBtn.Content = 'Test Output'
        $testBtn.ToolTip = 'Play a snippet of the converted MP4 to verify the result'
        $testBtn.Tag     = $discInfo
        $testBtn.Add_Click({
            param($btnSender, $e)
            $info = $btnSender.Tag
            Invoke-VCTestOutput -OutputName $info.NameBox.Text -Label $info.Label
        })

        $convertBtn = New-Object System.Windows.Controls.Button
        $convertBtn.Style   = $sync.Form.Resources['WinUtilButton']
        $convertBtn.Content = if ($isThisConverting) { 'Converting...' } else { 'Convert to MP4' }
        $convertBtn.IsEnabled = -not $busy
        $convertBtn.ToolTip = 'Copy + merge the VOBs to the staging folder, then convert to MP4'
        $convertBtn.Tag     = $discInfo
        $convertBtn.Add_Click({
            param($btnSender, $e)
            $info = $btnSender.Tag
            Start-VCConversion -VideoTsPath $info.VideoTs -Label $info.Label -DiscId $info.DiscId -OutputName $info.NameBox.Text
        })

        [void]$buttons.Children.Add($previewBtn)
        [void]$buttons.Children.Add($testBtn)
        [void]$buttons.Children.Add($convertBtn)
        [void]$actions.Children.Add($buttons)
        [void]$grid.Children.Add($actions)
    }

    $card.Child = $grid
    return $card
}

function Update-VCDiscMenu {
    $drives = @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'CDRom' })

    # Announce new discs / forget ejected ones (same identity scheme as the CLI version)
    foreach ($d in $drives) {
        $letter = $d.Name.TrimEnd('\')
        if (-not $d.IsReady) {
            if ($sync.Seen.ContainsKey($letter)) {
                Write-VCLog "Disc ejected from $letter."
                $sync.Seen.Remove($letter)
            }
            continue
        }
        $id = "$letter|$($d.VolumeLabel)"
        if ($sync.Seen.ContainsKey($letter) -and $sync.Seen[$letter] -eq $id) { continue }
        $sync.Seen[$letter] = $id

        Write-VCLog "Disc detected in $letter : '$($d.VolumeLabel)'"
        $videoTs = Join-Path $d.Name 'VIDEO_TS'
        if (-not (Test-Path $videoTs)) {
            Write-VCLog "No VIDEO_TS folder on $letter - not a DVD-Video disc."
        } elseif ($sync.AutoConvertToggle.IsChecked) {
            Write-VCLog "Auto-Convert is ON - starting conversion of '$($d.VolumeLabel)'."
            $autoName = ''
            if ($sync.NameOverrides.ContainsKey($id)) { $autoName = $sync.NameOverrides[$id] }
            Start-VCConversion -VideoTsPath $videoTs -Label $d.VolumeLabel -DiscId $id -OutputName $autoName
        }
    }

    # Rebuild the menu only when something actually changed (cheap signature check)
    $parts = foreach ($d in $drives) {
        $lbl = ''
        if ($d.IsReady) { $lbl = $d.VolumeLabel }
        '{0}|{1}|{2}' -f $d.Name, $d.IsReady, $lbl
    }
    $signature = ($parts -join ';') + "|conv=$($sync.Converting)|$($sync.ConvertingId)"
    if ($signature -eq $sync.LastSignature) { return }
    $sync.LastSignature = $signature

    $sync.DiscPanel.Children.Clear()
    if ($drives.Count -eq 0) {
        $none = New-Object System.Windows.Controls.TextBlock
        $none.Text = 'No optical drives found on this machine.'
        $none.Opacity = 0.6
        $none.Margin = New-Object System.Windows.Thickness 8
        [void]$sync.DiscPanel.Children.Add($none)
        return
    }
    foreach ($d in $drives) {
        [void]$sync.DiscPanel.Children.Add((New-VCDiscCard -Drive $d))
    }
}

# --- window chrome wiring ----------------------------------------------------
$sync.TitleBar.Add_MouseLeftButtonDown({ $sync.Form.DragMove() })
$sync.MinimizeButton.Add_Click({ $sync.Form.WindowState = 'Minimized' })
$sync.CloseButton.Add_Click({ $sync.Form.Close() })

# --- always-on watcher -------------------------------------------------------
# The DispatcherTimer never stops while the app runs: discs inserted into the
# machine appear in the menu automatically, ejected ones disappear.
if ($PollSeconds -lt 1) { $PollSeconds = 1 }
$sync.Timer = New-Object System.Windows.Threading.DispatcherTimer
$sync.Timer.Interval = [TimeSpan]::FromSeconds($PollSeconds)
$sync.Timer.Add_Tick({
    # Relay log lines from background conversion runspaces
    while ($sync.LogQueue.Count -gt 0) {
        Write-VCLog ([string]$sync.LogQueue.Dequeue())
    }
    # Busy bar mirrors the conversion state
    $wanted = if ($sync.Converting) { 'Visible' } else { 'Collapsed' }
    if ("$($sync.BusyBar.Visibility)" -ne $wanted) { $sync.BusyBar.Visibility = $wanted }

    Update-VCDiscMenu
})

$sync.Form.Add_Loaded({
    Write-VCLog "VOB Converter started - watching optical drives every $PollSeconds s (always on)."
    if (-not (Test-Path $sync.VlcPathBox.Text)) {
        Write-VCLog "WARNING: VLC not found at '$($sync.VlcPathBox.Text)' - set the correct path above."
    }
    Update-VCDiscMenu
    $sync.Timer.Start()
})

$sync.Form.Add_Closing({
    $sync.Timer.Stop()
    foreach ($entry in $sync.Runspaces) {
        try {
            $entry.PowerShell.Stop()
            $entry.PowerShell.Dispose()
            $entry.Runspace.Dispose()
        } catch { }
    }
})

[void]$sync.Form.ShowDialog()
