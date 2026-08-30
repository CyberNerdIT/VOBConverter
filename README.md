# VOB Converter

A [WinUtil](https://github.com/CyberNerdIT/winutil)-style PowerShell WPF menu for ripping DVD-Video discs to MP4 with VLC — no ffmpeg needed.

![dark theme](https://img.shields.io/badge/theme-WinUtil%20dark-232629)

## What it does

- **Always-on disc watcher** — optical drives on the Windows machine are polled continuously in the background. Every disc you insert shows up as a card in the menu the moment it's ready, and disappears when ejected. The watcher never stops while the app is open.
- **Disc menu** — each DVD-Video disc card shows the volume label and drive letter, plus:
  - a **title set list** — every `VTS_xx` title set on the disc with its part count and size, as checkboxes. The largest set is auto-selected as the main movie; if two title sets are closely sized/named and the auto-select picked the wrong one, just untick it and tick the right one (you can tick several — they merge in order),
  - **Add VOB file...** — manually add specific VOB file(s) to the merge list (the picker opens in the disc's `VIDEO_TS` folder) for when the auto-selection can't be trusted at all; **Clear added** removes them again,
  - an **Output name** box — type a new name for the converted file (defaults to the disc label),
  - **Preview** — plays a short snippet of the selected files straight from the disc in VLC so you can confirm it's the right content,
  - **Convert to MP4** — stages and converts the selection (see below),
  - **Test Output** — plays a snippet of the converted MP4 so you can verify the result.
- **Copy + merge in one pass** — on convert, the selected VOB files are read straight off the disc and binary-concatenated into **one local file** in the staging folder (default `%USERPROFILE%\Downloads\VOB\<name>.vob`). Copying and merging are a single pass; the merged VOB is kept as your local copy, and once it's staged the disc is no longer needed. The log shows the exact merge list before conversion starts.
- **Background conversion** — the staged VOB is transcoded to MP4 via VLC CLI (H.264 CRF 18, AAC 256k 48kHz) in a background runspace, so the menu and the disc watcher stay responsive the whole time.
- **Progress bar with ETA** — a determinate progress bar shows percent done and estimated time to completion for both phases: the copy+merge phase is byte-accurate (percent, MB/s, ETA), and the transcode phase reads VLC's real position via its local-only HTTP status interface (bound to `127.0.0.1` on a random port with a random password). If the status interface isn't reachable, it falls back to showing elapsed time and MB written.
- **Auto-Convert toggle** — flip it on and every new DVD-Video disc is converted automatically on insertion, no clicks needed.
- Editable settings in the menu: output folder, staging folder, VLC path, preview snippet start/length.

## Requirements

- Windows with Windows PowerShell 5.1+ (WPF)
- [VLC](https://www.videolan.org/) installed (default path `C:\Program Files\VideoLAN\VLC\vlc.exe`)

## Usage

```powershell
powershell -ExecutionPolicy Bypass -File .\VOBConverter.ps1
```

Optional parameters (all editable in the UI afterwards):

```powershell
powershell -ExecutionPolicy Bypass -File .\VOBConverter.ps1 `
    -OutputDir "D:\Rips" `
    -StagingDir "$env:USERPROFILE\Downloads\VOB" `
    -VlcPath "C:\Program Files\VideoLAN\VLC\vlc.exe" `
    -SnippetStart 30 -SnippetLength 15 -PollSeconds 3
```

## Legacy CLI version

`script.ps1` is the original console watch-loop version (poll drives, preview, y/n prompt, convert). The GUI supersedes it but it's kept for headless use.
