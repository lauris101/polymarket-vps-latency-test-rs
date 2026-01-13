#!/bin/bash

# 1. Identify the primary network interface (usually ens5, eth0, or ens3)
INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
echo "Detected Interface: $INTERFACE"

# 2. Disable Adaptive Coalescing (The "Auto-Wait" feature)
# This prevents the card from automatically deciding to wait for more packets.
ethtool -C $INTERFACE adaptive-rx off adaptive-tx off

# 3. Set Coalescing timers to ZERO (Interrupt immediately)
# rx-usecs 0: Generate interrupt immediately when a packet arrives (WebSocket message)
# tx-usecs 0: Generate interrupt immediately when a packet is sent (Order)
ethtool -C $INTERFACE rx-usecs 0 tx-usecs 0

# 4. Increase Ring Buffer Sizes (Optional but recommended)
# This prevents packet drops if the CPU is momentarily busy,
# acting as a safety net since we removed the "wait" time.
# We set it to the maximum supported by the hardware.
MAX_RX=$(ethtool -g $INTERFACE | grep -A 5 "Pre-set maximums" | grep "RX:" | awk '{print $2}')
MAX_TX=$(ethtool -g $INTERFACE | grep -A 5 "Pre-set maximums" | grep "TX:" | awk '{print $2}')
ethtool -G $INTERFACE rx $MAX_RX tx $MAX_TX

echo "Network optimization complete. Latency buffering disabled on $INTERFACE."
