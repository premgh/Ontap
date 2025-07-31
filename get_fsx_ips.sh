#!/bin/bash

# Variables
SVM_NAME="SVM1"
TAG_KEY="myid"
TAG_VALUE="id123445"
AWS_REGION="us-east-1"  # Replace with your AWS region

# Function to check if AWS CLI and jq are installed
check_prerequisites() {
  if ! command -v aws &> /dev/null; then
    echo "AWS CLI is not installed. Please install it and configure credentials."
    exit 1
  fi
  if ! command -v jq &> /dev/null; then
    echo "jq is not installed. Please install it (e.g., 'sudo apt-get install jq' or 'brew install jq')."
    exit 1
  fi
}

# Function to get FSx File System IDs by tag
get_filesystem_ids() {
  FILESYSTEM_IDS=$(aws fsx describe-file-systems \
    --region "$AWS_REGION" \
    --query "FileSystems[?Tags[?Key=='$TAG_KEY' && Value=='$TAG_VALUE']].FileSystemId" \
    --output text 2>/dev/null)

  if [ -z "$FILESYSTEM_IDS" ]; then
    echo "No FSx file systems found with tag $TAG_KEY=$TAG_VALUE"
    exit 1
  fi
}

# Function to get capacity utilization for each file system
get_capacity_utilization() {
  declare -A UTILIZATION_MAP
  MIN_UTILIZATION=100
  SELECTED_FILESYSTEM_ID=""

  echo "Evaluating FSx file systems for capacity utilization:"
  for FS_ID in $FILESYSTEM_IDS; do
    # Check if SVM_NAME exists in this file system
    SVM_EXISTS=$(aws fsx describe-storage-virtual-machines \
      --region "$AWS_REGION" \
      --filters "Name=file-system-id,Values=$FS_ID" \
      --query "StorageVirtualMachines[?Name=='$SVM_NAME'].StorageVirtualMachineId" \
      --output text 2>/dev/null)

    if [ -n "$SVM_EXISTS" ]; then
      # Get storage capacity and used capacity
      FS_DETAILS=$(aws fsx describe-file-systems \
        --region "$AWS_REGION" \
        --file-system-ids "$FS_ID" \
        --query "FileSystems[0]" \
        --output json 2>/dev/null)

      TOTAL_CAPACITY=$(echo "$FS_DETAILS" | jq -r '.StorageCapacity')
      USED_CAPACITY=$(echo "$FS_DETAILS" | jq -r '.OntapConfiguration.StorageUsed // 0')
      
      if [ "$TOTAL_CAPACITY" -eq 0 ]; then
        echo "Warning: File System $FS_ID has zero storage capacity, skipping."
        continue
      fi

      # Calculate utilization percentage
      UTILIZATION=$(echo "scale=2; ($USED_CAPACITY / $TOTAL_CAPACITY) * 100" | bc)
      UTILIZATION_MAP["$FS_ID"]="$UTILIZATION"
      echo "File System ID: $FS_ID, Utilization: $UTILIZATION%"

      # Update selected file system if utilization is lower
      if (( $(echo "$UTILIZATION < $MIN_UTILIZATION" | bc -l) )); then
        MIN_UTILIZATION="$UTILIZATION"
        SELECTED_FILESYSTEM_ID="$FS_ID"
      fi
    fi
  done

  if [ -z "$SELECTED_FILESYSTEM_ID" ]; then
    echo "No file systems with SVM $SVM_NAME found."
    exit 1
  fi

  echo "Selected File System ID: $SELECTED_FILESYSTEM_ID (Utilization: ${UTILIZATION_MAP[$SELECTED_FILESYSTEM_ID]}%)"
  FILESYSTEM_ID="$SELECTED_FILESYSTEM_ID"
}

# Function to get SVM details
get_svm_details() {
  SVM_DETAILS=$(aws fsx describe-storage-virtual-machines \
    --region "$AWS_REGION" \
    --filters "Name=file-system-id,Values=$FILESYSTEM_ID" \
    --query "StorageVirtualMachines[?Name=='$SVM_NAME']" \
    --output json 2>/dev/null)

  if [ -z "$SVM_DETAILS" ] || [ "$SVM_DETAILS" == "[]" ]; then
    echo "No SVM named $SVM_NAME found in file system $FILESYSTEM_ID"
    exit 1
  fi
}

# Function to extract and display IPs
extract_ips() {
  MANAGEMENT_IP=$(echo "$SVM_DETAILS" | jq -r '.[0].Endpoints.Management.IpAddresses[0]')
  SVM_IP=$(echo "$SVM_DETAILS" | jq -r '.[0].Endpoints.Iscsi.IpAddresses[0]')

  if [ -z "$MANAGEMENT_IP" ] || [ "$MANAGEMENT_IP" == "null" ]; then
    echo "Management IP not found for SVM $SVM_NAME"
  else
    echo "Management IP: $MANAGEMENT_IP"
  fi

  if [ -z "$SVM_IP" ] || [ "$SVM_IP" == "null" ]; then
    echo "SVM IP (iSCSI) not found for SVM $SVM_NAME"
  else
    echo "SVM IP (iSCSI): $SVM_IP"
  fi
}

# Main execution
check_prerequisites
get_filesystem_ids
get_capacity_utilization
get_svm_details
extract_ips
