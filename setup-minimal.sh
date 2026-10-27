#!/bin/bash

###############################################################################
# Minimal Dev Setup Script
# Installs: Git, Neovim, Lazygit, Docker, Docker Compose, Zsh, Oh My Zsh, btop
# Creates a user and stores credentials in /home/<user>/.user.credential
# Run as: sudo bash setup-minimal.sh [username]
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
NEW_USER="${1:-deploy}"
USER_HOME="/home/$NEW_USER"

echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}Minimal Dev Setup${NC}"
echo -e "${GREEN}================================${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root${NC}"
    exit 1
fi

# Validate username (avoid paths/space surprises since home is hardcoded /home/$USER)
if ! [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo -e "${RED}Invalid username: $NEW_USER${NC}"
    echo -e "Use lowercase letters, digits, '-' or '_' (must not start with a digit)."
    exit 1
fi

###############################################################################
# 1. System Update and Basic Packages
###############################################################################
echo -e "\n${YELLOW}[1/5] Updating system and installing basic packages...${NC}"

# Configure to keep local versions and avoid prompts
echo 'libc6 libraries/restart-without-asking boolean true' | debconf-set-selections
echo 'openssh-server openssh-server/permit-root-login boolean true' | debconf-set-selections

# Use -o Dpkg::Options to keep local config files
apt-get update
apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    curl wget git ca-certificates gnupg lsb-release openssl zsh btop neovim

echo -e "${GREEN}✓ Git, Neovim, Zsh, btop installed${NC}"

###############################################################################
# 2. Install Docker and Docker Compose
###############################################################################
echo -e "\n${YELLOW}[2/5] Installing Docker and Docker Compose...${NC}"

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
# 3. Install Lazygit
###############################################################################
echo -e "\n${YELLOW}[3/5] Installing Lazygit...${NC}"

# Map apt architecture to lazygit release architecture
RAW_ARCH=$(dpkg --print-architecture)
case "$RAW_ARCH" in
    amd64) LG_ARCH="x86_64" ;;
    arm64) LG_ARCH="aarch64" ;;
    *)
        echo -e "${RED}Unsupported architecture: $RAW_ARCH${NC}"
        exit 1
        ;;
esac

# Get the latest lazygit version tag from GitHub
LAZYGIT_VERSION=$(curl -fsSL "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" \
    | grep -Po '"tag_name": *"v\K[^"]*')

if [ -z "$LAZYGIT_VERSION" ]; then
    echo -e "${RED}Failed to fetch lazygit version from GitHub API${NC}"
    exit 1
fi

# Download, extract and install the binary
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
curl -fsSL -o "$TMP_DIR/lazygit.tar.gz" \
    "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_${LG_ARCH}.tar.gz"
tar -xf "$TMP_DIR/lazygit.tar.gz" -C "$TMP_DIR" lazygit
install -m 0755 "$TMP_DIR/lazygit" /usr/local/bin/lazygit

echo -e "${GREEN}✓ Lazygit v$LAZYGIT_VERSION installed${NC}"

###############################################################################
# 4. Create User and Store Credentials
###############################################################################
echo -e "\n${YELLOW}[4/5] Creating user and storing credentials...${NC}"

if id "$NEW_USER" &>/dev/null; then
    echo -e "${YELLOW}User '$NEW_USER' already exists — resetting its password...${NC}"
else
    useradd -m -s /usr/bin/zsh "$NEW_USER"
fi

# Make sure home directory exists (in case the existing user had none)
if [ ! -d "$USER_HOME" ]; then
    mkdir -p "$USER_HOME"
    chown "$NEW_USER:$NEW_USER" "$USER_HOME"
fi

# Generate a random 20-char alphanumeric password and set it
PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
echo "$NEW_USER:$PASSWORD" | chpasswd

# Use zsh as default shell and allow docker access
usermod -s "$(command -v zsh)" "$NEW_USER"
usermod -aG docker "$NEW_USER"

# Write credentials file (plain text!) readable only by the user
CRED_FILE="$USER_HOME/.user.credential"
cat > "$CRED_FILE" <<EOF
# Server user credentials — created by setup-minimal.sh on $(date '+%Y-%m-%d %H:%M:%S')
# WARNING: this file is plain text. Copy the password to your password manager
# and DELETE this file afterwards!

username: $NEW_USER
password: $PASSWORD
home:     $USER_HOME
shell:    $(command -v zsh)
server:   $SERVER_IP
EOF
chown "$NEW_USER:$NEW_USER" "$CRED_FILE"
chmod 600 "$CRED_FILE"

echo -e "${GREEN}✓ User '$NEW_USER' created (credentials in $CRED_FILE)${NC}"

###############################################################################
# 5. Install Oh My Zsh
###############################################################################
echo -e "\n${YELLOW}[5/5] Installing Oh My Zsh...${NC}"

sudo -u "$NEW_USER" bash -c "
    if [ ! -d '$USER_HOME/.oh-my-zsh' ]; then
        git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git '$USER_HOME/.oh-my-zsh'
    fi
    if [ ! -f '$USER_HOME/.zshrc' ]; then
        cp '$USER_HOME/.oh-my-zsh/templates/zshrc.zsh-template' '$USER_HOME/.zshrc'
    fi
"

# Ensure ownership in case anything ran as root
chown -R "$NEW_USER:$NEW_USER" "$USER_HOME/.oh-my-zsh" "$USER_HOME/.zshrc"

echo -e "${GREEN}✓ Oh My Zsh installed${NC}"

###############################################################################
# Final Output
###############################################################################
echo -e "\n${GREEN}================================${NC}"
echo -e "${GREEN}Setup Complete!${NC}"
echo -e "${GREEN}================================${NC}"
echo -e "\n${YELLOW}Important Information:${NC}\n"
echo -e "User: ${GREEN}$NEW_USER${NC}"
echo -e "User Home: ${GREEN}$USER_HOME${NC}"
echo -e "Server IP: ${GREEN}$SERVER_IP${NC}"
echo -e "Credentials: ${GREEN}$CRED_FILE${NC}"
echo -e "View password (as root): ${GREEN}cat $CRED_FILE${NC}"

echo -e "\n${YELLOW}Installed Software:${NC}"
echo -e "  ✓ Git"
echo -e "  ✓ Neovim"
echo -e "  ✓ Lazygit"
echo -e "  ✓ Docker + Docker Compose"
echo -e "  ✓ Zsh + Oh My Zsh"
echo -e "  ✓ btop"

echo -e "\n${YELLOW}To verify installations (switch to user first):${NC}"
echo -e "  Switch to user: ${GREEN}su - $NEW_USER${NC}"
echo -e "  Check Git: ${GREEN}git --version${NC}"
echo -e "  Check Neovim: ${GREEN}nvim --version${NC}"
echo -e "  Check Lazygit: ${GREEN}lazygit --version${NC}"
echo -e "  Check Docker: ${GREEN}docker --version${NC}"
echo -e "  Check Docker Compose: ${GREEN}docker compose version${NC}"
echo -e "  Check btop: ${GREEN}btop --version${NC}"

echo -e "\n${RED}Security note:${NC}"
echo -e "  $CRED_FILE contains the password in plain text."
echo -e "  Copy it somewhere safe, then delete it: ${GREEN}rm $CRED_FILE${NC}"

echo -e "\n${GREEN}Setup completed successfully!${NC}\n"
