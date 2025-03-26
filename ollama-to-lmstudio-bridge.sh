#!/usr/bin/env bash
#
# Ollama-LM-Studio Bridge - Bash version
# This script scans your Ollama manifests, figures out each model's "blob" files,
# and creates symbolic links in a folder recognized by LM Studio.
#
# Requirements:
#   - jq (for JSON parsing)
#   - A shell that supports basic parameter expansion (macOS default is fine)

VERSION="1.2.4"

set -euo pipefail

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }

# Default settings
RUN=false
VERBOSE=false
QUIET=false
SKIP_EXISTING=false
CUSTOM_MODEL_DIR=""
OLLAMA_MODEL_DIR=""

# Help message
show_help() {
    cat << EOF
Ollama-LM-Studio Bridge v${VERSION}
Usage: $(basename "$0") --run [OPTIONS]

Options:
  -h, --help           Show this help message
  -r, --run            Run the script to execute needed changes
  -v, --verbose        Enable verbose output
  -q, --quiet         Suppress non-essential output
  -s, --skip-existing  Skip existing symlinks instead of overwriting
  -d, --dir DIR       Specify custom models directory
  -o, --ollama-dir    Specify Ollama models directory
  --version           Show version information

Example:
  $(basename "$0") --run --verbose --dir ~/custom/models/path
  $(basename "$0") --run --ollama-dir /usr/share/ollama/.ollama/models

Report issues at: https://github.com/yourusername/ollama-lmstudio-bridge
EOF
    exit 0
}

# Version information
show_version() {
    echo "Ollama-LM-Studio Bridge v${VERSION}"
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            ;;
        -r|--run)
            RUN=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -q|--quiet)
            QUIET=true
            shift
            ;;
        -s|--skip-existing)
            SKIP_EXISTING=true
            shift
            ;;
        -d|--dir)
            CUSTOM_MODEL_DIR="$2"
            shift 2
            ;;
        -o|--ollama-dir)
            OLLAMA_MODEL_DIR="$2"
            shift 2
            ;;
        --version)
            show_version
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

[ "$RUN" == "false" ] && show_help

# Enable verbose mode if requested
[[ "$VERBOSE" == "true" ]] && set -x

# Error handler
trap 'log_error "An error occurred on line $LINENO. Exit code: $?"' ERR

# Detect if script is being sourced
(return 0 2>/dev/null) && SOURCED=1 || SOURCED=0

if [ $SOURCED -eq 1 ]; then
    log_warning "This script should be executed directly, not sourced."
    log_warning "Please run it as: ./ollama-bridge.sh"
    echo ""
fi

# Suppress Konsole warning if we're not running in Konsole
if [ -z "${KONSOLE_VERSION:-}" ]; then
    export KONSOLE_PROFILE_NAME=""
fi

# Suppress macOS shell session saving
if [[ "$(uname)" == "Darwin" ]]; then
    export SHELL_SESSION_SAVE=0
    # If script is sourced, disable session save functions
    if [ $SOURCED -eq 1 ]; then
        shell_session_save_user_state() { :; }
        shell_session_save() { :; }
    fi
fi

# Create temporary directory for operations
TEMP_DIR=$(mktemp -d) || { log_error "Failed to create temporary directory"; exit 1; }
trap 'rm -rf "$TEMP_DIR"' EXIT

# Determine user's home directory more reliably
HOME_DIR="${HOME:-$(getent passwd $(whoami) | cut -d: -f6)}"
[ -z "$HOME_DIR" ] && { log_error "Could not determine home directory"; exit 1; }

# Function to find Ollama installation directory
find_ollama_dir() {
    local ollama_dir

    # If user specified an Ollama directory, use that
    if [ -n "$OLLAMA_MODEL_DIR" ]; then
        if [ -d "$OLLAMA_MODEL_DIR" ]; then
            [ "$VERBOSE" = true ] && log_info "Using specified Ollama directory: $OLLAMA_MODEL_DIR"
            echo "$OLLAMA_MODEL_DIR"
            return
        else
            log_error "Specified Ollama directory does not exist: $OLLAMA_MODEL_DIR"
            exit 1
        fi
    fi

    # Check if running as ollama user
    if [ "$(id -u -n)" = "ollama" ]; then
        ollama_dir="/usr/share/ollama/.ollama/models"
        [ "$VERBOSE" = true ] && log_info "Running as ollama user, using: $ollama_dir"
        echo "$ollama_dir"
        return
    fi

    # Check if systemd service is running and we have proper access
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet ollama.service; then
            # Check if we're in ollama group or have direct access
            if groups | grep -q '\bollama\b' || [ -w "/usr/share/ollama/.ollama/models" ]; then
                ollama_dir="/usr/share/ollama/.ollama/models"
                [ "$VERBOSE" = true ] && log_info "Found active ollama service with access, using: $ollama_dir"
                echo "$ollama_dir"
                return
            fi
        fi
    fi

    # Check system-wide installation
    if [ -d "/usr/share/ollama/.ollama/models" ]; then
        if [ -w "/usr/share/ollama/.ollama/models" ] || groups | grep -q '\bollama\b'; then
            ollama_dir="/usr/share/ollama/.ollama/models"
            [ "$VERBOSE" = true ] && log_info "Found system-wide installation with access: $ollama_dir"
            echo "$ollama_dir"
            return
        elif [ -r "/usr/share/ollama/.ollama/models" ]; then
            ollama_dir="/usr/share/ollama/.ollama/models"
            [ "$VERBOSE" = true ] && log_info "Found readable system-wide installation: $ollama_dir"
            echo "$ollama_dir"
            return
        fi
    fi

    # Check user's home directory (for brew and default installations)
    if [ -d "$HOME/.ollama/models" ]; then
        ollama_dir="$HOME/.ollama/models"
        [ "$VERBOSE" = true ] && log_info "Found models in home directory: $ollama_dir"
        echo "$ollama_dir"
        return
    fi

    # Default to user's home directory if nothing else is found
    ollama_dir="$HOME/.ollama/models"
    [ "$VERBOSE" = true ] && log_warning "No existing installation found, defaulting to: $ollama_dir"
    echo "$ollama_dir"
}

# Function to convert between Windows and MSYS paths
convert_path() {
    local path="$1"
    local to_type="$2"  # 'windows' or 'msys'
    
    if [ "$to_type" = "windows" ]; then
        # Convert MSYS to Windows path
        if [[ "$path" == /* ]]; then
            # Remove leading slash and add drive letter back
            path="${path:1}"
            path="${path/\//:\\}"
            path="${path//\//\\}"
        fi
    else
        # Convert Windows to MSYS path
        if [[ "$path" == [A-Za-z]:* ]]; then
            path="/${path//\\//}"
            path="${path/:/}"
        fi
    fi
    echo "$path"
}

# Function to create Windows symlink
create_windows_symlink() {
    local source="$1"
    local target="$2"
    local win_source
    local win_target
    
    # Convert paths to Windows format
    win_source="$(convert_path "$source" "windows")"
    win_target="$(convert_path "$target" "windows")"
    
    [ "$VERBOSE" = true ] && log_info "Creating Windows symlink from $win_source to $win_target"
    
    # First try native symlink
    if ln -sf "$source" "$target" 2>/dev/null; then
        return 0
    fi
    
    # Try mklink as administrator
    if cmd.exe /c "mklink \"$win_target\" \"$win_source\"" > /dev/null 2>&1; then
        return 0
    fi
    
    # Fall back to copy if symlinks fail
    [ "$VERBOSE" = true ] && log_warning "Falling back to file copy for $win_target"
    cp "$source" "$target"
    return $?
}

# Function to validate directory exists and is accessible
validate_dir() {
    local dir="$1"
    local dir_type="$2"
    
    if [ ! -d "$dir" ]; then
        if [ "$VERBOSE" = true ]; then
            log_warning "$dir_type directory not found: $dir"
            log_info "Creating directory: $dir"
        fi
        mkdir -p "$dir" || {
            log_error "Failed to create $dir_type directory: $dir"
            return 1
        }
    fi
    
    if [ ! -r "$dir" ]; then
        log_error "Cannot read $dir_type directory: $dir"
        return 1
    fi
    
    return 0
}

# Function to find Windows Ollama directory
find_windows_ollama_dir() {
    local ollama_dir

    # If user specified an Ollama directory, use that
    if [ -n "$OLLAMA_MODEL_DIR" ]; then
        ollama_dir="$(convert_path "$OLLAMA_MODEL_DIR" "msys")"
        if [ -d "$ollama_dir/manifests/registry.ollama.ai" ]; then
            [ "$VERBOSE" = true ] && log_info "Using specified Ollama directory: $ollama_dir"
            echo "$ollama_dir"
            return
        else
            log_error "Specified Ollama directory does not contain Ollama models: $ollama_dir"
            exit 1
        fi
    fi

    # Use find to locate Ollama model directories
    local found_dir
    [ "$VERBOSE" = true ] && log_info "Searching for Ollama model directories..."

    # Search all drives from C to Z
    for drive in {C..Z}; do
        if [ -d "/$drive" ]; then
            [ "$VERBOSE" = true ] && log_info "Searching drive $drive:/"
            found_dir=$(find "/$drive" -type d -path "*/manifests/registry.ollama.ai" 2>/dev/null | head -n 1 | xargs dirname 2>/dev/null | xargs dirname 2>/dev/null)
            if [ -n "$found_dir" ]; then
                [ "$VERBOSE" = true ] && log_info "Found Ollama models at: $found_dir"
                echo "$found_dir"
                return
            fi
        fi
    done

    # If still not found, check if Ollama is running and get path from process
    if command -v wmic >/dev/null 2>&1; then
        local process_path
        process_path=$(wmic process where "name='ollama.exe'" get ExecutablePath 2>/dev/null | grep -i "ollama.exe")
        if [ -n "$process_path" ]; then
            process_path="$(dirname "$(echo "$process_path" | tr -d '\r')")"
            ollama_dir="$(convert_path "$process_path" "msys")"
            
            # Search around the Ollama executable location
            [ "$VERBOSE" = true ] && log_info "Searching around Ollama executable at: $ollama_dir"
            
            # Check parent directories up to root
            local current_dir="$ollama_dir"
            while [ "$current_dir" != "/" ]; do
                found_dir=$(find "$current_dir" -maxdepth 3 -type d -path "*/manifests/registry.ollama.ai" 2>/dev/null | head -n 1 | xargs dirname 2>/dev/null | xargs dirname 2>/dev/null)
                if [ -n "$found_dir" ]; then
                    [ "$VERBOSE" = true ] && log_info "Found Ollama models at: $found_dir"
                    echo "$found_dir"
                    return
                fi
                current_dir="$(dirname "$current_dir")"
            done
        fi
    fi

    # If still not found, try to locate .ollama directory
    [ "$VERBOSE" = true ] && log_info "Searching for .ollama directory..."
    found_dir=$(find "$HOME_DIR" -maxdepth 4 -type d -name ".ollama" 2>/dev/null | head -n 1)
    if [ -n "$found_dir" ]; then
        found_dir="$found_dir/models"
        [ "$VERBOSE" = true ] && log_info "Found potential Ollama directory at: $found_dir"
        if validate_dir "$found_dir" "Ollama models"; then
            echo "$found_dir"
            return
        fi
    fi

    # If still not found, default to user's AppData
    ollama_dir="$HOME_DIR/AppData/Local/.ollama/models"
    ollama_dir="$(convert_path "$ollama_dir" "msys")"
    [ "$VERBOSE" = true ] && log_warning "No existing installation found, defaulting to: $ollama_dir"
    
    # Try to create default directory
    if validate_dir "$ollama_dir" "Ollama models"; then
        echo "$ollama_dir"
        return
    fi
    
    log_error "Could not find or create a valid Ollama models directory"
    exit 1
}

# Function to get Windows environment variable value
get_windows_env() {
    local var_name="$1"
    local default_value="$2"
    
    # Try environment variable first
    if [ -n "${!var_name}" ]; then
        echo "${!var_name}"
        return
    fi
    
    # Use default paths if environment variable not found
    case "$var_name" in
        LOCALAPPDATA)
            echo "$HOME_DIR/AppData/Local"
            ;;
        USERPROFILE)
            echo "$HOME_DIR"
            ;;
        *)
            echo "$default_value"
            ;;
    esac
}

# Function to normalize Windows paths
normalize_windows_path() {
    local path="$1"
    # Replace backslashes with forward slashes
    path="${path//\\//}"
    # Remove any trailing slash
    path="${path%/}"
    echo "$path"
}

# Function to find LM Studio models directory
find_lmstudio_dir() {
    local lmstudio_dir

    # If user specified a custom directory, use that
    if [ -n "$CUSTOM_MODEL_DIR" ]; then
        lmstudio_dir="$(convert_path "$CUSTOM_MODEL_DIR" "msys")"
        if validate_dir "$lmstudio_dir" "LM Studio models"; then
            [ "$VERBOSE" = true ] && log_info "Using specified LM Studio directory: $lmstudio_dir"
            echo "$lmstudio_dir"
            return
        else
            log_error "Specified LM Studio directory is not accessible: $lmstudio_dir"
            exit 1
        fi
    fi

    # Search for LM Studio directories
    local search_paths=(
        "$HOME_DIR/.lmstudio/models"
        "$HOME_DIR/AppData/Local/LMStudio/models"
        "$HOME_DIR/AppData/Roaming/LMStudio/models"
        "$HOME_DIR/Documents/.lmstudio/models"
        "$HOME_DIR/Documents/LMStudio/models"
    )

    # Search all drives for LM Studio directories
    for drive in {C..Z}; do
        if [ -d "/$drive" ]; then
            [ "$VERBOSE" = true ] && log_info "Searching drive $drive:/ for LM Studio directories"
            local found_dir
            found_dir=$(find "/$drive/Users" -maxdepth 5 -type d -name "models" -path "*LMStudio*" 2>/dev/null | head -n 1)
            if [ -n "$found_dir" ]; then
                [ "$VERBOSE" = true ] && log_info "Found LM Studio directory at: $found_dir"
                echo "$found_dir"
                return
            fi
        fi
    done

    # Check common paths
    for path in "${search_paths[@]}"; do
        path="$(convert_path "$path" "msys")"
        if [ -d "$path" ] || validate_dir "$path" "LM Studio models"; then
            [ "$VERBOSE" = true ] && log_info "Using LM Studio directory: $path"
            echo "$path"
            return
        fi
    done

    # Default to .lmstudio in user's home
    lmstudio_dir="$HOME_DIR/.lmstudio/models"
    [ "$VERBOSE" = true ] && log_warning "No existing LM Studio directory found, defaulting to: $lmstudio_dir"
    
    if validate_dir "$lmstudio_dir" "LM Studio models"; then
        echo "$lmstudio_dir"
        return
    fi
    
    log_error "Could not find or create a valid LM Studio models directory"
    exit 1
}

# Determine OS type and set paths
OS_TYPE="$(uname -s)"
case "${OS_TYPE}" in
    Linux*|Darwin*)     
        ollama_models_dir="$(find_ollama_dir)"
        manifest_dir="$ollama_models_dir/manifests/registry.ollama.ai"
        blob_dir="$ollama_models_dir/blobs"
        publicModels_dir="$HOME_DIR/.lmstudio/models"
        ;;
    MINGW*|CYGWIN*|MSYS*)
        ollama_models_dir="$(find_windows_ollama_dir)"
        manifest_dir="$ollama_models_dir/manifests/registry.ollama.ai"
        blob_dir="$ollama_models_dir/blobs"
        publicModels_dir="$(find_lmstudio_dir)"
        ;;
    *)
        log_error "Unsupported operating system: $OS_TYPE"
        exit 1
        ;;
esac

# Verify jq installation
if ! command -v jq >/dev/null 2>&1; then
    log_error "jq is not installed. Please install jq first:"
    echo "  On Ubuntu/Debian: sudo apt-get install jq"
    echo "  On macOS: brew install jq"
    echo "  On Windows: choco install jq"
    exit 1
fi

# Test symlink capability
if [[ "$OS_TYPE" == MINGW* || "$OS_TYPE" == CYGWIN* || "$OS_TYPE" == MSYS* ]]; then
    # Try to enable native Windows symlinks in MSYS2/Git Bash
    export MSYS=winsymlinks:nativestrict
    
    # First try using native ln -s with MSYS=winsymlinks:nativestrict
    if ln -s "$0" "$TEMP_DIR/__test_symlink__" >/dev/null 2>&1; then
        [[ "$QUIET" == "false" ]] && log_info "Using native Windows symlinks via MSYS"
    else
        # If that fails, try using Windows mklink command
        if cmd.exe /c "mklink /?>" /dev/null 2>&1; then
            if cmd.exe /c "mklink $TEMP_DIR\\__test_symlink__ $0" > /dev/null 2>&1; then
                [[ "$QUIET" == "false" ]] && log_info "Using Windows mklink command"
            else
                log_warning "Native symlinks not available. Files will be copied instead."
                log_info "To enable native symlinks, either:"
                echo "1. Run Git Bash as Administrator, or"
                echo "2. Enable Developer Mode in Windows settings"
                echo "   (Settings > Update & Security > For Developers)"
                # Don't exit, we'll fall back to copying
            fi
        else
            log_warning "Windows mklink not available. Files will be copied instead."
        fi
    fi
else
    # Original Unix symlink test
    if ! ln -s "$0" "$TEMP_DIR/__test_symlink__" >/dev/null 2>&1; then
        log_error "Unable to create symbolic links."
        exit 1
    fi
fi

[[ "$QUIET" == "false" ]] && {
    log_info "Configuration:"
    log_info "Manifest Directory: $manifest_dir"
    log_info "Blob Directory: $blob_dir"
    log_info "Public Models Dir: $publicModels_dir"
}

# Verify required directories exist
[ ! -d "$manifest_dir" ] && { log_error "Manifest directory not found: $manifest_dir"; exit 1; }
[ ! -d "$blob_dir" ] && { log_error "Blob directory not found: $blob_dir"; exit 1; }

# Recreate the models directory
if [ -d "$publicModels_dir/lmstudio" ]; then
    [[ "$QUIET" == "false" ]] && log_info "Removing old $publicModels_dir/lmstudio"
    rm -rf "$publicModels_dir/lmstudio" || { log_error "Failed to remove old lmstudio directory"; exit 1; }
fi

# Create public models directory if it doesn't exist
if [ ! -d "$publicModels_dir" ]; then
    [[ "$QUIET" == "false" ]] && log_info "Creating $publicModels_dir"
    mkdir -p "$publicModels_dir" || { log_error "Failed to create models directory"; exit 1; }
fi

# Function to normalize path separators
normalize_path() {
    local path="$1"
    echo "${path//\\//}"
}

# Function to validate manifest file
validate_manifest() {
    local manifest="$1"
    if [ ! -f "$manifest" ]; then
        return 1
    fi
    if [ ! -r "$manifest" ]; then
        return 2
    fi
    # Check if it's a valid JSON file
    if ! jq empty "$manifest" >/dev/null 2>&1; then
        return 3
    fi
    return 0
}

# Function to get relative path from base
get_relative_path() {
    local base="$1"
    local full="$2"
    # Remove base path and leading slash
    echo "${full#$base/}"
}

# Function to safely create directory
safe_mkdir() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" || return 1
    fi
    # Check if directory is writable
    if [ ! -w "$dir" ]; then
        return 2
    fi
    return 0
}

# Verify base manifest directory exists and is readable
manifest_base_dir="$ollama_models_dir/manifests"
if [ ! -d "$manifest_base_dir" ]; then
    log_error "Base manifest directory not found: $manifest_base_dir"
    exit 1
fi
if [ ! -r "$manifest_base_dir" ]; then
    log_error "Cannot read manifest directory: $manifest_base_dir"
    exit 1
fi

[[ "$QUIET" == "false" ]] && log_info "Scanning manifest directory: $manifest_base_dir"

# Initialize array for manifest files
manifest_files=()

# Platform-specific manifest discovery
case "${OS_TYPE}" in
    Linux*|Darwin*)     
        while IFS= read -r -d '' file; do
            manifest_files+=("$(normalize_path "$file")")
        done < <(find "$manifest_base_dir" -type f -print0 2>/dev/null)
        ;;
    MINGW*|CYGWIN*|MSYS*)
        # Try Windows dir command first
        if command -v cmd.exe >/dev/null 2>&1; then
            while IFS= read -r file; do
                manifest_files+=("$(normalize_path "$file")")
            done < <(cmd.exe /c "dir /s /b /a-d \"$manifest_base_dir\"" 2>/dev/null)
        fi
        # Fall back to find if dir fails or returns no results
        if [ ${#manifest_files[@]} -eq 0 ]; then
            while IFS= read -r file; do
                manifest_files+=("$(normalize_path "$file")")
            done < <(find "$manifest_base_dir" -type f 2>/dev/null)
        fi
        ;;
    *)
        log_error "Unsupported operating system: $OS_TYPE"
        exit 1
        ;;
esac

# Check if we found any manifest files
if [ ${#manifest_files[@]} -eq 0 ]; then
    log_warning "No manifest files found in $manifest_base_dir"
    exit 0
fi

[[ "$QUIET" == "false" ]] && {
    log_info "Found manifest files:"
    for manifest in "${manifest_files[@]}"; do
        echo "  $manifest"
    done
}

# Process each manifest file
for manifest in "${manifest_files[@]}"; do
    # Validate manifest file
    validate_manifest "$manifest"
    validation_result=$?
    case $validation_result in
        1)
            log_warning "Manifest file not found: $manifest"
            continue
            ;;
        2)
            log_warning "Cannot read manifest file: $manifest"
            continue
            ;;
        3)
            log_warning "Invalid JSON in manifest file: $manifest"
            continue
            ;;
    esac

    # Get relative path components
    relative_path="$(get_relative_path "$manifest_base_dir" "$manifest")"
    IFS='/' read -ra path_parts <<< "$relative_path"
    
    # Extract registry and model information
    if [ ${#path_parts[@]} -lt 2 ]; then
        log_warning "Invalid manifest path structure: $manifest"
        continue
    fi
    
    registry="${path_parts[0]}"
    model_path=$(printf "/%s" "${path_parts[@]:1}")
    model_path=${model_path:1}
    model_path=${model_path%/*} # Remove manifest filename

    # Use original model path
    model_name="${registry}/${model_path}"

    [[ "$QUIET" == "false" ]] && log_info "Processing model: $model_name from registry: $registry"

    # Using jq to parse top-level keys
    if ! config_digest="$(jq -r '.config.digest // empty' "$manifest")"; then
        log_error "Failed to parse config digest from $manifest"
        continue
    fi
    
    if ! layers_count="$(jq -r '.layers | length' "$manifest")"; then
        log_error "Failed to parse layers from $manifest"
        continue
    fi

    # Convert the config digest "sha256:xxxx" -> "sha256-xxxx" path
    if [ -n "$config_digest" ]; then
        config_no_prefix="$(echo "$config_digest" | sed 's/sha256://')"
        modelConfig="$blob_dir/sha256-$config_no_prefix"
    else
        log_warning "No config digest found in $manifest"
        modelConfig=""
    fi

    # Prepare empty variables for layer-based files
    modelFile=""
    modelTemplate=""
    modelParams=""

    # Loop over each layer
    for i in $(seq 0 $((layers_count-1))); do
        if ! mediaType="$(jq -r ".layers[$i].mediaType" "$manifest")"; then
            log_error "Failed to parse mediaType for layer $i in $manifest"
            continue
        fi
        
        if ! digestVal="$(jq -r ".layers[$i].digest" "$manifest")"; then
            log_error "Failed to parse digest for layer $i in $manifest"
            continue
        fi
        
        digest_no_prefix="$(echo "$digestVal" | sed 's/sha256://')"

        # If mediaType ends in "model"
        if [[ "$mediaType" == *"model" ]]; then
            modelFile="$blob_dir/sha256-$digest_no_prefix"
        fi

        # If mediaType ends in "template"
        if [[ "$mediaType" == *"template" ]]; then
            modelTemplate="$blob_dir/sha256-$digest_no_prefix"
        fi

        # If mediaType ends in "params"
        if [[ "$mediaType" == *"params" ]]; then
            modelParams="$blob_dir/sha256-$digest_no_prefix"
        fi
    done

    # Parse JSON from $modelConfig if it exists
    if [ -n "$modelConfig" ] && [ -f "$modelConfig" ]; then
        if ! modelConfigObj="$(cat "$modelConfig")"; then
            log_error "Failed to read model config file: $modelConfig"
            continue
        fi
        
        modelQuant="$(echo "$modelConfigObj"     | jq -r '.file_type     // empty')"
        modelExt="$(echo "$modelConfigObj"       | jq -r '.model_format  // empty')"
        modelTrainedOn="$(echo "$modelConfigObj" | jq -r '.model_type    // empty')"
    else
        modelQuant=""
        modelExt=""
        modelTrainedOn=""
    fi

    # Get the parent directory => model name
    parentDir="$(dirname "$manifest")"
    modelName="$(basename "$parentDir")"

    [[ "$QUIET" == "false" ]] && {
        log_info "Processing model: $modelName"
        log_info "  Quantization: $modelQuant"
        log_info "  Format: $modelExt"
        log_info "  Training: $modelTrainedOn"
    }

    # Ensure $publicModels_dir/lmstudio exists
    if [ ! -d "$publicModels_dir/lmstudio" ]; then
        [[ "$QUIET" == "false" ]] && log_info "Creating lmstudio directory..."
        mkdir -p "$publicModels_dir/lmstudio" || { 
            log_error "Failed to create lmstudio directory"
            continue
        }
    fi

    # Ensure subdirectory for this modelName exists
    model_dir="$publicModels_dir/lmstudio/$modelName"
    if [ ! -d "$model_dir" ]; then
        [[ "$QUIET" == "false" ]] && log_info "Creating directory for $modelName..."
        mkdir -p "$model_dir" || {
            log_error "Failed to create directory for $modelName"
            continue
        }
    fi

    # Create the symlink for the modelFile if it exists
    if [ -n "$modelFile" ] && [ -f "$modelFile" ]; then
        # Create target directory preserving original path structure
        target_dir="$publicModels_dir/lmstudio/$model_name"
        if ! safe_mkdir "$target_dir"; then
            log_error "Failed to create directory: $target_dir"
            continue
        fi

        # Build target link name with all available information
        target_link="$target_dir/${model_path##*/}"
        [ -n "$modelTrainedOn" ] && target_link="${target_link}-${modelTrainedOn}"
        [ -n "$modelQuant" ] && target_link="${target_link}-${modelQuant}"
        [ -n "$modelExt" ] && target_link="${target_link}.${modelExt}"
        
        # Check if symlink already exists and skip if requested
        if [ -L "$target_link" ] && [ "$SKIP_EXISTING" = "true" ]; then
            [[ "$QUIET" == "false" ]] && log_info "Skipping existing symlink for $model_name"
            continue
        fi
        
        [[ "$QUIET" == "false" ]] && log_info "Creating symbolic link for $model_name..."
        
        # Create symlink or copy file
        if [[ "$OS_TYPE" == MINGW* || "$OS_TYPE" == CYGWIN* || "$OS_TYPE" == MSYS* ]]; then
            if create_windows_symlink "$modelFile" "$target_link"; then
                [[ "$QUIET" == "false" ]] && log_success "Successfully created link for $model_name"
            else
                log_error "Failed to create link for $model_name"
                continue
            fi
        else
            # Original Unix symlink creation
            ln -sf "$modelFile" "$target_link" || {
                log_error "Failed to create symlink for $model_name"
                continue
            }
            [[ "$QUIET" == "false" ]] && log_success "Successfully linked $model_name"
        fi
    else
        log_warning "No model file found for $model_name"
    fi
done

[[ "$QUIET" == "false" ]] && {
    log_success "Ollama Bridge complete."
    
    # Cleanup empty directories
    if [ -d "$publicModels_dir/lmstudio" ]; then
        find "$publicModels_dir/lmstudio" -type d -empty -delete 2>/dev/null || true
    fi
    
    log_info "Set the Models Directory in LMStudio to:"
    log_info "    $publicModels_dir"
    echo ""  # Add a blank line for cleaner output
}

exit 0
