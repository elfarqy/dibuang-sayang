#!/bin/bash

###############################################################################
# Development Stack Setup Script
# Installs: Git, Node.js (via NVM), pnpm, Docker, Docker Compose, Neovim, Cloudflared
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
SERVER_IP=$(hostname -I | awk '{print $1}')

echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}Development Stack Setup${NC}"
echo -e "${GREEN}================================${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root${NC}"
    exit 1
fi

###############################################################################
# 1. System Update and Basic Packages
###############################################################################
echo -e "\n${YELLOW}[1/6] Updating system and installing basic packages...${NC}"

# Configure to keep local versions and avoid prompts
echo 'libc6 libraries/restart-without-asking boolean true' | debconf-set-selections
echo 'openssh-server openssh-server/permit-root-login boolean true' | debconf-set-selections

# Use -o Dpkg::Options to keep local config files
apt-get update
apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    curl wget git build-essential ca-certificates gnupg lsb-release

###############################################################################
# 2. Install Docker and Docker Compose
###############################################################################
echo -e "\n${YELLOW}[2/6] Installing Docker and Docker Compose...${NC}"

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
echo -e "\n${YELLOW}[3/6] Installing NVM and Node.js LTS...${NC}"

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
echo -e "\n${YELLOW}[4/6] Installing pnpm...${NC}"

sudo -u $REGULAR_USER bash -c "
    export NVM_DIR=\"$USER_HOME/.nvm\"
    [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
    npm install -g pnpm
"

echo -e "${GREEN}✓ pnpm installed${NC}"

# Add user to docker group for Docker access
usermod -aG docker $REGULAR_USER

###############################################################################
# 5. Install Neovim
###############################################################################
echo -e "\n${YELLOW}[5/6] Installing Neovim...${NC}"

# Install Neovim from default OS package manager
apt-get update
apt-get install -y neovim

# Set nvim as default editor for the user
sudo -u $REGULAR_USER bash -c "
    mkdir -p $USER_HOME/.config/nvim
    echo 'set number' > $USER_HOME/.config/nvim/init.vim
    echo 'set relativenumber' >> $USER_HOME/.config/nvim/init.vim
    echo 'set expandtab' >> $USER_HOME/.config/nvim/init.vim
    echo 'set tabstop=2' >> $USER_HOME/.config/nvim/init.vim
    echo 'set shiftwidth=2' >> $USER_HOME/.config/nvim/init.vim
    echo 'set autoindent' >> $USER_HOME/.config/nvim/init.vim
    echo 'syntax on' >> $USER_HOME/.config/nvim/init.vim
"

echo -e "${GREEN}✓ Neovim installed${NC}"

###############################################################################
# 6. Install Cloudflared
###############################################################################
echo -e "\n${YELLOW}[6/6] Installing Cloudflared...${NC}"

# Add Cloudflare GPG key
mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null

# Add Cloudflare repository
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | tee /etc/apt/sources.list.d/cloudflared.list

# Install cloudflared
apt-get update
apt-get install -y cloudflared

echo -e "${GREEN}✓ Cloudflared installed${NC}"

###############################################################################
# 7. Git Repository Setup (Optional)
###############################################################################
echo -e "\n${YELLOW}[7/7] Git Repository Setup...${NC}"

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
# Final Output
###############################################################################
echo -e "\n${GREEN}================================${NC}"
echo -e "${GREEN}Setup Complete!${NC}"
echo -e "${GREEN}================================${NC}"
echo -e "\n${YELLOW}Important Information:${NC}\n"
echo -e "Development User: ${GREEN}$REGULAR_USER${NC}"
echo -e "User Home: ${GREEN}$USER_HOME${NC}"
echo -e "Server IP: ${GREEN}$SERVER_IP${NC}"

echo -e "\n${YELLOW}Installed Software:${NC}"
echo -e "  ✓ Git"
echo -e "  ✓ Node.js (via NVM) + pnpm"
echo -e "  ✓ Docker + Docker Compose"
echo -e "  ✓ Neovim"
echo -e "  ✓ Cloudflared"

echo -e "\n${YELLOW}To verify installations (switch to dev user first):${NC}"
echo -e "  Switch to dev user: ${GREEN}su - $REGULAR_USER${NC}"
echo -e "  Check Node: ${GREEN}node --version${NC}"
echo -e "  Check pnpm: ${GREEN}pnpm --version${NC}"
echo -e "  Check Docker: ${GREEN}docker --version${NC}"
echo -e "  Check Docker Compose: ${GREEN}docker compose version${NC}"
echo -e "  Check Neovim: ${GREEN}nvim --version${NC}"
echo -e "  Check Cloudflared: ${GREEN}cloudflared --version${NC}"

echo -e "\n${YELLOW}Cloudflared Tunnel Setup:${NC}"
echo -e "  Login to Cloudflare: ${GREEN}cloudflared tunnel login${NC}"
echo -e "  Create tunnel: ${GREEN}cloudflared tunnel create <tunnel-name>${NC}"
echo -e "  Route tunnel: ${GREEN}cloudflared tunnel route dns <tunnel-name> <hostname>${NC}"
echo -e "  Run tunnel: ${GREEN}cloudflared tunnel run <tunnel-name>${NC}"

echo -e "\n${GREEN}Setup completed successfully!${NC}\n"
