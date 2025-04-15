#!/usr/bin/env bash

# === Configuration ===
# Default values (can be overridden by flags)
DEFAULT_AUDIO_BITRATE="128k"
DEFAULT_AUDIO_CHANNELS="2"
DEFAULT_AUDIO_SAMPLE_RATE="44100"
DEFAULT_AUDIO_FORMAT="mp3"
DEFAULT_LOG_LEVEL="error"
DEFAULT_SILENCE_THRESHOLD="-30.0" # dB
DEFAULT_MIN_SILENCE_DURATION="0.500" # Seconds
DEFAULT_SEGMENT_TIME_FLAG_SEC="" # Value from -s flag, converted to SECONDS
DEFAULT_TEMPO_RATE="1.0" # Base tempo rate
DEFAULT_NORMALIZE=false
DEFAULT_DENOISE=false
DEFAULT_DRY_RUN=false
DEFAULT_LOG_FILE=""
DEFAULT_BATCH_FILTER=""
DEFAULT_TRANSCRIBE=false
DEFAULT_WHISPER_MODEL="medium"
DEFAULT_WHISPER_LANGUAGE=""
DEFAULT_USE_WHISPER_API=false # New default for using Whisper API
DEFAULT_OPENAI_API_KEY="" # Default API key (empty, will be taken from env)

# Interactive mode defaults
DEFAULT_SEGMENT_TIME_INTERACTIVE_MIN="10"
DEFAULT_SEGMENT_TIME_INTERACTIVE_SEC=$((DEFAULT_SEGMENT_TIME_INTERACTIVE_MIN * 60))
DEFAULT_TEMPO_INTERACTIVE_RATE="0.75" # Default tempo suggested in interactive mode

# Internal calculated defaults
DEFAULT_OUTPUT_DIR="condensed_audio"
TRANSCRIPTS_DIR_NAME="transcripts"

# === Script Variables ===
AUDIO_BITRATE="$DEFAULT_AUDIO_BITRATE"
AUDIO_CHANNELS="$DEFAULT_AUDIO_CHANNELS"
AUDIO_SAMPLE_RATE="$DEFAULT_AUDIO_SAMPLE_RATE"
AUDIO_FORMAT="$DEFAULT_AUDIO_FORMAT"
LOG_LEVEL="$DEFAULT_LOG_LEVEL"
SILENCE_THRESHOLD="$DEFAULT_SILENCE_THRESHOLD"
MIN_SILENCE_DURATION="$DEFAULT_MIN_SILENCE_DURATION"
SEGMENT_TIME_FROM_FLAG_SEC="$DEFAULT_SEGMENT_TIME_FLAG_SEC"
TEMPO_RATE="$DEFAULT_TEMPO_RATE" # This will be used for processing
FLAG_NORMALIZE=$DEFAULT_NORMALIZE
FLAG_DENOISE=$DEFAULT_DENOISE
FLAG_DRY_RUN=$DEFAULT_DRY_RUN
LOG_FILE_PATH="$DEFAULT_LOG_FILE"
BATCH_FILTER="$DEFAULT_BATCH_FILTER"
FLAG_TRANSCRIBE=$DEFAULT_TRANSCRIBE
WHISPER_MODEL_SIZE="$DEFAULT_WHISPER_MODEL"
WHISPER_LANGUAGE="$DEFAULT_WHISPER_LANGUAGE"
USE_WHISPER_API=$DEFAULT_USE_WHISPER_API # New flag for using Whisper API
OPENAI_API_KEY="$DEFAULT_OPENAI_API_KEY" # Store API key

OUTPUT_DIR=""; OUTPUT_FILE=""; INPUT_PATH=""; BATCH_MODE=false
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
files_to_process=()

# Interactive mode variables
SEGMENT_INTERACTIVE_ENABLED=false; SEGMENT_INTERACTIVE_TIME_SEC="$DEFAULT_SEGMENT_TIME_INTERACTIVE_SEC"; SEGMENT_OUTPUT_DIR=""
TRANSCRIPTION_INTERACTIVE_ENABLED=false; TRANSCRIPTS_OUTPUT_DIR=""

# Duration tracking variables
total_original_duration_sec="0.0"
total_condensed_duration_sec="0.0"
files_measured_count=0


# === Usage Function ===
usage() {
  cat << EOF
Usage: $0 [options] [<input_file_or_dir> [<output_file_or_dir>]]

Condenses audio/video, removes silence, adjusts tempo, normalizes, denoises,
and optionally transcribes for language immersion. Calculates time saved.

Behavior without arguments:
  Prompts to process media files in script's directory ('${SCRIPT_DIR}').
  Prompts for optional segmentation (default ${DEFAULT_SEGMENT_TIME_INTERACTIVE_MIN} min).
  Prompts for optional tempo adjustment (default suggested rate: ${DEFAULT_TEMPO_INTERACTIVE_RATE}x).
  Prompts for optional transcription using local Whisper or Whisper API (default model: ${DEFAULT_WHISPER_MODEL}).

Arguments:
  <input_file_or_dir>   Input file or directory for batch processing.
  [<output_file_or_dir>] Output file (if input is file) or directory (if input is dir).
                        Defaults: single -> './<input_base>_condensed.<format>'
                                  batch  -> './${DEFAULT_OUTPUT_DIR}/'
                        Transcripts go into a '${TRANSCRIPTS_DIR_NAME}' subdirectory relative to output.

Options:
  Processing:
    -t <db>         Silence threshold dB (default: ${DEFAULT_SILENCE_THRESHOLD}).
    -d <sec>        Min silence duration sec (default: ${DEFAULT_MIN_SILENCE_DURATION}).
    -s <min>        Segment output into <min> MINUTE chunks. Overrides interactive prompt.
    -r <rate>       Playback rate multiplier (default: ${DEFAULT_TEMPO_RATE}; e.g., 0.8). Overrides interactive.
    -N              Normalize volume (Loudness Normalization).
    -D              Apply noise reduction.
  Output:
    -f <format>     Output audio format (default: ${DEFAULT_AUDIO_FORMAT}; mp3, opus, ogg, wav).
    -b <kbps>       Output audio bitrate (default: ${DEFAULT_AUDIO_BITRATE}; e.g., 128k, 96k).
  Transcription:
    -T              Enable transcription using local Whisper install. Overrides interactive prompt.
    -W              Enable transcription using OpenAI Whisper API. Overrides interactive prompt.
    -K <api_key>    OpenAI API key for Whisper API (default: from environment OPENAI_API_KEY).
    --model <size>  Whisper model size (default: ${DEFAULT_WHISPER_MODEL}).
                    Common: tiny, base, small, medium, large (and .en variants like small.en).
    -G <lang>       Specify language for Whisper (e.g., en, es, ja). Default: auto-detect.
  General:
    -l <level>      FFmpeg log level (default: ${DEFAULT_LOG_LEVEL}).
    -L <file>       Redirect FFmpeg output/errors to log file (appends).
    -F <pattern>    Batch mode only: Process only files matching shell pattern (e.g., "*Lesson*").
    -n              Dry run: Print commands and planned actions; skips duration calculation.
    -h              Show this help message.

Examples:
  # Process files in script dir, interactive prompts for seg/tempo/transcribe
  $0
  # Process files in script dir, segment(5min), slow(80%), normalize, transcribe(medium, auto-lang)
  $0 -s 5 -r 0.8 -N -T
  # Single file, default output, slow, transcribe with small English model
  $0 -r 0.75 -T --model small.en -G en "Lecture 1.mp4"
  # Batch process dir, output to 'condensed', filter, slow, transcribe Japanese
  $0 -r 0.9 -F "Ep*.mp4" -T -G ja "./Episodes" "./condensed"
  # Transcribe with OpenAI Whisper API, provide API key
  $0 -r 0.8 -W -K "your-api-key-here" "audio.mp3"

EOF
  exit 1
}

# === Helper Functions ===

# *** UPDATED: Function to format seconds into HH:MM:SS using awk ***
format_duration() {
    local total_seconds_float="$1"
    # Use awk for robust rounding and formatting, setting LC_NUMERIC inside awk
    LC_NUMERIC=C awk -v secs="$total_seconds_float" 'BEGIN {
        if (secs < 0) secs = 0;
        # Use sprintf to round to integer before calculations
        total_int = sprintf("%.0f", secs);
        h = int(total_int / 3600);
        m = int((total_int % 3600) / 60);
        s = int(total_int % 60);
        # Use printf within awk for formatting
        printf "%02d:%02d:%02d", h, m, s;
    }'
}

# Function to get duration using ffprobe, with optional timeout
get_duration() {
    local file_path="$1"
    local duration
    local ffprobe_cmd_string # Store the command to execute
    local use_timeout=false

    # Check if timeout command exists
    if command -v timeout >/dev/null 2>&1; then
        use_timeout=true
        # Construct command with timeout
        ffprobe_cmd_string="timeout 10 ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 \"$file_path\""
    else
        # Timeout not available, construct command to run ffprobe directly
        ffprobe_cmd_string="ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 \"$file_path\""
    fi

    # Execute the constructed command string using eval (needed for proper quoting of file_path)
    # Ensure C locale for ffprobe output consistency if it matters (usually doesn't for duration)
    duration=$(LC_NUMERIC=C eval "$ffprobe_cmd_string" 2>/dev/null)
    local cmd_status=$? # Status of the eval'd command

    # Check command exit status and if duration is a valid number (using C locale regex)
    if [ $cmd_status -ne 0 ] || ! [[ "$duration" =~ ^[0-9]+([.][0-9]*)?$ ]]; then
         # Improved error message for status 127 (command not found)
        if [ $cmd_status -eq 127 ]; then
             # If timeout was attempted, it's likely timeout command failed. Otherwise ffprobe failed.
             if $use_timeout; then
                 echo "Warning: Failed to execute duration check. 'timeout' command might not be found in PATH. Status: $cmd_status" >&2
             else
                 echo "Warning: Failed to execute duration check. 'ffprobe' command might not be found in PATH. Status: $cmd_status" >&2
             fi
        # Handle timeout specific exit codes (124) if timeout was used
        elif $use_timeout && [ $cmd_status -eq 124 ]; then
             echo "Warning: ffprobe timed out (10s) getting duration for '$file_path'. Status: $cmd_status" >&2
        else
             # General ffprobe failure
             echo "Warning: Could not get valid duration for '$file_path'. ffprobe status: $cmd_status, Output: '$duration'" >&2
        fi
        echo "" # Return empty string on failure
    else
        echo "$duration" # Return duration on success
    fi
}


calculate_atempo_chain() {
    local rate=$1; local current_rate=1.0; local filter_chain=""; local tempo
    # Use C locale for bc comparisons and calculations
    if ! [[ "$rate" =~ ^[0-9]+([.][0-9]*)?$ ]] || (( $(LC_NUMERIC=C echo "$rate <= 0" | bc -l) )); then echo "Warning: Invalid tempo rate '$rate'. Using 1.0." >&2; echo "atempo=1.0"; return; fi
    if (( $(LC_NUMERIC=C echo "$rate == 1.0" | bc -l) )); then echo "atempo=1.0"; return; fi
    local max_iterations=10; local i=0
    while (( $(LC_NUMERIC=C echo "scale=10; $current_rate != $rate" | bc -l) )) && (( i < max_iterations )); do
        if (( $(LC_NUMERIC=C echo "$current_rate < $rate" | bc -l) )); then tempo=$(LC_NUMERIC=C echo "scale=10; r = $rate / $current_rate; if (r > 2.0) r = 2.0; r" | bc -l);
        else tempo=$(LC_NUMERIC=C echo "scale=10; r = $rate / $current_rate; if (r < 0.5) r = 0.5; r" | bc -l); fi
        tempo=$(echo "$tempo" | sed 's/\.\{0,1\}0\{1,\}$//'); if [ -z "$filter_chain" ]; then filter_chain="atempo=${tempo}"; else filter_chain="${filter_chain},atempo=${tempo}"; fi
        current_rate=$(LC_NUMERIC=C echo "scale=10; $current_rate * $tempo" | bc -l); ((i++))
    done; if (( i == max_iterations )); then echo "Warning: Could not reach exact tempo rate '$rate' in $max_iterations iterations. Approx $(LC_NUMERIC=C printf "%.3f" $current_rate)." >&2; fi
    echo "$filter_chain"
}

is_whisper_installed() { command -v whisper >/dev/null 2>&1; }

is_curl_installed() { command -v curl >/dev/null 2>&1; }

prepare_transcripts_dir() {
    local base_dir="$1"
    local trans_dir="${base_dir}/${TRANSCRIPTS_DIR_NAME}"
    # Ensure base_dir is not empty or just '.'
    if [ -z "$base_dir" ] || [ "$base_dir" == "." ]; then
        base_dir=$(pwd) # Use current directory if base is empty or '.'
        trans_dir="${base_dir}/${TRANSCRIPTS_DIR_NAME}"
    fi

    if [ $FLAG_DRY_RUN = true ]; then
        echo "DRY RUN: Would ensure transcript directory exists: '$trans_dir'"
        # Return the path even in dry run so subsequent steps can use it
    else
        mkdir -p "$trans_dir"
        if [ $? -ne 0 ]; then
            echo "Error: Could not create transcripts directory '$trans_dir'" >&2
            return 1 # Signal failure
        fi
    fi
    echo "$trans_dir" # Return the path on success
    return 0
}


# Function to transcribe using local Whisper
transcribe_local() {
    local input_file="$1"
    local output_dir="$2"
    local model_size="$3"
    local language="$4"
    local lang_param=""
    # *** Use the original filename for the transcript base name ***
    local original_input_basename=$(basename "${input_file%.*}")
    local output_file="${output_dir}/${original_input_basename}.txt"

    # Check if whisper is installed
    if ! is_whisper_installed; then
        echo "Warning: Local Whisper not available. Skipping transcription for '$input_file'." >&2
        echo "Other audio processing tasks will continue as normal." >&2
        return 2  # Return code 2 means skipped but not fatal
    fi

    if [ -n "$language" ]; then
        lang_param="--language $language"
    fi

    if [ $FLAG_DRY_RUN = true ]; then
        echo "DRY RUN: whisper \"$input_file\" --model $model_size $lang_param --output_dir \"$output_dir\" --output_format txt"
        # Create dummy file for dry run consistency
        touch "$output_file"
        return 0
    fi

    echo "Transcribing with local Whisper: $original_input_basename (model: $model_size)"
    # *** Transcribe the ORIGINAL input file, not the condensed one ***
    whisper "$input_file" --model $model_size $lang_param --output_dir "$output_dir" --output_format txt

    local whisper_exit_code=$?
    if [ $whisper_exit_code -ne 0 ]; then
        echo "Warning: Local Whisper transcription failed for '$input_file' (Exit code: $whisper_exit_code)" >&2
        echo "Skipping transcription, but other audio processing will continue." >&2
        return 2  # Return code 2 means skipped but not fatal
    fi

    # Rename the output file if whisper added its own extension (like .mp3.txt)
    local expected_whisper_output="${output_dir}/${original_input_basename}.txt"
    if [ ! -f "$expected_whisper_output" ]; then
         # Try to find a file whisper might have created (e.g., file.mp3.txt)
         # Use find with -name matching pattern based on original basename
         # Quote the pattern to handle spaces etc.
         local actual_whisper_output=$(find "$output_dir" -maxdepth 1 -name "${original_input_basename}.*.txt" -print -quit)
         if [ -f "$actual_whisper_output" ]; then
             # Check if the found file is exactly the one we expected (handles cases where output format was already .txt)
             if [ "$actual_whisper_output" != "$expected_whisper_output" ]; then
                 echo "Info: Renaming whisper output '$actual_whisper_output' to '$expected_whisper_output'"
                 mv "$actual_whisper_output" "$expected_whisper_output" || echo "Warning: Could not rename whisper output '$actual_whisper_output' to '$expected_whisper_output'" >&2
             fi
         else
             # Check if the primary target file (without extra extension) exists now
             # This handles cases where whisper correctly outputted "base.txt" directly
             if [ ! -f "$expected_whisper_output" ]; then
                echo "Warning: Could not find expected transcript file '$expected_whisper_output' or similar pattern after running whisper." >&2
             fi
         fi
    fi

    # Final check if the expected file exists
    if [ -f "$expected_whisper_output" ]; then
        echo "Transcribed: $expected_whisper_output"
        return 0 # Success
    else
        # If we reach here, something went wrong finding/renaming the file
        return 1 # Indicate an error occurred post-whisper
    fi
}

# Function to transcribe using OpenAI Whisper API
transcribe_api() {
    local input_file="$1"
    local output_dir="$2"
    local model_size="$3" # Note: model_size is ignored by API, uses whisper-1
    local language="$4"
    local api_key="$5"
    # *** Use the original filename for the transcript base name ***
    local original_input_basename=$(basename "${input_file%.*}")
    local output_file="${output_dir}/${original_input_basename}.txt"
    local language_param=""

    if [ -z "$api_key" ]; then
        echo "Warning: No OpenAI API key provided for Whisper API. Skipping transcription for '$input_file'." >&2
        echo "Other audio processing tasks will continue as normal." >&2
        return 2  # Return code 2 means skipped but not fatal
    fi

    # Map model size to API model names - API only supports whisper-1
    local api_model="whisper-1"

    # Prepare language parameter for API
    if [ -n "$language" ]; then
        language_param="-F language=$language"
    fi

    if [ $FLAG_DRY_RUN = true ]; then
        echo "DRY RUN: curl -s -X POST -H \"Authorization: Bearer {API_KEY}\" -H \"Content-Type: multipart/form-data\" -F \"file=@$input_file\" $language_param -F \"model=$api_model\" -F \"response_format=text\" https://api.openai.com/v1/audio/transcriptions > \"$output_file\""
        # Create dummy file for dry run consistency
        touch "$output_file"
        return 0
    fi

    echo "Transcribing with Whisper API: $original_input_basename (model: $api_model)"
    # *** Transcribe the ORIGINAL input file, not the condensed one ***
    local response
    response=$(curl -s -X POST \
        -H "Authorization: Bearer $api_key" \
        -H "Content-Type: multipart/form-data" \
        -F "file=@${input_file}" \
        $language_param \
        -F "model=$api_model" \
        -F "response_format=text" \
        https://api.openai.com/v1/audio/transcriptions)

    # Check for curl errors explicitly
    local curl_exit_code=$?
    if [ $curl_exit_code -ne 0 ]; then
        echo "Warning: API request failed (curl exit code: $curl_exit_code) for '$input_file' - Check connection or API endpoint." >&2
        echo "Skipping transcription, but other audio processing will continue." >&2
        return 2  # Return code 2 means skipped but not fatal
    fi

    # Check for API errors (errors typically start with { in JSON format, or contain "error":)
    # Also check for empty response which might indicate an issue
    if [[ "$response" == "{"* ]] || [[ "$response" == *'"error":'* ]] || [ -z "$response" ]; then
        echo "Warning: API returned an error or empty response for '$input_file'. Response: $response" >&2
        echo "Skipping transcription, but other audio processing will continue." >&2
        return 2  # Return code 2 means skipped but not fatal
    fi

    # Write response to output file
    echo "$response" > "$output_file"

    if [ $? -ne 0 ]; then
        echo "Warning: Failed to write transcript to '$output_file'" >&2
        echo "Skipping transcription, but other audio processing will continue." >&2
        # Technically transcription succeeded, but saving failed - treat as error
        return 1
    fi

    echo "Transcribed: $output_file"
    return 0 # Success
}


# === Argument Parsing ===
segment_time_flag_raw=""; tempo_rate_flag_raw=""; raw_model_flag=""; api_key_flag=""
# Handle --model separately as getopts doesn't handle --long options easily
# Store original args
original_args=("$@")
processed_args=()
skip_next=false
i=0
# Use a C-style loop for safe index access with shift
while [ $i -lt ${#original_args[@]} ]; do
    arg="${original_args[$i]}"
    next_arg="${original_args[$((i+1))]}" # Look ahead

    if $skip_next; then
        skip_next=false
        i=$((i+1)) # Increment counter
        continue
    fi

    if [[ "$arg" == "--model" ]]; then
        # Check if next arg exists and isn't an option itself
        if [[ -n "$next_arg" ]] && [[ "$next_arg" != -* ]]; then
            raw_model_flag="$next_arg"
            skip_next=true # Tell the loop to skip the value next iteration
        else
            echo "Error: --model requires an argument." >&2; usage
        fi
    else
        processed_args+=("$arg") # Keep non --model args
    fi
    i=$((i+1)) # Increment counter
done
# Reset positional parameters to only those not handled above
set -- "${processed_args[@]}"

while getopts "t:d:s:r:f:b:l:L:F:G:K:TWNDnh" opt; do
  case $opt in
    t) SILENCE_THRESHOLD="$OPTARG" ;;
    d) MIN_SILENCE_DURATION="$OPTARG" ;;
    s) segment_time_flag_raw="$OPTARG" ;;
    r) tempo_rate_flag_raw="$OPTARG" ;;
    f) AUDIO_FORMAT=$(echo "$OPTARG" | tr '[:upper:]' '[:lower:]') ;;
    b) AUDIO_BITRATE="$OPTARG" ;;
    l) LOG_LEVEL="$OPTARG" ;;
    L) LOG_FILE_PATH="$OPTARG" ;;
    F) BATCH_FILTER="$OPTARG" ;;
    G) WHISPER_LANGUAGE="$OPTARG" ;;
    K) api_key_flag="$OPTARG" ;;
    T) FLAG_TRANSCRIBE=true; USE_WHISPER_API=false ;; # -T implies local
    W) FLAG_TRANSCRIBE=true; USE_WHISPER_API=true ;; # -W implies API
    N) FLAG_NORMALIZE=true ;;
    D) FLAG_DENOISE=true ;;
    n) FLAG_DRY_RUN=true ;;
    h) usage ;;
    \?) echo "Invalid option: -$OPTARG" >&2; usage ;;
    :) echo "Option -$OPTARG requires an argument." >&2; usage ;;
  esac
done
shift $((OPTIND-1))

# Check for OpenAI API key from flag or environment
if [ -n "$api_key_flag" ]; then
    OPENAI_API_KEY="$api_key_flag"
else
    # If not provided via flag, try to get it from environment
    # Use printenv for better compatibility, default to empty string if not set
    OPENAI_API_KEY=$(printenv OPENAI_API_KEY || echo "")
fi

# === Validate and Convert Flag Inputs ===
if [ -n "$raw_model_flag" ]; then WHISPER_MODEL_SIZE="$raw_model_flag"; echo "Info: Using Whisper model from --model flag: ${WHISPER_MODEL_SIZE}"; fi
if [ -n "$segment_time_flag_raw" ]; then if [[ "$segment_time_flag_raw" =~ ^[1-9][0-9]*$ ]]; then SEGMENT_TIME_FROM_FLAG_SEC=$((segment_time_flag_raw * 60)); echo "Info: Using segment length from -s flag: ${segment_time_flag_raw} minutes (${SEGMENT_TIME_FROM_FLAG_SEC} seconds)."; else echo "Error: Invalid value for -s flag (minutes): '$segment_time_flag_raw'." >&2; exit 1; fi; fi
# Use C locale for validating tempo rate from flag
if [ -n "$tempo_rate_flag_raw" ]; then if [[ "$tempo_rate_flag_raw" =~ ^[0-9]+([.][0-9]*)?$ ]] && (( $(LC_NUMERIC=C echo "$tempo_rate_flag_raw > 0" | bc -l) )); then TEMPO_RATE="$tempo_rate_flag_raw"; echo "Info: Using tempo rate from -r flag: ${TEMPO_RATE}x"; else echo "Error: Invalid value for -r flag: '$tempo_rate_flag_raw'." >&2; exit 1; fi; fi
case "$AUDIO_FORMAT" in mp3|opus|ogg|wav) ;; *) echo "Error: Invalid audio format '$AUDIO_FORMAT'. Supported: mp3, opus, ogg, wav." >&2; exit 1 ;; esac
if [[ "$AUDIO_BITRATE" != *[kK] ]] && ! [[ "$AUDIO_BITRATE" =~ ^[0-9]+$ ]]; then echo "Warning: Bitrate format '$AUDIO_BITRATE' might be invalid. Ensure it's like '128k' or a raw number." >&2; fi
if [[ -n "$WHISPER_MODEL_SIZE" ]] && ! [[ "$WHISPER_MODEL_SIZE" =~ ^[a-zA-Z0-9._-]+$ ]]; then echo "Warning: Whisper model name '$WHISPER_MODEL_SIZE' seems invalid." >&2; fi # Allow . _ -
if [[ -n "$WHISPER_LANGUAGE" ]] && ! [[ "$WHISPER_LANGUAGE" =~ ^[a-z]{2,3}(-[A-Z][a-z]{3})?(-[A-Z]{2})?$ ]]; then echo "Warning: Whisper language code '$WHISPER_LANGUAGE' might be invalid (should be like 'en', 'es', 'ja')." >&2; fi

# --- Essential Dependency Checks ---
if ! command -v ffmpeg >/dev/null 2>&1; then echo "Error: 'ffmpeg' command not found. Please install ffmpeg." >&2; exit 1; fi
if ! command -v ffprobe >/dev/null 2>&1; then echo "Error: 'ffprobe' command not found (usually included with ffmpeg). Needed for duration calculation." >&2; exit 1; fi
if ! command -v bc >/dev/null 2>&1; then echo "Error: 'bc' command not found. Needed for duration calculations." >&2; exit 1; fi
if ! command -v awk >/dev/null 2>&1; then echo "Error: 'awk' command not found. Needed for duration formatting." >&2; exit 1; fi


# Check dependencies for transcription methods if explicitly enabled via flags
# This check happens *before* interactive mode prompts
transcription_possible_local=false
transcription_possible_api=false
if is_whisper_installed; then transcription_possible_local=true; fi
if is_curl_installed; then transcription_possible_api=true; fi

if [ "$FLAG_TRANSCRIBE" = true ]; then
    if [ "$USE_WHISPER_API" = true ]; then
        if ! $transcription_possible_api; then
            echo "Warning: 'curl' command is required for Whisper API (-W) but not found." >&2
            echo "Audio processing will continue but transcription will be skipped." >&2
            FLAG_TRANSCRIBE=false # Disable transcription if dependency missing
        elif [ -z "$OPENAI_API_KEY" ]; then
            echo "Warning: OpenAI API key required for Whisper API (-W)." >&2
            echo "Audio processing will continue but transcription will be skipped." >&2
            echo "Provide key with -K flag or set OPENAI_API_KEY environment variable." >&2
            FLAG_TRANSCRIBE=false # Disable transcription if key missing
        fi
    else # Using local Whisper (-T)
        if ! $transcription_possible_local; then
            echo "Warning: Local 'whisper' command required for local transcription (-T) but not found." >&2
            echo "Audio processing will continue but transcription will be skipped." >&2
            FLAG_TRANSCRIBE=false # Disable transcription if dependency missing
        fi
    fi
fi

# === Function Definitions ===
process_file() {
  local input_file="$1"
  local output_file="$2"
  local current_tempo_rate="$3" # Use the tempo rate passed for this specific process run
  local input_filename=$(basename "$input_file")

  # Create output directory if needed
  local output_dir=$(dirname "$output_file")
   # Handle output dir being '.' for relative paths
    if [[ "$output_dir" == "." ]]; then
        output_dir=$(pwd) # Use current working directory explicitly
        output_file="${output_dir}/$(basename "$output_file")" # Prepend cwd path if needed
    fi

  if [ ! -d "$output_dir" ]; then
    if [ $FLAG_DRY_RUN = true ]; then
        echo "DRY RUN: Would create directory '$output_dir'"
    else
        mkdir -p "$output_dir"
        if [ $? -ne 0 ]; then
          echo "Error: Could not create output directory '$output_dir'" >&2
          return 1 # Signal failure
        fi
    fi
  fi

  echo "Processing '$input_filename' -> '$(basename "$output_file")' (Tempo: ${current_tempo_rate}x)"

  # Prepare filter chain
  # Start with silenceremove
  local filter_chain="silenceremove=stop_periods=-1:stop_duration=${MIN_SILENCE_DURATION}:stop_threshold=${SILENCE_THRESHOLD}dB"

  # Add tempo adjustment if not 1.0
  # Use C locale for bc comparison
  if (( $(LC_NUMERIC=C echo "$current_tempo_rate != 1.0" | bc -l) )); then
    local atempo_chain=$(calculate_atempo_chain "$current_tempo_rate")
    filter_chain="${filter_chain},${atempo_chain}"
  fi

  # Add normalization if requested
  if [ "$FLAG_NORMALIZE" = true ]; then
    # Loudnorm needs two passes ideally, but one pass is often good enough here
    # Using recommended parameters for speech/podcasts
    filter_chain="${filter_chain},loudnorm=I=-16:TP=-1.5:LRA=11:print_format=summary"
    # Note: print_format=summary will print stats to stderr (or log file)
  fi

  # Add noise reduction if requested
  if [ "$FLAG_DENOISE" = true ]; then
    # anlmdn is a relatively simple denoiser. Adjust parameters if needed.
    filter_chain="${filter_chain},anlmdn=s=0.001:p=0.01:r=0.01"
  fi

  # Build the ffmpeg command parts
  local ffmpeg_base_cmd="ffmpeg"
  local ffmpeg_log_opts="-loglevel ${LOG_LEVEL}"
  local ffmpeg_input_opts="-i \"$input_file\""
  # Specify audio codec based on format
  local ffmpeg_codec_opt="-c:a libmp3lame" # Default to mp3
  if [ "$AUDIO_FORMAT" == "opus" ]; then ffmpeg_codec_opt="-c:a libopus";
  elif [ "$AUDIO_FORMAT" == "ogg" ]; then ffmpeg_codec_opt="-c:a libvorbis";
  elif [ "$AUDIO_FORMAT" == "wav" ]; then ffmpeg_codec_opt="-c:a pcm_s16le"; fi # Use uncompressed PCM for WAV

  local ffmpeg_audio_opts="$ffmpeg_codec_opt -b:a ${AUDIO_BITRATE} -ac ${AUDIO_CHANNELS} -ar ${AUDIO_SAMPLE_RATE}"
  local ffmpeg_filter_opts="-af \"${filter_chain}\""
  local ffmpeg_output_opts="-vn -y \"$output_file\"" # -vn: no video, -y: overwrite

  # Handle log file redirection
  local log_redirect=""
  if [ -n "$LOG_FILE_PATH" ]; then
    # If log file is set, redirect stderr (2) there, appending (>>)
    log_redirect="2>> \"$LOG_FILE_PATH\""
    # Don't set -loglevel when redirecting, let ffmpeg default (info) go to file
    ffmpeg_log_opts=""
  fi

  # Assemble the full command string - use eval carefully
  local full_ffmpeg_cmd="$ffmpeg_base_cmd $ffmpeg_log_opts $ffmpeg_input_opts $ffmpeg_audio_opts $ffmpeg_filter_opts $ffmpeg_output_opts $log_redirect"

  # Execute or display the command
  if [ $FLAG_DRY_RUN = true ]; then
    echo "DRY RUN: $full_ffmpeg_cmd"
    # Create dummy output file for dry run consistency if segmenting later
    touch "$output_file"
    return 0 # Signal success for dry run
  fi

  # Use eval to handle spaces in paths and the filter chain correctly
  eval $full_ffmpeg_cmd
  local ret=$?
  if [ $ret -ne 0 ]; then
    echo "Error: Processing failed for '$input_filename' (FFmpeg exit code: $ret)." >&2
    # Optionally, print the command that failed
    # echo "Failed command: $full_ffmpeg_cmd" >&2
    return 1 # Signal failure
  fi

  echo "Processed: $output_file"
  return 0 # Signal success
}

segment_file() {
  local input_file="$1" # This should be the already processed (condensed) file
  local segment_output_dir="$2"
  local base_name="$3" # Base name without extension (e.g., "Lecture1_condensed")
  local segment_duration_sec="$4" # Actual duration in seconds

  # Check if input file exists (might not if previous step failed or dry run)
  if [ ! -f "$input_file" ] && [ $FLAG_DRY_RUN = false ]; then
      echo "Warning: Input file '$input_file' for segmentation does not exist. Skipping segmentation." >&2
      return 1
  fi

   # Handle output dir being '.' for relative paths
    if [[ "$segment_output_dir" == "." ]]; then
        segment_output_dir=$(pwd) # Use current working directory explicitly
    fi


  # Create segment output directory if needed
  if [ ! -d "$segment_output_dir" ]; then
     if [ $FLAG_DRY_RUN = true ]; then
        echo "DRY RUN: Would create directory '$segment_output_dir'"
     else
        mkdir -p "$segment_output_dir"
        if [ $? -ne 0 ]; then
          echo "Error: Could not create segment output directory '$segment_output_dir'" >&2
          return 1
        fi
    fi
  fi

  echo "Segmenting '$input_file' into ${segment_duration_sec}-second chunks -> '$segment_output_dir'"

  # Build the ffmpeg command for segmentation
  # Use -c copy to avoid re-encoding
  local ffmpeg_base_cmd="ffmpeg"
  local ffmpeg_log_opts="-loglevel ${LOG_LEVEL}"
  # Check if input file exists before using it (for dry run)
  if [ -f "$input_file" ]; then
      ffmpeg_input_opts="-i \"$input_file\""
  else
      # Use dummy input for dry run if file doesn't exist yet
      ffmpeg_input_opts="-f lavfi -i anullsrc=cl=mono:d=1" # Dummy 1s silent input
      echo "DRY RUN Info: Using dummy input for segmentation command as '$input_file' doesn't exist yet."
  fi
  local ffmpeg_segment_opts="-f segment -segment_time ${segment_duration_sec} -reset_timestamps 1" # reset timestamps helps player compatibility
  local ffmpeg_output_opts="-c copy \"${segment_output_dir}/${base_name}_%03d.${AUDIO_FORMAT}\"" # %03d for 000, 001, etc.

  # Handle log file redirection
  local log_redirect=""
  if [ -n "$LOG_FILE_PATH" ]; then
    log_redirect="2>> \"$LOG_FILE_PATH\""
    ffmpeg_log_opts="" # Don't set -loglevel when redirecting
  fi

  local full_ffmpeg_cmd="$ffmpeg_base_cmd $ffmpeg_log_opts $ffmpeg_input_opts $ffmpeg_segment_opts $ffmpeg_output_opts $log_redirect"

  # Execute or display the command
  if [ $FLAG_DRY_RUN = true ]; then
    echo "DRY RUN: $full_ffmpeg_cmd"
    # Create a dummy first segment file for dry run testing
    touch "${segment_output_dir}/${base_name}_000.${AUDIO_FORMAT}"
    return 0
  fi

  eval $full_ffmpeg_cmd
  local ret=$?
  if [ $ret -ne 0 ]; then
    echo "Error: Segmentation failed for '$input_file' (FFmpeg exit code: $ret)." >&2
    # echo "Failed command: $full_ffmpeg_cmd" >&2
    return 1
  fi

  echo "Segmented: ${segment_output_dir}/${base_name}_*.${AUDIO_FORMAT}"
  return 0
}


# === Determine Mode and Files ===

# Case 1: No positional arguments - Interactive Mode
if [ "$#" -eq 0 ]; then
  echo "--- Interactive Mode ---"
  echo "No input path provided. Scanning script's directory: '${SCRIPT_DIR}'"
  INPUT_PATH="$SCRIPT_DIR"
  # Default output dir relative to script dir in interactive mode
  OUTPUT_DIR="$SCRIPT_DIR/$DEFAULT_OUTPUT_DIR"
  BATCH_MODE=true # Interactive mode is always batch mode over the script dir

  # Find compatible files in the script's directory
  while IFS= read -r -d $'\0' file; do
      # Exclude the script itself and files potentially within known output dirs to avoid loops
      filepath_lower=$(echo "$file" | tr '[:upper:]' '[:lower:]')
      output_dir_lower=$(echo "$OUTPUT_DIR" | tr '[:upper:]' '[:lower:]')
      # Ensure script path comparison is robust (e.g., using realpath if available)
      script_file_path=$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}") # Fallback if realpath fails

      if [[ "$file" != "$script_file_path" && "$filepath_lower" != "$output_dir_lower"* ]]; then
          files_to_process+=("$file")
      fi
  done < <(find "$INPUT_PATH" -maxdepth 1 -type f \( \
      -iname "*.mp3" -o -iname "*.mp4" -o -iname "*.m4a" -o -iname "*.avi" \
      -o -iname "*.mov" -o -iname "*.mkv" -o -iname "*.wav" -o -iname "*.flac" \
      -o -iname "*.ogg" -o -iname "*.opus" \
      \) -print0)


  if [ ${#files_to_process[@]} -eq 0 ]; then
      echo "No compatible media files found directly in '${SCRIPT_DIR}'. Nothing to do."
      exit 0
  fi

  echo "Found ${#files_to_process[@]} potential media file(s):"
  for f in "${files_to_process[@]}"; do printf " - %s\n" "$(basename "$f")"; done
  echo "Proposed main output directory: '$OUTPUT_DIR'"
  if [ -n "$BATCH_FILTER" ]; then echo "Note: Batch filter '$BATCH_FILTER' from flags will be applied."; fi
  echo

  # Confirm proceeding
  read -p "Proceed with processing? [y/N]: " -n 1 -r reply; echo
  if [[ ! "$reply" =~ ^[Yy]$ ]]; then echo "Operation cancelled."; exit 0; fi

  # Ensure base output directory exists (do this *after* confirmation)
  # process_file will create subdirs if needed
  if [ ! -d "$OUTPUT_DIR" ]; then
      if [ "$FLAG_DRY_RUN" = true ]; then
          echo "DRY RUN: Would create main output directory '$OUTPUT_DIR'"
      else
          mkdir -p "$OUTPUT_DIR";
          if [ $? -ne 0 ]; then echo "Error: Could not create output directory '$OUTPUT_DIR'" >&2; exit 1; fi
      fi
  fi

  # --- Interactive Prompts (only if flags not already set) ---

  # 1. Segmentation Prompt (if -s not used)
  if [ -z "$SEGMENT_TIME_FROM_FLAG_SEC" ]; then
      read -p "Create segmented versions? (Default segment length: ${DEFAULT_SEGMENT_TIME_INTERACTIVE_MIN} min) [y/N]: " -n 1 -r seg_reply; echo
      if [[ "$seg_reply" =~ ^[Yy]$ ]]; then
          read -p "Enter segment length in MINUTES [${DEFAULT_SEGMENT_TIME_INTERACTIVE_MIN}]: " user_seg_time_min
          chosen_minutes=$DEFAULT_SEGMENT_TIME_INTERACTIVE_MIN # Default if input is empty/invalid
          if [[ "$user_seg_time_min" =~ ^[1-9][0-9]*$ ]]; then
              chosen_minutes=$user_seg_time_min
          elif [ -n "$user_seg_time_min" ]; then # User entered something invalid
              echo "Invalid input. Using default ${DEFAULT_SEGMENT_TIME_INTERACTIVE_MIN} min." >&2
          fi
          SEGMENT_INTERACTIVE_TIME_SEC=$((chosen_minutes * 60))
          SEGMENT_INTERACTIVE_ENABLED=true
          SEGMENT_OUTPUT_DIR="$OUTPUT_DIR/segmented" # Define segment dir path
          echo "Segmentation enabled: ${chosen_minutes} min (${SEGMENT_INTERACTIVE_TIME_SEC}s) chunks -> '$SEGMENT_OUTPUT_DIR'"
          # Directory will be created by segment_file if needed
      else
          echo "Segmentation skipped."
      fi
  else
      # -s flag was used, respect it
      SEGMENT_INTERACTIVE_ENABLED=false # Flag takes precedence
      SEGMENT_OUTPUT_DIR="$OUTPUT_DIR/segmented" # Still define the path based on flag
      echo "Segmentation will use -s flag value (${SEGMENT_TIME_FROM_FLAG_SEC}s) -> '$SEGMENT_OUTPUT_DIR'."
  fi

  # 2. Tempo Prompt (if -r not used)
  if [ -z "$tempo_rate_flag_raw" ]; then # Check if -r flag was used
      read -p "Adjust audio tempo? (Default suggested rate: ${DEFAULT_TEMPO_INTERACTIVE_RATE}x) [y/N]: " -n 1 -r tempo_reply; echo
      if [[ "$tempo_reply" =~ ^[Yy]$ ]]; then
          read -p "Enter desired tempo rate (e.g., 0.8 for slower, 1.2 for faster) [${DEFAULT_TEMPO_INTERACTIVE_RATE}]: " user_tempo_rate
          chosen_rate=$DEFAULT_TEMPO_INTERACTIVE_RATE # Default if input is empty/invalid
          # Use C locale for bc comparison
          if [[ "$user_tempo_rate" =~ ^[0-9]+([.][0-9]*)?$ ]] && (( $(LC_NUMERIC=C echo "$user_tempo_rate > 0" | bc -l) )); then
              chosen_rate=$user_tempo_rate
          elif [ -n "$user_tempo_rate" ]; then # User entered something invalid
              echo "Invalid input. Using default rate ${DEFAULT_TEMPO_INTERACTIVE_RATE}x." >&2
          fi
          # *** Update the main TEMPO_RATE variable ***
          TEMPO_RATE="$chosen_rate"
          echo "Tempo adjustment enabled: ${TEMPO_RATE}x speed for primary output."
      else
          echo "Tempo adjustment skipped. Using default rate ${TEMPO_RATE}x."
      fi
  else
      # -r flag was used, respect it
      echo "Tempo rate already set by -r flag: ${TEMPO_RATE}x."
  fi

  # 3. Transcription Prompt (if -T and -W not used)
  if [ "$FLAG_TRANSCRIBE" = false ]; then
      transcription_options=""
      prompt_options_list=() # Store valid single-letter options

      if $transcription_possible_local && $transcription_possible_api; then
          transcription_options="(L) Local Whisper, (A) OpenAI Whisper API, or (N) No"
          prompt_options_list+=("L" "l" "A" "a" "N" "n")
      elif $transcription_possible_local; then
          transcription_options="(L) Local Whisper or (N) No"
          prompt_options_list+=("L" "l" "N" "n")
      elif $transcription_possible_api; then
          transcription_options="(A) OpenAI Whisper API or (N) No"
          prompt_options_list+=("A" "a" "N" "n")
      else
          echo "Transcription unavailable: Neither local Whisper nor curl (for API) seem installed."
      fi

      if [ -n "$transcription_options" ]; then
          # Build prompt string like "[L/A/N]" or "[L/N]" etc.
          prompt_letters=""
          unique_letters=""
          for opt in "${prompt_options_list[@]}"; do
              letter=$(echo "$opt" | tr '[:lower:]' '[:upper:]')
              if [[ "$unique_letters" != *"$letter"* ]]; then
                  unique_letters+="$letter"
                  if [ -z "$prompt_letters" ]; then prompt_letters="$letter"; else prompt_letters+="/$letter"; fi
              fi
          done # End of for loop to build prompt string

          read -p "Transcribe audio using $transcription_options? [$prompt_letters]: " -n 1 -r trans_reply; echo

          # Normalize reply to uppercase for easier comparison
          trans_reply_upper=$(echo "$trans_reply" | tr '[:lower:]' '[:upper:]')

          case "$trans_reply_upper" in
              L)
                  if $transcription_possible_local; then
                      FLAG_TRANSCRIBE=true
                      USE_WHISPER_API=false
                      TRANSCRIPTION_INTERACTIVE_ENABLED=true # Mark that decision was interactive
                      echo "Transcription enabled: Using local Whisper (Default model: ${WHISPER_MODEL_SIZE})"
                      # Prompt for model/language refinement maybe? For now, use defaults/flags.
                  else
                      echo "Error: Local Whisper selected but not found. Cannot enable." >&2
                  fi
                  ;;
              A)
                  if $transcription_possible_api; then
                      # Check for API key *now*
                      if [ -z "$OPENAI_API_KEY" ]; then
                          echo "OpenAI API key needed for Whisper API transcription."
                          # Use -s for silent input if hiding key is desired, though still visible in process list
                          read -sp "Enter OpenAI API key (or press Enter to skip transcription): " api_key_input; echo # -s hides input
                          if [ -n "$api_key_input" ]; then
                              OPENAI_API_KEY="$api_key_input" # Store entered key
                          else
                              echo "No API key provided. Skipping API transcription." >&2
                          fi
                      fi
                      # Enable transcription only if key is now available
                      if [ -n "$OPENAI_API_KEY" ]; then
                           FLAG_TRANSCRIBE=true
                           USE_WHISPER_API=true
                           TRANSCRIPTION_INTERACTIVE_ENABLED=true # Mark that decision was interactive
                           echo "Transcription enabled: Using OpenAI Whisper API."
                      fi
                  else
                       echo "Error: Whisper API selected but curl not found. Cannot enable." >&2
                  fi
                  ;;
              N|*) # Default to No / Skip if input is N, n, or anything else invalid
                  echo "Transcription skipped."
                  ;;
          esac
      fi # End if transcription options available
  elif [ "$FLAG_TRANSCRIBE" = true ]; then # Transcription was enabled by flag
        if [ "$USE_WHISPER_API" = true ]; then
            echo "Transcription already enabled via -W flag (OpenAI Whisper API)."
        else
            echo "Transcription already enabled via -T flag (Local Whisper)."
        fi
  fi

  # Prepare transcripts directory *if* transcription is now enabled (by flag or interactively)
  if [ "$FLAG_TRANSCRIBE" = true ]; then
      # prepare_transcripts_dir handles dry run internally
      TRANSCRIPTS_OUTPUT_DIR_RESULT=$(prepare_transcripts_dir "$OUTPUT_DIR")
      prepare_status=$?
      if [ $prepare_status -ne 0 ]; then
          echo "Error: Failed to prepare transcripts directory. Transcription may fail." >&2
          # Decide whether to exit or just warn and disable transcription
          FLAG_TRANSCRIBE=false # Safer to disable if dir creation failed
      else
          TRANSCRIPTS_OUTPUT_DIR="$TRANSCRIPTS_OUTPUT_DIR_RESULT" # Store the returned path
          echo "Transcripts will be saved to: '$TRANSCRIPTS_OUTPUT_DIR'"
      fi
  fi

  echo # Newline before processing starts
  echo "--- Starting Processing ---"

  # === Process Files Found Interactively ===
  processed_count=0
  skipped_count=0
  error_count=0
  # Reset duration counters specific to this run
  total_original_duration_sec="0.0"
  total_condensed_duration_sec="0.0"
  files_measured_count=0


  for original_input_file in "${files_to_process[@]}"; do
    input_filename=$(basename "$original_input_file")

    # Apply batch filter if specified
    if [ -n "$BATCH_FILTER" ] && ! [[ "$input_filename" == $BATCH_FILTER ]]; then
      echo "Skipping '$input_filename' (doesn't match filter '$BATCH_FILTER')"
      ((skipped_count++))
      continue
    fi

    # --- Get Original Duration ---
    if [ "$FLAG_DRY_RUN" = false ]; then
        orig_dur=$(get_duration "$original_input_file")
        if [ -n "$orig_dur" ]; then
            # Use bc with C locale for floating point addition
            total_original_duration_sec=$(LC_NUMERIC=C echo "$total_original_duration_sec + $orig_dur" | bc -l)
        fi
    else
        echo "DRY RUN: Skipping duration measurement for '$input_filename'."
    fi

    input_base="${input_filename%.*}"
    # Output file uses the base name and goes into the main output dir
    processed_output_file="$OUTPUT_DIR/${input_base}.${AUDIO_FORMAT}"

    # --- Step 1: Process the file (Condense + Tempo/Normalize/Denoise) ---
    # Uses the TEMPO_RATE determined by flags or interactive prompt
    process_file "$original_input_file" "$processed_output_file" "$TEMPO_RATE"
    process_status=$?

    if [ $process_status -ne 0 ]; then
        echo "Error processing '$input_filename'. Skipping subsequent steps for this file." >&2
        ((error_count++))
        continue # Skip segmentation, condensed duration measurement, and transcription for this file
    fi

    # --- Get Condensed Duration (only if processing succeeded) ---
     if [ "$FLAG_DRY_RUN" = false ]; then
        cond_dur=$(get_duration "$processed_output_file")
        if [ -n "$cond_dur" ]; then
            # Use bc with C locale for floating point addition
            total_condensed_duration_sec=$(LC_NUMERIC=C echo "$total_condensed_duration_sec + $cond_dur" | bc -l)
            ((files_measured_count++)) # Count files successfully processed and measured
        else
             # If we couldn't get duration of output file, still increment error count? Or just processed?
             # Let's just note it was processed, but duration summary might be incomplete.
             echo "Warning: Could not measure duration of processed file '$processed_output_file'." >&2
        fi
    fi
    # Increment processed count regardless of duration measurement success, as file *was* processed
    ((processed_count++))


    # --- Step 2: Segment the *processed* file if enabled ---
    # Check interactive flag OR command-line flag
    segment_time_to_use=""
    effective_segment_output_dir="" # Use local scope here

    if [ "$SEGMENT_INTERACTIVE_ENABLED" = true ]; then
        segment_time_to_use="$SEGMENT_INTERACTIVE_TIME_SEC"
        effective_segment_output_dir="$SEGMENT_OUTPUT_DIR" # Use path determined interactively
    elif [ -n "$SEGMENT_TIME_FROM_FLAG_SEC" ]; then
        segment_time_to_use="$SEGMENT_TIME_FROM_FLAG_SEC"
        effective_segment_output_dir="$SEGMENT_OUTPUT_DIR" # Use path determined from flag setup
    fi

    if [ -n "$segment_time_to_use" ]; then
        # Base name for segments should reflect the processed file base
        segment_base_name=$(basename "${processed_output_file%.*}")
        segment_file "$processed_output_file" "$effective_segment_output_dir" "$segment_base_name" "$segment_time_to_use"
        segment_status=$?
        if [ $segment_status -ne 0 ]; then
            echo "Warning: Segmentation failed for '$processed_output_file'." >&2
            # Continue processing other files even if segmentation fails
        fi
    fi

    # --- Step 3: Transcription (handled in a separate loop later) ---
    # Placeholder - loop runs after this one finishes.

  done # End of file processing loop

  echo "--- Main Processing Complete ---"
  echo "Processed: ${processed_count}, Skipped by filter: ${skipped_count}, Errors: ${error_count}"


  # === Handle Transcription (Interactive/Batch) ===
  if [ "$FLAG_TRANSCRIBE" = true ]; then
      echo # Newline for clarity
      echo "--- Starting Transcription Process ---"
      transcribed_count=0
      transcription_skipped_count=0
      transcription_error_count=0

      # Iterate through the original list of files again
      for original_input_file in "${files_to_process[@]}"; do
          input_filename=$(basename "$original_input_file")

          # Apply batch filter again if specified
          if [ -n "$BATCH_FILTER" ] && ! [[ "$input_filename" == $BATCH_FILTER ]]; then
              # No message needed here, already skipped in main loop
              continue
          fi

          # Ensure the base output directory exists before transcription attempts to write
          if [ ! -d "$TRANSCRIPTS_OUTPUT_DIR" ] && [ "$FLAG_DRY_RUN" = false ]; then
                echo "Error: Transcript output directory '$TRANSCRIPTS_OUTPUT_DIR' not found. Skipping transcription for '$input_filename'." >&2
                ((transcription_error_count++))
                continue
          fi


          # *** IMPORTANT: Transcribe the ORIGINAL input file ***
          if [ "$USE_WHISPER_API" = true ]; then
              # Pass the original file path
              transcribe_api "$original_input_file" "$TRANSCRIPTS_OUTPUT_DIR" "$WHISPER_MODEL_SIZE" "$WHISPER_LANGUAGE" "$OPENAI_API_KEY"
              transcribe_status=$?
          else
              # Pass the original file path
              transcribe_local "$original_input_file" "$TRANSCRIPTS_OUTPUT_DIR" "$WHISPER_MODEL_SIZE" "$WHISPER_LANGUAGE"
              transcribe_status=$?
          fi

          # Tally results based on return code from transcribe functions
          case $transcribe_status in
              0) ((transcribed_count++)) ;;             # Success
              2) ((transcription_skipped_count++)) ;;    # Skipped (e.g., dependency missing, API error)
              *) ((transcription_error_count++)) ;;      # Other errors (code 1)
          esac
      done
      echo "--- Transcription Process Complete ---"
      echo "Transcribed: ${transcribed_count}, Skipped/Warnings: ${transcription_skipped_count}, Errors: ${transcription_error_count}"
  fi

  # --- Time Saving Summary ---
  if [ "$FLAG_DRY_RUN" = false ] && [ "$files_measured_count" -gt 0 ]; then
      echo # Newline
      echo "--- Time Saving Summary ---"
      # Use format_duration which now handles locale internally via awk
      formatted_original_duration=$(format_duration "$total_original_duration_sec")
      formatted_condensed_duration=$(format_duration "$total_condensed_duration_sec")
      # Use bc with C locale for subtraction
      time_saved_sec=$(LC_NUMERIC=C echo "$total_original_duration_sec - $total_condensed_duration_sec" | bc -l)
      formatted_time_saved=$(format_duration "$time_saved_sec")

      echo "Total original duration:  $formatted_original_duration"
      echo "Total condensed duration: $formatted_condensed_duration (for $files_measured_count successfully processed files)"
      echo "Total time saved:         $formatted_time_saved"

      # Calculate percentage saved, handle potential division by zero
      # Use C locale for bc comparison and calculation
      if (( $(LC_NUMERIC=C echo "$total_original_duration_sec > 0.001" | bc -l) )); then # Avoid division by zero or near-zero
          percentage_saved=$(LC_NUMERIC=C echo "scale=2; ($time_saved_sec / $total_original_duration_sec) * 100" | bc -l)
          # *** UPDATED: Use awk for final percentage formatting ***
          LC_NUMERIC=C awk -v p="$percentage_saved" 'BEGIN {printf "Reduction:                %.2f%%\n", p}'
      else
          echo "Reduction:                N/A (Original duration too short)"
      fi
  elif [ "$FLAG_DRY_RUN" = true ]; then
       echo "--- Time Saving Summary (DRY RUN) ---"
       echo "Duration calculation skipped in dry run mode."
  elif [ "$processed_count" -gt 0 ]; then # Some files processed, but none measured
       echo "--- Time Saving Summary ---"
       echo "Could not calculate time savings (failed to measure duration for processed files)."
  fi


  echo "--- Script Finished ---"
  exit 0 # Successful exit from interactive mode
fi # End of interactive mode block


# === Command-Line Argument Mode (Single File or Batch) ===

# Determine input/output paths based on arguments
if [ "$#" -eq 1 ]; then
  INPUT_PATH="$1"
  if [ ! -e "$INPUT_PATH" ]; then echo "Error: Input path '$INPUT_PATH' does not exist." >&2; exit 1; fi

  if [ -d "$INPUT_PATH" ]; then
    # Input is a directory -> Batch mode
    BATCH_MODE=true
    # Default output dir in current directory if input is dir and no output specified
    OUTPUT_DIR="./$DEFAULT_OUTPUT_DIR"
    echo "Batch mode: Processing directory '$INPUT_PATH' -> '$OUTPUT_DIR'"
  else
    # Input is a file -> Single file mode
    BATCH_MODE=false
    input_filename=$(basename "$INPUT_PATH")
    input_base="${input_filename%.*}"
    # Default output file in current directory
    OUTPUT_FILE="./${input_base}_condensed.${AUDIO_FORMAT}"
    echo "Single file mode: Processing '$INPUT_PATH' -> '$OUTPUT_FILE'"
  fi
elif [ "$#" -eq 2 ]; then
  INPUT_PATH="$1"
  if [ ! -e "$INPUT_PATH" ]; then echo "Error: Input path '$INPUT_PATH' does not exist." >&2; exit 1; fi

  if [ -d "$INPUT_PATH" ]; then
    # Input is directory, output is directory -> Batch mode
    BATCH_MODE=true
    OUTPUT_DIR="$2"
    echo "Batch mode: Processing directory '$INPUT_PATH' -> '$OUTPUT_DIR'"
  else
    # Input is file, output is file -> Single file mode
    BATCH_MODE=false
    OUTPUT_FILE="$2"
    # Ensure output file has an extension if specified as just a name
    if [[ "$OUTPUT_FILE" != *"."* ]]; then
        OUTPUT_FILE="${OUTPUT_FILE}.${AUDIO_FORMAT}"
        echo "Warning: Output file '$2' had no extension, using '.${AUDIO_FORMAT}' -> '$OUTPUT_FILE'" >&2
    fi
     echo "Single file mode: Processing '$INPUT_PATH' -> '$OUTPUT_FILE'"
  fi
elif [ "$#" -gt 2 ]; then
    echo "Error: Too many arguments." >&2
    usage
fi

# --- Setup for Non-Interactive Modes ---

# Prepare segment output directory if needed (based on -s flag)
segment_time_to_use=""
effective_segment_output_dir="" # Define variable for segment output path

if [ -n "$SEGMENT_TIME_FROM_FLAG_SEC" ]; then
    segment_time_to_use="$SEGMENT_TIME_FROM_FLAG_SEC"
    base_output_path="" # Determine base path for segments
    if [ "$BATCH_MODE" = true ]; then
        base_output_path="$OUTPUT_DIR"
    else # Single file mode
        base_output_path=$(dirname "$OUTPUT_FILE")
         # Handle base path being '.'
        if [[ "$base_output_path" == "." ]]; then base_output_path=$(pwd); fi
    fi
    effective_segment_output_dir="${base_output_path}/segmented"
    echo "Segmentation enabled by -s flag (${segment_time_to_use}s) -> '$effective_segment_output_dir'."
    # Directory created by segment_file if needed
fi

# Prepare transcripts directory if transcription enabled by flag
if [ "$FLAG_TRANSCRIBE" = true ]; then
    transcript_base_dir="" # Determine base path for transcripts
    if [ "$BATCH_MODE" = true ]; then
        transcript_base_dir="$OUTPUT_DIR"
    else # Single file mode
        transcript_base_dir=$(dirname "$OUTPUT_FILE")
         # Handle base path being '.'
        if [[ "$transcript_base_dir" == "." ]]; then transcript_base_dir=$(pwd); fi
    fi

    TRANSCRIPTS_OUTPUT_DIR_RESULT=$(prepare_transcripts_dir "$transcript_base_dir")
    prepare_status=$?
    if [ $prepare_status -ne 0 ]; then
        echo "Error: Failed to prepare transcripts directory '$transcript_base_dir/${TRANSCRIPTS_DIR_NAME}'. Transcription may fail." >&2
        FLAG_TRANSCRIBE=false # Disable if dir prep failed
    else
        TRANSCRIPTS_OUTPUT_DIR="$TRANSCRIPTS_OUTPUT_DIR_RESULT" # Store the returned path
        echo "Transcripts will be saved to: '$TRANSCRIPTS_OUTPUT_DIR'"
    fi
fi

# === Batch Mode Processing (Command Line) ===
if [ "$BATCH_MODE" = true ]; then
  echo "--- Starting Batch Processing ---"

  # Find all compatible media files in the input directory
  files_to_process=()
   while IFS= read -r -d $'\0' file; do
      # In batch mode from args, process recursively unless user specifies otherwise
      # Simple find, assumes user wants all matching files in subdirs too
       files_to_process+=("$file")
   done < <(find "$INPUT_PATH" -type f \( \
      -iname "*.mp3" -o -iname "*.mp4" -o -iname "*.m4a" -o -iname "*.avi" \
      -o -iname "*.mov" -o -iname "*.mkv" -o -iname "*.wav" -o -iname "*.flac" \
      -o -iname "*.ogg" -o -iname "*.opus" \
      \) -print0)


  if [ ${#files_to_process[@]} -eq 0 ]; then
    echo "No compatible media files found in '$INPUT_PATH' or its subdirectories."
    exit 0
  fi

  echo "Found ${#files_to_process[@]} potential media file(s)."
  if [ -n "$BATCH_FILTER" ]; then echo "Applying filter: '$BATCH_FILTER'"; fi

  # Ensure base output directory exists
  if [ ! -d "$OUTPUT_DIR" ]; then
      if [ $FLAG_DRY_RUN = true ]; then
          echo "DRY RUN: Would create main output directory '$OUTPUT_DIR'"
      else
          mkdir -p "$OUTPUT_DIR";
          if [ $? -ne 0 ]; then echo "Error: Could not create output directory '$OUTPUT_DIR'" >&2; exit 1; fi
      fi
  fi

  processed_count=0
  skipped_count=0
  error_count=0
  # Reset duration counters specific to this run
  total_original_duration_sec="0.0"
  total_condensed_duration_sec="0.0"
  files_measured_count=0

  # Process each file
  for original_input_file in "${files_to_process[@]}"; do
    input_filename=$(basename "$original_input_file")

    # Apply batch filter if specified
    if [ -n "$BATCH_FILTER" ] && ! [[ "$input_filename" == $BATCH_FILTER ]]; then
      echo "Skipping '$input_filename' (doesn't match filter '$BATCH_FILTER')"
      ((skipped_count++))
      continue
    fi

     # --- Get Original Duration ---
    if [ "$FLAG_DRY_RUN" = false ]; then
        orig_dur=$(get_duration "$original_input_file")
        if [ -n "$orig_dur" ]; then
             # Use bc with C locale for floating point addition
            total_original_duration_sec=$(LC_NUMERIC=C echo "$total_original_duration_sec + $orig_dur" | bc -l)
        fi
    else
        echo "DRY RUN: Skipping duration measurement for '$input_filename'."
    fi

    input_base="${input_filename%.*}"
    # Maintain relative path structure in output dir if input was deep
    # Correctly handle files directly in INPUT_PATH
    relative_path=$(realpath --relative-to="$INPUT_PATH" "$(dirname "$original_input_file")" 2>/dev/null || echo ".")

    if [[ "$relative_path" == "." ]]; then # File was directly in INPUT_PATH or realpath failed
        output_subdir="$OUTPUT_DIR"
    else
        output_subdir="$OUTPUT_DIR/$relative_path"
    fi
    processed_output_file="$output_subdir/${input_base}.${AUDIO_FORMAT}"

    # process_file creates the output_subdir if needed
    process_file "$original_input_file" "$processed_output_file" "$TEMPO_RATE"
    process_status=$?

    if [ $process_status -ne 0 ]; then
        echo "Error processing '$input_filename'. Skipping subsequent steps for this file." >&2
        ((error_count++))
        continue # Skip segmentation and transcription
    fi

    # --- Get Condensed Duration (only if processing succeeded) ---
    if [ "$FLAG_DRY_RUN" = false ]; then
        cond_dur=$(get_duration "$processed_output_file")
        if [ -n "$cond_dur" ]; then
             # Use bc with C locale for floating point addition
            total_condensed_duration_sec=$(LC_NUMERIC=C echo "$total_condensed_duration_sec + $cond_dur" | bc -l)
            ((files_measured_count++)) # Count files successfully processed and measured
        else
             echo "Warning: Could not measure duration of processed file '$processed_output_file'." >&2
        fi
    fi
    # Increment processed count regardless of duration measurement success
    ((processed_count++))

    # Handle segmentation if enabled by flag
    if [ -n "$segment_time_to_use" ]; then
        segment_base_name=$(basename "${processed_output_file%.*}")
        # Segments go into a subdir relative to the *output file's* location
        segment_output_dir_for_file="${output_subdir}/segmented"
        segment_file "$processed_output_file" "$segment_output_dir_for_file" "$segment_base_name" "$segment_time_to_use"
        segment_status=$?
        if [ $segment_status -ne 0 ]; then
            echo "Warning: Segmentation failed for '$processed_output_file'." >&2
        fi
    fi

  done # End batch processing loop

  echo "--- Main Processing Complete ---"
  echo "Processed: ${processed_count}, Skipped by filter: ${skipped_count}, Errors: ${error_count}"

  # Handle Transcription in Batch Mode (Command Line)
  if [ "$FLAG_TRANSCRIBE" = true ]; then
      echo # Newline for clarity
      echo "--- Starting Transcription Process ---"
      transcribed_count=0
      transcription_skipped_count=0
      transcription_error_count=0

      for original_input_file in "${files_to_process[@]}"; do
          input_filename=$(basename "$original_input_file")
          if [ -n "$BATCH_FILTER" ] && ! [[ "$input_filename" == $BATCH_FILTER ]]; then
              continue
          fi

          # Determine where the transcript should go, mirroring output structure
           # Correctly handle files directly in INPUT_PATH
            relative_path=$(realpath --relative-to="$INPUT_PATH" "$(dirname "$original_input_file")" 2>/dev/null || echo ".")

            if [[ "$relative_path" == "." ]]; then
                transcript_output_subdir="$TRANSCRIPTS_OUTPUT_DIR"
            else
                transcript_output_subdir="$TRANSCRIPTS_OUTPUT_DIR/$relative_path"
            fi
            # Ensure this specific subdir exists
            if [ ! -d "$transcript_output_subdir" ] && [ "$FLAG_DRY_RUN" = false ]; then
                 # prepare_transcripts_dir function now handles mkdir -p
                prepare_transcripts_dir "$transcript_output_subdir" > /dev/null # Call just for side-effect of creating dir
                if [ $? -ne 0 ]; then
                    echo "Error creating transcript subdir '$transcript_output_subdir'" >&2;
                    ((transcription_error_count++));
                    continue; # Skip this file if dir creation fails
                fi
            elif [ "$FLAG_DRY_RUN" = true ] && [ ! -d "$transcript_output_subdir" ]; then
                 echo "DRY RUN: Would ensure transcript directory exists: '$transcript_output_subdir'"
            fi

          # Ensure the transcript output directory exists before transcription
          if [ ! -d "$transcript_output_subdir" ] && [ "$FLAG_DRY_RUN" = false ]; then
               echo "Error: Transcript output directory '$transcript_output_subdir' not found. Skipping transcription for '$input_filename'." >&2
               ((transcription_error_count++))
               continue
          fi


          # Transcribe the original file into the calculated transcript subdir
          if [ "$USE_WHISPER_API" = true ]; then
              transcribe_api "$original_input_file" "$transcript_output_subdir" "$WHISPER_MODEL_SIZE" "$WHISPER_LANGUAGE" "$OPENAI_API_KEY"
              transcribe_status=$?
          else
              transcribe_local "$original_input_file" "$transcript_output_subdir" "$WHISPER_MODEL_SIZE" "$WHISPER_LANGUAGE"
              transcribe_status=$?
          fi

          case $transcribe_status in
              0) ((transcribed_count++)) ;;
              2) ((transcription_skipped_count++)) ;;
              *) ((transcription_error_count++)) ;;
          esac
      done
      echo "--- Transcription Process Complete ---"
      echo "Transcribed: ${transcribed_count}, Skipped/Warnings: ${transcription_skipped_count}, Errors: ${transcription_error_count}"
  fi

  # --- Time Saving Summary ---
  if [ "$FLAG_DRY_RUN" = false ] && [ "$files_measured_count" -gt 0 ]; then
      echo # Newline
      echo "--- Time Saving Summary ---"
      # Use format_duration which now handles locale internally via awk
      formatted_original_duration=$(format_duration "$total_original_duration_sec")
      formatted_condensed_duration=$(format_duration "$total_condensed_duration_sec")
      # Use bc with C locale for subtraction
      time_saved_sec=$(LC_NUMERIC=C echo "$total_original_duration_sec - $total_condensed_duration_sec" | bc -l)
      formatted_time_saved=$(format_duration "$time_saved_sec")

      echo "Total original duration:  $formatted_original_duration"
      echo "Total condensed duration: $formatted_condensed_duration (for $files_measured_count successfully processed files)"
      echo "Total time saved:         $formatted_time_saved"

      # Calculate percentage saved, handle potential division by zero
      # Use C locale for bc comparison and calculation
      if (( $(LC_NUMERIC=C echo "$total_original_duration_sec > 0.001" | bc -l) )); then # Avoid division by zero or near-zero
          percentage_saved=$(LC_NUMERIC=C echo "scale=2; ($time_saved_sec / $total_original_duration_sec) * 100" | bc -l)
           # *** UPDATED: Use awk for final percentage formatting ***
           LC_NUMERIC=C awk -v p="$percentage_saved" 'BEGIN {printf "Reduction:                %.2f%%\n", p}'
      else
          echo "Reduction:                N/A (Original duration too short)"
      fi
  elif [ "$FLAG_DRY_RUN" = true ]; then
       echo "--- Time Saving Summary (DRY RUN) ---"
       echo "Duration calculation skipped in dry run mode."
  elif [ "$processed_count" -gt 0 ]; then # Some files processed, but none measured
       echo "--- Time Saving Summary ---"
       echo "Could not calculate time savings (failed to measure duration for processed files)."
  fi

  echo "--- Script Finished ---"
  exit 0 # Successful exit from command-line batch mode
fi


# === Single File Mode Processing (Command Line) ===
if [ "$BATCH_MODE" = false ]; then
    echo "--- Starting Single File Processing ---"

    # Ensure output directory exists for the single file
    output_dir=$(dirname "$OUTPUT_FILE")
     # Handle output dir being '.'
    if [[ "$output_dir" == "." ]]; then
        output_dir=$(pwd) # Use current working directory explicitly
        OUTPUT_FILE="${output_dir}/$(basename "$OUTPUT_FILE")" # Prepend cwd path
        echo "Info: Output file specified relative to current directory. Using full path: '$OUTPUT_FILE'"
    fi

    if [ ! -d "$output_dir" ]; then
        if [ $FLAG_DRY_RUN = true ]; then
            echo "DRY RUN: Would create directory '$output_dir'"
        else
            mkdir -p "$output_dir"
            if [ $? -ne 0 ]; then echo "Error: Could not create output directory '$output_dir'" >&2; exit 1; fi
        fi
    fi

    # Reset duration counters for single file mode
    total_original_duration_sec="0.0"
    total_condensed_duration_sec="0.0"
    files_measured_count=0
    processed_count=0

    # --- Get Original Duration ---
    if [ "$FLAG_DRY_RUN" = false ]; then
        orig_dur=$(get_duration "$INPUT_PATH")
        if [ -n "$orig_dur" ]; then
            total_original_duration_sec=$orig_dur # Initialize total with the single file's duration
        fi
    else
         echo "DRY RUN: Skipping duration measurement for '$INPUT_PATH'."
    fi

    # --- Step 1: Process the file ---
    process_file "$INPUT_PATH" "$OUTPUT_FILE" "$TEMPO_RATE"
    process_status=$?

    if [ $process_status -ne 0 ]; then
        echo "Error processing '$INPUT_PATH'. Aborting." >&2
        exit 1 # Exit if the main processing fails for single file
    fi

    # --- Get Condensed Duration (only if processing succeeded) ---
    if [ "$FLAG_DRY_RUN" = false ]; then
        cond_dur=$(get_duration "$OUTPUT_FILE")
        if [ -n "$cond_dur" ]; then
            total_condensed_duration_sec=$cond_dur # Initialize total with the single file's duration
            files_measured_count=1 # Mark that one file was measured
        else
             echo "Warning: Could not measure duration of processed file '$OUTPUT_FILE'." >&2
        fi
    fi
    processed_count=1 # Single file processed

    # --- Step 2: Handle segmentation if enabled by flag ---
    if [ -n "$segment_time_to_use" ]; then
      # Use the base name of the *output* file for segments
      segment_base_name=$(basename "${OUTPUT_FILE%.*}")
      # Use the effective_segment_output_dir determined earlier
      segment_file "$OUTPUT_FILE" "$effective_segment_output_dir" "$segment_base_name" "$segment_time_to_use"
      segment_status=$?
      if [ $segment_status -ne 0 ]; then
           echo "Warning: Segmentation failed for '$OUTPUT_FILE'." >&2
           # Don't exit, main processing succeeded
      fi
    fi

    # --- Step 3: Handle Transcription in Single File Mode ---
    if [ "$FLAG_TRANSCRIBE" = true ]; then
        echo # Newline
        echo "--- Starting Transcription Process ---"

        # Ensure the transcript output directory exists before transcription
        if [ ! -d "$TRANSCRIPTS_OUTPUT_DIR" ] && [ "$FLAG_DRY_RUN" = false ]; then
              echo "Error: Transcript output directory '$TRANSCRIPTS_OUTPUT_DIR' not found. Skipping transcription." >&2
              # Set status to error for final reporting if needed
              transcribe_status=1
        else
            # *** Transcribe the ORIGINAL INPUT_PATH ***
            # TRANSCRIPTS_OUTPUT_DIR should have been set up earlier based on OUTPUT_FILE's dir
            if [ "$USE_WHISPER_API" = true ]; then
                transcribe_api "$INPUT_PATH" "$TRANSCRIPTS_OUTPUT_DIR" "$WHISPER_MODEL_SIZE" "$WHISPER_LANGUAGE" "$OPENAI_API_KEY"
                transcribe_status=$?
            else
                transcribe_local "$INPUT_PATH" "$TRANSCRIPTS_OUTPUT_DIR" "$WHISPER_MODEL_SIZE" "$WHISPER_LANGUAGE"
                transcribe_status=$?
            fi
            case $transcribe_status in
                0) echo "Transcription successful." ;;
                2) echo "Transcription skipped/warning issued." ;;
                *) echo "Transcription failed." ;;
            esac
            echo "--- Transcription Process Complete ---"
         fi # End check for transcript dir existence
    fi

    # --- Time Saving Summary ---
    if [ "$FLAG_DRY_RUN" = false ] && [ "$files_measured_count" -gt 0 ]; then
        echo # Newline
        echo "--- Time Saving Summary ---"
        # Use format_duration which now handles locale internally via awk
        formatted_original_duration=$(format_duration "$total_original_duration_sec")
        formatted_condensed_duration=$(format_duration "$total_condensed_duration_sec")
        # Use bc with C locale for subtraction
        time_saved_sec=$(LC_NUMERIC=C echo "$total_original_duration_sec - $total_condensed_duration_sec" | bc -l)
        formatted_time_saved=$(format_duration "$time_saved_sec")

        echo "Original duration:   $formatted_original_duration"
        echo "Condensed duration:  $formatted_condensed_duration"
        echo "Time saved:          $formatted_time_saved"

        # Calculate percentage saved, handle potential division by zero
        # Use C locale for bc comparison and calculation
        if (( $(LC_NUMERIC=C echo "$total_original_duration_sec > 0.001" | bc -l) )); then # Avoid division by zero or near-zero
            percentage_saved=$(LC_NUMERIC=C echo "scale=2; ($time_saved_sec / $total_original_duration_sec) * 100" | bc -l)
            # *** UPDATED: Use awk for final percentage formatting ***
            LC_NUMERIC=C awk -v p="$percentage_saved" 'BEGIN {printf "Reduction:           %.2f%%\n", p}'
        else
           echo "Reduction:           N/A (Original duration too short)"
        fi
    elif [ "$FLAG_DRY_RUN" = true ]; then
         echo "--- Time Saving Summary (DRY RUN) ---"
         echo "Duration calculation skipped in dry run mode."
    elif [ "$processed_count" -gt 0 ]; then # File processed, but duration failed
         echo "--- Time Saving Summary ---"
         echo "Could not calculate time savings (failed to measure duration)."
    fi


    echo "--- Script Finished ---"
    exit 0 # Successful exit from single file mode
fi

# Should not be reached, but good practice
exit 1