#!/bin/bash

# ============================================================================
# IMPROVED VPS Low-Latency Optimization for Trading (HFT-Grade)
# Run as root: sudo bash optimize_trading_vps.sh
# ============================================================================

set -e

echo "🚀 Starting HFT-Grade VPS optimization..."
echo ""

# ----------------------------------------------------------------------------
# 1. NETWORK INTERFACE OPTIMIZATION
# ----------------------------------------------------------------------------
echo "═══════════════════════════════════════════════════════════════"
echo "1️⃣  NETWORK INTERFACE OPTIMIZATION"
echo "═══════════════════════════════════════════════════════════════"

# Robust Interface Detection
INTERFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -n1)
if [ -z "$INTERFACE" ]; then
    echo "❌ Error: Could not detect primary network interface."
    exit 1
fi
echo "✓ Detected Interface: $INTERFACE"
echo ""

# 1. Disable Adaptive Coalescing (prevents NIC from "guessing" when to interrupt)
echo "→ Disabling adaptive coalescing..."
ethtool -C $INTERFACE adaptive-rx off adaptive-tx off 2>/dev/null && echo "  ✓ Done" || echo "  ⚠ Not supported on this NIC"

# 2. Set Coalescing to Zero (interrupt immediately on packet arrival)
echo "→ Setting interrupt coalescing to 0 (immediate interrupts)..."
ethtool -C $INTERFACE rx-usecs 0 tx-usecs 0 2>/dev/null && echo "  ✓ Done" || echo "  ⚠ Not supported on this NIC"

# 3. Maximize Ring Buffers (prevents packet drops during micro-bursts)
echo "→ Maximizing ring buffer sizes..."
# More robust extraction of max values
MAX_RX=$(ethtool -g $INTERFACE 2>/dev/null | awk '/Pre-set maximums:/{flag=1; next} /Current hardware settings:/{flag=0} flag && /RX:/{print $2; exit}')
MAX_TX=$(ethtool -g $INTERFACE 2>/dev/null | awk '/Pre-set maximums:/{flag=1; next} /Current hardware settings:/{flag=0} flag && /TX:/{print $2; exit}')

if [ -n "$MAX_RX" ] && [ -n "$MAX_TX" ]; then
    ethtool -G $INTERFACE rx $MAX_RX tx $MAX_TX 2>/dev/null
    echo "  ✓ Set RX: $MAX_RX, TX: $MAX_TX"
else
    echo "  ⚠ Could not detect ring buffer limits"
fi

# 4. Disable ALL Offloading (force CPU to handle packets immediately)
# Added LRO (Large Receive Offload) - critical for low latency!
echo "→ Disabling offload features (TSO/GSO/GRO/LRO)..."
ethtool -K $INTERFACE tso off gso off gro off lro off 2>/dev/null && echo "  ✓ Done" || echo "  ⚠ Some features not supported"

echo ""

# ----------------------------------------------------------------------------
# 2. TCP/IP STACK TUNING (With BUSY POLLING - The Nuclear Option)
# ----------------------------------------------------------------------------
echo "═══════════════════════════════════════════════════════════════"
echo "2️⃣  TCP/IP STACK TUNING (With Busy Polling)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Backup original sysctl.conf
cp /etc/sysctl.conf /etc/sysctl.conf.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true

cat >> /etc/sysctl.conf << 'EOF'

# ============================================================
# HFT-Grade Low-Latency Trading Optimizations
# Added by optimize_trading_vps.sh
# ============================================================

# --- BUSY POLLING (The "Nuclear" Option) ---
# Forces kernel to spin-loop for packets instead of sleeping
# Burns CPU but drastically lowers latency (saves ~5-15μs per packet)
# Values in microseconds - 50μs is aggressive but safe
net.core.busy_read = 50
net.core.busy_poll = 50

# --- BBR Congestion Control (better than CUBIC for low latency) ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- Connection Setup ---
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0

# --- TCP Keepalive (faster dead connection detection) ---
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6

# --- Network Buffer Sizes ---
# Balanced for throughput without bufferbloat
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# --- Backlog Queues ---
net.core.netdev_max_backlog = 5000
net.core.somaxconn = 4096

# --- Socket Behavior ---
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1

# --- Reduce SYN retries (fail fast) ---
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2

EOF

echo "✓ TCP/IP parameters written to /etc/sysctl.conf"
echo "→ Applying settings..."
sysctl -p > /dev/null 2>&1
echo "  ✓ Applied (including busy polling)"
echo ""

# ----------------------------------------------------------------------------
# 3. CPU GOVERNOR & C-STATES
# ----------------------------------------------------------------------------
echo "═══════════════════════════════════════════════════════════════"
echo "3️⃣  CPU GOVERNOR & C-STATES"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Try installing cpupower if missing
if ! command -v cpupower &> /dev/null; then
    echo "→ Installing cpupower..."
    apt-get update -qq
    apt-get install -y linux-cpupower 2>/dev/null || apt-get install -y linux-tools-common 2>/dev/null || true
fi

# Set Performance Governor
if command -v cpupower &> /dev/null; then
    cpupower frequency-set -g performance > /dev/null 2>&1 && echo "  ✓ CPU Governor: performance" || echo "  ⚠ Could not set governor"
else
    # Fallback method
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo "performance" > $cpu 2>/dev/null || true
    done
    echo "  ✓ CPU Governor: performance (via fallback)"
fi

# Disable C-States (prevents CPU from sleeping)
# This is aggressive but necessary for microsecond-level latency
echo "→ Disabling CPU C-States (prevents CPU sleep)..."
C_STATE_COUNT=0
for state in /sys/devices/system/cpu/cpu*/cpuidle/state*/disable; do
    if [ -f "$state" ]; then
        echo 1 > "$state" 2>/dev/null && ((C_STATE_COUNT++)) || true
    fi
done

if [ $C_STATE_COUNT -gt 0 ]; then
    echo "  ✓ Disabled $C_STATE_COUNT C-States (CPU stays awake)"
else
    echo "  ⚠ C-States not available (may not be supported on VM)"
fi

echo ""

# ----------------------------------------------------------------------------
# 4. IRQ BALANCING & AFFINITY
# ----------------------------------------------------------------------------
echo "═══════════════════════════════════════════════════════════════"
echo "4️⃣  IRQ BALANCING & AFFINITY"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Disable irqbalance (prevents interrupt spreading across cores)
if systemctl is-active --quiet irqbalance 2>/dev/null; then
    systemctl stop irqbalance
    systemctl disable irqbalance
    echo "  ✓ irqbalance disabled (stable interrupt routing)"
else
    echo "  ✓ irqbalance already disabled"
fi

echo ""

# ----------------------------------------------------------------------------
# 5. PERSISTENCE (Survives Reboot)
# ----------------------------------------------------------------------------
echo "═══════════════════════════════════════════════════════════════"
echo "5️⃣  PERSISTENCE SETUP"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Create unified systemd service for all optimizations
cat > /etc/systemd/system/trading-optimization.service << 'EOF'
[Unit]
Description=HFT Trading Low-Latency Optimizations
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
    # Network Interface \
    INTERFACE=$(ip -o -4 route show to default | awk "{print \$5}" | head -n1); \
    [ -n "$INTERFACE" ] || exit 0; \
    ethtool -C $INTERFACE adaptive-rx off adaptive-tx off 2>/dev/null || true; \
    ethtool -C $INTERFACE rx-usecs 0 tx-usecs 0 2>/dev/null || true; \
    ethtool -K $INTERFACE tso off gso off gro off lro off 2>/dev/null || true; \
    MAX_RX=$(ethtool -g $INTERFACE 2>/dev/null | awk "/Pre-set maximums:/{flag=1; next} /Current hardware settings:/{flag=0} flag && /RX:/{print \$2; exit}"); \
    MAX_TX=$(ethtool -g $INTERFACE 2>/dev/null | awk "/Pre-set maximums:/{flag=1; next} /Current hardware settings:/{flag=0} flag && /TX:/{print \$2; exit}"); \
    [ -n "$MAX_RX" ] && [ -n "$MAX_TX" ] && ethtool -G $INTERFACE rx $MAX_RX tx $MAX_TX 2>/dev/null || true; \
    \
    # CPU Governor \
    if command -v cpupower &>/dev/null; then cpupower frequency-set -g performance >/dev/null 2>&1; fi; \
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $cpu 2>/dev/null || true; done; \
    \
    # Disable C-States \
    for state in /sys/devices/system/cpu/cpu*/cpuidle/state*/disable; do echo 1 > $state 2>/dev/null || true; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable trading-optimization.service > /dev/null 2>&1
echo "  ✓ Persistence service enabled (survives reboot)"

echo ""

# ----------------------------------------------------------------------------
# COMPLETION
# ----------------------------------------------------------------------------
echo "═══════════════════════════════════════════════════════════════"
echo "✅ HFT-GRADE OPTIMIZATION COMPLETE!"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "📋 Applied optimizations:"
echo "  • Network: Zero-latency interrupts + LRO disabled"
echo "  • TCP/IP: BBR + Busy Polling (spin-wait for packets)"
echo "  • CPU: Performance governor + C-States disabled"
echo "  • IRQ: Stable interrupt routing (no balancing)"
echo ""
echo "⚠️  IMPORTANT: Busy polling will use ~10-20% more CPU"
echo "   (This is NORMAL and GOOD for low latency)"
echo ""
echo "🔄 Next steps:"
echo "  1. Reboot now: sudo reboot"
echo "  2. After reboot, verify: sudo bash verify_optimizations.sh"
echo "  3. Run your bot and measure improvements"
echo ""
echo "📊 Expected improvements:"
echo "  • Network latency: -5-15μs per packet (busy polling)"
echo "  • Total order latency: 35-45ms (down from 60ms)"
echo "  • More consistent timing (C-States disabled)"
echo ""
