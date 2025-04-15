# Yujin
![yujin (1)](https://github.com/user-attachments/assets/d7377bc7-f32e-45c7-ab96-22604635a75d)


**Audio/Video Condenser & Transcriber Script**

This script processes audio and video files to optimize them for focused listening, such as language immersion. It removes silences, adjusts playback speed, normalizes volume, reduces noise, and optionally generates transcripts using OpenAI's Whisper (locally or via API). It also calculates the total time saved by removing silent portions.

## Features

*   **Silence Removal:** Automatically detects and removes silent parts based on configurable dB threshold and duration.
*   **Tempo Adjustment:** Changes the playback speed (slower or faster) without altering pitch.
*   **Volume Normalization:** Applies loudness normalization (EBU R128 standard) for consistent volume levels.
*   **Noise Reduction:** Applies a basic noise reduction filter.
*   **Segmentation:** Splits the final processed audio into smaller, fixed-length chunks for easier handling.
*   **Transcription:**
    *   Utilizes OpenAI's Whisper model for accurate transcription.
    *   Supports both **local** Whisper installations and the **OpenAI API**.
    *   Transcribes the *original* audio content for maximum accuracy before tempo changes.
    *   Configurable model size and language detection/specification.
*   **Processing Modes:**
    *   **Interactive:** Runs without arguments, scans its own directory, and prompts the user for settings.
    *   **Single File:** Processes one specified input file.
    *   **Batch:** Processes all compatible media files found recursively within a specified directory, optionally filtering by name pattern. Output mirrors the input directory structure.
*   **Output Control:** Specify audio format (`mp3`, `opus`, `ogg`, `wav`), bitrate, channels, and sample rate.
*   **Time Saving Report:** Calculates and displays the total duration of silence removed across all processed files.
*   **Dry Run:** Preview the commands and actions the script would perform without actually modifying files or making API calls.
*   **Logging:** Control verbosity and redirect `ffmpeg` logs to a file.

## Dependencies

**Essential:**

*   **Bash:** The shell environment to run the script.
*   **ffmpeg:** The core tool for all audio/video processing (version 4+ recommended). Must include `ffprobe`.
    *   *Ubuntu/Debian:* `sudo apt update && sudo apt install ffmpeg`
    *   *macOS:* `brew install ffmpeg`
*   **bc:** An arbitrary precision calculator, used for duration calculations.
    *   *Ubuntu/Debian:* `sudo apt install bc`
    *   *macOS:* Usually pre-installed. `brew install bc` if needed.
*   **awk:** A pattern scanning and processing language, used for duration formatting.
    *   *Installation:* Almost always pre-installed on Linux/macOS.

**Optional (for Transcription):**

*   **Local Whisper:** Required if using the `-T` flag.
    *   *Installation:* Follow instructions at [OpenAI Whisper GitHub](https://github.com/openai/whisper#setup). Generally involves Python and pip: `pip install -U openai-whisper`.
*   **curl:** Required if using the Whisper API (`-W` flag).
    *   *Ubuntu/Debian:* `sudo apt install curl`
    *   *macOS:* Usually pre-installed. `brew install curl` if needed.
*   **OpenAI API Key:** Required if using the Whisper API (`-W` flag). Provide via `-K` flag or `OPENAI_API_KEY` environment variable.

**Optional (for Robustness):**

*   **timeout:** Used by `get_duration` function to prevent `ffprobe` from hanging indefinitely on problematic files. Part of `coreutils`.
    *   *Ubuntu/Debian:* Usually pre-installed (`coreutils`).
    *   *macOS:* `brew install coreutils` (command might be `gtimeout`). The script checks for `timeout` specifically.
*   **realpath:** Used for more robust path handling, especially in interactive mode. Part of `coreutils`.

## Usage

**Basic Syntax:**

```bash
./condense_audio.sh [options] [<input_file_or_dir> [<output_file_or_dir>]]
```

### Interactive Mode (No Arguments)

Run the script without any arguments to activate interactive mode:

```bash
./yujin.sh
```

**Behavior:**

*   Scans the script's own directory for compatible media files.
*   Lists found files and the proposed output directory (`./condensed_audio`).
*   Asks for confirmation to proceed.
*   Prompts for optional features (unless already set by flags):
    *   Segmentation (Enable/disable, segment length).
    *   Tempo Adjustment (Enable/disable, rate).
    *   Transcription (Local Whisper / OpenAI API / None).
*   Processes files based on selections and any provided flags.

### Options

**Processing:**

*   `-t <db>`: Silence threshold in decibels (dB). Quieter parts below this level are considered silence. (Default: `-30.0`)
*   `-d <sec>`: Minimum duration in seconds for a silent part to be removed. (Default: `0.500`)
*   `-s <min>`: Segment the processed output into chunks of `<min>` MINUTES. Overrides interactive prompt if used.
*   `-r <rate>`: Playback rate multiplier for tempo adjustment (e.g., `0.8` for 80% speed, `1.2` for 120%). Overrides interactive prompt if used. (Default: `1.0`)
*   `-N`: Normalize volume using loudness normalization (EBU R128). (Default: Disabled)
*   `-D`: Apply noise reduction (ANLMDN filter). (Default: Disabled)

**Output:**

*   `-f <format>`: Output audio format. Supported: `mp3`, `opus`, `ogg`, `wav`. (Default: `mp3`)
*   `-b <kbps>`: Output audio bitrate (e.g., `128k`, `96k`, `64k`). (Default: `128k`)

**Transcription:**

*   `-T`: Enable transcription using a local Whisper installation. Requires `whisper` command in PATH. Overrides interactive prompt.
*   `-W`: Enable transcription using the OpenAI Whisper API. Requires `curl` and an API key. Overrides interactive prompt.
*   `-K <api_key>`: Provide OpenAI API key directly for the Whisper API (`-W`). (Default: Reads from `OPENAI_API_KEY` environment variable)
*   `--model <size>`: Specify the Whisper model size (e.g., `tiny`, `base`, `small`, `medium`, `large`, `small.en`). (Default: `medium`)
    *   *Note:* API currently uses `whisper-1` regardless of this setting.
*   `-G <lang>`: Specify the two-letter language code (e.g., `en`, `es`, `ja`) for Whisper. If omitted, Whisper auto-detects. (Default: Auto-detect)

**General:**

*   `-l <level>`: Set the FFmpeg log level (e.g., `quiet`, `error`, `warning`, `info`, `verbose`). (Default: `error`)
*   `-L <file>`: Redirect all FFmpeg output/errors to a log file (appends). Overrides `-l`.
*   `-F <pattern>`: Batch mode only. Process only files whose names match the shell pattern (e.g., `"*.mp3"`). Quote patterns with wildcards.
*   `-n`: Dry run. Print commands without executing them. Skips duration calculation.
*   `-h`: Show this help message and exit.

## Examples

**Interactive mode: Scan script dir, prompts for options**
```bash
./yujin.sh
```

**Interactive mode: Force segmentation (5min), slow (80%), normalize, local transcribe (medium)**
```bash
./yujin.sh -s 5 -r 0.8 -N -T
```

**Single file: Process, default output name, slow (75%), local transcribe (small.en model, English)**
```bash
./yujin.sh -r 0.75 -T --model small.en -G en "My Lecture.mp4"
```

**Batch mode: Process 'SourceMaterial' to 'ProcessedAudio', filter "Ep*", slow (90%), transcribe Japanese (API, key via env)**
```bash
./yujin.sh -r 0.9 -F "Ep*.mkv" -W -G ja "./SourceMaterial" "./ProcessedAudio"
```

**Single file: Specify output, transcribe using API (key via flag)**
```bash
./yujin.sh -W -K "sk-YOUR_API_KEY_HERE" "dialogue.wav" "dialogue_condensed.mp3"
```

**Interactive mode: Process files in current dir, log ffmpeg details to file**
```bash
./yujin.sh -L ffmpeg_run.log
```

**Batch mode: Process directory, create 15-minute segments, normalize audio**
```bash
./yujin.sh -s 15 -N ./raw_lectures ./condensed_lectures
```

**Dry run: Preview batch operation actions**
```bash
./yujin.sh -n -r 0.85 -T ./input_dir ./output_dir
```
