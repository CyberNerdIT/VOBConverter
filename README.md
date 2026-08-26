# VOB Converter

A [WinUtil](https://github.com/CyberNerdIT/winutil)-style PowerShell WPF menu for ripping DVD-Video discs to MP4 with VLC — no ffmpeg needed.

![dark theme](https://img.shields.io/badge/theme-WinUtil%20dark-232629)

## What it does

- **Always-on disc watcher** — optical drives on the Windows machine are polled continuously in the background. Every disc you insert shows up as a card in the menu the moment it's ready, and disappears when ejected. The watcher never stops while the app is open.
- **Disc menu** — each DVD-Video disc card shows the volume label, drive letter, main title size and VOB part count, plus:
  - an **Output name** box — type a new name for the converted file (defaults to the disc label),
  - **Preview** — plays a short snippet of the main title straight from the disc in VLC so you can confirm it's the right content,
  - **Convert to MP4** — stages and converts the disc (see below),
  - **Test Output** — plays a snippet of the converted MP4 so you can verify the result.
- **Copy + merge in one pass** — on convert, the main title's VOB parts are read straight off the disc and binary-concatenated into **one local file** in the staging folder (default `%USERPROFILE%\Downloads\VOB\<name>.vob`). Copying and merging are a single pass; the merged VOB is kept as your local copy, and once it's staged the disc is no longer needed.
- **Background conversion** — the staged VOB is transcoded to MP4 via VLC CLI (H.264 CRF 18, AAC 256k 48kHz) in a background runspace, so the menu and the disc watcher stay responsive the whole time.
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
