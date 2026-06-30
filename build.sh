#!/bin/bash
set -e

echo "=== Ollama Usage Monitor Menu Bar App Builder ==="

# Define paths
WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$WORKSPACE_DIR"

# Clean previous build
if [ -f "OllamaMenuBar" ]; then
    echo "Cleaning up previous build..."
    rm "OllamaMenuBar"
fi

# Create virtual environment and install packages if not done
if [ ! -d ".venv" ]; then
    echo "Creating Python virtual environment..."
    python3 -m venv .venv
    .venv/bin/pip install requests psutil flask waitress pycookiecheat cryptography beautifulsoup4
fi

# Compile the Swift application
echo "Compiling native Swift application..."
SDK_PATH=$(xcrun --show-sdk-path)
swiftc -O -sdk "$SDK_PATH" -parse-as-library OllamaMenuBar.swift -o OllamaMenuBar

echo "Compilation successful!"

# Stop existing processes if running
echo "Checking for running instances..."
pkill -f "OllamaMenuBar" || true
pkill -f "ollama_monitor.py" || true

# Start the application
echo "Launching Ollama Monitor Menu Bar App..."
nohup ./OllamaMenuBar > ollama_menu_bar.log 2>&1 &

echo "=============================================="
echo "Successfully built and launched Ollama Monitor!"
echo "You should now see the 'brain' icon in your macOS menu bar."
echo ""
echo "Important: Configure your Ollama clients (VSCode, Cursor, etc.)"
echo "to send requests to: http://localhost:8080/ollama"
echo "instead of: http://localhost:11434"
echo "=============================================="
