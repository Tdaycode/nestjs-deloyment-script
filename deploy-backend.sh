#!/bin/bash

# =============================================================================
# NestJS Backend Deployment Automation Script
# Automates deployment of NestJS applications on EC2 with SSL
# Author: Omotayo
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
    
    # Check if NVM is installed
    if [ ! -f "$HOME/.nvm/nvm.sh" ]; then
        log "NVM not found. Installing NVM..."
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
        log "NVM installed successfully ✓"
    else
        # Load NVM
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
        log "NVM loaded ✓"
    fi
    
    log "All dependencies are checked ✓"
}

# Function to collect user input
collect_input() {
    log "Collecting backend deployment information..."
    
    # Domain name (can be subdomain for API)
    while true; do
        read -p "Enter your API domain name (e.g., api.example.com or example.com): " DOMAIN_NAME
        if [[ $DOMAIN_NAME =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
            break
        else
            error "Invalid domain name format. Please try again."
        fi
    done
    
    # Node.js version
    read -p "Enter Node.js version to use (default: 18): " NODE_VERSION
    NODE_VERSION=${NODE_VERSION:-18}
    
    # Package manager
    while true; do
        read -p "Package manager (npm/yarn/pnpm): " PACKAGE_MANAGER
        if [[ $PACKAGE_MANAGER == "npm" || $PACKAGE_MANAGER == "yarn" || $PACKAGE_MANAGER == "pnpm" ]]; then
            break
        else
            error "Please enter either 'npm', 'yarn', or 'pnpm'"
        fi
    done
    
    # App name
    read -p "Enter your backend app name (used for PM2 process name): " APP_NAME
    APP_NAME=${APP_NAME// /_}  # Replace spaces with underscores
    
    # Git repository URL
    read -p "Enter your Git repository URL: " GIT_REPO_URL
    
    # Branch name
    read -p "Enter branch name (default: main): " BRANCH_NAME
    BRANCH_NAME=${BRANCH_NAME:-main}
    
    # Backend port
    read -p "Enter backend port (default: 3000): " BACKEND_PORT
    BACKEND_PORT=${BACKEND_PORT:-3000}
    
    # Backend folder (if it's a monorepo)
    read -p "Backend folder name (leave empty if root): " BACKEND_FOLDER
    
    # Database configuration
    read -p "Do you need database setup? (y/n): " NEEDS_DATABASE
    if [[ $NEEDS_DATABASE == "y" || $NEEDS_DATABASE == "Y" ]]; then
        read -p "Database type (postgres/mysql/mongodb): " DB_TYPE
    fi
    
    # Environment variables
    read -p "Do you have environment variables to set? (y/n): " HAS_ENV_VARS
    
    # API path prefix
    read -p "API path prefix (default: /api): " API_PREFIX
    API_PREFIX=${API_PREFIX:-/api}
    
    # Enable CORS for frontend domain
    read -p "Frontend domain for CORS (optional, e.g., app.example.com): " FRONTEND_DOMAIN
    
    # Email for SSL certificate
    read -p "Enter your email for SSL certificate: " SSL_EMAIL
    
    # Deployment directory
    DEPLOY_DIR="/home/$USER/apps/$APP_NAME"
    
    # Display summary
    echo ""
    info "=== Backend Deployment Summary ==="
    info "Node.js Version: $NODE_VERSION"
    info "Package Manager: $PACKAGE_MANAGER"
    info "API Domain: $DOMAIN_NAME"
    info "Node.js Version: $NODE_VERSION ($(node --version))"
    info "Package Manager: $PACKAGE_MANAGER"
    info "App Name: $APP_NAME"
    info "Repository: $GIT_REPO_URL"
    info "Branch: $BRANCH_NAME"
    info "Backend Port: $BACKEND_PORT"
    info "Backend Folder: ${BACKEND_FOLDER:-'Root directory'}"
    info "API Prefix: $API_PREFIX"
    info "Database: ${DB_TYPE:-'None specified'}"
    info "Frontend Domain: ${FRONTEND_DOMAIN:-'Not specified'}"
    info "Deploy Directory: $DEPLOY_DIR"
    info "SSL Email: $SSL_EMAIL"
    echo ""
    
    read -p "Continue with deployment? (y/n): " CONFIRM
    if [[ $CONFIRM != "y" && $CONFIRM != "Y" ]]; then
        log "Deployment cancelled by user"
        exit 0
    fi
}

# Function to setup Node.js environment
setup_nodejs() {
    log "Setting up Node.js environment..."
    
    # Load NVM
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
    
    # Install and use specified Node.js version
    log "Installing Node.js version $NODE_VERSION..."
    nvm install "$NODE_VERSION"
    nvm use "$NODE_VERSION"
    nvm alias default "$NODE_VERSION"
    
    # Verify Node.js installation
    NODE_ACTUAL_VERSION=$(node --version)
    log "Node.js version $NODE_ACTUAL_VERSION is now active ✓"
    
    # Install/setup package manager
    case $PACKAGE_MANAGER in
        "yarn")
            if ! command -v yarn &> /dev/null; then
                log "Installing Yarn..."
                npm install -g yarn
            fi
            log "Yarn is ready ✓"
            ;;
        "pnpm")
            if ! command -v pnpm &> /dev/null; then
                log "Installing pnpm..."
                npm install -g pnpm
            fi
            log "pnpm is ready ✓"
            ;;
        "npm")
            log "Using npm (built-in with Node.js) ✓"
            ;;
    esac
    
    # Install PM2 globally
    if ! command -v pm2 &> /dev/null; then
        log "Installing PM2..."
        npm install -g pm2
    fi
    log "PM2 is ready ✓"
    
    log "Node.js environment setup completed ✓"
}

# Function to get package manager command
get_package_cmd() {
    case $PACKAGE_MANAGER in
        "yarn")
            echo "yarn"
            ;;
        "pnpm")
            echo "pnpm"
            ;;
        *)
            echo "npm"
            ;;
    esac
}

# Function to get install command
get_install_cmd() {
    case $PACKAGE_MANAGER in
        "yarn")
            echo "yarn install"
            ;;
        "pnpm")
            echo "pnpm install"
            ;;
        *)
            echo "npm install"
            ;;
    esac
}

# Function to get build command
get_build_cmd() {
    case $PACKAGE_MANAGER in
        "yarn")
            echo "yarn build"
            ;;
        "pnpm")
            echo "pnpm run build"
            ;;
        *)
            echo "npm run build"
            ;;
    esac
}

# Function to get migration command
get_migration_cmd() {
    case $PACKAGE_MANAGER in
        "yarn")
            echo "yarn migration:run"
            ;;
        "pnpm")
            echo "pnpm run migration:run"
            ;;
        *)
            echo "npm run migration:run"
            ;;
    esac
}
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
    
    # Navigate to backend folder if specified
    if [ -n "$BACKEND_FOLDER" ]; then
        if [ ! -d "$DEPLOY_DIR/$BACKEND_FOLDER" ]; then
            error "Backend folder '$BACKEND_FOLDER' not found in repository"
            exit 1
        fi
        BACKEND_PATH="$DEPLOY_DIR/$BACKEND_FOLDER"
    else
        BACKEND_PATH="$DEPLOY_DIR"
    fi
    
    cd "$BACKEND_PATH"
    log "Repository cloned successfully ✓"
}

# Function to setup backend
setup_backend() {
    log "Setting up NestJS backend..."
    
    cd "$BACKEND_PATH"
    
    # Load NVM and use correct Node.js version
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    nvm use "$NODE_VERSION"
    
    # Install dependencies
    log "Installing backend dependencies with $PACKAGE_MANAGER..."
    INSTALL_CMD=$(get_install_cmd)
    $INSTALL_CMD
    
    # Handle environment variables
    if [[ $HAS_ENV_VARS == "y" || $HAS_ENV_VARS == "Y" ]]; then
        log "Setting up environment variables..."
        
        if [ -f ".env.example" ]; then
            cp ".env.example" ".env"
            log "Copied .env.example to .env"
        else
            log "Creating .env template..."
            cat > .env << EOF
# Environment Configuration
NODE_ENV=production
PORT=$BACKEND_PORT

# Database Configuration
# DATABASE_URL=postgresql://username:password@localhost:5432/database_name
# DATABASE_HOST=localhost
# DATABASE_PORT=5432
# DATABASE_USER=
# DATABASE_PASS=
# DATABASE_NAME=

# JWT Configuration
# JWT_SECRET=your-super-secret-jwt-key
# JWT_EXPIRES_IN=7d

# External APIs
# API_KEY=
# EXTERNAL_SERVICE_URL=

# CORS Configuration
EOF

            if [ -n "$FRONTEND_DOMAIN" ]; then
                echo "CORS_ORIGIN=https://$FRONTEND_DOMAIN" >> .env
            fi
        fi
        
        log "Environment file created. Please edit it with your values."
        info "File location: $BACKEND_PATH/.env"
        read -p "Press Enter after editing the .env file..."
        
        if [ ! -f ".env" ]; then
            error "No .env file found. Please create it before continuing."
            exit 1
        fi
    fi
    
    # Build the application
    log "Building backend application..."
    BUILD_CMD=$(get_build_cmd)
    $BUILD_CMD
    
    # Run database migrations if needed
    if [[ $NEEDS_DATABASE == "y" || $NEEDS_DATABASE == "Y" ]]; then
        log "Database setup detected..."
        if [ -f "package.json" ] && grep -q "migration" package.json; then
            warning "Database migrations found in package.json"
            read -p "Do you want to run migrations now? (y/n): " RUN_MIGRATIONS
            if [[ $RUN_MIGRATIONS == "y" || $RUN_MIGRATIONS == "Y" ]]; then
                MIGRATION_CMD=$(get_migration_cmd)
                $MIGRATION_CMD || warning "Migration failed - please run manually"
            fi
        fi
    fi
    
    log "Backend setup completed ✓"
}

# Function to setup PM2
setup_pm2() {
    log "Setting up PM2 process..."
    
    # Create PM2 ecosystem file
    if [ -n "$BACKEND_FOLDER" ]; then
        PM2_CWD="./$BACKEND_FOLDER"
    else
        PM2_CWD="."
    fi
    
    cat > "$DEPLOY_DIR/ecosystem.config.js" << EOF
module.exports = {
  apps: [
    {
      name: '${APP_NAME}-backend',
      cwd: '${PM2_CWD}',
      script: 'dist/main.js',
      instances: 1,
      autorestart: true,
      watch: false,
      max_memory_restart: '1G',
      env: {
        NODE_ENV: 'production',
        PORT: ${BACKEND_PORT}
      },
      error_file: './logs/err.log',
      out_file: './logs/out.log',
      log_file: './logs/combined.log',
      time: true,
      // Node.js version and environment setup
      interpreter: 'node'
    }
  ]
};
EOF

    # Create logs directory
    mkdir -p "$BACKEND_PATH/logs"
    
    cd "$DEPLOY_DIR"
    
    # Load NVM and use correct Node.js version for PM2
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    nvm use "$NODE_VERSION"
    
    # Stop any existing processes
    pm2 delete "${APP_NAME}-backend" 2>/dev/null || true
    
    # Start PM2 process
    log "Starting PM2 process..."
    pm2 start ecosystem.config.js
    pm2 save
    
    # Setup PM2 startup script
    sudo env PATH=$PATH:/usr/bin pm2 startup systemd -u $USER --hp /home/$USER
    
    log "PM2 setup completed ✓"
}

# Function to setup nginx
setup_nginx() {
    log "Setting up Nginx configuration..."

    TMP_CONF="/tmp/$DOMAIN_NAME.conf"

    # --- Ensure global rate limit zone exists ---
    # Create /etc/nginx/conf.d/limits.conf if not already there
    LIMITS_CONF="/etc/nginx/conf.d/limits.conf"
    if ! grep -q "limit_req_zone" "$LIMITS_CONF" 2>/dev/null; then
        echo "⚙️ Adding global rate limit zone..."
        echo 'limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;' | sudo tee "$LIMITS_CONF" > /dev/null
    fi

    # --- Build site config in /tmp ---
    cat > "$TMP_CONF" << EOF
server {
    listen 80;
    server_name $DOMAIN_NAME;
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;
    
    # API routes
    location $API_PREFIX {
        limit_req zone=api burst=20 nodelay;
        
        proxy_pass http://localhost:$BACKEND_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        
        # Timeout settings
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        
        # CORS headers for API
EOF

    if [ -n "$FRONTEND_DOMAIN" ]; then
        cat >> "$TMP_CONF" << EOF
        add_header Access-Control-Allow-Origin "https://$FRONTEND_DOMAIN" always;
        add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Origin, X-Requested-With, Content-Type, Accept, Authorization" always;
        add_header Access-Control-Allow-Credentials true always;
        
        # Handle preflight requests
        if (\$request_method = 'OPTIONS') {
            add_header Access-Control-Allow-Origin "https://$FRONTEND_DOMAIN";
            add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS";
            add_header Access-Control-Allow-Headers "Origin, X-Requested-With, Content-Type, Accept, Authorization";
            add_header Access-Control-Allow-Credentials true;
            add_header Content-Type "text/plain charset=UTF-8";
            add_header Content-Length 0;
            return 204;
        }
EOF
    fi

    cat >> "$TMP_CONF" << EOF
    }
    
    # Health check endpoint
    location /health {
        proxy_pass http://localhost:$BACKEND_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        access_log off;
    }
    
    # Block access to sensitive files
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
    
    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/json
        application/javascript
        application/xml+rss
        application/atom+xml
        image/svg+xml;
}
EOF

    # --- Move config into nginx and enable it ---
    sudo mv "$TMP_CONF" "/etc/nginx/sites-available/$DOMAIN_NAME"
    sudo ln -sf "/etc/nginx/sites-available/$DOMAIN_NAME" "/etc/nginx/sites-enabled/"

    # --- Test nginx configuration ---
    if ! sudo nginx -t; then
        error "Nginx configuration test failed"
        exit 1
    fi
    
    # --- Reload nginx ---
    sudo systemctl reload nginx
    
    log "Nginx configuration completed ✓"
}


# Function to setup SSL with Let's Encrypt
setup_ssl() {
    log "Setting up SSL certificate with Let's Encrypt..."
    
    # Check if domain is pointing to this server
    info "Please ensure your domain $DOMAIN_NAME is pointing to this server's IP address"
    read -p "Press Enter when your domain is properly configured..."
    
    # Obtain SSL certificate
    sudo certbot --nginx -d "$DOMAIN_NAME" --email "$SSL_EMAIL" --agree-tos --non-interactive
    
    if [ $? -eq 0 ]; then
        log "SSL certificate installed successfully ✓"
        
        # Test automatic renewal
        sudo certbot renew --dry-run
        log "SSL auto-renewal test passed ✓"
    else
        error "Failed to obtain SSL certificate"
        warning "Your API is still accessible via HTTP"
    fi
}

# Function to create deployment update script
create_update_script() {
    log "Creating deployment update script..."
    
    cat > "$DEPLOY_DIR/update-backend.sh" << EOF
#!/bin/bash
# Backend update script for $APP_NAME

set -e

echo "Updating $APP_NAME backend..."

# Load NVM
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \\. "\$NVM_DIR/nvm.sh"
nvm use $NODE_VERSION

# Pull latest changes
git pull origin $BRANCH_NAME

# Navigate to backend directory
EOF

    if [ -n "$BACKEND_FOLDER" ]; then
        echo "cd $BACKEND_FOLDER" >> "$DEPLOY_DIR/update-backend.sh"
    fi

    INSTALL_CMD=$(get_install_cmd)
    BUILD_CMD=$(get_build_cmd)

    cat >> "$DEPLOY_DIR/update-backend.sh" << EOF

# Install/update dependencies
$INSTALL_CMD

# Build application
$BUILD_CMD

# Restart PM2 process
cd $DEPLOY_DIR
pm2 restart ${APP_NAME}-backend

echo "Backend deployment updated successfully!"
echo "API available at: https://$DOMAIN_NAME$API_PREFIX"
EOF

    chmod +x "$DEPLOY_DIR/update-backend.sh"
    
    log "Update script created at $DEPLOY_DIR/update-backend.sh ✓"
}

# Function to create monitoring script
create_monitoring_script() {
    log "Creating monitoring script..."
    
    cat > "$DEPLOY_DIR/monitor-backend.sh" << EOF
#!/bin/bash
# Backend monitoring script for $APP_NAME

echo "=== $APP_NAME Backend Status ==="
echo ""

echo "PM2 Process Status:"
pm2 show ${APP_NAME}-backend

echo ""
echo "Recent Logs:"
pm2 logs ${APP_NAME}-backend --lines 20

echo ""
echo "System Resources:"
echo "Memory Usage:"
free -h

echo ""
echo "Disk Usage:"
df -h

echo ""
echo "API Health Check:"
curl -s https://$DOMAIN_NAME/health || echo "Health check failed"

echo ""
echo "Nginx Status:"
sudo systemctl status nginx --no-pager -l

echo ""
echo "SSL Certificate Status:"
sudo certbot certificates | grep -A 2 "$DOMAIN_NAME"
EOF

    chmod +x "$DEPLOY_DIR/monitor-backend.sh"
    
    log "Monitoring script created at $DEPLOY_DIR/monitor-backend.sh ✓"
}

# Function to display final information
display_final_info() {
    log "Backend deployment completed successfully! 🎉"
    echo ""
    info "=== Backend Deployment Information ==="
    info "App Name: $APP_NAME"
    info "API URL: https://$DOMAIN_NAME$API_PREFIX"
    info "Deploy Directory: $DEPLOY_DIR"
    info "Backend Port: $BACKEND_PORT"
    if [ -n "$BACKEND_FOLDER" ]; then
        info "Backend Path: $DEPLOY_DIR/$BACKEND_FOLDER"
    fi
    echo ""
    info "=== Useful Commands ==="
    info "Check PM2 process: pm2 show ${APP_NAME}-backend"
    info "View logs: pm2 logs ${APP_NAME}-backend"
    info "Restart backend: pm2 restart ${APP_NAME}-backend"
    info "Update deployment: cd $DEPLOY_DIR && ./update-backend.sh"
    info "Monitor system: cd $DEPLOY_DIR && ./monitor-backend.sh"
    info "Check nginx: sudo systemctl status nginx"
    info "Check SSL: sudo certbot certificates"
    echo ""
    info "=== File Locations ==="
    info "Nginx config: /etc/nginx/sites-available/$DOMAIN_NAME"
    info "PM2 config: $DEPLOY_DIR/ecosystem.config.js"
    info "Environment file: $BACKEND_PATH/.env"
    info "Update script: $DEPLOY_DIR/update-backend.sh"
    info "Monitor script: $DEPLOY_DIR/monitor-backend.sh"
    info "Application logs: $BACKEND_PATH/logs/"
    echo ""
    info "=== API Testing ==="
    info "Test API: curl https://$DOMAIN_NAME$API_PREFIX"
    info "Health check: curl https://$DOMAIN_NAME/health"
    echo ""
    warning "Don't forget to:"
    warning "1. Configure your environment variables in $BACKEND_PATH/.env"
    warning "2. Set up your database connection"
    warning "3. Run database migrations if needed"
    warning "4. Test your API endpoints"
    warning "5. Configure monitoring and logging"
}

# Main execution function
main() {
    log "Starting NestJS Backend Deployment Automation"
    
    check_root
    check_dependencies
    collect_input
    setup_nodejs
    setup_project
    setup_backend
    setup_pm2
    setup_nginx
    setup_ssl
    create_update_script
    create_monitoring_script
    display_final_info
    
    log "Backend deployment complete! Your API is live at https://$DOMAIN_NAME$API_PREFIX"
}

# Trap to handle script interruption
trap 'error "Script interrupted. Cleaning up..."; exit 1' INT TERM

# Run main function
main "$@"