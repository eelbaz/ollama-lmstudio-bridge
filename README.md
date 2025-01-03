# Ollama LM Studio Bridge
Use your Ollama managed models with LM Studio!

A utility script that fixes and enables LM Studio to use your Ollama models by creating the necessary symbolic links between Ollama's model storage and LM Studio's expected format.

## Prerequisites

- [Ollama](https://ollama.ai) installed with at least one model downloaded
- [LM Studio](https://lmstudio.ai) installed
- `jq` command-line JSON processor
  - macOS: `brew install jq`
  - Linux: `sudo apt-get install jq` or equivalent
  - Windows: `choco install jq`

## Installation

1. Clone the repository: `git clone https://github.com/eelbaz/ollama-lmstudio-bridge.git`
2. `cd ollama-lmstudio-bridge`
3. Make the script executable: `chmod +x ollama-lmstudio-bridge.sh`


## Usage

1. Run the script:


2. The script will:
   - Scan your Ollama models
   - Create a `publicmodels/lmstudio` directory in your home folder
   - Create symbolic links to your Ollama model files

3. In LM Studio:
   - Go to Settings
   - Set Models Directory to the path shown by the script
   - Your Ollama models should now appear in LM Studio from the dropdown

## Supported Operating Systems

- macOS
- Linux
- Windows (requires Developer Mode or Administrator privileges for symlink creation)

## File Locations

- macOS/Linux:
  - Ollama manifests: `~/.ollama/models/manifests/registry.ollama.ai`
  - Bridge output: `~/publicmodels/lmstudio`

- Windows:
  - Ollama manifests: `%USERPROFILE%\AppData\Local\ollama\models\manifests\registry.ollama.ai`
  - Bridge output: `%USERPROFILE%\Documents\publicmodels\lmstudio`

## Troubleshooting

- **Symlink Creation Fails**: On Windows, enable Developer Mode or run as Administrator
- **Models Not Found**: Ensure you have downloaded models through Ollama first
- **jq Not Found**: Install jq using your system's package manager

## License

MIT License - See [LICENSE](LICENSE) file for details.
