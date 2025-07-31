#!/bin/bash

# Script to retrieve FSx for ONTAP cluster management IP, SVM iSCSI IP, and inter-cluster IP
# for SVM named "SVM1" from the least utilized file system (by IOPS and capacity) with tag myid=id111111

# Variables
SVM_NAME="SVM1"
AWS_REGION="us-east-1"  # Replace with your AWS region
OUTPUT_FILE="fsx_ontap_ips.txt"
TAG_KEY="myid"
TAG_VALUE="id111111"
PERIOD=3600  # Period for CloudWatch metrics (1 hour in seconds)
END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)  # Current UTC time
START_TIME=$(date -u -d "1 hour ago" +%Y-%m-%dT%H:%M:%SZ)  # 1 hour ago
IOPS_WEIGHT=0.5  # Weight for IOPS in combined utilization score
CAPACITY_WEIGHT=0.5  # Weight for capacity in combined utilization score

# Step 1: Get FSx for ONTAP file systems with the specified tag
echo "Retrieving FSx for ONTAP file systems with tag $TAG_KEY=$TAG_VALUE..."
FILE_SYSTEMS=$(aws fsx describe-file-systems \
  --region $AWS_REGION \
  --filters Name=file-system-type,Values=ONTAP \
  --query "FileSystems[?Tags[?Key=='$TAG_KEY' && Value=='$TAG_VALUE']].{FileSystemId:FileSystemId, ConsumedStorageCapacity:OntapConfiguration.ConsumedStorageCapacity, StorageCapacity:StorageCapacity}" \
  --output json)

if [ -z "$FILE_SYSTEMS" ] || [ "$FILE_SYSTEMS" == "[]" ]; then
  echo "No FSx for ONTAP file systems found with tag $TAG_KEY=$TAG_VALUE in region $AWS_REGION"
  exit 1
fi

# Step 2: Find the least utilized file system based on TotalIops and capacity utilization
echo "Determining the least utilized file system (IOPS and capacity)..."
LOWEST_SCORE=999999999
SELECTED_FS_ID=""
SELECTED_IOPS=0
SELECTED_CAPACITY_PERCENT=0

# Collect IOPS and capacity data for normalization
IOPS_VALUES=()
CAPACITY_PERCENT_VALUES=()
while IFS= read -r fs; do
  FS_ID=$(echo $fs | jq -r '.FileSystemId')
  
  # Get IOPS from CloudWatch
  IOPS=$(aws cloudwatch get-metric-statistics \
    --region $AWS_REGION \
    --namespace AWS/FSx \
    --metric-name TotalIops \
    --dimensions Name=FileSystemId,Value=$FS_ID \
    --start-time $START_TIME \
    --end-time $END_TIME \
    --period $PERIOD \
    --statistics Average \
    --query "Datapoints[0].Average" \
    --output text)
  
  # Handle case where no IOPS data is available
  if [ "$IOPS" == "None" ]; then
    IOPS=0
  fi
  IOPS_VALUES+=($IOPS)

  # Calculate capacity utilization percentage
  CONSUMED=$(echo $fs | jq -r '.ConsumedStorageCapacity')
  TOTAL=$(echo $fs | jq -r '.StorageCapacity')
  if [ "$TOTAL" != "0" ]; then
    CAPACITY_PERCENT=$(echo "scale=2; ($CONSUMED / $TOTAL) * 100" | bc)
  else
    CAPACITY_PERCENT=0
  fi
  CAPACITY_PERCENT_VALUES+=($CAPACITY_PERCENT)
done <<< "$(echo $FILE_SYSTEMS | jq -c '.[]')"

# Normalize IOPS and capacity percentages
MAX_IOPS=$(printf "%s\n" "${IOPS_VALUES[@]}" | sort -nr | head -n1)
MAX_CAPACITY_PERCENT=$(printf "%s\n" "${CAPACITY_PERCENT_VALUES[@]}" | sort -nr | head -n1)

# Avoid division by zero
if [ "$(echo "$MAX_IOPS <= 0" | bc)" -eq 1 ]; then
  MAX_IOPS=1
fi
if [ "$(echo "$MAX_CAPACITY_PERCENT <= 0" | bc)" -eq 1 ]; then
  MAX_CAPACITY_PERCENT=1
fi

# Evaluate combined utilization score
INDEX=0
while IFS= read -r fs; do
  FS_ID=$(echo $fs | jq -r '.FileSystemId')
  IOPS=${IOPS_VALUES[$INDEX]}
  CAPACITY_PERCENT=${CAPACITY_PERCENT_VALUES[$INDEX]}

  # Normalize IOPS and capacity to 0-1 scale
  NORMALIZED_IOPS=$(echo "scale=4; $IOPS / $MAX_IOPS" | bc)
  NORMALIZED_CAPACITY=$(echo "scale=4; $CAPACITY_PERCENT / $MAX_CAPACITY_PERCENT" | bc)

  # Calculate combined score
  SCORE=$(echo "scale=4; ($IOPS_WEIGHT * $NORMALIZED_IOPS) + ($CAPACITY_WEIGHT * $NORMALIZED_CAPACITY)" | bc)

  # Update if score is lower
  if (( $(echo "$SCORE < $LOWEST_SCORE" | bc -l) )); then
    LOWEST_SCORE=$SCORE
    SELECTED_FS_ID=$FS_ID
    SELECTED_IOPS=$IOPS
    SELECTED_CAPACITY_PERCENT=$CAPACITY_PERCENT
  fi
  ((INDEX++))
done <<< "$(echo $FILE_SYSTEMS | jq -c '.[]')"

if [ -z "$SELECTED_FS_ID" ]; then
  echo "Failed to determine the least utilized file system"
  exit 1
fi

echo "Selected file system: $SELECTED_FS_ID (Average IOPS: $SELECTED_IOPS, Capacity Utilization: $SELECTED_CAPACITY_PERCENT%)"

# Step 3: Get SVM details for the selected file system
echo "Retrieving details for SVM named $SVM_NAME in file system $SELECTED_FS_ID..."
SVM_DETAILS=$(aws fsx describe-storage-virtual-machines \
  --region $AWS_REGION \
  --filters Name=file-system-id,Values=$SELECTED_FS_ID Name=name,Values=$SVM_NAME \
  --query "StorageVirtualMachines[0]" --output json)

if [ "$(echo $SVM_DETAILS | jq -r '.Name')" != "$SVM_NAME" ]; then
  echo "SVM named '$SVM_NAME' not found in file system $SELECTED_FS_ID"
  exit 1
fi

# Step 4: Extract IPs
MANAGEMENT_IP=$(aws fsx describe-file-systems \
  --region $AWS_REGION \
  --file-system-ids $SELECTED_FS_ID \
  --query "FileSystems[0].OntapConfiguration.Endpoints.Management.IpAddresses[0]" --output text)

ISCSI_IPS=$(echo $SVM_DETAILS | jq -r '.Endpoints.Iscsi.IpAddresses[]' | tr '\n' ', ' | sed 's/, $//')
INTERCLUSTER_IPS=$(aws fsx describe-file-systems \
  --region $AWS_REGION \
  --file-system-ids $SELECTED_FS_ID \
  --query "FileSystems[0].OntapConfiguration.Endpoints.InterCluster.IpAddresses[]" --output text | tr '\n' ', ' | sed 's/, $//')

# Step 5: Output results
echo "Results for SVM '$SVM_NAME' in File System '$SELECTED_FS_ID':" > $OUTPUT_FILE
echo "Cluster Management IP: $MANAGEMENT_IP" >> $OUTPUT_FILE
echo "SVM iSCSI IPs: $ISCSI_IPS" >> $OUTPUT_FILE
echo "Inter-Cluster IPs: $INTERCLUSTER_IPS" >> $OUTPUT_FILE
echo "Average IOPS: $SELECTED_IOPS" >> $OUTPUT_FILE
echo "Capacity Utilization: $SELECTED_CAPACITY_PERCENT%" >> $OUTPUT_FILE

# Print to console
cat $OUTPUT_FILE

echo "Results saved to $OUTPUT_FILE"