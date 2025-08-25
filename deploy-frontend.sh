#!/bin/bash

# =============================================================================
# Frontend Deployment Automation Script (React/Next.js)
# Automates deployment of React and Next.js applications on EC2 with SSL
# Author: Omotayo Ganiyu
# Version: 1.0
# =============================================================================

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}

# Function to check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        error "This script should not be run as root for security reasons"
        exit 1
    fi
}

# Function to check if required tools are installed
check_dependencies() {
    log "Checking dependencies..."
    
    local deps=("git" "curl" "nginx" "certbot")
    for dep in "${deps[@]}"; do
        if ! command -v $dep &> /dev/null; then
            error "$dep is not installed. Please install it first."
            exit 1
        fi
    done
    
    # Check if Node.js is installed
    if ! command -v node &> /dev/null; then
        error "Node.js is not installed. Please install it first."
        exit 1
    fi
    
    log "All dependencies are installed ✓"
}

# Function to collect user input
collect_input() {
    log "Collecting frontend deployment information..."
    
    # Domain name
    while true; do
        read -p "Enter your frontend domain name (e.g., app.example.com or example.com): " DOMAIN_NAME
        if [[ $DOMAIN_NAME =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]\.[a-zA-Z]{2,}$ ]]; then
            break
        else
            error "Invalid domain name format. Please try again."
        fi
    done
    
    # App name
    read -p "Enter your frontend app name: " APP_NAME
    APP_NAME=${APP_NAME// /_}  # Replace spaces with underscores
    
    # Git repository URL
    read -p "Enter your Git repository URL: " GIT_REPO_URL
    
    # Branch name
    read -p "Enter branch name (default: main): " BRANCH_NAME
    BRANCH_NAME=${BRANCH_NAME:-main}
    
    # Frontend type
    while true; do
        read -p "Frontend type (react/nextjs): " FRONTEND_TYPE
        if [[ $FRONTEND_TYPE == "react" || $FRONTEND_TYPE == "nextjs" ]]; then
            break
        else
            error "Please enter either 'react' or 'nextjs'"
        fi
    done
    
    # Frontend folder (if it's a monorepo)
    read -p "Frontend folder name (leave empty if root): " FRONTEND_FOLDER
    
    # API URL configuration
    read -p "Backend API URL (e.g., https://api.example.com/api): " API_URL
    
    # Environment variables
    read -p "Do you have environment variables to set? (y/n): " HAS_ENV_VARS
    
    # Build command customization
    read -p "Custom build command (default: npm run build): " BUILD_COMMAND
    BUILD_COMMAND=${BUILD_COMMAND:-"npm run build"}
    
    # For Next.js, check if it needs PM2
    if [[ $FRONTEND_TYPE == "nextjs" ]]; then
        read -p "Next.js port (default: 3001): " NEXTJS_PORT
        NEXTJS_PORT=${NEXTJS_PORT:-3001}
        
        # Check if PM2 is installed for Next.js
        if ! command -v pm2 &> /dev/null; then
            error "PM2 is required for Next.js deployment. Please install it: npm install -g pm2"
            exit 1
        fi
    fi
    
    # Email for SSL certificate
    read -p "Enter your email for SSL certificate: " SSL_EMAIL
    
    # Deployment directory
    DEPLOY_DIR="/home/$USER/apps/$APP_NAME"
    
    # Display summary
    echo ""
    info "=== Frontend Deployment Summary ==="
    info "Domain: $DOMAIN_NAME"
    info "App Name: $APP_NAME"
    info "Repository: $GIT_REPO_URL"
    info "Branch: $BRANCH_NAME"
    info "Frontend Type: $FRONTEND_TYPE"
    info "Frontend Folder: ${FRONTEND_FOLDER:-'Root directory'}"
    info "API URL: $API_URL"
    info "Build Command: $BUILD_COMMAND"
    if [[ $FRONTEND_TYPE == "nextjs" ]]; then
        info "Next.js Port: $NEXTJS_PORT"
    fi
    info "Deploy Directory: $DEPLOY_DIR"
    info "SSL Email: $SSL_EMAIL"
    echo ""
    
    read -p "Continue with deployment? (y/n): " CONFIRM
    if [[ $CONFIRM != "y" && $CONFIRM != "Y" ]]; then
        log "Deployment cancelled by user"
        exit 0
    fi
}

# Function to setup project directory and clone repository
setup_project() {
    log "Setting up project directory..."
    
    # Create apps directory if it doesn't exist
    mkdir -p "/home/$USER/apps"
    
    # Remove existing directory if it exists
    if [ -d "$DEPLOY_DIR" ]; then
        warning "Directory $DEPLOY_DIR already exists. Removing..."
        rm -rf "$DEPLOY_DIR"
    fi
    
    # Clone repository
    log "Cloning repository..."
    git clone -b "$BRANCH_NAME" "$GIT_REPO_URL" "$DEPLOY_DIR"
    
    if [ ! -d "$DEPLOY_DIR" ]; then
        error "Failed to clone repository"
        exit 1
    fi
    
    # Navigate to frontend folder if specified
    if [ -n "$FRONTEND_FOLDER" ]; then
        if [ ! -d "$DEPLOY_DIR/$FRONTEND_FOLDER" ]; then
            error "Frontend folder '$FRONTEND_FOLDER' not found in repository"
            exit 1
        fi
        FRONTEND_PATH="$DEPLOY_DIR/$FRONTEND_FOLDER"
    else
        FRONTEND_PATH="$DEPLOY_DIR"
    fi
    
    cd "$FRONTEND_PATH"
    log "Repository cloned successfully ✓"
}

# Function to setup frontend
setup_frontend() {
    log "Setting up $FRONTEND_TYPE frontend..."
    
    cd "$FRONTEND_PATH"
    
    # Install dependencies
    log "Installing frontend dependencies..."
    npm install
    
    # Handle environment variables
    if [[ $HAS_ENV_VARS == "y" || $HAS_ENV_VARS == "Y" ]]; then
        log "Setting up environment variables..."
        
        if [[ $FRONTEND_TYPE == "nextjs" ]]; then
            ENV_FILE=".env.local"
            if [ -f ".env.local.example" ]; then
                cp ".env.local.example" ".env.local"
                log "Copied .env.local.example to .env.local"
            elif [ -f ".env.example" ]; then
                cp ".env.example" ".env.local"
                log "Copied .env.example to .env.local"
            else
                log "Creating .env.local template..."
                cat > .env.local << EOF
# Next.js Environment Configuration
NEXT_PUBLIC_API_URL=$API_URL
NEXT_PUBLIC_APP_URL=https://$DOMAIN_NAME

# Add your environment variables here
# NEXT_PUBLIC_ANALYTICS_ID=
# NEXT_PUBLIC_STRIPE_PUBLIC_KEY=
# NEXTAUTH_SECRET=
# NEXTAUTH_URL=https://$DOMAIN_NAME
EOF
            fi
        else
            ENV_FILE=".env"
            if [ -f ".env.example" ]; then
                cp ".env.example" ".env"
                log "Copied .env.example to .env"
            else
                log "Creating .env template..."
                cat > .env << EOF
# React Environment Configuration
REACT_APP_API_URL=$API_URL
REACT_APP_APP_URL=https://$DOMAIN_NAME

# Add your environment variables here
# REACT_APP_ANALYTICS_ID=
# REACT_APP_STRIPE_PUBLIC_KEY=
EOF
            fi
        fi
        
        log "Environment file created. Please edit it with your values."
        info "File location: $FRONTEND_PATH/$ENV_FILE"
        read -p "Press Enter after editing the environment file..."
        
        if [ ! -f "$ENV_FILE" ]; then
            error "No environment file found. Please create it before continuing."
            exit 1
        fi
    fi
    
    # Build the application
    log "Building frontend application..."
    $BUILD_COMMAND
    
    # Verify build output
    if [[ $FRONTEND_TYPE == "react" ]]; then
        if [ ! -d "build" ]; then
            error "Build directory not found. Build may have failed."
            exit 1
        fi
        log "React build completed ✓"
    else
        if [ ! -d ".next" ]; then
            error "Next.js build directory not found. Build may have failed."
            exit 1
        fi
        log "Next.js build completed ✓"
    fi
    
    log "Frontend setup completed ✓"
}

# Function to setup PM2 for Next.js
setup_pm2() {
    if [[ $FRONTEND_TYPE != "nextjs" ]]; then
        return
    fi
    
    log "Setting up PM2 for Next.js..."
    
    # Install PM2 if not already installed
    if ! command -v pm2 &> /dev/null; then
        log "Installing PM2..."
        npm install -g pm2
    fi
    
    # Start PM2 with the correct interpreter
    log "Starting PM2 with the correct interpreter..."