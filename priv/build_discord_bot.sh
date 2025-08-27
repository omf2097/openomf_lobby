#!/bin/bash

set -e

echo "Building Discord bot..."

# Navigate to the discord bot directory
cd "$(dirname "$0")/discord_bot"

# Build the bot in release mode
cargo build --release

# Copy the binary to priv directory
cp target/release/discord_bot ../discord_bot_bin

# Make sure it's executable
chmod +x ../discord_bot_bin

echo "Discord bot built successfully: priv/discord_bot_bin"
