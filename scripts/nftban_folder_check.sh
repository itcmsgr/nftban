#!/bin/bash

# Define the base directory for the nftban project
BASE_DIR="/etc/nftban"

# Check if the base directory already exists
if [ ! -d "$BASE_DIR" ]; then
    echo "Directory structure for $BASE_DIR does not exist. Creating now..."
    # The -p flag creates parent directories if they don't exist,
    # and prevents an error if the directory already exists.
    mkdir -p "$BASE_DIR"/{config,scripts,logs,backups,templates}
    echo "✅ Directory structure created successfully."
else
    echo "✅ Directory structure already exists at $BASE_DIR. No action needed."
fi
