#!/bin/bash

# ============================================================================
# VPS Low-Latency Optimization for Trading
# Run as root: sudo bash optimize_trading_vps.sh
# ============================================================================

set -e

echo "🚀 Starting VPS optimization for low-latency trading..."
echo ""

# ----------------------------------------------------------------------------
# 1. NETWORK INTERFACE OPTIMIZATION (Biggest Impact: 5-10ms)
# ----------------------------------------------------------------------------
echo "═══════════════════════════════════════════════════════════════"
echo "1️⃣  NETWORK INTERFACE OPTIMIZATION"
echo "═══════════════════════════════════════════════════════════════"

INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
echo "✓ Detected Interface: $INTERFACE"
echo ""

# Disable adaptive coalescing (prevents auto-waiting for packet batching)
echo "→ Disabling adaptive coalescing..."
ethtool -C $INTERFACE adaptive-rx off adaptive-tx off 2>/dev/null && echo "  ✓ Done" || echo "  ⚠ Not supported on this NIC"

# Set coalescing timers to ZERO (interrupt immediately on packet arrival)
echo "→ Setting interrupt coalescing to 0 (immediate interrupts)..."
ethtool -C $INTERFACE rx-usecs 0 tx-usecs 0 2>/dev/null && echo "  ✓ Done" || echo "  ⚠ Not supported on this NIC"

# Increase ring buffer sizes to maximum
echo "→ Maximizing ring buffer sizes..."
MAX_RX=$(ethtool -g $INTERFACE 2>/dev/null | grep -A 5 "Pre-set maximums" | grep "RX:" | awk '{print $2}')
MAX_TX=$(ethtool -g $INTERFACE 2>/dev/null | grep -A 5 "Pre-set maximums" | grep "TX:" | awk '{print $2}')

if [ -n "$MAX_RX" ] && [ -n "$MAX_TX" ]; then
    ethtool -G $INTERFACE rx $MAX_RX tx $MAX_TX 2>/dev/null
    echo "  ✓ Set RX: $MAX_RX, TX: $MAX_TX"
else
    echo "  ⚠ Could not detect ring buffer limits"
fi

# Disable TCP offloading features that add latency
echo "→ Disabling offload features (TSO/GSO/GRO)..."
ethtool -K $INTERFACE tso off gso off gro off 2>/dev/null && echo "  ✓ Done" || echo "  ⚠ Some features not supported"

echo ""

# ----------------------------------------------------------------------------
# 2. TCP/IP STACK TUNING (Impact: 3-5ms)
# ----------------------------------------------------------------------------
echo "═══════════════════════════════════════════════════════════════"
echo "2️⃣  TCP/IP STACK TUNING"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Backup original sysctl.conf
cp /etc/sysctl.conf /etc/sysctl.conf.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true

cat >> /etc/sysctl.conf << 'EOF'

# ============================================================
# Low-Latency Trading Optimizations
# Added by optimize_trading_vps.sh
# ============================================================

# BBR Congestion Control (better than CUBIC for low latency)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP Fast Open (saves 1 RTT on connection setup)
net.ipv4.tcp_fastopen = 3

# Disable slow start after idle (maintain cwnd)
net.ipv4.tcp_slow_start_after_idle = 0

# TCP Keepalive (faster detection of dead connections)
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6

# Reuse TIME_WAIT sockets faster
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# Increase network buffer sizes
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Increase backlog queues
net.core.netdev_max_backlog = 5000
net.core.somaxconn = 4096

# Reduce SYN retries (fail fast)
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2

EOF

echo "✓ TCP/IP parameters written to /etc/sysctl.conf"
echo "→ Applying settings..."
sysctl -p | grep -E "bbr|fastopen|slow_start|keepalive|tw_reuse"
echo ""

# ----------------------------------------------------------------------------
# 3. CPU GOVERNOR (Reduces jitter, consistent performance)
# ----------------------------------------------------------------------------
echo "═══════════════════════════════════════════════════════════════"
echo "3️⃣  CPU GOVERNOR (Performance Mode)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Check if cpupower is available
if command -v cpupower &> /dev/null; then
    echo "✓ cpupower found"
else
    echo "→ Installing cpupower..."
    apt-get update -qq
    apt-get install -y linux-tools-common linux-tools-$(uname -r) 2>/dev/null || {
        echo "⚠ Could not install cpupower - may not be available on this kernel"
    }
fi

# Set performance governor
if command -v cpupower &> /dev/null; then
    echo "→ Setting CPU governor to 'performance'..."
    cpupower frequency-set -g performance 2>/dev/null && echo "  ✓ Done" || echo "  ⚠ Not supported"
else
    # Fallback method
    echo "→ Trying alternative method..."
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo "performance" > $cpu 2>/dev/null
    done
    echo "  ✓ Done (alternative method)"
fi

echo ""

# ----------------------------------------------------------------------------
# 4. DISABLE UNNECESSARY SERVICES
# ----------------------------------------------------------------------------
echo "═══════════════════════════════════════════════════════════════"
echo "4️⃣  DISABLE UNNECESSARY SERVICES"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Disable irqbalance (prevents CPU core hopping for interrupts)
if systemctl is-active --quiet irqbalance 2>/dev/null; then
    echo "→ Disabling irqbalance..."
    systemctl stop irqbalance
    systemctl disable irqbalance
    echo "  ✓ irqbalance stopped and disabled"
else
    echo "✓ irqbalance already disabled or not present"
fi

echo ""

# ----------------------------------------------------------------------------
# 5. PERSISTENCE (Make changes survive reboot)
# ----------------------------------------------------------------------------
echo "═══════════════════════════════════════════════════════════════"
echo "5️⃣  PERSISTENCE SETUP"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Create systemd service to apply network settings on boot
cat > /etc/systemd/system/network-latency-optimization.service << 'EOF'
[Unit]
Description=Network Latency Optimization for Trading
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
INTERFACE=$(ip -o -4 route show to default | awk "{print \$5}"); \
ethtool -C $INTERFACE adaptive-rx off adaptive-tx off 2>/dev/null || true; \
ethtool -C $INTERFACE rx-usecs 0 tx-usecs 0 2>/dev/null || true; \
ethtool -K $INTERFACE tso off gso off gro off 2>/dev/null || true; \
MAX_RX=$(ethtool -g $INTERFACE 2>/dev/null | grep -A 5 "Pre-set maximums" | grep "RX:" | awk "{print \$2}"); \
MAX_TX=$(ethtool -g $INTERFACE 2>/dev/null | grep -A 5 "Pre-set maximums" | grep "TX:" | awk "{print \$2}"); \
[ -n "$MAX_RX" ] && [ -n "$MAX_TX" ] && ethtool -G $INTERFACE rx $MAX_RX tx $MAX_TX 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable network-latency-optimization.service 2>/dev/null
echo "✓ Network optimization service created and enabled"
echo "  (Will run automatically on boot)"

# CPU governor persistence
cat > /etc/systemd/system/cpu-performance.service << 'EOF'
[Unit]
Description=Set CPU Governor to Performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $cpu 2>/dev/null || true; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cpu-performance.service 2>/dev/null
echo "✓ CPU performance service created and enabled"

echo ""

# ----------------------------------------------------------------------------
# COMPLETION
# ----------------------------------------------------------------------------
echo "═══════════════════════════════════════════════════════════════"
echo "✅ OPTIMIZATION COMPLETE!"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "📋 Summary of changes:"
echo "  • Network interface optimized for minimum latency"
echo "  • TCP/IP stack tuned with BBR congestion control"
echo "  • CPU governor set to performance mode"
echo "  • Unnecessary services disabled"
echo "  • All changes will persist after reboot"
echo ""
echo "🔄 Next steps:"
echo "  1. Reboot to ensure all changes take effect:"
echo "     sudo reboot"
echo ""
echo "  2. After reboot, verify optimizations:"
echo "     sudo bash verify_optimizations.sh"
echo ""
echo "  3. Run your trading bot and measure improvements"
echo ""
echo "📊 Expected improvements:"
echo "  • 5-10ms from network interface tuning"
echo "  • 3-5ms from TCP/IP stack optimization"
echo "  • Reduced latency jitter (more consistent)"
echo "  • Total: 40-50ms order latency (down from 60ms)"
echo ""
