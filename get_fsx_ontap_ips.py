import boto3
import datetime
import json
from botocore.exceptions import ClientError

# Script to retrieve FSx for ONTAP cluster management IP, SVM iSCSI IP, and inter-cluster IP
# for SVM named "SVM1" from the least utilized file system (by IOPS and capacity) with tag myid=id111111

# Variables
SVM_NAME = "SVM1"
AWS_REGION = "us-east-1"  # Replace with your AWS region
OUTPUT_FILE = "fsx_ontap_ips.txt"
TAG_KEY = "myid"
TAG_VALUE = "id111111"
PERIOD = 3600  # Period for CloudWatch metrics (1 hour in seconds)
END_TIME = datetime.datetime.utcnow()
START_TIME = END_TIME - datetime.timedelta(seconds=3600)
IOPS_WEIGHT = 0.5  # Weight for IOPS in combined utilization score
CAPACITY_WEIGHT = 0.5  # Weight for capacity in combined utilization score

# Initialize AWS clients
fsx_client = boto3.client('fsx', region_name=AWS_REGION)
cloudwatch_client = boto3.client('cloudwatch', region_name=AWS_REGION)

# Step 1: Get FSx for ONTAP file systems with the specified tag
print(f"Retrieving FSx for ONTAP file systems with tag {TAG_KEY}={TAG_VALUE}...")
try:
    response = fsx_client.describe_file_systems(
        Filters=[{'Name': 'file-system-type', 'Values': ['ONTAP']}]
    )
    file_systems = [
        {
            'FileSystemId': fs['FileSystemId'],
            'ConsumedStorageCapacity': fs.get('OntapConfiguration', {}).get('ConsumedStorageCapacity', 0),
            'StorageCapacity': fs.get('StorageCapacity', 0)
        }
        for fs in response['FileSystems']
        if any(tag['Key'] == TAG_KEY and tag['Value'] == TAG_VALUE for tag in fs.get('Tags', []))
    ]
except ClientError as e:
    print(f"Error retrieving file systems: {e}")
    exit(1)

if not file_systems:
    print(f"No FSx for ONTAP file systems found with tag {TAG_KEY}={TAG_VALUE} in region {AWS_REGION}")
    exit(1)

# Step 2: Find the least utilized file system based on TotalIops and capacity utilization
print("Determining the least utilized file system (IOPS and capacity)...")
lowest_score = float('inf')
selected_fs_id = None
selected_iops = 0
selected_capacity_percent = 0

# Collect IOPS and capacity data for normalization
iops_values = []
capacity_percent_values = []

for fs in file_systems:
    fs_id = fs['FileSystemId']
    
    # Get IOPS from CloudWatch
    try:
        response = cloudwatch_client.get_metric_statistics(
            Namespace='AWS/FSx',
            MetricName='TotalIops',
            Dimensions=[{'Name': 'FileSystemId', 'Value': fs_id}],
            StartTime=START_TIME,
            EndTime=END_TIME,
            Period=PERIOD,
            Statistics=['Average']
        )
        iops = response['Datapoints'][0]['Average'] if response['Datapoints'] else 0
    except ClientError as e:
        print(f"Error retrieving IOPS for {fs_id}: {e}")
        iops = 0
    iops_values.append(iops)

    # Calculate capacity utilization percentage
    consumed = fs['ConsumedStorageCapacity']
    total = fs['StorageCapacity']
    capacity_percent = (consumed / total * 100) if total != 0 else 0
    capacity_percent_values.append(capacity_percent)

# Normalize IOPS and capacity percentages
max_iops = max(iops_values) if iops_values else 1
max_capacity_percent = max(capacity_percent_values) if capacity_percent_values else 1
max_iops = max(max_iops, 1)  # Avoid division by zero
max_capacity_percent = max(max_capacity_percent, 1)  # Avoid division by zero

# Evaluate combined utilization score
for i, fs in enumerate(file_systems):
    fs_id = fs['FileSystemId']
    iops = iops_values[i]
    capacity_percent = capacity_percent_values[i]

    # Normalize IOPS and capacity to 0-1 scale
    normalized_iops = iops / max_iops
    normalized_capacity = capacity_percent / max_capacity_percent

    # Calculate combined score
    score = (IOPS_WEIGHT * normalized_iops) + (CAPACITY_WEIGHT * normalized_capacity)

    # Update if score is lower
    if score < lowest_score:
        lowest_score = score
        selected_fs_id = fs_id
        selected_iops = iops
        selected_capacity_percent = capacity_percent

if not selected_fs_id:
    print("Failed to determine the least utilized file system")
    exit(1)

print(f"Selected file system: {selected_fs_id} (Average IOPS: {selected_iops}, Capacity Utilization: {selected_capacity_percent:.2f}%)")

# Step 3: Get SVM details for the selected file system
print(f"Retrieving details for SVM named {SVM_NAME} in file system {selected_fs_id}...")
try:
    response = fsx_client.describe_storage_virtual_machines(
        Filters=[
            {'Name': 'file-system-id', 'Values': [selected_fs_id]},
            {'Name': 'name', 'Values': [SVM_NAME]}
        ]
    )
    svm_details = response['StorageVirtualMachines'][0] if response['StorageVirtualMachines'] else None
except ClientError as e:
    print(f"Error retrieving SVM details: {e}")
    exit(1)

if not svm_details or svm_details['Name'] != SVM_NAME:
    print(f"SVM named '{SVM_NAME}' not found in file system {selected_fs_id}")
    exit(1)

# Step 4: Extract IPs
try:
    fs_response = fsx_client.describe_file_systems(FileSystemIds=[selected_fs_id])
    management_ip = fs_response['FileSystems'][0]['OntapConfiguration']['Endpoints']['Management']['IpAddresses'][0]
    intercluster_ips = ', '.join(fs_response['FileSystems'][0]['OntapConfiguration']['Endpoints']['InterCluster']['IpAddresses'])
    iscsi_ips = ', '.join(svm_details['Endpoints']['Iscsi']['IpAddresses'])
except ClientError as e:
    print(f"Error retrieving IPs: {e}")
    exit(1)

# Step 5: Output results
output = f"""Results for SVM '{SVM_NAME}' in File System '{selected_fs_id}':
Cluster Management IP: {management_ip}
SVM iSCSI IPs: {iscsi_ips}
Inter-Cluster IPs: {intercluster_ips}
Average IOPS: {selected_iops}
Capacity Utilization: {selected_capacity_percent:.2f}%"""

with open(OUTPUT_FILE, 'w') as f:
    f.write(output)

# Print to console
print(output)
print(f"Results saved to {OUTPUT_FILE}")