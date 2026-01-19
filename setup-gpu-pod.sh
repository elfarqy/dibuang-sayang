#!/bin/bash

###############################################################################
# Development Stack Setup Script for GPU Pods
# Installs: Git, Node.js (via NVM), pnpm, VS Code Server, PostgreSQL, Redis
# Uses Cloudflare Tunnel for secure external access
# Run as: sudo bash setup.sh
###############################################################################

set -e  # Exit on error

# Set non-interactive mode to avoid prompts
export DEBIAN_FRONTEND=noninteractive

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
VSCODE_USER="vscode-admin"

echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}GPU Pod Development Stack Setup${NC}"
echo -e "${GREEN}================================${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Please run as root${NC}"
    exit 1
fi

###############################################################################
# 1. System Update and Basic Packages
###############################################################################
echo -e "\n${YELLOW}[1/8] Updating system and installing basic packages...${NC}"

# Configure to keep local versions and avoid prompts
echo 'libc6 libraries/restart-without-asking boolean true' | debconf-set-selections
echo 'openssh-server openssh-server/permit-root-login boolean true' | debconf-set-selections

# Use -o Dpkg::Options to keep local config files
apt-get update
apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    curl wget git build-essential apache2-utils \
    ca-certificates gnupg lsb-release

###############################################################################
# 2. Install PostgreSQL and Redis
###############################################################################
echo -e "\n${YELLOW}[2/8] Installing PostgreSQL and Redis...${NC}"

# Install PostgreSQL
apt-get install -y postgresql postgresql-contrib

# Install Redis
apt-get install -y redis-server

# Generate PostgreSQL password
POSTGRES_PASSWORD=$(openssl rand -base64 16)

# Find PostgreSQL version and data directory
PG_VERSION=$(ls /etc/postgresql/ | head -n1)
PG_DATA_DIR="/var/lib/postgresql/$PG_VERSION/main"
PG_BIN_DIR="/usr/lib/postgresql/$PG_VERSION/bin"
PG_CONF_DIR="/etc/postgresql/$PG_VERSION/main"

echo -e "${YELLOW}PostgreSQL version: $PG_VERSION${NC}"

# Ensure postgres user owns the data directory
chown -R postgres:postgres /var/lib/postgresql
chmod 700 "$PG_DATA_DIR" 2>/dev/null || true

# Create necessary runtime directories
mkdir -p /var/run/postgresql
chown postgres:postgres /var/run/postgresql
chmod 2775 /var/run/postgresql

# Start PostgreSQL based on environment
if pidof systemd > /dev/null 2>&1; then
    echo -e "${YELLOW}Starting PostgreSQL with systemd...${NC}"
    systemctl start postgresql
    systemctl enable postgresql
else
    echo -e "${YELLOW}Starting PostgreSQL without systemd...${NC}"
    
    # Check if data directory is initialized
    if [ ! -f "$PG_DATA_DIR/PG_VERSION" ]; then
        echo -e "${YELLOW}PostgreSQL data directory not initialized. This is likely a fresh install.${NC}"
        echo -e "${YELLOW}Attempting to use existing installation...${NC}"
    fi
    
    # Start PostgreSQL with explicit config
    su - postgres -c "$PG_BIN_DIR/postgres -D $PG_DATA_DIR -c config_file=$PG_CONF_DIR/postgresql.conf" > /tmp/postgres.log 2>&1 &
    
    # Store PID
    PG_PID=$!
    
    # Add to startup script for non-systemd environments
    POSTGRES_START_SCRIPT="/usr/local/bin/start-postgres.sh"
    cat > "$POSTGRES_START_SCRIPT" << EOFPG
#!/bin/bash
if ! pgrep -f "postgres -D" > /dev/null; then
    su - postgres -c "$PG_BIN_DIR/postgres -D $PG_DATA_DIR -c config_file=$PG_CONF_DIR/postgresql.conf" > /tmp/postgres.log 2>&1 &
fi
EOFPG
    chmod +x "$POSTGRES_START_SCRIPT"
fi

# Wait for PostgreSQL to start
echo -e "${YELLOW}Waiting for PostgreSQL to start...${NC}"
POSTGRE_RUNNING=false
for i in {1..30}; do
    if su - postgres -c "$PG_BIN_DIR/psql -c 'SELECT 1;'" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ PostgreSQL is running${NC}"
        POSTGRES_RUNNING=true
        break
    fi
    sleep 1
    echo -n "."
done
echo ""

# Check if PostgreSQL is actually running
if [ "$POSTGRES_RUNNING" = false ]; then
    echo -e "${RED}Error: PostgreSQL failed to start${NC}"
    echo -e "${YELLOW}Checking logs...${NC}"
    
    if [ -f /tmp/postgres.log ]; then
        echo -e "${YELLOW}Last 20 lines of PostgreSQL log:${NC}"
        tail -20 /tmp/postgres.log
    fi
    
    if [ -f "$PG_DATA_DIR/logfile" ]; then
        echo -e "${YELLOW}PostgreSQL data directory log:${NC}"
        tail -20 "$PG_DATA_DIR/logfile"
    fi
    
    # Check if it's a port conflict
    if netstat -tln 2>/dev/null | grep -q ":5432"; then
        echo -e "${YELLOW}Port 5432 is already in use. Another PostgreSQL instance may be running.${NC}"
    fi
    
    echo -e "${YELLOW}Trying alternative approach with pg_ctlcluster...${NC}"
    if command -v pg_ctlcluster &> /dev/null; then
        pg_ctlcluster $PG_VERSION main start
        sleep 3
        if su - postgres -c "$PG_BIN_DIR/psql -c 'SELECT 1;'" > /dev/null 2>&1; then
            echo -e "${GREEN}✓ PostgreSQL started with pg_ctlcluster${NC}"
            POSTGRES_RUNNING=true
        fi
    fi
fi

if [ "$POSTGRES_RUNNING" = true ]; then
    # Set PostgreSQL password and create database
    su - postgres << EOF
$PG_BIN_DIR/psql -c "ALTER USER postgres WITH PASSWORD '$POSTGRES_PASSWORD';"
$PG_BIN_DIR/psql -c "CREATE DATABASE devdb;"
EOF

    # Configure PostgreSQL to allow password authentication
    PG_HBA="$PG_CONF_DIR/pg_hba.conf"

    # Backup original config
    cp "$PG_HBA" "$PG_HBA.backup"

    # Allow password authentication from localhost
    sed -i 's/local   all             postgres                                peer/local   all             postgres                                md5/' "$PG_HBA"
    sed -i 's/local   all             all                                     peer/local   all             all                                     md5/' "$PG_HBA"
    sed -i 's/host    all             all             127.0.0.1\/32            scram-sha-256/host    all             all             127.0.0.1\/32            md5/' "$PG_HBA"

    # Reload PostgreSQL configuration
    if pidof systemd > /dev/null 2>&1; then
        systemctl reload postgresql
    else
        su - postgres -c "$PG_BIN_DIR/pg_ctl -D $PG_DATA_DIR reload"
    fi

    echo -e "${GREEN}✓ PostgreSQL installed and configured${NC}"
else
    echo -e "${RED}PostgreSQL could not be started automatically${NC}"
    echo -e "${YELLOW}You may need to start it manually or use an external database${NC}"
fi

# Configure and start Redis
if pidof systemd > /dev/null 2>&1; then
    systemctl start redis-server
    systemctl enable redis-server
else
    # Start Redis without systemd
    if [ -f /etc/redis/redis.conf ]; then
        redis-server /etc/redis/redis.conf --daemonize yes
    else
        redis-server --daemonize yes
    fi
    
    # Add to startup script
    REDIS_START_SCRIPT="/usr/local/bin/start-redis.sh"
    cat > "$REDIS_START_SCRIPT" << EOFREDIS
#!/bin/bash
if ! pgrep redis-server > /dev/null; then
    if [ -f /etc/redis/redis.conf ]; then
        redis-server /etc/redis/redis.conf --daemonize yes
    else
        redis-server --daemonize yes
    fi
fi
EOFREDIS
    chmod +x "$REDIS_START_SCRIPT"
fi

# Verify Redis
if redis-cli ping > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Redis installed and started${NC}"
else
    echo -e "${YELLOW}Warning: Redis may not be running${NC}"
fi

###############################################################################
# 3. Install NVM and Node.js LTS
###############################################################################
echo -e "\n${YELLOW}[3/8] Installing NVM and Node.js LTS...${NC}"

# Determine the regular user (non-root) if script is run via sudo
if [ -n "$SUDO_USER" ]; then
    REGULAR_USER="$SUDO_USER"
    USER_HOME=$(eval echo ~$SUDO_USER)
else
    # If no sudo user, create a deployment user
    REGULAR_USER="deploy"
    if ! id "$REGULAR_USER" &>/dev/null; then
        useradd -m -s /bin/bash "$REGULAR_USER"
    fi
    USER_HOME="/home/$REGULAR_USER"
fi

# Check if sudo is available
if command -v sudo &> /dev/null; then
    SUDO_CMD="sudo -u $REGULAR_USER"
else
    SUDO_CMD="su - $REGULAR_USER -c"
fi

# Install NVM for the regular user
export NVM_DIR="$USER_HOME/.nvm"

if command -v sudo &> /dev/null; then
    sudo -u $REGULAR_USER bash -c "
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
        export NVM_DIR=\"$USER_HOME/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
        nvm install --lts
        nvm use --lts
        nvm alias default 'lts/*'
    "
else
    # Run as the user directly without sudo
    su - $REGULAR_USER << 'EOFNVM'
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
        nvm install --lts
        nvm use --lts
        nvm alias default 'lts/*'
EOFNVM
fi

echo -e "${GREEN}✓ Node.js LTS installed${NC}"

###############################################################################
# 4. Install pnpm
###############################################################################
echo -e "\n${YELLOW}[4/8] Installing pnpm...${NC}"

if command -v sudo &> /dev/null; then
    sudo -u $REGULAR_USER bash -c "
        export NVM_DIR=\"$USER_HOME/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
        npm install -g pnpm
    "
else
    su - $REGULAR_USER << 'EOFPNPM'
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
        npm install -g pnpm
EOFPNPM
fi

echo -e "${GREEN}✓ pnpm installed${NC}"

###############################################################################
# 5. Clone Git Repository
###############################################################################
echo -e "\n${YELLOW}[5/8] Git Repository Setup...${NC}"

# Ask for Git repository
echo -e "${YELLOW}Do you want to clone a Git repository? (y/n)${NC}"
read -r CLONE_REPO

if [[ "$CLONE_REPO" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Enter Git repository URL:${NC}"
    read -r GIT_URL
    
    if [ -n "$GIT_URL" ]; then
        echo -e "${YELLOW}Enter Git username (leave empty if not required):${NC}"
        read -r GIT_USERNAME
        
        if [ -n "$GIT_USERNAME" ]; then
            echo -e "${YELLOW}Enter Git password/token:${NC}"
            read -s GIT_PASSWORD
            echo ""
            
            # Parse URL and inject credentials
            if [[ "$GIT_URL" =~ ^https:// ]]; then
                GIT_URL_WITH_CREDS=$(echo "$GIT_URL" | sed "s|https://|https://${GIT_USERNAME}:${GIT_PASSWORD}@|")
            else
                GIT_URL_WITH_CREDS="$GIT_URL"
            fi
        else
            GIT_URL_WITH_CREDS="$GIT_URL"
        fi
        
        # Extract repo name from URL
        REPO_NAME=$(basename "$GIT_URL" .git)
        PROJECT_DIR="$USER_HOME/projects/$REPO_NAME"
        
        # Create projects directory and clone as regular user
        if command -v sudo &> /dev/null; then
            sudo -u $REGULAR_USER mkdir -p "$USER_HOME/projects"
        else
            su - $REGULAR_USER -c "mkdir -p $USER_HOME/projects"
        fi
        
        echo -e "${YELLOW}Cloning repository...${NC}"
        # Run git clone entirely as the regular user
        if command -v sudo &> /dev/null; then
            sudo -u $REGULAR_USER bash -c "git clone '$GIT_URL_WITH_CREDS' '$PROJECT_DIR'"
        else
            su - $REGULAR_USER -c "git clone '$GIT_URL_WITH_CREDS' '$PROJECT_DIR'"
        fi
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Repository cloned to $PROJECT_DIR${NC}"
            
            # Setup git config for the user if provided
            if [ -n "$GIT_USERNAME" ]; then
                if command -v sudo &> /dev/null; then
                    sudo -u $REGULAR_USER bash -c "cd '$PROJECT_DIR' && git config user.name '$GIT_USERNAME'"
                else
                    su - $REGULAR_USER -c "cd '$PROJECT_DIR' && git config user.name '$GIT_USERNAME'"
                fi
                echo -e "${YELLOW}Enter your Git email:${NC}"
                read -r GIT_EMAIL
                if [ -n "$GIT_EMAIL" ]; then
                    if command -v sudo &> /dev/null; then
                        sudo -u $REGULAR_USER bash -c "cd '$PROJECT_DIR' && git config user.email '$GIT_EMAIL'"
                    else
                        su - $REGULAR_USER -c "cd '$PROJECT_DIR' && git config user.email '$GIT_EMAIL'"
                    fi
                fi
            fi
        else
            echo -e "${RED}Failed to clone repository${NC}"
        fi
    fi
else
    echo -e "${YELLOW}Skipping Git repository clone${NC}"
fi

###############################################################################
# 6. Install VS Code Server
###############################################################################
echo -e "\n${YELLOW}[6/8] Installing VS Code Server...${NC}"

VSCODE_DIR="$USER_HOME/.vscode-server"
if command -v sudo &> /dev/null; then
    sudo -u $REGULAR_USER mkdir -p "$VSCODE_DIR"
else
    su - $REGULAR_USER -c "mkdir -p $VSCODE_DIR"
fi

# Download and install code-server
curl -fsSL https://code-server.dev/install.sh | sh

# Create VS Code Server config directory
VSCODE_CONFIG_DIR="$USER_HOME/.config/code-server"
if command -v sudo &> /dev/null; then
    sudo -u $REGULAR_USER mkdir -p "$VSCODE_CONFIG_DIR"
else
    su - $REGULAR_USER -c "mkdir -p $VSCODE_CONFIG_DIR"
fi

# Generate random password for VS Code
VSCODE_PASSWORD=$(openssl rand -base64 24)

# Create config file - bind to all interfaces for tunnel access
cat > "$VSCODE_CONFIG_DIR/config.yaml" << EOF
bind-addr: 0.0.0.0:8443
auth: password
password: $VSCODE_PASSWORD
cert: false
EOF

chown -R $REGULAR_USER:$REGULAR_USER "$VSCODE_CONFIG_DIR"

# Configure VS Code settings (dark mode + preferences)
VSCODE_USER_DIR="$USER_HOME/.local/share/code-server/User"
if command -v sudo &> /dev/null; then
    sudo -u $REGULAR_USER mkdir -p "$VSCODE_USER_DIR"
else
    su - $REGULAR_USER -c "mkdir -p $VSCODE_USER_DIR"
fi

cat > "$VSCODE_USER_DIR/settings.json" << 'EOF'
{
  "workbench.colorTheme": "Default Dark Modern",
  "editor.fontSize": 14,
  "editor.tabSize": 2,
  "editor.insertSpaces": true,
  "editor.formatOnSave": true,
  "editor.minimap.enabled": true,
  "files.autoSave": "afterDelay",
  "files.autoSaveDelay": 1000,
  "terminal.integrated.fontSize": 13,
  "workbench.startupEditor": "none",
  "explorer.confirmDelete": false,
  "explorer.confirmDragAndDrop": false
}
EOF

chown -R $REGULAR_USER:$REGULAR_USER "$VSCODE_USER_DIR"

# Install extensions for TS, JS, SQL, Markdown, YAML
echo -e "${YELLOW}Installing VS Code extensions...${NC}"

if command -v sudo &> /dev/null; then
    sudo -u $REGULAR_USER bash -c "
export SERVICE_URL=https://marketplace.visualstudio.com/_apis/public/gallery
export ITEM_URL=https://marketplace.visualstudio.com/items

# TypeScript & JavaScript
code-server --install-extension dbaeumer.vscode-eslint
code-server --install-extension esbenp.prettier-vscode

# SQL
code-server --install-extension mtxr.sqltools

# Markdown
code-server --install-extension yzhang.markdown-all-in-one
code-server --install-extension DavidAnson.vscode-markdownlint

# YAML
code-server --install-extension redhat.vscode-yaml

# General utilities
code-server --install-extension eamodio.gitlens
code-server --install-extension streetsidesoftware.code-spell-checker
"
else
    su - $REGULAR_USER << 'EOFEXT'
export SERVICE_URL=https://marketplace.visualstudio.com/_apis/public/gallery
export ITEM_URL=https://marketplace.visualstudio.com/items

# TypeScript & JavaScript
code-server --install-extension dbaeumer.vscode-eslint
code-server --install-extension esbenp.prettier-vscode

# SQL
code-server --install-extension mtxr.sqltools

# Markdown
code-server --install-extension yzhang.markdown-all-in-one
code-server --install-extension DavidAnson.vscode-markdownlint

# YAML
code-server --install-extension redhat.vscode-yaml

# Docker
code-server --install-extension ms-azuretools.vscode-docker

# General utilities
code-server --install-extension eamodio.gitlens
code-server --install-extension streetsidesoftware.code-spell-checker
EOFEXT
fi

echo -e "${GREEN}✓ VS Code Server installed with extensions${NC}"

###############################################################################
# 7. Setup VS Code Server Service
###############################################################################
echo -e "\n${YELLOW}[7/8] Setting up VS Code Server startup...${NC}"

# Check if systemd is available
if pidof systemd > /dev/null 2>&1; then
    # Use systemd
    cat > /etc/systemd/system/code-server.service << EOF
[Unit]
Description=VS Code Server
After=network.target

[Service]
Type=simple
User=$REGULAR_USER
WorkingDirectory=$USER_HOME
Environment="NVM_DIR=$USER_HOME/.nvm"
ExecStart=/usr/bin/code-server --config $VSCODE_CONFIG_DIR/config.yaml
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable code-server
    systemctl start code-server
    echo -e "${GREEN}✓ VS Code Server service configured (systemd)${NC}"
else
    # Use supervisor or simple background process for containerized environments
    echo -e "${YELLOW}Systemd not available, using background process${NC}"
    
    # Create startup script
    cat > "$USER_HOME/start-code-server.sh" << EOF
#!/bin/bash
export NVM_DIR="$USER_HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"
/usr/bin/code-server --config $VSCODE_CONFIG_DIR/config.yaml
EOF
    
    chmod +x "$USER_HOME/start-code-server.sh"
    chown $REGULAR_USER:$REGULAR_USER "$USER_HOME/start-code-server.sh"
    
    # Start code-server in background
    if command -v sudo &> /dev/null; then
        sudo -u $REGULAR_USER bash -c "nohup $USER_HOME/start-code-server.sh > $USER_HOME/code-server.log 2>&1 &"
    else
        su - $REGULAR_USER -c "nohup $USER_HOME/start-code-server.sh > $USER_HOME/code-server.log 2>&1 &"
    fi
    
    # Add to bashrc for auto-start on login
    if ! grep -q "start-code-server.sh" "$USER_HOME/.bashrc"; then
        echo "" >> "$USER_HOME/.bashrc"
        echo "# Auto-start code-server" >> "$USER_HOME/.bashrc"
        echo "if ! pgrep -f code-server > /dev/null; then" >> "$USER_HOME/.bashrc"
        echo "    nohup $USER_HOME/start-code-server.sh > $USER_HOME/code-server.log 2>&1 &" >> "$USER_HOME/.bashrc"
        echo "fi" >> "$USER_HOME/.bashrc"
    fi
    
    echo -e "${GREEN}✓ VS Code Server configured (background process)${NC}"
    echo -e "${YELLOW}  Log file: $USER_HOME/code-server.log${NC}"
fi

###############################################################################
# 8. Install and Configure Cloudflare Tunnel
###############################################################################
echo -e "\n${YELLOW}[8/8] Setting up Cloudflare Tunnel...${NC}"

# Install cloudflared
curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
dpkg -i cloudflared.deb
rm cloudflared.deb

echo -e "${GREEN}✓ Cloudflared installed${NC}"

# Create tunnel config directory
TUNNEL_DIR="$USER_HOME/.cloudflared"
if command -v sudo &> /dev/null; then
    sudo -u $REGULAR_USER mkdir -p "$TUNNEL_DIR"
else
    su - $REGULAR_USER -c "mkdir -p $TUNNEL_DIR"
fi

echo -e "\n${YELLOW}Cloudflare Tunnel Setup Instructions:${NC}"
echo -e "To complete the setup, run these commands as ${GREEN}$REGULAR_USER${NC}:"
echo -e ""
echo -e "1. Login to Cloudflare:"
echo -e "   ${GREEN}cloudflared tunnel login${NC}"
echo -e ""
echo -e "2. Create a tunnel:"
echo -e "   ${GREEN}cloudflared tunnel create my-dev-tunnel${NC}"
echo -e ""
echo -e "3. Create config file at ${GREEN}~/.cloudflared/config.yml${NC}:"
cat << 'TUNNEL_CONFIG'
tunnel: <TUNNEL-ID>
credentials-file: /home/<USER>/.cloudflared/<TUNNEL-ID>.json

ingress:
  # VS Code Server
  - hostname: code.yourdomain.com
    service: http://localhost:8443
  # Catch-all rule
  - service: http_status:404
TUNNEL_CONFIG

echo -e ""
echo -e "4. Create DNS records:"
echo -e "   ${GREEN}cloudflared tunnel route dns my-dev-tunnel code.yourdomain.com${NC}"
echo -e ""
echo -e "5. Run the tunnel:"
echo -e "   ${GREEN}cloudflared tunnel run my-dev-tunnel${NC}"
echo -e ""
echo -e "6. (Optional) Install as a service:"
echo -e "   ${GREEN}sudo cloudflared service install${NC}"

###############################################################################
# Final Output
###############################################################################
echo -e "\n${GREEN}================================${NC}"
echo -e "${GREEN}Setup Complete!${NC}"
echo -e "${GREEN}================================${NC}"
echo -e "\n${YELLOW}Important Information:${NC}\n"
echo -e "Development User: ${GREEN}$REGULAR_USER${NC}"
echo -e "Node.js & pnpm installed for user: ${GREEN}$REGULAR_USER${NC}"
echo -e "\n${YELLOW}Local Access (from within pod):${NC}"
echo -e "  VS Code Server: ${GREEN}http://localhost:8443${NC}"
echo -e "  VS Code Password: ${GREEN}$VSCODE_PASSWORD${NC}"
echo -e "  Adminer: ${GREEN}http://localhost:8080${NC}"
echo -e "\nDatabase Access:"
echo -e "  PostgreSQL Host: ${GREEN}localhost:5432${NC}"
echo -e "  PostgreSQL User: ${GREEN}postgres${NC}"
echo -e "  PostgreSQL Password: ${GREEN}$POSTGRES_PASSWORD${NC}"
echo -e "  PostgreSQL Database: ${GREEN}devdb${NC}"
echo -e "\nAdminer Login:"
echo -e "  System: ${GREEN}PostgreSQL${NC}"
echo -e "  Server: ${GREEN}postgres${NC}"
echo -e "  Username: ${GREEN}postgres${NC}"
echo -e "  Password: ${GREEN}$POSTGRES_PASSWORD${NC}"
echo -e "  Database: ${GREEN}devdb${NC}"

echo -e "\n${YELLOW}Next Steps for Cloudflare Tunnel:${NC}"
echo -e "1. Switch to dev user: ${GREEN}su - $REGULAR_USER${NC}"
echo -e "2. Follow the Cloudflare Tunnel setup instructions above"
echo -e "3. Access your services via your custom domain (e.g., code.yourdomain.com)"

echo -e "\n${YELLOW}To verify installations:${NC}"
echo -e "  Switch to dev user: ${GREEN}su - $REGULAR_USER${NC}"
echo -e "  Check Node: ${GREEN}node --version${NC}"
echo -e "  Check pnpm: ${GREEN}pnpm --version${NC}"
echo -e "  Check PostgreSQL: ${GREEN}psql -U postgres -d devdb${NC}"
echo -e "  Check Redis: ${GREEN}redis-cli ping${NC}"

# Only show systemctl status if systemd is available
if pidof systemd > /dev/null 2>&1; then
    echo -e "\n${YELLOW}Service Status:${NC}"
    systemctl status code-server --no-pager
else
    echo -e "\n${YELLOW}VS Code Server Process:${NC}"
    ps aux | grep code-server | grep -v grep || echo "  Not running yet - will start on next login"
fi

echo -e "\n${GREEN}Save these credentials securely!${NC}\n"
