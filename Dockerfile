# --- Phase 1: Builder ---
# Use 'rust:nightly' (Official nightly build, based on Debian Bookworm)
FROM rustlang/rust:nightly-bookworm as builder

WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y pkg-config libssl-dev git clang cmake && rm -rf /var/lib/apt/lists/*

# Copy source and build
COPY . .
RUN cargo build --release

# --- Phase 2: Runner ---
# Use 'bookworm-slim' to match the builder's OS (fixes GLIBC error)
FROM debian:bookworm-slim

WORKDIR /app

# Install runtime dependencies
RUN apt-get update && apt-get install -y ca-certificates libssl3 && rm -rf /var/lib/apt/lists/*

# Copy the binary from the Builder
COPY --from=builder /app/target/release/poly-official-tester .

# Run
ENTRYPOINT ["./poly-official-tester"]
