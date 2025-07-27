import requests
import urllib3
import argparse

# Disable SSL warnings for simplicity (not recommended for production)
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

def send_request(method: str, url: str, auth: tuple, data: dict = None) -> dict:
    headers = {"Accept": "application/json"}
    try:
        response = requests.request(
            method,
            url,
            auth=auth,
            headers=headers,
            json=data,
            verify=False
        )
        response.raise_for_status()
        return response.json(), response.status_code
    except requests.exceptions.HTTPError as e:
        print(f"HTTP Error: {e.response.status_code} - {e.response.reason}")
        exit(1)
    except requests.exceptions.RequestException as e:
        print(f"Request Error: {str(e)}")
        exit(1)

def get_volume(cluster: str, vserver: str, vol_name: str, auth: tuple) -> dict:
    url = f"https://{cluster}/api/storage/volumes?name={vol_name}&svm.name={vserver}&fields=size"
    response, status_code = send_request("GET", url, auth)
    volumes = response.get("records", [])
    if not volumes:
        print(f"Error: Volume {vol_name} not found in SVM {vserver} (Status: {status_code})")
        exit(1)
    return volumes[0], status_code

def modify_volume_size(cluster: str, vserver: str, vol_name: str, new_size: int, auth: tuple) -> dict:
    volume, _ = get_volume(cluster, vserver, vol_name, auth)
    volume_uuid = volume["uuid"]
    url = f"https://{cluster}/api/storage/volumes/{volume_uuid}"
    data = {"size": new_size}
    response, status_code = send_request("PATCH", url, auth, data)
    return response, status_code

def get_lun(cluster: str, vserver: str, lun_path: str, auth: tuple) -> dict:
    url = f"https://{cluster}/api/storage/luns?name={lun_path}&svm.name={vserver}&fields=space.size"
    response, status_code = send_request("GET", url, auth)
    luns = response.get("records", [])
    if not luns:
        print(f"Error: LUN {lun_path} not found in SVM {vserver} (Status: {status_code})")
        exit(1)
    return luns[0], status_code

def resize_lun(cluster: str, vserver: str, lun_path: str, new_size: int, auth: tuple) -> dict:
    lun, _ = get_lun(cluster, vserver, lun_path, auth)
    lun_uuid = lun["uuid"]
    url = f"https://{cluster}/api/storage/luns/{lun_uuid}"
    data = {"space": {"size": new_size}}
    response, status_code = send_request("PATCH", url, auth, data)
    return response, status_code

def calculate_sizes(volume_size: int) -> tuple:
    # Apply 5% overhead to volume size for LUN
    lun_size = int(volume_size * 0.95)
    return volume_size, lun_size

def main():
    parser = argparse.ArgumentParser(description="ONTAP Volume and LUN Resize Script")
    parser.add_argument("--cluster", required=True, help="ONTAP cluster management IP")
    parser.add_argument("--vserver", required=True, help="SVM name")
    parser.add_argument("--volume", required=True, help="Volume name")
    parser.add_argument("--lun-path", required=True, help="LUN path (e.g., /vol/vol1/lun1)")
    parser.add_argument("--size", required=True, type=int, help="New volume size in bytes")
    parser.add_argument("--username", required=True, help="ONTAP admin username")
    parser.add_argument("--password", required=True, help="ONTAP admin password")
    
    args = parser.parse_args()
    auth = (args.username, args.password)

    try:
        # Calculate sizes
        volume_size, lun_size = calculate_sizes(args.size)
        
        # Modify volume size
        print(f"Modifying volume {args.volume} to size {volume_size} bytes")
        vol_response, vol_status = modify_volume_size(args.cluster, args.vserver, args.volume, volume_size, auth)
        print(f"Volume modification successful: Status {vol_status}")

        # Resize LUN
        print(f"Resizing LUN {args.lun_path} to size {lun_size} bytes")
        lun_response, lun_status = resize_lun(args.cluster, args.vserver, args.lun_path, lun_size, auth)
        print(f"LUN resize successful: Status {lun_status}")

    except Exception as e:
        print(f"Error: {str(e)}")
        exit(1)

if __name__ == "__main__":
    main()