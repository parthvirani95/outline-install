#!/bin/bash
set -x
exec > >(tee /var/log/outline-config.log) 2>&1

NODE_ENV=${environment} 

# Enable automatic yes to all prompts
export DEBIAN_FRONTEND=noninteractive

# Function to install Docker without confirmation
install_docker() {
    echo "Verifying that Docker is installed..."
    if ! command -v docker &> /dev/null; then
        echo "Docker NOT INSTALLED - Installing automatically..."
        curl -fsSL https://get.docker.com | sh > /dev/null 2>&1
        sudo usermod -aG docker $USER
        echo "Docker installed successfully"
    else
        echo "Docker already installed"
    fi
}

sudo apt update -y

# Main script execution
echo "=== Starting Automated Outline VPN Configuration ==="

# Install required dependencies without confirmation
install_docker

# Install Outline server
echo "Installing Outline Server..."

sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Jigsaw-Code/outline-server/master/src/server_manager/install_scripts/install_server.sh)" -y --api-port=62144 --keys-port=2342

echo "Waiting for Outline Server to start..."
sleep 5
 
echo "🔒 Securing VPN server with iptables rules..."

# Backup current rules (in case of failure)
iptables-save > /tmp/iptables.backup

# Allow current SSH session explicitly (critical!)
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A OUTPUT -p tcp --sport 22 -j ACCEPT
iptables -A OUTPUT -p tcp --sport 2342 -j ACCEPT
iptables -A OUTPUT -p tcp --sport 62144 -j ACCEPT

# Allow loopback interface (localhost)
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Flush rules (now SSH is temporarily allowed)
iptables -F
iptables -X

# Default policies
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT DROP  # We whitelist what we want

iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# 1. Allow essential outbound ports
iptables -A OUTPUT -p tcp -m multiport --dports 80,443 -j ACCEPT     # HTTP/HTTPS
iptables -A OUTPUT -p tcp -m multiport --dports 587,993,995,5222,5228:5230 -j ACCEPT  # Email & Google push
iptables -A OUTPUT -p udp --dport 123 -m limit --limit 10/sec --limit-burst 30 -j ACCEPT  # NTP
iptables -A OUTPUT -p udp --dport 3478 -m limit --limit 10/sec --limit-burst 30 -j ACCEPT  # STUN

# 2. Rate limit DNS (UDP 53) to prevent abuse
iptables -A OUTPUT -p udp --dport 53 -m hashlimit \
  --hashlimit 20/sec --hashlimit-burst 50 \
  --hashlimit-mode srcip --hashlimit-name dns-limit -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j DROP

# 3. Block dangerous UDP ports (DDoS/Scan vectors)
for port in 19 67:68 111 137:139 161:162 1900 5353 11211 69; do
    iptables -A OUTPUT -p udp --dport $port -j DROP
done

# 4. Block dangerous TCP ports (Spam/Exploits)
for port in 25 135 139 445 1433 3306 23 21; do
    iptables -A OUTPUT -p tcp --dport $port -j REJECT --reject-with tcp-reset
done

# 5. Allow VPN protocols (if you use TCP-based Shadowsocks/Outline)
iptables -A OUTPUT -p tcp --sport 1024:65535 -j ACCEPT
iptables -A OUTPUT -p udp --sport 1024:65535 -j ACCEPT

# 6. ICMP (optional ping/healthcheck)
iptables -A OUTPUT -p icmp -j ACCEPT

echo "✅ Rules applied. Saving them..."

# Save rules to persist after reboot (Ubuntu/Debian)
apt-get install -y iptables-persistent
netfilter-persistent save

echo "🔐 VPN server secured against common abuse ports."

echo "Outline Server setup complete!"