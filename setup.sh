#!/bin/bash

# Setup script to load environment and verify configuration
# Usage: source setup.sh

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Loading configuration...${NC}"

# Check if .env file exists
if [ ! -f .env ]; then
    echo -e "${RED}Error: .env file not found!${NC}"
    echo -e "${YELLOW}Please create .env from .env.example:${NC}"
    echo "  cp .env.example .env"
    echo "  nano .env  # Edit with your values"
    return 1
fi

# Load .env file
set -a
source .env
set +a

echo -e "${GREEN}Environment loaded successfully!${NC}"
echo ""
echo "Configuration:"
echo "  PROJECT_ID: $PROJECT_ID"
echo "  REGION: $REGION"
echo "  ZONE: $ZONE"
echo "  CLUSTER_NAME: $CLUSTER_NAME"
echo ""

# Verify required variables
REQUIRED_VARS=("PROJECT_ID" "REGION" "ZONE" "CLUSTER_NAME")
MISSING_VARS=()

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        MISSING_VARS+=("$var")
    fi
done

if [ ${#MISSING_VARS[@]} -ne 0 ]; then
    echo -e "${RED}Error: Missing required variables:${NC}"
    for var in "${MISSING_VARS[@]}"; do
        echo "  - $var"
    done
    return 1
fi

# Set gcloud project
echo -e "${YELLOW}Setting GCP project...${NC}"
gcloud config set project $PROJECT_ID 2>/dev/null

echo -e "${GREEN}Ready to go! 🚀${NC}"
echo ""
echo "Next steps:"
echo "  1. Run: gcloud auth application-default login"
echo "  2. Run: cd terraform && terraform init"
echo ""
