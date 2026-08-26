<#
.SYNOPSIS
  Watches for DVD insertion, previews the main title, then offers conversion.

.DESCRIPTION
  Loop polls optical drives. On new disc with VIDEO_TS:
    1. Groups VTS_xx_*.VOB files by title set, picks the largest (= main movie).
    2. Plays a short snippet of it in VLC so you can confirm it's the right content.
    3. Prompts: convert? If yes, concatenates the title's VOBs and converts to MP4
       via VLC CLI (H.264 CRF 18, AAC 256k 48kHz) into the output folder.

.REQUIREMENTS
  - VLC installed (default path below, adjust if needed). No ffmpeg needed.

.USAGE
  powershell -ExecutionPolicy Bypass -File .\Watch-DvdConvert.ps1
  Optional: -OutputDir "D:\Rips" -SnippetStart 30 -SnippetLength 15
#>

param(
    [string]$OutputDir     = "$env:USERPROFILE\Videos\DVD-Rips",
    [string]$VlcPath       = "C:\Program Files\VideoLAN\VLC\vlc.exe",
    [int]$SnippetStart     = 30,   # seconds into the title to start preview
    [int]$SnippetLength    = 15,   # seconds of preview
    [int]$PollSeconds      = 3
)

# --- sanity checks -----------------------------------------------------------
if (-not (Test-Path $VlcPath)) {
    Write-Error "VLC not found at $VlcPath - adjust -VlcPath."
    exit 1
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

function Get-MainTitleVobs {
    param([string]$VideoTsPath)

    # Group VTS_xx_1..9.VOB by title set number; skip VTS_xx_0.VOB (menus)
    $groups = Get-ChildItem -Path $VideoTsPath -Filter 'VTS_*.VOB' |
        Where-Object { $_.Name -match '^VTS_(\d\d)_([1-9])\.VOB$' } |
        Group-Object { $_.Name.Substring(4,2) }

    if (-not $groups) { return $null }

    # Main movie = title set with largest total size
    $main = $groups | Sort-Object { ($_.Group | Measure-Object Length -Sum).Sum } -Descending |
        Select-Object -First 1

    # Return VOBs in part order (VTS_xx_1, _2, ...)
    return $main.Group | Sort-Object Name
}

function Invoke-Preview {
    param([System.IO.FileInfo]$Vob, [int]$Start, [int]$Length)

    Write-Host "Previewing $($Vob.Name) ($([math]::Round($Vob.Length/1MB,1)) MB)..." -ForegroundColor Cyan
    $args = @(
        "`"$($Vob.FullName)`"",
        "--start-time=$Start",
        "--run-time=$Length",
        "--play-and-exit",
        "--no-video-title-show"
    )
    Start-Process -FilePath $VlcPath -ArgumentList $args -Wait
}

function Convert-Title {
    param([System.IO.FileInfo[]]$Vobs, [string]$DiscLabel)

    $safeLabel = ($DiscLabel -replace '[^\w\-]', '_')
    if (-not $safeLabel) { $safeLabel = "dvd_$(Get-Date -Format yyyyMMdd_HHmmss)" }
    $outFile = Join-Path $OutputDir "$safeLabel.mp4"

    # Binary-concat the title's VOB parts into one temp file (safe within a title set)
    if ($Vobs.Count -gt 1) {
        $srcVob = Join-Path $OutputDir "_concat_temp.vob"
        Write-Host "Concatenating $($Vobs.Count) VOB parts..." -ForegroundColor Yellow
        $out = [System.IO.File]::Create($srcVob)
        try {
            foreach ($v in $Vobs) {
                $in = [System.IO.File]::OpenRead($v.FullName)
                try { $in.CopyTo($out) } finally { $in.Dispose() }
            }
        } finally { $out.Dispose() }
    } else {
        $srcVob = $Vobs[0].FullName
    }

    Write-Host "Converting -> $outFile (VLC, this can take a while)..." -ForegroundColor Yellow
    $sout = "#transcode{vcodec=h264,venc=x264{crf=18,preset=slow},acodec=mp4a,ab=256,channels=2,samplerate=48000}:std{access=file,mux=mp4,dst='$outFile'}"
    $vlcArgs = @(
        '--intf', 'dummy',
        '--no-repeat', '--no-loop',
        "`"$srcVob`"",
        "--sout=$sout",
        'vlc://quit'
    )
    Start-Process -FilePath $VlcPath -ArgumentList $vlcArgs -Wait -NoNewWindow

    # Clean up temp concat file
    if ($Vobs.Count -gt 1 -and (Test-Path $srcVob)) { Remove-Item $srcVob -Force }

    if (Test-Path $outFile) {
        $mb = [math]::Round((Get-Item $outFile).Length / 1MB, 1)
        Write-Host "Done: $outFile ($mb MB)" -ForegroundColor Green
    } else {
        Write-Warning "Output file not created - VLC transcode failed. Check disc readability."
    }
}

# --- main watch loop ---------------------------------------------------------
Write-Host "Watching optical drives for new discs. Ctrl+C to stop." -ForegroundColor Cyan
$seen = @{}   # driveLetter -> volume serial of disc already handled

while ($true) {
    $drives = [System.IO.DriveInfo]::GetDrives() |
        Where-Object { $_.DriveType -eq 'CDRom' }

    foreach ($d in $drives) {
        $letter = $d.Name.TrimEnd('\')

        if (-not $d.IsReady) {
            # Disc removed -> forget it so re-insert triggers again
            if ($seen.ContainsKey($letter)) { $seen.Remove($letter) }
            continue
        }

        $id = "$letter|$($d.VolumeLabel)"
        if ($seen.ContainsKey($letter) -and $seen[$letter] -eq $id) { continue }
        $seen[$letter] = $id

        Write-Host "`nDisc detected in $letter : '$($d.VolumeLabel)'" -ForegroundColor Green

        $videoTs = Join-Path $d.Name 'VIDEO_TS'
        if (-not (Test-Path $videoTs)) {
            Write-Host "No VIDEO_TS folder - not a DVD-Video disc. Skipping."
            continue
        }

        $vobs = Get-MainTitleVobs -VideoTsPath $videoTs
        if (-not $vobs) {
            Write-Host "No title VOBs found. Skipping."
            continue
        }

        Invoke-Preview -Vob $vobs[0] -Start $SnippetStart -Length $SnippetLength

        $answer = Read-Host "Convert this title to MP4? (y/n)"
        if ($answer -match '^y') {
            Convert-Title -Vobs $vobs -DiscLabel $d.VolumeLabel
        } else {
            Write-Host "Skipped conversion."
        }
    }

    Start-Sleep -Seconds $PollSeconds
}
