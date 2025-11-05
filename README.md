# Quay Rootless Podman Deployment

This repository provides a set of shell scripts to automate the deployment of a Project Quay container registry on a rootless Podman host.

It automatically sets up Quay with dependent Postgres and Redis containers, runs them on a dedicated network, and applies necessary patches to the configuration for compatibility with modern Postgres versions.

This setup is designed to be persistent using **systemd Quadlets** and **static IPs** to ensure stability after reboots.

## Features

* **Rootless:** Runs entirely as a non-root user using Podman.
* **Persistent:** Uses `systemd` Quadlets to manage services and start them on boot.
* **Static IPs:** Assigns static IPs to database and cache containers to prevent breakage on reboot, as hostname resolution may not work in all rootless environments.
* **Single-Script Install:** A single script handles environment prep, dependency startup, and the main Quay installation.
* **Patched:** Automatically removes incompatible settings from the generated `config.yaml` (e.g., `keepalivescount`, `keepalivesidle`).
* **Networked:** Creates a dedicated `quay-net` podman network with a defined subnet.
* **Separated Config:** All user-configurable variables (passwords, paths, IPs) are stored in `quay.env`.

## Prerequisites

Before you begin, ensure you have the following tools installed:
* `podman`
* `sed`

## Installation

1.  **Clone the Repository**
    ```bash
    git clone [https://github.com/lennysh/quay-deploy.git](https://github.com/lennysh/quay-deploy.git)
    cd quay-deploy
    ```

2.  **Configure Passwords and IPs**
    Copy the example config and edit it to set your passwords. The default IPs (`10.90.0.10`, `10.90.0.11`) should be fine unless they conflict with your network.
    ```bash
    cp quay.env.example quay.env
    nano quay.env
    ```
    Inside `quay.env`, replace both `REPLACEME` values for `PG_PASS` and `REDIS_PASS`.

3.  **Make Scripts Executable**
    ```bash
    chmod +x install-persistent.sh uninstall.sh
    ```

4.  **Run the Installation Script**
    This is the only script you need to run for setup. It will install and enable all persistent services.
    ```bash
    ./install-persistent.sh
    ```

5.  **Follow the MANUAL ACTION REQUIRED**
    The script will pause and prompt you to perform the web UI setup. **Follow these on-screen instructions exactly.**

    You will be asked to:
    * **Run a `podman run ...` command** in a **separate terminal** to start the config tool.
    * **Open `http://localhost:8080`** in your browser.
    * **Log in** with `quayconfig` / `secret`.
    * **Enter Database Settings (Use Static IPs):**
        * Host: `10.90.0.10` (or your value from `PG_IP`)
        * User: `quay` (or your value from `PG_USER`)
        * Password: (Your password from `PG_PASS`)
        * Database: `quay` (or your value from `PG_DB`)
    * **Enter Redis Settings (Use Static IPs):**
        * Hostname: `10.90.0.11` (or your value from `REDIS_IP`)
        * Password: (Your password from `REDIS_PASS`)
    * **Create your Super User** account.
    * **Download the `quay-config.tar.gz` file** and save it to the *exact path* shown in the script's output (e.g., `/home/user/quay-deploy/config/quay-config.tar.gz`).
    * **Stop the config container** (Ctrl+C) in your second terminal.
    * **Press [Enter]** in the original `install-persistent.sh` terminal.

6.  **Enable Linger (One Time Only)**
    After the script succeeds, run the command it gives you to allow your services to start at boot:
    ```bash
    loginctl enable-linger $(whoami)
    ```

## Managing the Quay Service

All services are now managed by `systemd`.

* **Check Status:**
    ```bash
    systemctl --user status quay-quay.service quay-postgres.service quay-redis.service
    ```
* **Stop Services:**
    ```bash
    systemctl --user stop quay-quay.service quay-postgres.service quay-redis.service
    ```
* **Start Services:**
    ```bash
    systemctl --user start quay-quay.service
    ```

## Full Cleanup

To completely remove all containers, data, and `systemd` files, use the `uninstall.sh` script.

```bash
./uninstall.sh
```
