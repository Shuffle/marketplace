#!/bin/bash
set -eu

# Test deployment script for Shuffle on GCP
# Project: shuffle-australia-southeast1
# Region: australia-southeast1

echo "========================================"
echo "Shuffle Terraform Test Deployment"
echo "========================================"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
PROJECT_ID="shuffle-australia-southeast1"
REGION="australia-southeast1"
DEPLOYMENT_NAME="shuffle-test-$(date +%Y%m%d-%H%M%S)"

# Change to terraform directory
cd "$(dirname "$0")/.."

echo -e "${YELLOW}Using configuration:${NC}"
echo "  Project: $PROJECT_ID"
echo "  Region: $REGION"
echo "  Deployment: $DEPLOYMENT_NAME"
echo ""

# Check if logged in to gcloud
echo -e "${YELLOW}Checking GCP authentication...${NC}"
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
    echo -e "${RED}Not authenticated with gcloud. Please run: gcloud auth login${NC}"
    exit 1
fi

# Set the project
echo -e "${YELLOW}Setting GCP project...${NC}"
gcloud config set project $PROJECT_ID

# Enable required APIs
echo -e "${YELLOW}Enabling required APIs...${NC}"
gcloud services enable compute.googleapis.com \
    cloudresourcemanager.googleapis.com \
    logging.googleapis.com \
    monitoring.googleapis.com \
    --project $PROJECT_ID

# Initialize Terraform
echo -e "${YELLOW}Initializing Terraform...${NC}"
terraform init

# Validate configuration
echo -e "${YELLOW}Validating Terraform configuration...${NC}"
terraform validate

# Create terraform plan
echo -e "${YELLOW}Creating deployment plan...${NC}"
terraform plan \
    -var="project_id=$PROJECT_ID" \
    -var="goog_cm_deployment_name=$DEPLOYMENT_NAME" \
    -var="region=$REGION" \
    -var-file="test/terraform.tfvars" \
    -out=test.tfplan

echo ""
echo -e "${GREEN}Plan created successfully!${NC}"
echo ""
echo "Review the plan above. To deploy, run:"
echo -e "${YELLOW}terraform apply test.tfplan${NC}"
echo ""
echo "To deploy automatically, run this script with 'apply' argument:"
echo -e "${YELLOW}$0 apply${NC}"
echo ""

# Apply if requested
if [[ "${1:-}" == "apply" ]]; then
    echo -e "${YELLOW}Applying Terraform configuration...${NC}"
    terraform apply test.tfplan
    
    echo ""
    echo -e "${GREEN}Deployment complete!${NC}"
    echo ""
    echo "Getting deployment information..."
    
    # Get outputs
    FRONTEND_URL=$(terraform output -raw shuffle_frontend_url)
    
    echo ""
    echo "========================================"
    echo -e "${GREEN}Deployment Successful!${NC}"
    echo "========================================"
    echo ""
    echo "Access Information:"
    echo "  Frontend URL: $FRONTEND_URL"
    echo ""
    echo "SSH Access:"
    echo "  gcloud compute ssh --zone=\"australia-southeast1-a\" \"$DEPLOYMENT_NAME-manager-1\" --project=\"$PROJECT_ID\""
    echo ""
    echo "To destroy this deployment:"
    echo "  terraform destroy -var=\"project_id=$PROJECT_ID\" -var=\"goog_cm_deployment_name=$DEPLOYMENT_NAME\""
    echo ""
fi