#!/usr/bin/env bash
#
# Ollma-LM-Studio Bridge - Bash version
# This script scans your Ollama manifests, figures out each model's "blob" files,
# and creates symbolic links in a folder recognized by LM Studio.
#
# Requirements:
#   - jq (for JSON parsing)
#   - A shell that supports basic parameter expansion (macOS default is fine)

set -euo pipefail

# Detect if script is being sourced
(return 0 2>/dev/null) && SOURCED=1 || SOURCED=0

if [ $SOURCED -eq 1 ]; then
    echo "Warning: This script should be executed directly, not sourced."
    echo "Please run it as: ./ollama-bridge.sh"
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

# Determine user's home directory more reliably
HOME_DIR="${HOME:-$(getent passwd $(whoami) | cut -d: -f6)}"

# Determine OS type
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
        echo "Unsupported operating system: $OS_TYPE"
        exit 1
        ;;
esac

# Default public models directory based on OS
case "${OS_TYPE}" in
    Linux*|Darwin*)     
        publicModels_dir="$HOME_DIR/.lmstudio/models"
        ;;
    MINGW*|CYGWIN*|MSYS*)
        publicModels_dir="$HOME_DIR/Documents/.lmstudio/models"
        ;;
esac

# Check if jq is installed
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is not installed. Please install jq first."
    echo "On Ubuntu/Debian: sudo apt-get install jq"
    echo "On macOS: brew install jq"
    echo "On Windows: choco install jq"
    exit 1
fi

# Check if we can create symlinks (especially important for Windows)
if ! ln -s "$0" "__test_symlink__" >/dev/null 2>&1; then
    echo "Error: Unable to create symbolic links."
    echo "On Windows, you may need to:"
    echo "1. Run this script as Administrator, or"
    echo "2. Enable Developer Mode in Windows settings"
    rm -f "__test_symlink__"
    exit 1
fi
rm -f "__test_symlink__"

echo ""
echo "Confirming directories:"
echo "Manifest Directory: $manifest_dir"
echo "Blob Directory:     $blob_dir"
echo "Public Models Dir:  $publicModels_dir"

# Recreate the $publicModels_dir/lmstudio directory if needed
if [ -d "$publicModels_dir/lmstudio" ]; then
  echo ""
  echo "Removing old $publicModels_dir/lmstudio"
  rm -rf "$publicModels_dir/lmstudio"
fi

# Make sure $publicModels_dir exists
if [ ! -d "$publicModels_dir" ]; then
  echo ""
  echo "Creating $publicModels_dir"
  mkdir -p "$publicModels_dir"
fi

echo ""
echo "Exploring Manifest Directory..."

# Instead of 'mapfile' or 'readarray', we use command substitution:
manifest_locations=( $(find "$manifest_dir" -type f) )

echo ""
echo "File Locations:"
for manifest_file in "${manifest_locations[@]}"; do
  echo "$manifest_file"
done

# Loop through each discovered manifest file
for manifest in "${manifest_locations[@]}"; do
  # Using jq to parse top-level keys
  config_digest="$(jq -r '.config.digest // empty' "$manifest")"
  layers_count="$(jq -r '.layers | length' "$manifest")"

  # Convert the config digest "sha256:xxxx" -> "sha256-xxxx" path
  if [ -n "$config_digest" ]; then
    config_no_prefix="$(echo "$config_digest" | sed 's/sha256://')"
    modelConfig="$blob_dir/sha256-$config_no_prefix"
  else
    modelConfig=""
  fi

  # Prepare empty variables for layer-based files
  modelFile=""
  modelTemplate=""
  modelParams=""

  # Loop over each layer
  for i in $(seq 0 $((layers_count-1))); do
    mediaType="$(jq -r ".layers[$i].mediaType" "$manifest")"
    digestVal="$(jq -r ".layers[$i].digest" "$manifest")"
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
    modelConfigObj="$(cat "$modelConfig")"
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

  echo ""
  echo "Model Name:  $modelName"
  echo "Quant:       $modelQuant"
  echo "Extension:   $modelExt"
  echo "Trained on:  $modelTrainedOn"

  # Ensure $publicModels_dir/lmstudio exists
  if [ ! -d "$publicModels_dir/lmstudio" ]; then
    echo ""
    echo "Creating lmstudio directory..."
    mkdir -p "$publicModels_dir/lmstudio"
  fi

  # Ensure subdirectory for this modelName exists
  if [ ! -d "$publicModels_dir/lmstudio/$modelName" ]; then
    echo ""
    echo "Creating $modelName directory..."
    mkdir -p "$publicModels_dir/lmstudio/$modelName"
  fi

  # Create the symlink for the modelFile if it exists
  if [ -n "$modelFile" ] && [ -f "$modelFile" ]; then
    echo ""
    echo "Creating symbolic link for $modelFile..."
    ln -s "$modelFile" \
      "$publicModels_dir/lmstudio/$modelName/${modelName}-${modelTrainedOn}-${modelQuant}.${modelExt}"
  fi
done

echo ""
echo "*********************"
echo "Ollm Bridge complete."
echo "Set the Models Directory in LMStudio to:"
echo "    $publicModels_dir/lmstudio"
echo ""  # Add a blank line for cleaner output

exit 0
