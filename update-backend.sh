#!/bin/bash
# Backend update script for tday

set -e

echo "Updating tday backend..."

# Load NVM
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm use 20

# Pull latest changes
git pull origin main

# Navigate to backend directory

# Install/update dependencies
yarn install

# Build application
yarn build

# Restart PM2 process
cd /home/ubuntu/apps/tday
pm2 restart tday-backend

echo "Backend deployment updated successfully!"
echo "API available at: https://tday.scholarscoven.com/api"



