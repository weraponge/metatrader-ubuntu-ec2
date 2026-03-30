#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get upgrade -y --fix-missing || true

# XFCE desktop + RDP + Firefox
apt-get install -y xfce4 xfce4-goodies xrdp dbus-x11 firefox
echo "xfce4-session" > /etc/skel/.xsession
systemctl enable xrdp && systemctl start xrdp

# Wine (retry with fresh index if first attempt fails)
dpkg --add-architecture i386
mkdir -pm755 /etc/apt/keyrings
wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
wget -NP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/ubuntu/dists/noble/winehq-noble.sources
apt-get update
apt-get install -y --install-recommends winehq-stable \
  || { apt-get update && apt-get install -y --fix-missing --install-recommends winehq-stable; }

# Trader user
useradd -m -s /bin/bash trader
echo "trader:${TRADER_PASSWORD:?Set TRADER_PASSWORD env var}" | chpasswd
echo "xfce4-session" > /home/trader/.xsession
chown trader:trader /home/trader/.xsession
adduser trader ssl-cert

# MetaTrader 4 — silent install as trader
su - trader -c '
  wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt4/mt4oldsetup.exe -O ~/mt4setup.exe
  WINEPREFIX=/home/trader/.wine WINEDLLOVERRIDES="mscoree,mshtml=" wine ~/mt4setup.exe /auto 2>/dev/null || true
  rm -f ~/mt4setup.exe

  # Auto-start MetaTrader on login
  mkdir -p ~/.config/autostart
  cat > ~/.config/autostart/metatrader.desktop << EOF
[Desktop Entry]
Type=Application
Name=MetaTrader
Exec=wine "/home/trader/.wine/drive_c/Program Files (x86)/MetaTrader 4/terminal.exe"
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF
'
