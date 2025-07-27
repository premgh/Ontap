import requests
import base64
import json
import time
from urllib3.exceptions import InsecureRequestWarning

# Suppress SSL warnings (use only for testing; enable SSL verification in production)
requests.packages.urllib3.disable_warnings(InsecureRequestWarning)

# Configuration for source and destination FSx for ONTAP clusters
source_cluster = {
    "hostname": "management.fs-XXXXXXXX.fsx.us-east-1.amazonaws.com",  # Replace with source FSx management endpoint
    "username": "fsxadmin",
    "password": "your_fsxadmin_password",  # Replace with your fsxadmin password
    "verify_ssl": False  # Set to True in production with valid certificates
}

destination_cluster = {
    "hostname": "management.fs-YYYYYYYY.fsx.us-west-2.amazonaws.com",  # Replace with destination FSx management endpoint
    "username": "fsxadmin",
    "password": "your_fsxadmin_password",  # Replace with your fsxadmin password
    "verify_ssl": False  # Set to True in production with valid certificates
}

# Inter-cluster LIFs for peering
source_intercluster_lifs = ["10.0.0.1", "10.0.0.2"]  # Replace with source inter-cluster LIF IPs
destination_intercluster_lifs = ["10.1.0.1", "10.1.0.2"]  # Replace with destination inter-cluster LIF IPs

# SVM names for peering
source_svm_name = "svm_source"  # Replace with your source SVM name
destination_svm_name = "svm_destination"  # Replace with your destination SVM name

# Cluster peer passphrase (must be the same for both clusters)
passphrase = "your_cluster_peer_passphrase"  # Replace with a secure passphrase

def get_auth_headers(cluster):
    """Generate HTTP Basic Authentication headers."""
    auth_str = f"{cluster['username']}:{cluster['password']}"
    auth_encoded = base64.b64encode(auth_str.encode()).decode()
    return {"Authorization": f"Basic {auth_encoded}", "Content-Type": "application/json"}

def create_cluster_peer(cluster, remote_lifs, peer_name, passphrase, is_source=True):
    """Create a cluster peering relationship."""
    url = f"https://{cluster['hostname']}/api/cluster/peers"
    headers = get_auth_headers(cluster)
    
    # Construct the payload for cluster peering
    payload = {
        "name": peer_name,
        "remote": {"ip_addresses": remote_lifs},
        "encryption": {"proposed": "tls_psk"},
        "passphrase": passphrase
    }
    
    try:
        response = requests.post(url, headers=headers, json=payload, verify=cluster["verify_ssl"])
        response.raise_for_status()
        print(f"Cluster peer created on {'source' if is_source else 'destination'} cluster: {peer_name}")
        return response.json()
    except requests.exceptions.RequestException as e:
        print(f"Error creating cluster peer on {'source' if is_source else 'destination'} cluster: {e}")
        if response.text:
            print(f"Response details: {response.text}")
        raise

def create_svm_peer(source_cluster, dest_cluster, source_svm, dest_svm):
    """Create and accept an SVM peering relationship."""
    # Step 1: Initiate SVM peering from source cluster
    url = f"https://{source_cluster['hostname']}/api/svm/peers"
    headers = get_auth_headers(source_cluster)
    
    payload = {
        "svm": {"name": source_svm},
        "peer": {"svm": {"name": dest_svm}, "cluster": {"name": "dest_cluster"}},
        "applications": ["snapmirror"]
    }
    
    try:
        response = requests.post(url, headers=headers, json=payload, verify=source_cluster["verify_ssl"])
        response.raise_for_status()
        print(f"SVM peering initiated for {source_svm} to {dest_svm}.")
    except requests.exceptions.RequestException as e:
        print(f"Error initiating SVM peering: {e}")
        if response.text:
            print(f"Response details: {response.text}")
        raise
    
    # Step 2: Accept SVM peering on destination cluster
    url = f"https://{dest_cluster['hostname']}/api/svm/peers"
    headers = get_auth_headers(dest_cluster)
    
    payload = {
        "svm": {"name": dest_svm},
        "peer": {"svm": {"name": source_svm}, "cluster": {"name": "source_cluster"}}
    }
    
    try:
        response = requests.post(url, headers=headers, json=payload, verify=dest_cluster["verify_ssl"])
        response.raise_for_status()
        print(f"SVM peering accepted for {dest_svm} to {source_svm}.")
    except requests.exceptions.RequestException as e:
        print(f"Error accepting SVM peering: {e}")
        if response.text:
            print(f"Response details: {response.text}")
        raise

def main():
    try:
        # Create cluster peering on source and destination
        create_cluster_peer(source_cluster, destination_intercluster_lifs, "dest_cluster", passphrase, is_source=True)
        time.sleep(5)  # Allow time for cluster peer to establish
        create_cluster_peer(destination_cluster, source_intercluster_lifs, "source_cluster", passphrase, is_source=False)
        
        # Create SVM peering
        time.sleep(5)  # Wait for cluster peering to stabilize
        create_svm_peer(source_cluster, destination_cluster, source_svm_name, destination_svm_name)
        
        print("Cluster and SVM peering successfully established.")
        
    except Exception as e:
        print(f"An error occurred: {e}")

if __name__ == "__main__":
    main()