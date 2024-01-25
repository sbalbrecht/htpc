# HTPC Containers
This docker compose deploys the following applications for a media server automation setup:
* **Plex**: Media server
* **qBittorrent**: Torrent download client and VPN. Other containers can route their traffic through this one to stay behind a VPN (only used by SABnzbd)
* **SABnzbd**: Usenet client
* **Prowlarr**: Indexer aggregator for torrents and usenet
* **Radarr**: Movie automation client
* **Sonarr**: TV automation client
* **Requestrr**: Discord bot for easily requesting media away from your LAN

## Considerations
This compose file assumes quite a lot about your setup. 

* Deployment is on Linux (Ubuntu)
* `/mnt/storage` stores all media and downloads
* `/host` stores container config files outside of the containers so setup persists between teardowns
* Intel QuickSync is available for hardware transcoding
* AirVPN is used with an OpenVPN configuration

## Prerequisites
### Docker Engine
If you want to take advantage of Plex hardware transcoding (recommended), you cannot use the Docker daemon installed through Docker Desktop to deploy this compose file (at least on Linux).

You must instead [install the Docker Engine](https://docs.docker.com/engine/install/ubuntu/). This is because Docker Desktop runs in a VM that prevents access to the `/dev/dri` directory, and thus hardware transcoding.

### Directories
To allow for application settings to persist across container redeployment, container configuration files are stored in `/host`. You can optionally mount a drive to this directory so the application files are isolated from the OS drive.

### VPN Configuration
Only qBittorrent and SABnzbd are behind a VPN. Per [Servarr docs](https://wiki.servarr.com/prowlarr/faq#vpns-jackett-and-the-arrs), none of the Servarr stack should be behind one.

AirVPN is the currently configured provider, but you can reference the `qbittorrentvpn`'s documentation to see other supported provider configurations.

Docker secrets are used to pass the VPN credentials to the VPN container, which are required for OpenVPN. You must create two files containing the username and password respectively:
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

## Configuration
After deploying the compose file, you must configure each application via its web UI.

Significant steps include, but are not limited to:
1. Set SABnzbd download and incomplete directories to `/data/downloads` and `/data/incomplete` in the *Folders* config
2. Add `qbittorrentvpn` to SABnzbd's `host_whitelist` under *Config > Special > `host_whitelist`* (separate existing values with a comma)
3. If using VPN port forwarding, set your port in qBittorrent under *Options > Connection > Listening Port* 
4. Set qBittorrent network interface to `tun0` under *Options > Advanced > Network interface*
5. Connect all the apps to one another, including the download clients to the Servarr apps. The containers will be using the Docker bridge network, so their IP will be `<container name>` instead of `localhost`, e.g., `http://prowlarr:4545` or `http://qbittorrentvpn:8080` for SABnzbd.

Refer to the documentation of each application for further configuration steps.