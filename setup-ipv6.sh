#!/bin/bash

###############################################################################
# Development Stack Setup Script (IPv6 Only)
# Installs: Git, Node.js (via NVM), pnpm, VS Code Server with HTTPS
# Run as: sudo bash setup-ipv6.sh
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
VSCODE_PORT=8443
VSCODE_USER="vscode-admin"

# Get IPv6 address (first global/scoped IPv6 address, excluding loopback)
SERVER_IP=$(ip -6 addr show | grep -E 'inet6.*scope global' | grep -oP '(?<=inet6\s)[0-9a-f:]+' | head -n1)

# Fallback: get any non-loopback, non-link-local IPv6
if [ -z "$SERVER_IP" ] || [ "$SERVER_IP" = "::1" ]; then
    SERVER_IP=$(ip -6 addr show | grep -oP '(?<=inet6\s)[0-9a-f:]+' | grep -v '^::1' | grep -v '^fe80' | grep -v '^::' | head -n1)
fi

# Fallback: get from eth0 interface specifically
if [ -z "$SERVER_IP" ] || [ "$SERVER_IP" = "::1" ]; then
    SERVER_IP=$(ip -6 addr show eth0 2>/dev/null | grep -oP '(?<=inet6\s)[0-9a-f:]+' | grep -v '^fe80' | head -n1)
fi

# Last resort: manual input if all detection fails
if [ -z "$SERVER_IP" ] || [ "$SERVER_IP" = "::1" ]; then
    echo -e "${RED}⚠ Could not auto-detect IPv6 address${NC}"
    echo -e "${YELLOW}Enter your IPv6 address:${NC}"
    read -r SERVER_IP
fi

# Helper function to format IPv6 for URLs
format_ipv6_url() {
    local ip="$1"
    if [[ "$ip" =~ : ]]; then
        echo "[$ip]"
    else
        echo "$ip"
    fi
}

SERVER_IP_FORMATTED=$(format_ipv6_url "$SERVER_IP")

echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}Development Stack Setup (IPv6)${NC}"
echo -e "${GREEN}================================${NC}"
echo -e "${YELLOW}Detected IPv6: $SERVER_IP${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root${NC}"
    exit 1
fi

###############################################################################
# 0. Configure IPv6 DNS and GitHub Proxy
###############################################################################
echo -e "\n${YELLOW}[0/9] Configuring IPv6 DNS and GitHub Proxy...${NC}"

# Configure IPv6 DNS (using DNS64 or standard IPv6 DNS)
echo -e "${YELLOW}Configuring IPv6-capable DNS servers...${NC}"
# Backup existing resolv.conf
[ -f /etc/resolv.conf ] && cp /etc/resolv.conf /etc/resolv.conf.backup.$(date +%Y%m%d_%H%M%S)

# Use DNS64 and standard IPv6 DNS
cat > /etc/resolv.conf << EOF
# IPv6 DNS servers configured by setup-ipv6.sh
nameserver 2606:4700:4700::64
nameserver 2001:4860:4860::64
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
options timeout:2 attempts:3
EOF

# Setup GitHub Proxy via /etc/hosts
echo -e "${YELLOW}Adding GitHub IPv6 Proxy entries to /etc/hosts...${NC}"
# Remove any existing proxy entries to avoid duplicates
sed -i '/# GitHub IPv6 Proxy/,/# End GitHub IPv6 Proxy/d' /etc/hosts

cat >> /etc/hosts << EOF

# GitHub IPv6 Proxy (danwin1210.de)
2a01:4f8:c010:d56::2 github.com
2a01:4f8:c010:d56::3 api.github.com
2a01:4f8:c010:d56::4 codeload.github.com
2a01:4f8:c010:d56::6 ghcr.io
2a01:4f8:c010:d56::7 pkg.github.com npm.pkg.github.com maven.pkg.github.com nuget.pkg.github.com rubygems.pkg.github.com
2a01:4f8:c010:d56::8 uploads.github.com
2606:50c0:8000::133 objects.githubusercontent.com www.objects.githubusercontent.com release-assets.githubusercontent.com gist.githubusercontent.com repository-images.githubusercontent.com camo.githubusercontent.com private-user-images.githubusercontent.com avatars0.githubusercontent.com avatars1.githubusercontent.com avatars2.githubusercontent.com avatars3.githubusercontent.com cloud.githubusercontent.com desktop.githubusercontent.com support.github.com
2606:50c0:8000::154 support-assets.githubassets.com github.githubassets.com opengraph.githubassets.com github-registry-files.githubusercontent.com github-cloud.githubusercontent.com
# End GitHub IPv6 Proxy
EOF

echo -e "${GREEN}✓ DNS and Proxy configured${NC}"

###############################################################################
# 1. System Update and Basic Packages
###############################################################################
echo -e "\n${YELLOW}[1/9] Updating system and installing basic packages...${NC}"

# Configure to keep local versions and avoid prompts
echo 'libc6 libraries/restart-without-asking boolean true' | debconf-set-selections
echo 'openssh-server openssh-server/permit-root-login boolean true' | debconf-set-selections

# Use -o Dpkg::Options to keep local config files
apt-get update
apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    curl wget git build-essential nginx certbot python3-certbot-nginx apache2-utils \
    ca-certificates gnupg lsb-release

###############################################################################
# 2. Install Docker and Docker Compose
###############################################################################
echo -e "\n${YELLOW}[2/9] Installing Docker and Docker Compose...${NC}"

# Remove any old Docker repository files
rm -f /etc/apt/sources.list.d/docker.list
rm -f /etc/apt/keyrings/docker.gpg

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo -e "${RED}Cannot detect OS${NC}"
    exit 1
fi

# Add Docker's official GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/${OS}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker repository based on OS
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS} \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine and Docker Compose
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Start and enable Docker
systemctl start docker
systemctl enable docker

echo -e "${GREEN}✓ Docker and Docker Compose installed${NC}"

###############################################################################
# 3. Install NVM and Node.js LTS
###############################################################################
echo -e "\n${YELLOW}[3/9] Installing NVM and Node.js LTS...${NC}"

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

# Install NVM for the regular user
export NVM_DIR="$USER_HOME/.nvm"
sudo -u $REGULAR_USER bash -c "
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    export NVM_DIR=\"$USER_HOME/.nvm\"
    [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
    nvm install --lts
    nvm use --lts
    nvm alias default 'lts/*'
"

echo -e "${GREEN}✓ Node.js LTS installed${NC}"

###############################################################################
# 4. Install pnpm
###############################################################################
echo -e "\n${YELLOW}[4/9] Installing pnpm...${NC}"

sudo -u $REGULAR_USER bash -c "
    export NVM_DIR=\"$USER_HOME/.nvm\"
    [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
    npm install -g pnpm
"

echo -e "${GREEN}✓ pnpm installed${NC}"

# Add user to docker group for Docker access
usermod -aG docker $REGULAR_USER

###############################################################################
# 5. Clone Git Repository
###############################################################################
echo -e "\n${YELLOW}[5/9] Git Repository Setup...${NC}"

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
        sudo -u $REGULAR_USER mkdir -p "$USER_HOME/projects"
        
        echo -e "${YELLOW}Cloning repository...${NC}"
        # Run git clone entirely as the regular user
        sudo -u $REGULAR_USER bash -c "git clone '$GIT_URL_WITH_CREDS' '$PROJECT_DIR'"
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Repository cloned to $PROJECT_DIR${NC}"
            
            # Setup git config for the user if provided
            if [ -n "$GIT_USERNAME" ]; then
                sudo -u $REGULAR_USER bash -c "cd '$PROJECT_DIR' && git config user.name '$GIT_USERNAME'"
                echo -e "${YELLOW}Enter your Git email:${NC}"
                read -r GIT_EMAIL
                if [ -n "$GIT_EMAIL" ]; then
                    sudo -u $REGULAR_USER bash -c "cd '$PROJECT_DIR' && git config user.email '$GIT_EMAIL'"
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
echo -e "\n${YELLOW}[6/9] Installing VS Code Server...${NC}"

VSCODE_DIR="$USER_HOME/.vscode-server"
sudo -u $REGULAR_USER mkdir -p "$VSCODE_DIR"

# Download and install code-server (Proxy handles github.com)
curl -fsSL https://code-server.dev/install.sh | sh

# Create VS Code Server config directory
VSCODE_CONFIG_DIR="$USER_HOME/.config/code-server"
sudo -u $REGULAR_USER mkdir -p "$VSCODE_CONFIG_DIR"

# Generate random password for VS Code
VSCODE_PASSWORD=$(openssl rand -base64 24)

    # Create config file - Use 127.0.0.1 for reliable internal loopback
    cat > "$VSCODE_CONFIG_DIR/config.yaml" << EOF
bind-addr: "127.0.0.1:8080"
auth: password
password: $VSCODE_PASSWORD
cert: false
EOF

    chown -R $REGULAR_USER:$REGULAR_USER "$VSCODE_CONFIG_DIR"
# Configure VS Code settings (dark mode + preferences)
VSCODE_USER_DIR="$USER_HOME/.local/share/code-server/User"
sudo -u $REGULAR_USER mkdir -p "$VSCODE_USER_DIR"

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

sudo -u $REGULAR_USER bash -c "
export SERVICE_URL=https://marketplace.visualstudio.com/_apis/public/gallery
export ITEM_URL=https://marketplace.visualstudio.com/items

# Install extensions
for ext in \
    dbaeumer.vscode-eslint \
    esbenp.prettier-vscode \
    mtxr.sqltools \
    yzhang.markdown-all-in-one \
    DavidAnson.vscode-markdownlint \
    redhat.vscode-yaml \
    ms-azuretools.vscode-docker \
    eamodio.gitlens \
    streetsidesoftware.code-spell-checker
do
    echo \"Installing \$ext...\"
    code-server --install-extension \"\$ext\" || echo \"⚠ Failed to install \$ext\"
done
"

echo -e "${GREEN}✓ VS Code Server installed with extensions${NC}"

###############################################################################
# 7. Setup Basic Auth for Nginx
###############################################################################
echo -e "\n${YELLOW}[7/9] Setting up basic authentication...${NC}"

# Generate basic auth credentials
BASIC_AUTH_USER="$VSCODE_USER"
BASIC_AUTH_PASS=$(openssl rand -base64 16)

htpasswd -bc /etc/nginx/.htpasswd "$BASIC_AUTH_USER" "$BASIC_AUTH_PASS"

echo -e "${GREEN}✓ Basic auth configured${NC}"

###############################################################################
# 8. Configure Nginx with HTTPS (IPv6 Only)
###############################################################################
echo -e "\n${YELLOW}[8/9] Configuring Nginx for IPv6...${NC}"

# Create Nginx config
cat > /etc/nginx/sites-available/vscode << 'EOF'
server {
    listen [::]:80;
    server_name _;

    # Redirect to HTTPS
    return 301 https://$host$request_uri;
}

server {
    listen [::]:443 ssl;
    server_name _;

    # SSL certificates (will be configured by certbot or self-signed)
    ssl_certificate /etc/nginx/ssl/cert.pem;
    ssl_certificate_key /etc/nginx/ssl/key.pem;
    
    # SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # Basic Authentication
    auth_basic "Restricted Access";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;
    }
}
EOF

# Create SSL directory
mkdir -p /etc/nginx/ssl

# Generate self-signed certificate for IPv6 address
# Create OpenSSL config for IPv6 SAN
cat > /tmp/ipv6-openssl.cnf << EOF
[req]
default_bits = 2048
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
C = US
ST = State
L = City
O = Organization
CN = $SERVER_IP

[v3_req]
subjectAltName = @alt_names

[alt_names]
IP.1 = $SERVER_IP
EOF

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/key.pem \
    -out /etc/nginx/ssl/cert.pem \
    -config /tmp/ipv6-openssl.cnf

# Clean up temp config
rm -f /tmp/ipv6-openssl.cnf

# Enable the site
ln -sf /etc/nginx/sites-available/vscode /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Test nginx configuration
nginx -t

# Restart nginx
systemctl restart nginx
systemctl enable nginx

echo -e "${GREEN}✓ Nginx configured with HTTPS for IPv6${NC}"

###############################################################################
# 9. Setup VS Code Server Service
###############################################################################
echo -e "\n${YELLOW}[9/9] Setting up VS Code Server service...${NC}"

# Find the actual code-server binary path
CODESERVER_BIN=$(which code-server 2>/dev/null || echo "/usr/bin/code-server")

cat > /etc/systemd/system/code-server.service << EOF
[Unit]
Description=VS Code Server
After=network.target

[Service]
Type=simple
User=$REGULAR_USER
WorkingDirectory=$USER_HOME
Environment="NVM_DIR=$USER_HOME/.nvm"
ExecStart=$CODESERVER_BIN --config $VSCODE_CONFIG_DIR/config.yaml
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the service
systemctl daemon-reload
systemctl enable code-server
systemctl start code-server

echo -e "${GREEN}✓ VS Code Server service configured${NC}"

###############################################################################
# Final Output
###############################################################################
echo -e "\n${GREEN}================================${NC}"
echo -e "${GREEN}Setup Complete!${NC}"
echo -e "${GREEN}================================${NC}"
echo -e "\n${YELLOW}Important Information:${NC}\n"
echo -e "Development User: ${GREEN}$REGULAR_USER${NC}"
echo -e "Node.js & pnpm installed for user: ${GREEN}$REGULAR_USER${NC}"
echo -e "\nVS Code Server Access:"
echo -e "  URL: ${GREEN}https://$SERVER_IP_FORMATTED${NC}"
echo -e "  Basic Auth User: ${GREEN}$BASIC_AUTH_USER${NC}"
echo -e "  Basic Auth Pass: ${GREEN}$BASIC_AUTH_PASS${NC}"
echo -e "  VS Code Password: ${GREEN}$VSCODE_PASSWORD${NC}"
echo -e "\n${YELLOW}Note: Using self-signed SSL certificate for IPv6 address.${NC}"
echo -e "${YELLOW}Your browser will show a security warning - this is expected.${NC}"
echo -e "${YELLOW}Click 'Advanced' and 'Proceed' to access VS Code Server.${NC}"

echo -e "\n${YELLOW}To verify installations:${NC}"
echo -e "  Switch to dev user: ${GREEN}su - $REGULAR_USER${NC}"
echo -e "  Check Node: ${GREEN}node --version${NC}"
echo -e "  Check pnpm: ${GREEN}pnpm --version${NC}"
echo -e "  Check Docker: ${GREEN}docker --version${NC}"
echo -e "  Check Docker Compose: ${GREEN}docker compose version${NC}"
echo -e "\n${YELLOW}Service Status:${NC}"
systemctl status code-server --no-pager

echo -e "\n${GREEN}Save these credentials securely!${NC}\n"