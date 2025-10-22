# 🚀 Automated Deployment Script

A production-ready Bash script that automates the setup, deployment, and configuration of Dockerized applications on remote Linux servers — built for HNG13 Stage 1 (DevOps Track).

## 🔧 Features

* 🔐 Secure SSH-based deployment
* 🐳 Docker & Docker Compose support
* 🌐 Automatic Nginx reverse proxy setup
* 🧾 Detailed logging and error handling
* 🔁 Idempotent operations (safe to re-run)
* 🧹 Cleanup option for full teardown

## 🧰 Prerequisites

### On Your Local Machine

* Bash 4.0+
* Git
* SSH client configured
* Executable permissions for `deploy.sh`

### On the Remote Server

* Ubuntu 18.04+ or CentOS 7+
* SSH access with `sudo` privileges
* Internet connectivity

## ⚙️ Usage

### 1. Make the script executable

```bash
chmod +x deploy.sh
```

### 2. Run the deployment

```bash
./deploy.sh
```

### 3. Follow the prompts

You’ll be asked to provide:

* Git repository URL (HTTPS)
* Personal Access Token (PAT)
* Branch name (default: `main`)
* SSH username, server IP, and SSH key path
* Application port (internal container port)

---

✅ **Tip:** You can safely re-run this script — it checks for existing containers, images, and Nginx configs before redeploying.

