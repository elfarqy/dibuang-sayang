#!/bin/bash

###############################################################################
# Minimal Dev Setup Script
# Installs: Git, Neovim (official build), Lazygit, Docker + Docker Compose,
#           Zsh + Oh My Zsh, btop
# Hardens SSH against brute force (sshd limits + fail2ban) and enables
# Docker log rotation.
# Creates a user and stores credentials in /home/<user>/.user.credential
# Run as: sudo bash setup-minimal.sh [username]
# Optional: IGNORE_IPS="1.2.3.4 10.0.0.0/8" sudo -E bash setup-minimal.sh
#           (IPs/CIDRs fail2ban must never ban, e.g. office/VPN)
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
IGNORE_IPS="${IGNORE_IPS:-}"

# Detect CPU architecture for binary downloads (Neovim, lazygit, btop)
CPU_ARCH=$(dpkg --print-architecture)
case "$CPU_ARCH" in
    amd64)
        NVIM_ASSET="nvim-linux-x86_64.tar.gz"
        LAZYGIT_ARCH="x86_64"
        BTOP_ASSET="btop-x86_64-unknown-linux-musl.tar.gz"
        ;;
    arm64)
        NVIM_ASSET="nvim-linux-arm64.tar.gz"
        LAZYGIT_ARCH="arm64"
        BTOP_ASSET="btop-aarch64-unknown-linux-musl.tar.gz"
        ;;
    *)
        echo -e "${RED}Unsupported CPU architecture for binary downloads: $CPU_ARCH${NC}"
        exit 1
        ;;
esac

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
echo -e "\n${YELLOW}[1/7] Updating system and installing basic packages...${NC}"

# Configure to keep local versions and avoid prompts
echo 'libc6 libraries/restart-without-asking boolean true' | debconf-set-selections
echo 'openssh-server openssh-server/permit-root-login boolean true' | debconf-set-selections

# Use -o Dpkg::Options to keep local config files
apt-get update
apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    curl wget git ca-certificates gnupg lsb-release zsh

echo -e "${GREEN}✓ Git and Zsh installed${NC}"

###############################################################################
# 2. Install Docker and Docker Compose
###############################################################################
echo -e "\n${YELLOW}[2/7] Installing Docker and Docker Compose...${NC}"

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

# Log rotation: the default json-file driver grows container logs without limit
# and eventually fills the disk. Cap each container at 3 x 10MB.
# Only applies to containers created after this; existing ones must be recreated.
if [ -f /etc/docker/daemon.json ]; then
    cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)"
fi
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

# Restart (not start): the package already started Docker with the old config
systemctl enable docker
systemctl restart docker

echo -e "${GREEN}✓ Docker and Docker Compose installed (log rotation: 3 x 10MB per container)${NC}"

###############################################################################
# 3. Create User and Store Credentials
# Created before the per-user config steps below (nvim init.vim, Oh My Zsh)
###############################################################################
echo -e "\n${YELLOW}[3/7] Creating user and storing credentials...${NC}"

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
chsh -s "$(command -v zsh)" "$NEW_USER" 2>/dev/null || \
    usermod -s "$(command -v zsh)" "$NEW_USER"
usermod -aG docker "$NEW_USER"

# Write credentials file (plain text!) readable only by the user
CRED_FILE="$USER_HOME/.user.credential"
cat > "$CRED_FILE" <<EOF
# Server user credentials — created by setup-minimal.sh on $(date '+%Y-%m-%d %H:%M:%S')
# WARNING: this file is plain text. Copy the password to your password manager
# and DELETE the "password:" line afterwards (keep the security notes below).

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
# 4. Install Neovim (official build)
###############################################################################
echo -e "\n${YELLOW}[4/7] Installing Neovim (official release)...${NC}"

# Debian/Ubuntu ships an outdated Neovim. Install the latest official build
# straight from the Neovim GitHub releases instead.
curl -fsSL -o /tmp/nvim.tar.gz "https://github.com/neovim/neovim/releases/latest/download/${NVIM_ASSET}"
rm -rf /opt/nvim
mkdir -p /opt/nvim
# --strip-components=1 so contents land directly under /opt/nvim regardless of
# the top-level directory name used inside the release tarball.
tar -xzf /tmp/nvim.tar.gz -C /opt/nvim --strip-components=1
rm -f /tmp/nvim.tar.gz
ln -sf /opt/nvim/bin/nvim /usr/local/bin/nvim

# Set nvim as default editor for the user
sudo -u "$NEW_USER" bash -c "
    mkdir -p $USER_HOME/.config/nvim
    echo 'set number' > $USER_HOME/.config/nvim/init.vim
    echo 'set relativenumber' >> $USER_HOME/.config/nvim/init.vim
    echo 'set expandtab' >> $USER_HOME/.config/nvim/init.vim
    echo 'set tabstop=2' >> $USER_HOME/.config/nvim/init.vim
    echo 'set shiftwidth=2' >> $USER_HOME/.config/nvim/init.vim
    echo 'set autoindent' >> $USER_HOME/.config/nvim/init.vim
    echo 'syntax on' >> $USER_HOME/.config/nvim/init.vim
"

echo -e "${GREEN}✓ Neovim installed ($(nvim --version | head -n1))${NC}"

###############################################################################
# 5. Install Lazygit and btop
###############################################################################
echo -e "\n${YELLOW}[5/7] Installing Lazygit and btop...${NC}"

# --- Lazygit (latest release from GitHub) ---
# The version is embedded in the asset filename, so fetch it from the API first.
LAZYGIT_VERSION=$(curl -fsSL "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep '"tag_name"' | cut -d'"' -f4 | sed 's/^v//')
curl -fsSL -o /tmp/lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_${LAZYGIT_ARCH}.tar.gz"
tar -xzf /tmp/lazygit.tar.gz -C /tmp lazygit
install -m 0755 /tmp/lazygit /usr/local/bin/lazygit
rm -f /tmp/lazygit.tar.gz /tmp/lazygit
echo -e "${GREEN}✓ Lazygit installed (v${LAZYGIT_VERSION})${NC}"

# --- btop (latest prebuilt musl static binary from GitHub) ---
# Since v1.4.7 the asset is a .tar.gz (was .tbz) named <triple>-unknown-linux-musl.tar.gz.
curl -fsSL -o /tmp/btop.tar.gz "https://github.com/aristocratos/btop/releases/latest/download/${BTOP_ASSET}"
mkdir -p /tmp/btop-extract
tar -xzf /tmp/btop.tar.gz -C /tmp/btop-extract
# The archive holds a single top-level dir (e.g. btop/) containing bin/ and themes/;
# match it with a glob so we don't depend on the dir name or tar --strip-components quirks.
install -D -m 0755 /tmp/btop-extract/*/bin/btop /usr/local/bin/btop
mkdir -p /usr/local/share/btop
cp -r /tmp/btop-extract/*/themes /usr/local/share/btop/
rm -rf /tmp/btop-extract /tmp/btop.tar.gz
echo -e "${GREEN}✓ btop installed${NC}"

###############################################################################
# 6. Install Oh My Zsh and set zsh as default shell
###############################################################################
echo -e "\n${YELLOW}[6/7] Installing Oh My Zsh...${NC}"

# Install Oh My Zsh for the user non-interactively.
# CHSH=no / RUNZSH=no skip the "change shell" prompt and the post-install zsh launch.
# Run from the user's home: the installer does `cd -` back to its start dir, and
# `sudo -u` keeps the current directory -- if this script runs from /root the
# regular user can't cd back there, aborting the install before .zshrc is written.
# ZSH= pins the install target even if ZSH is set in root's environment.
sudo -u "$NEW_USER" -H env HOME="$USER_HOME" ZSH="$USER_HOME/.oh-my-zsh" RUNZSH=no CHSH=no \
    bash -c 'cd "$HOME" && sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"'

# Make zsh the user's default login shell
chsh -s "$(command -v zsh)" "$NEW_USER" 2>/dev/null || \
    usermod -s "$(command -v zsh)" "$NEW_USER"

echo -e "${GREEN}✓ Oh My Zsh installed and zsh set as default shell${NC}"

###############################################################################
# 7. SSH Brute-Force Protection (sshd limits + fail2ban)
# Password login (incl. root) stays enabled since the root password is shared.
# Bans are per IP, never per account: locking the shared root account would let
# anyone lock the whole team out.
###############################################################################
echo -e "\n${YELLOW}[7/7] Hardening SSH against brute force...${NC}"

apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    openssh-server fail2ban python3-systemd

# --- sshd limits ---
# sshd uses the first value it reads for each option, so the 10- prefix wins over
# cloud images' 50-cloud-init.conf (which often sets PasswordAuthentication no).
# Note: sshd_config does not allow trailing comments on option lines.
SSHD_DROPIN=/etc/ssh/sshd_config.d/10-hardening.conf
if ! grep -qiE '^\s*Include\s+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
    echo -e "${RED}/etc/ssh/sshd_config does not include sshd_config.d/ — skipping sshd limits${NC}"
else
    cat > "$SSHD_DROPIN" <<'EOF'
# Created by setup-minimal.sh
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords no
# Drop the connection after 3 wrong passwords
MaxAuthTries 3
# 30s to authenticate, then disconnect
LoginGraceTime 30
# Throttle floods of unauthenticated connections
MaxStartups 10:30:60
EOF
    # Validate before restarting so a bad config can't take SSH down
    mkdir -p /run/sshd
    if sshd -t; then
        systemctl restart ssh 2>/dev/null || systemctl restart sshd
        echo -e "${GREEN}✓ sshd limits applied ($SSHD_DROPIN)${NC}"
    else
        rm -f "$SSHD_DROPIN"
        echo -e "${RED}sshd config test failed — removed $SSHD_DROPIN, SSH left unchanged${NC}"
    fi
fi

# --- fail2ban ---
# 5 failures within 10 min -> ban. Repeat offenders get doubled bans
# (1h, 2h, 4h ... capped at 1 week). Ban history is kept for 1 week
# (dbpurgeage) so the escalation doesn't reset after the default 1 day.
# backend=systemd: Debian 12+/Ubuntu 24.04 log sshd to journald, not auth.log.
# Bans are written straight to iptables/nftables, no ufw needed.
cat > /etc/fail2ban/jail.local <<EOF
# Created by setup-minimal.sh
[DEFAULT]
backend = systemd
bantime = 1h
bantime.increment = true
bantime.maxtime = 1w
findtime = 10m
maxretry = 5
dbpurgeage = 1w
ignoreip = 127.0.0.1/8 ::1 $IGNORE_IPS

[sshd]
enabled = true
mode = aggressive
EOF

systemctl enable fail2ban
systemctl restart fail2ban

echo -e "${GREEN}✓ fail2ban enabled (5 fails / 10 min -> ban 1h, doubling up to 1 week)${NC}"

# --- Document everything in the credentials file ---
cat >> "$CRED_FILE" <<EOF

###############################################################################
# Server security notes
###############################################################################

## SSH login
Password login is ENABLED (root and users) because the root password is shared.
Limits ($SSHD_DROPIN):
  - MaxAuthTries 3      -> connection dropped after 3 wrong passwords
  - LoginGraceTime 30   -> 30 seconds to log in, then disconnected
  - MaxStartups 10:30:60 -> floods of unauthenticated connections are throttled
Check config:   sshd -t
Apply changes:  systemctl restart ssh

## fail2ban (bans by IP, never locks the account)
Config: /etc/fail2ban/jail.local
Rule: 5 failed attempts within 10 minutes -> IP is banned.
Ban length doubles for repeat offenders, capped at 1 week:
  1st 1h | 2nd 2h | 3rd 4h | 4th 8h | 5th 16h | 6th ~1.3d | 7th ~2.7d | 8th ~5.3d | 9th+ 1w
Ban history is kept 1 week (dbpurgeage), and bans survive restarts.
Never banned (ignoreip): 127.0.0.1/8 ::1 ${IGNORE_IPS:-(none set)}

If a teammate mistypes the password 5 times, they are locked out for 1 hour.
  Show banned IPs:    fail2ban-client status sshd
  Unban an IP:        fail2ban-client set sshd unbanip <IP>
  Whitelist an IP:    add it to "ignoreip" in /etc/fail2ban/jail.local,
                      then: systemctl restart fail2ban
  Ban log:            journalctl -u fail2ban

## Docker log rotation
Config: /etc/docker/daemon.json (json-file, max 3 files x 10MB per container)
Only applies to containers created after setup; recreate older ones:
  docker compose up -d --force-recreate
Check a container:  docker inspect -f '{{.HostConfig.LogConfig}}' <container>

## Not configured (intentionally)
  - Firewall (ufw): ports depend on what the server will run
  - unattended-upgrades: avoid surprise version changes / breaking updates
EOF

echo -e "${GREEN}✓ Security notes written to $CRED_FILE${NC}"

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
echo -e "  ✓ Neovim (official build)"
echo -e "  ✓ Lazygit"
echo -e "  ✓ Docker + Docker Compose"
echo -e "  ✓ Zsh + Oh My Zsh"
echo -e "  ✓ btop"

echo -e "\n${YELLOW}Security:${NC}"
echo -e "  ✓ sshd limits (MaxAuthTries 3, LoginGraceTime 30, MaxStartups 10:30:60)"
echo -e "  ✓ fail2ban (5 fails / 10 min -> ban 1h, doubling up to 1 week)"
echo -e "  ✓ Docker log rotation (3 x 10MB per container)"
echo -e "  Ignored by fail2ban: ${GREEN}127.0.0.1/8 ::1 ${IGNORE_IPS}${NC}"
echo -e "  Details and unban commands: ${GREEN}$CRED_FILE${NC}"
echo -e "  ${RED}Before closing this session, test SSH login from a second terminal.${NC}"

echo -e "\n${YELLOW}To verify installations (switch to user first):${NC}"
echo -e "  Switch to user: ${GREEN}su - $NEW_USER${NC}"
echo -e "  Check Git: ${GREEN}git --version${NC}"
echo -e "  Check Neovim: ${GREEN}nvim --version${NC}"
echo -e "  Check Lazygit: ${GREEN}lazygit --version${NC}"
echo -e "  Check Docker: ${GREEN}docker --version${NC}"
echo -e "  Check Docker Compose: ${GREEN}docker compose version${NC}"
echo -e "  Check btop: ${GREEN}btop --version${NC}"
echo -e "  Check zsh: ${GREEN}zsh --version${NC}"

echo -e "\n${RED}Security note:${NC}"
echo -e "  $CRED_FILE contains the password in plain text."
echo -e "  Copy it somewhere safe, then remove that line: ${GREEN}sed -i '/^password:/d' $CRED_FILE${NC}"

echo -e "\n${GREEN}Setup completed successfully!${NC}\n"
