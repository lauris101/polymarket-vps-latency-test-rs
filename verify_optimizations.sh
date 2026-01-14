#!/bin/bash

# ============================================================================
# Verify VPS Low-Latency Optimizations
# Usage: sudo bash verify_optimizations.sh
# ============================================================================

echo ""
echo "🔍 Verifying Low-Latency Optimizations..."
echo ""

INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')

PASS=0
WARN=0
FAIL=0

# ----------------------------------------------------------------------------
# 1. Network Interface Settings
# ----------------------------------------------------------------------------
echo "═══════════════════════════════════════════════════════════════"
echo "1️⃣  NETWORK INTERFACE: $INTERFACE"
echo "═══════════════════════════════════════════════════════════════"
echo ""

echo "Interrupt Coalescing Settings:"
COALESCE=$(ethtool -c $INTERFACE 2>/dev/null)

# Check adaptive RX
if echo "$COALESCE" | grep -q "Adaptive RX.*off"; then
    echo "  ✅ Adaptive RX: off"
    ((PASS++))
else
    echo "  ⚠️  Adaptive RX: not disabled"
    ((WARN++))
fi

# Check adaptive TX
if echo "$COALESCE" | grep -q "Adaptive TX.*off"; then
    echo "  ✅ Adaptive TX: off"
    ((PASS++))
else
    echo "  ⚠️  Adaptive TX: not disabled"
    ((WARN++))
fi

# Check rx-usecs
RX_USECS=$(echo "$COALESCE" | grep "rx-usecs:" | awk '{print $2}')
if [ "$RX_USECS" = "0" ]; then
    echo "  ✅ rx-usecs: 0 (immediate)"
    ((PASS++))
else
    echo "  ⚠️  rx-usecs: $RX_USECS (should be 0)"
    ((WARN++))
fi

# Check tx-usecs
TX_USECS=$(echo "$COALESCE" | grep "tx-usecs:" | awk '{print $2}')
if [ "$TX_USECS" = "0" ]; then
    echo "  ✅ tx-usecs: 0 (immediate)"
    ((PASS++))
else
    echo "  ⚠️  tx-usecs: $TX_USECS (should be 0)"
    ((WARN++))
fi

echo ""
echo "Ring Buffers:"
ethtool -g $INTERFACE 2>/dev/null | grep -A 4 "Current hardware settings" | sed 's/^/  /'

echo ""
echo "Offload Features (should be off for low latency):"
OFFLOAD=$(ethtool -k $INTERFACE 2>/dev/null)

if echo "$OFFLOAD" | grep -q "tcp-segmentation-offload: off"; then
    echo "  ✅ TSO: off"
    ((PASS++))
else
    echo "  ⚠️  TSO: on (should be off)"
    ((WARN++))
fi

if echo "$OFFLOAD" | grep -q "generic-segmentation-offload: off"; then
    echo "  ✅ GSO: off"
    ((PASS++))
else
    echo "  ⚠️  GSO: on (should be off)"
    ((WARN++))
fi

if echo "$OFFLOAD" | grep -q "generic-receive-offload: off"; then
    echo "  ✅ GRO: off"
    ((PASS++))
else
    echo "  ⚠️  GRO: on (should be off)"
    ((WARN++))
fi

# ----------------------------------------------------------------------------
# 2. TCP/IP Stack
# ----------------------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "2️⃣  TCP/IP STACK"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Check BBR
CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
if [ "$CC" = "bbr" ]; then
    echo "  ✅ Congestion Control: bbr"
    ((PASS++))
else
    echo "  ❌ Congestion Control: $CC (should be bbr)"
    ((FAIL++))
fi

# Check TCP Fast Open
TFO=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)
if [ "$TFO" = "3" ]; then
    echo "  ✅ TCP Fast Open: 3 (enabled)"
    ((PASS++))
else
    echo "  ⚠️  TCP Fast Open: $TFO (should be 3)"
    ((WARN++))
fi

# Check slow start after idle
SSAI=$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null)
if [ "$SSAI" = "0" ]; then
    echo "  ✅ Slow Start After Idle: 0 (disabled)"
    ((PASS++))
else
    echo "  ⚠️  Slow Start After Idle: $SSAI (should be 0)"
    ((WARN++))
fi

# Check keepalive
KA_TIME=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)
if [ "$KA_TIME" = "60" ]; then
    echo "  ✅ TCP Keepalive Time: 60s"
    ((PASS++))
else
    echo "  ⚠️  TCP Keepalive Time: ${KA_TIME}s (should be 60)"
    ((WARN++))
fi

# Check tw_reuse
TW_REUSE=$(sysctl -n net.ipv4.tcp_tw_reuse 2>/dev/null)
if [ "$TW_REUSE" = "1" ]; then
    echo "  ✅ TCP TIME_WAIT Reuse: enabled"
    ((PASS++))
else
    echo "  ⚠️  TCP TIME_WAIT Reuse: disabled (should be enabled)"
    ((WARN++))
fi

# ----------------------------------------------------------------------------
# 3. CPU Governor
# ----------------------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "3️⃣  CPU SETTINGS"
echo "═══════════════════════════════════════════════════════════════"
echo ""

GOVERNORS=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort -u)
if [ "$GOVERNORS" = "performance" ]; then
    echo "  ✅ CPU Governor: performance (all cores)"
    ((PASS++))
elif [ -n "$GOVERNORS" ]; then
    echo "  ⚠️  CPU Governor: $GOVERNORS (should be 'performance')"
    ((WARN++))
else
    echo "  ⚠️  CPU Governor: unable to read (cpufreq may not be available)"
    ((WARN++))
fi

# ----------------------------------------------------------------------------
# 4. Services
# ----------------------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "4️⃣  SERVICES"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Check irqbalance
if systemctl is-active --quiet irqbalance 2>/dev/null; then
    echo "  ⚠️  irqbalance: RUNNING (should be stopped)"
    ((WARN++))
else
    echo "  ✅ irqbalance: stopped"
    ((PASS++))
fi

# Check network optimization service
if systemctl is-enabled --quiet network-latency-optimization.service 2>/dev/null; then
    echo "  ✅ network-latency-optimization.service: enabled"
    ((PASS++))
else
    echo "  ⚠️  network-latency-optimization.service: not enabled"
    ((WARN++))
fi

# Check CPU performance service
if systemctl is-enabled --quiet cpu-performance.service 2>/dev/null; then
    echo "  ✅ cpu-performance.service: enabled"
    ((PASS++))
else
    echo "  ⚠️  cpu-performance.service: not enabled"
    ((WARN++))
fi

# ----------------------------------------------------------------------------
# 5. Connectivity Test
# ----------------------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "5️⃣  CONNECTIVITY TEST"
echo "═══════════════════════════════════════════════════════════════"
echo ""

echo "Ping to Polymarket CLOB:"
if ping -c 5 -W 2 clob.polymarket.com &>/dev/null; then
    PING_STATS=$(ping -c 5 clob.polymarket.com 2>/dev/null | tail -n 2)
    echo "$PING_STATS" | sed 's/^/  /'

    # Extract avg latency
    AVG_LATENCY=$(echo "$PING_STATS" | grep "rtt" | awk -F'/' '{print $5}')
    if [ -n "$AVG_LATENCY" ]; then
        AVG_INT=${AVG_LATENCY%.*}
        if [ "$AVG_INT" -lt 30 ]; then
            echo "  ✅ Excellent latency (<30ms avg)"
        elif [ "$AVG_INT" -lt 50 ]; then
            echo "  ✅ Good latency (30-50ms avg)"
        else
            echo "  ⚠️  Higher latency (>50ms avg) - consider VPS relocation"
        fi
    fi
else
    echo "  ❌ Could not ping clob.polymarket.com"
    ((FAIL++))
fi

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "📊 VERIFICATION SUMMARY"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  ✅ Passed:   $PASS checks"
echo "  ⚠️  Warnings: $WARN checks"
echo "  ❌ Failed:   $FAIL checks"
echo ""

if [ $FAIL -eq 0 ] && [ $WARN -eq 0 ]; then
    echo "🎉 Perfect! All optimizations are active."
    echo ""
    echo "Expected performance:"
    echo "  • Order latency: 40-50ms (steady state)"
    echo "  • Reduced jitter and more consistent timing"
    exit 0
elif [ $FAIL -eq 0 ]; then
    echo "✅ Good! Core optimizations are active."
    echo "⚠️  Some optional features aren't available on this system."
    echo ""
    echo "Expected performance:"
    echo "  • Order latency: 45-55ms (steady state)"
    exit 0
else
    echo "⚠️  Some critical optimizations failed."
    echo ""
    echo "Recommended actions:"
    echo "  1. Re-run: sudo bash optimize_trading_vps.sh"
    echo "  2. Reboot: sudo reboot"
    echo "  3. Verify again after reboot"
    exit 1
fi
