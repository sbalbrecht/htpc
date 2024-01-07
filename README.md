# HTPC Containers
## Prerequisites
### Docker Engine
If you want to take advantage of Plex hardware transcoding (recommended), you cannot use the Docker daemon installed through Docker Desktop to deploy this compose file (at least on Linux, on which this deployment was tested).

You must instead [install the Docker Engine](https://docs.docker.com/engine/install/ubuntu/). This is because Docker Desktop runs in a VM that prevents access to the `/dev/dri` directory, and thus hardware transcoding.

### Directories
To allow for application settings to persist across container redeployment, container configuration files are stored in `/host`. You can optionally mount a drive to this directory so the application files are isolated from the OS drive.

### VPN Configuration
All containers besides Plex are behind a VPN. AirVPN is the currently configured provider, but you can reference the container's documentation to see other supported provider configurations.

Docker secrets are used to pass the VPN credentials to the VPN container. You must create two files containing the username and password respectively:
- `/host/vpnuser.txt`
- `/host/vpnpass.txt`

The VPN container uses OpenVPN and Wireguard, but OpenVPN is currently used. [Generate an AirVPN OpenVPN configuration file](https://airvpn.org/generator/) and place it in `/host/qbittorrent/openvpn/`.

## Deployment
Execute the following commands from the directory containing the compose file.
### Starting the containers
```
docker compose up -d
```
### Stopping the containers
```
docker compose down
```

