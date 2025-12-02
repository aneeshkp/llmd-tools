#!/bin/bash

# Create HuggingFace Token Secret for llm-d
# Usage: ./create_hf_token.sh [namespace] [hf_token]

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
BOLD='\033[1m'
NC='\033[0m'

# Function to show usage
show_usage() {
    echo -e "${BOLD}${CYAN}🔑 HuggingFace Token Secret Creator${NC}"
    echo
    echo "Usage:"
    echo "  $0 [NAMESPACE] [HF_TOKEN]"
    echo
    echo "Examples:"
    echo "  $0 llm-d-test                                    # Uses \$HF_TOKEN env var"
    echo "  $0 llm-d-test hf_xxxxxxxxxxxxxxxxxxxxx           # Uses provided token"
    echo "  NAMESPACE=llm-d-test $0                          # Uses env vars"
    echo
    echo "Environment variables:"
    echo "  NAMESPACE  - Target namespace (default: current or 'default')"
    echo "  HF_TOKEN   - HuggingFace token"
    echo
}

# Parse arguments
NAMESPACE_ARG=""
HF_TOKEN_ARG=""

if [ $# -eq 1 ]; then
    if [[ "$1" == "--help" || "$1" == "-h" ]]; then
        show_usage
        exit 0
    fi
    NAMESPACE_ARG="$1"
elif [ $# -eq 2 ]; then
    NAMESPACE_ARG="$1"
    HF_TOKEN_ARG="$2"
elif [ $# -gt 2 ]; then
    echo -e "${RED}❌ Too many arguments${NC}"
    show_usage
    exit 1
fi

# Determine namespace
if [ -n "$NAMESPACE_ARG" ]; then
    TARGET_NAMESPACE="$NAMESPACE_ARG"
elif [ -n "${NAMESPACE:-}" ]; then
    TARGET_NAMESPACE="$NAMESPACE"
else
    # Try to get current namespace context
    TARGET_NAMESPACE=$(kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null || echo "default")
    [ -z "$TARGET_NAMESPACE" ] && TARGET_NAMESPACE="default"
fi

# Determine HF token
if [ -n "$HF_TOKEN_ARG" ]; then
    HF_TOKEN_VALUE="$HF_TOKEN_ARG"
elif [ -n "${HF_TOKEN:-}" ]; then
    HF_TOKEN_VALUE="$HF_TOKEN"
else
    echo -e "${RED}❌ HuggingFace token not provided${NC}"
    echo -e "${WHITE}Please provide token via:${NC}"
    echo "  - Command line: $0 $TARGET_NAMESPACE <your_hf_token>"
    echo "  - Environment:  export HF_TOKEN=<your_hf_token>"
    exit 1
fi

# Validate HF token format
if [[ ! "$HF_TOKEN_VALUE" =~ ^hf_[a-zA-Z0-9]{34}$ ]]; then
    echo -e "${YELLOW}⚠️  Warning: Token doesn't match expected HuggingFace format (hf_xxxxx...)${NC}"
    echo -e "${WHITE}Continuing anyway...${NC}"
fi

echo -e "${BOLD}${CYAN}🔑 Creating HuggingFace Token Secret${NC}"
echo -e "${WHITE}Cluster: $(kubectl config current-context)${NC}"
echo -e "${WHITE}Namespace: ${CYAN}$TARGET_NAMESPACE${NC}"
echo -e "${WHITE}Token: ${CYAN}${HF_TOKEN_VALUE:0:8}...${HF_TOKEN_VALUE: -4}${NC}"
echo

# Check if namespace exists
if ! kubectl get namespace "$TARGET_NAMESPACE" >/dev/null 2>&1; then
    echo -e "${YELLOW}📦 Namespace '$TARGET_NAMESPACE' doesn't exist. Creating it...${NC}"
    kubectl create namespace "$TARGET_NAMESPACE"
    echo -e "${GREEN}✅ Namespace '$TARGET_NAMESPACE' created${NC}"
fi

# Check if secret already exists
if kubectl get secret llm-d-hf-token -n "$TARGET_NAMESPACE" >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠️  Secret 'llm-d-hf-token' already exists in namespace '$TARGET_NAMESPACE'${NC}"
    echo -e "${WHITE}Options:${NC}"
    echo "  1. Delete and recreate"
    echo "  2. Update existing secret"
    echo "  3. Skip creation"
    echo
    read -p "Choose option (1/2/3): " choice

    case $choice in
        1)
            echo -e "${YELLOW}🗑️  Deleting existing secret...${NC}"
            kubectl delete secret llm-d-hf-token -n "$TARGET_NAMESPACE"
            ;;
        2)
            echo -e "${BLUE}🔄 Updating existing secret...${NC}"
            kubectl create secret generic llm-d-hf-token \
                --from-literal=HF_TOKEN="$HF_TOKEN_VALUE" \
                -n "$TARGET_NAMESPACE" \
                --dry-run=client -o yaml | kubectl apply -f -
            echo -e "${GREEN}✅ Secret 'llm-d-hf-token' updated in namespace '$TARGET_NAMESPACE'${NC}"
            exit 0
            ;;
        3)
            echo -e "${CYAN}⏭️  Skipping secret creation${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}❌ Invalid choice. Exiting.${NC}"
            exit 1
            ;;
    esac
fi

# Create the secret
echo -e "${BLUE}🔐 Creating secret 'llm-d-hf-token'...${NC}"
kubectl create secret generic llm-d-hf-token \
    --from-literal=HF_TOKEN="$HF_TOKEN_VALUE" \
    -n "$TARGET_NAMESPACE"

echo -e "${GREEN}✅ Secret 'llm-d-hf-token' created successfully in namespace '$TARGET_NAMESPACE'${NC}"

# Verify the secret
echo -e "${WHITE}🔍 Verifying secret...${NC}"
kubectl get secret llm-d-hf-token -n "$TARGET_NAMESPACE" -o yaml | grep -E "name:|namespace:" | sed 's/^/  /'

echo
echo -e "${BOLD}${GREEN}🎉 HuggingFace token secret is ready for llm-d deployment!${NC}"
echo -e "${WHITE}Next steps:${NC}"
echo "  1. Run gateway infrastructure check: ~/check_gie_crds.sh"
echo "  2. Deploy llm-d: cd guides/inference-scheduling && helmfile apply -n $TARGET_NAMESPACE"