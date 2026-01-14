#!/bin/bash

# ============================================================================
# Verify HFT-Grade VPS Optimizations
# Usage: sudo bash verify_optimizations.sh
# ============================================================================

echo ""
echo "🔍 Verifying HFT-Grade Low-Latency Optimizations..."
echo ""

INTERFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -n1)

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
if echo "$COALESCE" | grep -iq "Adaptive RX.*off"; then
    echo "  ✅ Adaptive RX: off"
    ((PASS++))
else
    echo "  ⚠️  Adaptive RX: not disabled"
    ((WARN++))
fi

# Check adaptive TX
if echo "$COALESCE" | grep -iq "Adaptive TX.*off"; then
    echo "  ✅ Adaptive TX: off"
    ((PASS++))
else
    echo "  ⚠️  Adaptive TX: not disabled"
    ((WARN++))
fi

# Check rx-usecs
RX_USECS=$(echo "$COALESCE" | grep "rx-usecs:" | head -n1 | awk '{print $2}')
if [ "$RX_USECS" = "0" ]; then
    echo "  ✅ rx-usecs: 0 (immediate)"
    ((PASS++))
elif [ -z "$RX_USECS" ]; then
    echo "  ⚠️  rx-usecs: not readable"
    ((WARN++))
else
    echo "  ⚠️  rx-usecs: $RX_USECS (should be 0)"
    ((WARN++))
fi

# Check tx-usecs
TX_USECS=$(echo "$COALESCE" | grep "tx-usecs:" | head -n1 | awk '{print $2}')
if [ "$TX_USECS" = "0" ]; then
    echo "  ✅ tx-usecs: 0 (immediate)"
    ((PASS++))
elif [ -z "$TX_USECS" ]; then
    echo "  ⚠️  tx-usecs: not readable"
    ((WARN++))
else
    echo "  ⚠️  tx-usecs: $TX_USECS (should be 0)"
    ((WARN++))
fi

echo ""
echo "Ring Buffers:"
ethtool -g $INTERFACE 2>/dev/null | grep -A 4 "Current hardware settings" | sed 's/^/  /' || echo "  ⚠️  Could not read"

echo ""
echo "Offload Features (all should be OFF for HFT):"
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

# NEW: Check LRO (critical!)
if echo "$OFFLOAD" | grep -q "large-receive-offload: off"; then
    echo "  ✅ LRO: off (CRITICAL for low latency)"
    ((PASS++))
elif echo "$OFFLOAD" | grep -q "large-receive-offload:"; then
    echo "  ⚠️  LRO: on (should be off for HFT)"
    ((WARN++))
else
    echo "  ⚠️  LRO: not available on this NIC"
    ((WARN++))
fi

# ----------------------------------------------------------------------------
# 2. TCP/IP Stack (Including Busy Polling)
# ----------------------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "2️⃣  TCP/IP STACK"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# NEW: Check Busy Polling (The Nuclear Option)
BUSY_READ=$(sysctl -n net.core.busy_read 2>/dev/null)
BUSY_POLL=$(sysctl -n net.core.busy_poll 2>/dev/null)

echo "Busy Polling (HFT Feature):"
if [ "$BUSY_READ" = "50" ]; then
    echo "  ✅ busy_read: 50μs (active)"
    ((PASS++))
elif [ "$BUSY_READ" -gt 0 ] 2>/dev/null; then
    echo "  ⚠️  busy_read: ${BUSY_READ}μs (non-zero, but not optimal)"
    ((WARN++))
else
    echo "  ❌ busy_read: 0 or not set (should be 50)"
    ((FAIL++))
fi

if [ "$BUSY_POLL" = "50" ]; then
    echo "  ✅ busy_poll: 50μs (active)"
    ((PASS++))
elif [ "$BUSY_POLL" -gt 0 ] 2>/dev/null; then
    echo "  ⚠️  busy_poll: ${BUSY_POLL}μs (non-zero, but not optimal)"
    ((WARN++))
else
    echo "  ❌ busy_poll: 0 or not set (should be 50)"
    ((FAIL++))
fi

echo ""
echo "Congestion Control:"
CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
if [ "$CC" = "bbr" ]; then
    echo "  ✅ BBR congestion control"
    ((PASS++))
else
    echo "  ❌ Congestion Control: $CC (should be bbr)"
    ((FAIL++))
fi

echo ""
echo "TCP Optimizations:"
TFO=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)
if [ "$TFO" = "3" ]; then
    echo "  ✅ TCP Fast Open: enabled"
    ((PASS++))
else
    echo "  ⚠️  TCP Fast Open: $TFO (should be 3)"
    ((WARN++))
fi

SSAI=$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null)
if [ "$SSAI" = "0" ]; then
    echo "  ✅ Slow Start After Idle: disabled"
    ((PASS++))
else
    echo "  ⚠️  Slow Start After Idle: $SSAI (should be 0)"
    ((WARN++))
fi

TW_REUSE=$(sysctl -n net.ipv4.tcp_tw_reuse 2>/dev/null)
if [ "$TW_REUSE" = "1" ]; then
    echo "  ✅ TIME_WAIT Reuse: enabled"
    ((PASS++))
else
    echo "  ⚠️  TIME_WAIT Reuse: disabled"
    ((WARN++))
fi

# ----------------------------------------------------------------------------
# 3. CPU Governor & C-States
# ----------------------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "3️⃣  CPU SETTINGS"
echo "═══════════════════════════════════════════════════════════════"
echo ""

echo "CPU Governor:"
GOVERNORS=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort -u)
if [ "$GOVERNORS" = "performance" ]; then
    echo "  ✅ All cores: performance mode"
    ((PASS++))
elif [ -n "$GOVERNORS" ]; then
    echo "  ⚠️  Governor: $GOVERNORS (should be 'performance')"
    ((WARN++))
else
    echo "  ⚠️  CPU Governor: not available (VM limitation)"
    ((WARN++))
fi

# NEW: Check C-States
echo ""
echo "C-States (should be DISABLED for HFT):"
CSTATE_DISABLED=0
CSTATE_TOTAL=0

for state in /sys/devices/system/cpu/cpu*/cpuidle/state*/disable; do
    if [ -f "$state" ]; then
        ((CSTATE_TOTAL++))
        DISABLED=$(cat "$state" 2>/dev/null)
        if [ "$DISABLED" = "1" ]; then
            ((CSTATE_DISABLED++))
        fi
    fi
done

if [ $CSTATE_TOTAL -gt 0 ]; then
    if [ $CSTATE_DISABLED -eq $CSTATE_TOTAL ]; then
        echo "  ✅ All C-States disabled ($CSTATE_DISABLED/$CSTATE_TOTAL)"
        ((PASS++))
    elif [ $CSTATE_DISABLED -gt 0 ]; then
        echo "  ⚠️  Partially disabled ($CSTATE_DISABLED/$CSTATE_TOTAL)"
        ((WARN++))
    else
        echo "  ❌ C-States enabled (should be disabled)"
        ((FAIL++))
    fi
else
    echo "  ⚠️  C-States not available (VM limitation)"
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

# Check persistence service
if systemctl is-enabled --quiet trading-optimization.service 2>/dev/null; then
    echo "  ✅ trading-optimization.service: enabled"
    ((PASS++))
else
    echo "  ⚠️  trading-optimization.service: not enabled"
    ((WARN++))
fi

# ----------------------------------------------------------------------------
# 5. Connectivity & Latency Test
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
        if [ "$AVG_INT" -lt 20 ]; then
            echo "  ✅ Excellent latency (<20ms avg) - HFT ready!"
        elif [ "$AVG_INT" -lt 30 ]; then
            echo "  ✅ Great latency (20-30ms avg)"
        elif [ "$AVG_INT" -lt 50 ]; then
            echo "  ⚠️  Good latency (30-50ms avg)"
        else
            echo "  ⚠️  High latency (>50ms avg) - consider VPS relocation"
        fi
    fi
else
    echo "  ❌ Could not ping clob.polymarket.com"
    ((FAIL++))
fi

# ----------------------------------------------------------------------------
# CPU Usage Check (Busy Polling uses more CPU)
# ----------------------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "6️⃣  CPU USAGE (Busy Polling Impact)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

if [ "$BUSY_POLL" = "50" ]; then
    echo "⚠️  NOTE: Busy polling is ACTIVE"
    echo "   Expected idle CPU usage: 10-20% (this is NORMAL)"
    echo "   The kernel is spinning to catch packets faster"
    echo ""
    IDLE_CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print $8}' | cut -d'%' -f1)
    if [ -n "$IDLE_CPU" ]; then
        USED_CPU=$(echo "100 - $IDLE_CPU" | bc 2>/dev/null)
        echo "   Current CPU usage: ~${USED_CPU}%"
    fi
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
    echo "🎉 PERFECT! HFT-grade optimizations fully active."
    echo ""
    echo "Expected performance:"
    echo "  • Order latency: 35-45ms (steady state)"
    echo "  • WebSocket latency: 5-10ms"
    echo "  • Consistent sub-microsecond variance"
    exit 0
elif [ $FAIL -eq 0 ]; then
    echo "✅ GOOD! Core optimizations active."
    echo "⚠️  Some features unavailable (likely VM limitations)"
    echo ""
    echo "Expected performance:"
    echo "  • Order latency: 40-50ms (steady state)"
    echo "  • WebSocket latency: 8-12ms"
    exit 0
else
    echo "⚠️  Some CRITICAL optimizations failed!"
    echo ""
    echo "Failed checks that matter:"
    if [ "$BUSY_POLL" != "50" ]; then
        echo "  • Busy polling NOT active (missing 5-15μs improvement)"
    fi
    if [ "$CC" != "bbr" ]; then
        echo "  • BBR NOT active (missing congestion control benefits)"
    fi
    echo ""
    echo "Recommended actions:"
    echo "  1. Re-run: sudo bash optimize_trading_vps.sh"
    echo "  2. Reboot: sudo reboot"
    echo "  3. Verify again"
    exit 1
fi
