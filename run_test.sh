#!/bin/bash
if [ ! -f .env ]; then echo "Error: .env file missing"; exit 1; fi

# Build the container (clean build)
docker build -t poly-rust .

echo "--- Trade Details ---"
read -p "Token ID: " T_ID
read -p "Price: " P
read -p "Size: " S

# Run the container
docker run --rm --env-file .env poly-rust --token-id "$T_ID" --price "$P" --size "$S"
