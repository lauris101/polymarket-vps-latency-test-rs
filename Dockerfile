# STAGE 1: Builder
# We use the official Rust image to compile
FROM rust:latest as builder

# Create a new empty shell project
WORKDIR /usr/src/bot
USER root

# 1. OPTIMIZATION MAGIC HAPPENS HERE
ENV RUSTFLAGS="-C target-cpu=native"

# Copy your manifests first to cache dependencies
COPY ./Cargo.lock ./Cargo.lock
COPY ./Cargo.toml ./Cargo.toml

# Create a dummy main.rs to build dependencies and cache them
# This prevents rebuilding all crates every time you change one line of code
RUN mkdir src && \
    echo "fn main() {println!(\"if you see this, the build failed\")}" > src/main.rs
RUN cargo build --release

# Now copy the actual source code
COPY ./src ./src

# Touch the main file to force a re-build of your actual code
RUN touch src/main.rs

# Build the actual application
RUN cargo build --release

# STAGE 2: Runtime
# Use a minimal linux image (Debian Bookworm Slim)
# It's lighter and safer than a full OS image
FROM debian:trixie-slim

# Install OpenSSL/CA certificates (Critical for connecting to Polymarket HTTPS/WSS)
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy the binary from the builder stage
COPY --from=builder /usr/src/bot/target/release/poly-official-tester /usr/local/bin/bot

# Run the binary
# Note: We use the exec form ["..."] to ensure signals (SIGTERM) are passed correctly
ENTRYPOINT ["bot"]
