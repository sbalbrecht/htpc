# HTPC Containers
This docker compose deploys the following applications for a media server automation setup:
* **Plex**: Media server
* **qBittorrent**: Torrent download client and VPN. Other containers can route their traffic through this one to stay behind a VPN (only used by SABnzbd)
* **SABnzbd**: Usenet client
* **Prowlarr**: Indexer aggregator for torrents and usenet
* **Radarr**: Movie automation client
* **Sonarr**: TV automation client
* **Requestrr**: Discord bot for easily requesting media away from your LAN
* **Grafana / Prometheus**: Server monitoring (CPU, memory, network, per-disk SMART health, SnapRAID status) with 365 days of history

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

## Monitoring
Prometheus scrapes `node-exporter` (host stats) and `smartctl-exporter` (SMART data) and keeps 365 days of history in `/host/prometheus` (~4 GB/year). Grafana is at `http://grafana.home.arpa` (first login `admin`/`admin`), with the Prometheus data source provisioned automatically.

One-time host setup:
```
sudo mkdir -p /host/prometheus /host/grafana && sudo chown 1000:1000 /host/prometheus /host/grafana
# Let Prometheus (docker bridge) reach node-exporter on the host
sudo ufw allow from 172.16.0.0/12 to any port 9100 proto tcp
```

`scripts/snapraid-nightly.sh` writes `snapraid_*` metrics to `/var/lib/node_exporter/snapraid.prom` after each run, which the dashboard and alerts use.

The *Disk Health* dashboard (SMART status, temperatures, SATA sector counts, SAS grown defects/ECC errors, SnapRAID sync status) is provisioned from `grafana/provisioning/dashboards/json/disk-health.json` and appears automatically on a fresh deploy. Changes made in the Grafana UI are only stored in Grafana's database and are overwritten whenever the JSON file changes. To keep a UI edit, export it (*Dashboard > Export > Export as JSON*, with "Export for sharing externally" off) and replace the file in the repo.

Suggested host dashboard: *Node Exporter Full* (grafana.com ID 1860) via *Dashboards > New > Import*.

### Alerting
Grafana alerts are provisioned from `grafana/provisioning/alerting/`: rules (`rules.yml`), destinations (`contact-points.yml`), routing and repeat intervals (`policies.yml`) and the Discord message format (`templates.yml`). They are read-only in the Grafana UI; edit the files and run `docker compose restart grafana`.

* **Discord** receives the alerts: critical alerts repeat every 4 hours while firing, warnings once a day, plus a message when each clears.
* **healthchecks.io** is a dead-man's switch. An always-firing *Heartbeat* alert pings it every ~5 minutes; if the pings stop (server down, internet down, Grafana or Prometheus broken), healthchecks.io notifies you.

Both URLs are Docker secrets, like the VPN credentials, and must exist before Grafana will start:
1. Discord: *Server Settings > Integrations > Webhooks > New Webhook*, pick a channel, copy the URL.
2. healthchecks.io: create a check with *Period* 5 minutes and *Grace* 10 minutes, copy its ping URL (`https://hc-ping.com/...`), and add the notification method you want under *Integrations*.
3. Save them:
   ```
   echo 'https://discord.com/api/webhooks/...' | sudo tee /host/discord_webhook.txt >/dev/null
   echo 'https://hc-ping.com/...' | sudo tee /host/healthchecks_url.txt >/dev/null
   sudo chown 1000:1000 /host/discord_webhook.txt /host/healthchecks_url.txt
   sudo chmod 600 /host/discord_webhook.txt /host/healthchecks_url.txt
   ```

## Maintenance
Updates are automatic; you're only notified when something fails.

* **OS security updates** install daily via Ubuntu's `unattended-upgrades`.
* **`scripts/weekly-maintenance.sh`** runs Wednesdays at 11:00 (after the 03:00 SnapRAID run, waiting for it if it's still going). It installs remaining OS updates, pulls and recreates updated containers, checks every container is running, prunes old images and logs, and reboots if an update requires it.
* It reports to its own healthchecks.io check: silent on success, alerts on failure (including the end of its log) or if a run is missed. Full logs are in `logs/maintenance-*.log`.
* Prometheus (`v3`) and Grafana (`13.2`) are pinned so the monitoring stack doesn't take major upgrades unattended; bump those tags by hand. Everything else tracks `latest`.
* To roll back a bad container update, pin the app's previous version tag in `docker-compose.yml` and run `docker compose up -d`.
* **Hooks:** other projects on the machine can join the weekly run without this repo knowing about them. Put an executable (or a symlink to one) in `/etc/weekly-maintenance.d/`. Hooks run as root in name order, after this repo's containers update and before any reboot. A failing hook is reported but doesn't stop the rest of the run.

One-time host setup:
1. In healthchecks.io, create a second check with *Period* 7 days and *Grace* 1 day.
2. As root:
   ```
   # Refresh package lists daily so security updates apply within a day
   sed -i 's/Update-Package-Lists "7"/Update-Package-Lists "1"/' /etc/apt/apt.conf.d/20auto-upgrades
   echo 'https://hc-ping.com/...' > /host/healthchecks_maintenance_url.txt
   chmod 600 /host/healthchecks_maintenance_url.txt
   # Root crontab (crontab -e), alongside the SnapRAID entry:
   # 0 11 * * 3 /home/steve/server/scripts/weekly-maintenance.sh
   ```
