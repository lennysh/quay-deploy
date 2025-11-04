# Quay Rootless Podman Deployment

This repository provides a set of shell scripts to automate the deployment of a Project Quay container registry on a rootless Podman host.

It automatically sets up Quay with dependent Postgres and Redis containers, runs them on a dedicated network, and applies necessary patches to the configuration for compatibility with modern Postgres versions.

This setup is based on the original Quay Podman guide but is fully automated and configured to run rootlessly.

## Features

* **Rootless:** Runs entirely as a non-root user using Podman.
* **Automated:** Sets up Postgres (v15), Redis, and Quay.
* **Patched:** Automatically removes incompatible settings from the generated `config.yaml` (e.g., `keepalivescount`, `keepalivesidle`) that cause errors with modern Postgres.
* **Networked:** Creates a dedicated `quay-net` podman network for clean container communication using hostnames (`postgresql`, `redis`).
* **Separated Config:** All user-configurable variables (passwords, paths) are stored in `quay.env`.

## Prerequisites

Before you begin, ensure you have the following tools installed:
* `podman`
* `sed`

## 1. Initial Setup & Installation

1.  **Clone the Repository**
    ```bash
    git clone https://github.com/lennysh/quay-deploy.git
    cd quay-deploy
    ```

2.  **Configure Passwords**
    The `quay.env` file holds all your configuration. You **must** edit this file and set your own passwords.

    ```bash
    # Edit the file with your preferred editor
    nano quay.env
    ```

    Inside `quay.env`, replace both `REPLACEME` values for `PG_PASS` and `REDIS_PASS` with strong, unique passwords.

3.  **Make Scripts Executable**
    ```bash
    chmod +x install.sh start.sh
    ```

4.  **Run the Installation Script**
    This script will set up directories, start the database and cache, and then pause for the manual Quay configuration.

    ```bash
    ./install.sh
    ```

5.  **Follow the MANUAL ACTION REQUIRED**
    The `install.sh` script will pause and prompt you to perform the web UI setup. **Follow these on-screen instructions exactly.**

    You will be asked to:
    * **Run a `podman run ...` command** in a **separate terminal** to start the config tool.
    * **Open `http://localhost:8080`** in your browser.
    * **Log in** with `quayconfig` / `secret`.
    * **Enter Database Settings:**
        * Host: `postgresql`
        * User: `quay` (or your value from `PG_USER`)
        * Password: (Your password from `PG_PASS`)
        * Database: `quay` (or your value from `PG_DB`)
    * **Enter Redis Settings:**
        * Hostname: `redis`
        * Password: (Your password from `REDIS_PASS`)
    * **Create your Super User** account.
    * **Download the `quay-config.tar.gz` file** and save it to the *exact path* shown in the script's output (e.g., `/home/user/quay-deploy/config/quay-config.tar.gz`).
    * **Stop the config container** (Ctrl+C) in your second terminal.
    * **Press [Enter]** in the original `install.sh` terminal.

The script will then automatically unpack, patch, and start your Quay registry.

## 2. Managing the Quay Service

### Stopping Quay
To stop all containers:
```bash
podman stop quay postgresql redis
```

### Starting Quay
To restart the environment after it has been stopped:
```bash
./start.sh
```

This script uses `--replace` to safely remove any old, stopped containers before starting new ones. It also performs health checks to ensure Postgres and Redis are ready before starting Quay.

## 3. Full Cleanup

To completely remove all containers, data, and network configuration:

```bash
# Stop all running containers (if any)
podman stop quay postgresql redis || true

# Remove the podman network
podman network rm quay-net

# Source the env file to get the $QUAY path
source quay.env

# WARNING: This permanently deletes all Quay data, images, and config
echo "This will delete everything in $QUAY. Press Ctrl+C to cancel."
sleep 5
rm -rf $QUAY
```