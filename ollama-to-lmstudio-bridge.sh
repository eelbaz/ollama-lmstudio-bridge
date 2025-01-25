#!/usr/bin/env bash
#
# Ollama-LM-Studio Bridge - Bash version
# This script scans your Ollama manifests, figures out each model's "blob" files,
# and creates symbolic links in a folder recognized by LM Studio.
#
# Requirements:
#   - jq (for JSON parsing)
#   - A shell that supports basic parameter expansion (macOS default is fine)

VERSION="1.1.0"

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
VERBOSE=false
QUIET=false
SKIP_EXISTING=false
CUSTOM_MODEL_DIR=""

# Help message
show_help() {
    cat << EOF
Ollama-LM-Studio Bridge v${VERSION}
Usage: $(basename "$0") [OPTIONS]

Options:
  -h, --help           Show this help message
  -v, --verbose        Enable verbose output
  -q, --quiet         Suppress non-essential output
  -s, --skip-existing  Skip existing symlinks instead of overwriting
  -d, --dir DIR       Specify custom models directory
  --version           Show version information

Example:
  $(basename "$0") --verbose --dir ~/custom/models/path

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

# Determine OS type and set paths
OS_TYPE="$(uname -s)"
case "${OS_TYPE}" in
    Linux*)     
        manifest_dir="$HOME_DIR/.ollama/models/manifests/registry.ollama.ai"
        blob_dir="$HOME_DIR/.ollama/models/blobs"
        ;;
    Darwin*)    
        manifest_dir="$HOME_DIR/.ollama/models/manifests/registry.ollama.ai"
        blob_dir="$HOME_DIR/.ollama/models/blobs"
        ;;
    MINGW*|CYGWIN*|MSYS*)
        # Windows paths
        manifest_dir="$HOME_DIR/AppData/Local/ollama/models/manifests/registry.ollama.ai"
        blob_dir="$HOME_DIR/AppData/Local/ollama/models/blobs"
        ;;
    *)
        log_error "Unsupported operating system: $OS_TYPE"
        exit 1
        ;;
esac

# Set public models directory based on OS and custom directory argument
if [ -n "$CUSTOM_MODEL_DIR" ]; then
    publicModels_dir="$CUSTOM_MODEL_DIR"
else
    case "${OS_TYPE}" in
        Linux*|Darwin*)     
            publicModels_dir="$HOME_DIR/.lmstudio/models"
            ;;
        MINGW*|CYGWIN*|MSYS*)
            publicModels_dir="$HOME_DIR/Documents/.lmstudio/models"
            ;;
    esac
fi

# Verify jq installation
if ! command -v jq >/dev/null 2>&1; then
    log_error "jq is not installed. Please install jq first:"
    echo "  On Ubuntu/Debian: sudo apt-get install jq"
    echo "  On macOS: brew install jq"
    echo "  On Windows: choco install jq"
    exit 1
fi

# Test symlink capability
if ! ln -s "$0" "$TEMP_DIR/__test_symlink__" >/dev/null 2>&1; then
    log_error "Unable to create symbolic links."
    if [[ "$OS_TYPE" == MINGW* || "$OS_TYPE" == CYGWIN* || "$OS_TYPE" == MSYS* ]]; then
        echo "On Windows, you may need to:"
        echo "1. Run this script as Administrator, or"
        echo "2. Enable Developer Mode in Windows settings"
    fi
    exit 1
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

[[ "$QUIET" == "false" ]] && log_info "Exploring Manifest Directory..."

# Find manifest files
manifest_locations=( $(find "$manifest_dir" -type f) )
[ ${#manifest_locations[@]} -eq 0 ] && { log_warning "No manifest files found"; exit 0; }

[[ "$QUIET" == "false" ]] && {
    log_info "Found manifest files:"
    for manifest_file in "${manifest_locations[@]}"; do
        echo "  $manifest_file"
    done
}

# Loop through each discovered manifest file
for manifest in "${manifest_locations[@]}"; do
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
    target_link="$model_dir/${modelName}-${modelTrainedOn}-${modelQuant}.${modelExt}"
    
    # Check if symlink already exists and skip if requested
    if [ -L "$target_link" ] && [ "$SKIP_EXISTING" = "true" ]; then
      [[ "$QUIET" == "false" ]] && log_info "Skipping existing symlink for $modelName"
      continue
    fi
    
    [[ "$QUIET" == "false" ]] && log_info "Creating symbolic link for $modelName..."
    ln -sf "$modelFile" "$target_link" || {
      log_error "Failed to create symlink for $modelName"
      continue
    }
    [[ "$QUIET" == "false" ]] && log_success "Successfully linked $modelName"
  else
    log_warning "No model file found for $modelName"
  fi
done

[[ "$QUIET" == "false" ]] && {
  log_success "Ollama Bridge complete."
  log_info "Set the Models Directory in LMStudio to:"
  log_info "    $publicModels_dir/lmstudio"
  echo ""  # Add a blank line for cleaner output
}

exit 0
