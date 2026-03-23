#!/bin/bash

WORKSPACE_DIR=/workspace

# ==============================================================================
# Vast.ai Persistent Provisioning Script
# ==============================================================================
# This script installs Python packages to /"$WORKSPACE_DIR"/python-packages to 
# ensure they persist across instance restarts when the volume is mounted.
# It also configures Hugging Face cache to persist models on /"$WORKSPACE_DIR".
# Optimized to run only once (skips if already completed).
# ==============================================================================

set -e  # Exit on error

# ------------------------------------------------------------------------------
# Configuration & Paths
# ------------------------------------------------------------------------------
PYTHON_DIR="$WORKSPACE_DIR/python-packages"
HF_CACHE_DIR="$WORKSPACE_DIR/huggingface_cache"
COMPOSER_PATH="/usr/local/bin/composer"
CHANDRA_API_DIR="$WORKSPACE_DIR/chandra-api"
ENV_SETUP_SCRIPT="$WORKSPACE_DIR/env_setup.sh"
BASHRC_FILE="$HOME/.bashrc"
BUILD_FLAG="$WORKSPACE_DIR/.build_complete"
MODEL_DIR="$HF_CACHE_DIR/datalab-to/chandra"
# VLLM_API_SECRET="myscret" # should be passed on env vars during vast.ai build

if [ -f "$BUILD_FLAG" ]; then
    echo ">>> Build already done. Skipping."
else
    # ------------------------------------------------------------------------------
    # Create Directories
    # ------------------------------------------------------------------------------
    # Clean the directories before installing to avoid orphaned packages/models
    rm -rf $PYTHON_DIR/
    rm -rf $HF_CACHE_DIR/ 

    echo ">>> Creating persistent directories..."
    mkdir -p $PYTHON_DIR
    mkdir -p $HF_CACHE_DIR

    # ------------------------------------------------------------------------------
    # Install Utils
    # ------------------------------------------------------------------------------
    apt update
    apt install -y \
        btop

    # ------------------------------------------------------------------------------
    # Install PHP Packages
    # ------------------------------------------------------------------------------
    apt install -y software-properties-common
    add-apt-repository ppa:ondrej/php -y
    apt update
    apt install -y \
        php8.4 \
        php8.4-cli \
        php8.4-mbstring \
        php8.4-xml \
        php8.4-curl \
        php8.4-zip \
        php8.4-mysql \
        php8.4-common \
        unzip \
        curl \
        git \
        git-crypt 

    # ------------------------------------------------------------------------------
    # Install Composer
    # ------------------------------------------------------------------------------
    cd "$WORKSPACE_DIR"
    curl -sS https://getcomposer.org/installer | php
    sudo mv composer.phar "$COMPOSER_PATH"

    # ------------------------------------------------------------------------------
    # API Build
    # ------------------------------------------------------------------------------
    git clone https://github.com/Marcos-Pacheco/chandra-api.git "$CHANDRA_API_DIR"
    cd "$CHANDRA_API_DIR"
    echo "$GIT_CRYPT_KEY" | base64 -d > git-crypt-key #GIT_CRYPT_KEY as env var
    git-crypt unlock git-crypt-key
    shred -u git-crypt-key
    cp .env.example .env
    composer install
    sed -n 's/^Env Line: \(.*\)$/\1/p' <(bin/keys --name=production) | \
        xargs -I {} sed -i 's/^API_KEYS=.*/API_KEYS={}/' .env
    sed -i "s|^CHANDRA_BIN_PATH=.*|CHANDRA_BIN_PATH=${PYTHON_DIR}/bin|" .env
    # nohup php -S 0.0.0.0:8080 -t public > server.log 2>&1 &
    # tmux new-session -d -s api "php -S 0.0.0.0:8080 -t public > server.log 2>&1"
    tmux new-session -d -s api "php -S 0.0.0.0:8080 -t public"
    cd "$WORKSPACE_DIR"

    # ------------------------------------------------------------------------------
    # Install Python Packages
    # ------------------------------------------------------------------------------
    echo ">>> Installing packages to $PYTHON_DIR..."

    pip install --target=$PYTHON_DIR \
        --ignore-installed \
        --no-cache-dir \
        --index-url https://pypi.org/simple/   \
        --extra-index-url https://download.pytorch.org/whl/cu126   \
        torch==2.10.0+cu126 \
        torchaudio==2.10.0+cu126 \
        torchvision==0.25.0+cu126 \
        torchcodec==0.10.0 \
        torchdata==0.10.0 \
        torchtext==0.6.0 \
        torch_c_dlpack_ext==0.1.5 \
        pillow==12.1.0 \
        chandra-ocr==0.1.8 \
        huggingface_hub==0.36.2 \
        vllm==0.17.1
    echo ">>> Package installation complete. Flag file created."

    # ------------------------------------------------------------------------------
    # Create Environment Setup Script
    # ------------------------------------------------------------------------------
    # This file lives on "$WORKSPACE_DIR", so it persists across reboots.
    # It sets PYTHONPATH, PATH, and HF_HOME.
    # NOTE: pip --target installs scripts to the root of the target dir, NOT /bin
    # ------------------------------------------------------------------------------
    echo ">>> Creating environment setup script at $ENV_SETUP_SCRIPT..."
    cat > $ENV_SETUP_SCRIPT << EOF
# Auto-generated by provisioning_script.sh
# Persistent Environment Configuration

# 1. Python Packages Path
export PYTHONPATH=$PYTHON_DIR:\$PYTHONPATH
export PATH=\$PATH:$PYTHON_DIR

# 2. Hugging Face & Model Cache
# This ensures models downloaded by vllm/transformers are saved to "$WORKSPACE_DIR"
export HF_HOME=$HF_CACHE_DIR
export TRANSFORMERS_CACHE=$HF_CACHE_DIR
export HF_DATASETS_CACHE=$HF_CACHE_DIR
EOF

    # Configure tmux to use login shells and update environment
    echo ">>> Configuring tmux..."
cat >> ~/.tmux.conf << EOF
# Force tmux to use login shells (sources .bashrc properly)
set-option -g default-command "bash -l"

# Prevent tmux from stripping these variables on reattach
set-option -g update-environment "PATH PYTHONPATH LD_LIBRARY_PATH HF_HOME HOME USER"

# Allow tmux to accept the PATH variable from outside
# set-environment -g PATH
# set-environment -g PYTHONPATH
EOF

    # ------------------------------------------------------------------------------
    # Update ~/.bashrc to Source the Persistent Setup
    # ------------------------------------------------------------------------------
    echo ">>> Updating $BASHRC_FILE to source environment setup..."
    SOURCE_LINE="source $ENV_SETUP_SCRIPT"

    # Check if the line already exists to avoid duplicates on re-runs
    if ! grep -qF "$SOURCE_LINE" "$BASHRC_FILE"; then
        echo "$SOURCE_LINE" >> "$BASHRC_FILE"
        echo "    Added source command to $BASHRC_FILE"
    else
        echo "    Source command already exists in $BASHRC_FILE"
    fi

    # ------------------------------------------------------------------------------
    # Apply Changes
    # ------------------------------------------------------------------------------
    echo ">>> Applying environment changes to current session..."
    source $BASHRC_FILE

    # CRITICAL: Clear bash command cache so it finds newly installed binaries
    # This is required every time the container starts
    hash -r

    echo ">>> Environment applied and command cache cleared."

    # ------------------------------------------------------------------------------
    # Downloading Models
    # ------------------------------------------------------------------------------
    if [ -d "$MODEL_DIR" ]; then
        echo ">>> Models already present at $MODEL_DIR. Skipping download..."
    else
        echo ">>> Pulling models to $HF_CACHE_DIR..."
        # Use python -m to ensure we use the newly installed package regardless of PATH
        # python -m huggingface_hub.commands.huggingface_cli download datalab-to/chandra 
        hf download datalab-to/chandra
        echo ">>> Model download complete."
    fi

    # ------------------------------------------------------------------------------
    # Verification
    # ------------------------------------------------------------------------------
    echo ">>> Provisioning complete!"
    echo "    Packages installed in: $PYTHON_DIR"
    echo "    Model cache configured at: $HF_CACHE_DIR"
    echo ""
    echo "    To verify PyTorch:"
    echo "    python -c 'import torch; print(torch.__version__)'"
    echo ""
    echo "    To verify vLLM:"
    echo "    vllm --version"
    echo ""
    echo "    To verify Hugging Face CLI:"
    echo "    huggingface-cli --version"

    touch "$BUILD_FLAG"
fi