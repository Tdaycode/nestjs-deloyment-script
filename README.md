# 🚀 NestJS Backend Deployment on AWS EC2 (Automation Script)

A production‑ready Bash script that deploys a NestJS (or any Node.js) backend to an Ubuntu EC2 instance with:

* **Node.js via NVM** (version you choose)
* **PM2** process manager (autostart on boot)
* **Nginx** reverse proxy (HTTP → backend)
* **TLS/SSL** with Let’s Encrypt (Certbot)
* **CORS**, **security headers**, **gzip**, and **rate limiting**
* One‑command **update** & **monitoring** helpers

> **Author:** Omotayo · **Version:** 1.0

---

## 📚 Table of Contents

* [Why this script?](#-why-this-script)
* [Architecture at a glance](#-architecture-at-a-glance)
* [Prerequisites](#-prerequisites)
* [Server preparation (once)](#-server-preparation-once)
* [Clone & run the script](#-clone--run-the-script)
* [What the script asks you (prompts explained)](#-what-the-script-asks-you-prompts-explained)
* [What the script sets up](#-what-the-script-sets-up)
* [Post‑deployment commands](#-post-deployment-commands)
* [Environment variables / .env](#-environment-variables--env)
* [Nginx details (CORS, rate limits, health)](#-nginx-details-cors-rate-limits-health)
* [SSL/TLS with Let’s Encrypt](#-ssltls-with-lets-encrypt)
* [Logs & monitoring](#-logs--monitoring)
* [Updating your backend](#-updating-your-backend)
* [Rollback & zero‑downtime tips](#-rollback--zero-downtime-tips)
* [Multiple apps on one server](#-multiple-apps-on-one-server)
* [Security notes & hardening](#-security-notes--hardening)
* [Troubleshooting](#-troubleshooting)
* [FAQ](#-faq)
* [License](#-license)

---

## 💡 Why this script?

Manually wiring Node.js + PM2 + Nginx + SSL on a fresh EC2 box is repetitive and error‑prone. This script automates the boring parts but keeps things transparent and easy to tweak. You’ll go from **fresh EC2** to **live HTTPS API** in minutes.

---

## 🧩 Architecture at a glance

```
Client (HTTPS)
     │
     ▼
┌──────────┐      reverse proxy      ┌────────────────────────┐
│  Nginx   │  ───────────────────▶   │  Node.js (NestJS) API │
│ :80/:443 │                          │  running under PM2    │
└──────────┘      TLS via Certbot    └────────────────────────┘
        │                                  │
        └──────────── Logs & Metrics ◀─────┘
```

---

## ✅ Prerequisites

* **EC2 instance**: Ubuntu 20.04+ recommended (t2.micro works for small apps).
* **Public IP** (or Elastic IP) and **Security Group** allowing ports **22**, **80**, **443**.
* **Domain name** with an **A record** pointing to your server (e.g. `api.example.com`).
* **Non‑root sudo user** (script refuses to run as `root`).
* **Your API code in a Git repo** (GitHub/GitLab/Bitbucket).

> **Heads‑up:** If you use Cloudflare, temporarily set DNS to **DNS‑only** (grey cloud) when issuing the certificate so HTTP validation can pass.

---

## 🛠 Server preparation (once)

SSH into the server with your key, then:

```bash
# 1) Create a non-root user (if you don’t have one yet)
sudo adduser deployer
sudo usermod -aG sudo deployer
# (Optional) Allow passwordless sudo for convenience (decide per your policy)
# echo 'deployer ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-deployer

# 2) Switch to that user
su - deployer

# 3) Install base packages (if not already present)
sudo apt update
sudo apt install -y git curl nginx certbot python3-certbot-nginx
```

---

## ⬇️ Clone & run the script

```bash
git clone https://github.com/Tdaycode/nestjs-deloyment-script.git
cd <nestjs-deloyment-script>
chmod +x deploy-backend.sh
./deploy-backend.sh
```

The script is **interactive**. It will prompt for domain, repo URL, Node version, etc.

---

## ❓ What the script asks you (prompts explained)

* **API Domain**: e.g. `api.example.com` or `example.com` (regex enforces valid FQDN; supports subdomains of any depth).
* **Node.js Version**: default `18`. The script installs & selects it via **NVM**.
* **Package Manager**: `npm`, `yarn`, or `pnpm`.
* **App Name**: used for PM2 process and folder naming (spaces become `_`).
* **Git Repository URL**: your backend repo (HTTPS or SSH URL).
* **Branch**: default `main`.
* **Backend Port**: default `3000` (your app must listen on this).
* **Backend Folder** (optional): if your repo is a monorepo, set subfolder path.
* **Database Setup?**: if yes, script can run migrations (`migration:run` script).
* **Environment Variables?**: if yes, script generates a `.env` scaffold or copies `.env.example`.
* **API Path Prefix**: default `/api` (Nginx proxies this path to your app).
* **Frontend Domain (CORS)**: optional (e.g. `app.example.com`).
* **SSL Email**: for Let’s Encrypt notifications.

---

## 🧰 What the script sets up

* **Node.js + NVM** (installs if missing; activates selected version).
* **Package manager** (installs `yarn`/`pnpm` globally if chosen).
* **PM2** global install and **startup on boot**.
* **Project checkout** → `/home/<user>/apps/<app_name>` (cleans existing folder if present).
* **Build** using your package manager, then **PM2 app** started from `dist/main.js`.
* **Nginx site** at `/etc/nginx/sites-available/<domain>` and enabled via symlink.
* **Global rate‑limit zone** in `/etc/nginx/conf.d/limits.conf`:

  ```nginx
  limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
  ```

  Used inside your site as:

  ```nginx
  location /api { limit_req zone=api burst=20 nodelay; ... }
  ```
* **Helper scripts** in your deploy dir:

  * `update-backend.sh` – pulls latest, installs deps, builds, restarts PM2.
  * `monitor-backend.sh` – quick status, logs, disk/memory, health, nginx/ssl info.

> **Note on PM2 interpreter:** The script no longer hardcodes an interpreter path. PM2 uses whatever `node` NVM has set in PATH.

---

## ▶️ Post‑deployment commands

```bash
# PM2 process info
pm2 show <app-name>-backend

# View app logs (stream)
pm2 logs <app-name>-backend

# Hit health route
curl -i https://<your-domain>/health
curl -i https://<your-domain><API_PREFIX>
```

---

## 🔐 Environment variables / .env

If you said **Yes** to env vars, the script will:

* Copy `.env.example` → `.env` *or* create a minimal `.env` scaffold.
* Add `CORS_ORIGIN=https://<frontend-domain>` if you provided one.

Example scaffold the script may generate:

```env
NODE_ENV=production
PORT=3000

# DATABASE_URL=postgresql://user:pass@host:5432/db
# JWT_SECRET=super-secret
# JWT_EXPIRES_IN=7d
# API_KEY=
# EXTERNAL_SERVICE_URL=
# CORS_ORIGIN=https://app.example.com
```

> Ensure your NestJS app actually **reads from `.env`** (e.g. via `@nestjs/config` or `dotenv`).

---

## 🌐 Nginx details (CORS, rate limits, health)

* **Path prefix**: only requests under your `API_PREFIX` (default `/api`) are proxied to Node.
* **CORS**: if you provided a frontend domain, Nginx adds the necessary CORS headers (including handling `OPTIONS`).
* **Security headers**: `X-Frame-Options`, `X-Content-Type-Options`, basic CSP, etc.
* **Gzip**: enabled for common types.
* **Rate limiting**: uses `limit_req_zone` defined globally; enables per‑client rate limiting on the API location.
* **Health**: `location /health` proxies to your backend. Make sure your app serves it.

**Where files live**

* Site: `/etc/nginx/sites-available/<domain>` → symlinked to `sites-enabled/`
* Rate limit zone: `/etc/nginx/conf.d/limits.conf`

**Useful commands**

```bash
sudo nginx -t          # test config
sudo systemctl reload nginx
sudo tail -n 200 /var/log/nginx/error.log
```

---

## 🔒 SSL/TLS with Let’s Encrypt

The script includes a step that can obtain a certificate via Certbot (non‑interactive) **after** the HTTP site is online:

```bash
sudo certbot --nginx -d <your-domain> --email <your-email> --agree-tos --non-interactive
sudo certbot renew --dry-run
```

> Make sure your domain resolves to the server and port **80** is reachable. If using Cloudflare, use **DNS‑only** while issuing the cert.

---

## 📈 Logs & monitoring

* **PM2 logs**: stored under your app path `logs/` (err/out/combined). View with `pm2 logs`.
* **Nginx logs**: `/var/log/nginx/access.log`, `/var/log/nginx/error.log`.
* **System**: `free -h`, `df -h`, `top`/`htop`.

`monitor-backend.sh` prints a compact status report and runs a health check against `https://<domain>/health`.

---

## 🔁 Updating your backend

From your deploy directory:

```bash
./update-backend.sh
```

This runs: `git pull`, dependency install, build, and `pm2 restart <app>-backend`.

> **Tip:** For smoother updates, consider `pm2 reload` if your app supports graceful shutdown.

---

## 🧪 Rollback & zero‑downtime tips

* **PM2 ecosystem**: keep previous builds (e.g., with tags or commit hashes) so you can rollback quickly.
* **Blue/Green**: run a second PM2 process on another port, switch Nginx upstream, then stop the old one.
* **pm2 save/list**: snapshot and list processes to restore after reboot.

---

## 🧳 Multiple apps on one server

Repeat deployments with different **domains** and **ports**:

* Each app uses a unique `server_name` and backend **port**.
* PM2 process names are derived from your chosen **App Name**.
* Nginx gets an additional site file per domain.

> If you want two apps under the same domain (e.g., `/api` and `/admin`), add another `location` block in your Nginx site that proxies to a different port.

---

## 🛡 Security notes & hardening

* Script **refuses to run as root**; use a non‑root sudo user.
* Keep Ubuntu updated: `sudo apt update && sudo apt upgrade -y`.
* Consider enabling **UFW firewall**:

  ```bash
  sudo ufw allow OpenSSH
  sudo ufw allow 80
  sudo ufw allow 443
  sudo ufw enable
  ```
* Use **fail2ban** for SSH/Nginx brute‑force protection.
* Rotate and secure your `.env`/secrets (don’t commit to Git!).
* Enable **auto‑renew** for certificates (Certbot timer is installed by default).

---

## 🧰 Troubleshooting

### PM2 interpreter not found

```
[PM2][ERROR] Interpreter /home/ubuntu/.nvm/versions/node/v20*/bin/node is NOT AVAILABLE in PATH.
```

**Cause:** wildcard path in PM2 interpreter.
**Fix:** The script now avoids hardcoding an interpreter. If you edited manually, set:

```js
// in ecosystem.config.js
// interpreter: 'node'  // or remove the line entirely
```

Ensure PM2 is installed under the active Node version:

```bash
nvm use <version>
npm i -g pm2
```

### Nginx permission denied when writing site file

```
Permission denied: /etc/nginx/sites-available/<domain>
```

**Cause:** writing to `/etc` without sudo.
**Fix:** Script writes config to `/tmp` then moves it with `sudo mv`.

### `limit_req_zone` directive is not allowed here

**Cause:** `limit_req_zone` placed inside `server {}`.
**Fix:** Script writes it to `/etc/nginx/conf.d/limits.conf` (global). Use `limit_req` only inside locations.

### Certbot/SSL fails

* Ensure DNS A record resolves to server’s public IP.
* Port **80** must be open (Security Group + any firewall).
* If using Cloudflare, set DNS to **DNS‑only** during issuance.
* Check logs: `sudo tail -n 200 /var/log/nginx/error.log` and `/var/log/letsencrypt/letsencrypt.log`.

### 502/504 from Nginx

* App not listening on the configured port? (`ss -lnt | grep <port>`)
* Increase proxy timeouts in the site file if needed.

---

## ❓ FAQ

**Q: Does this only work for NestJS?**
A: It targets a Node.js build output at `dist/main.js`. Any Node app with a build/start script can work.

**Q: Where is my app deployed?**
A: `/home/<user>/apps/<app-name>` (or a subfolder if you specified a monorepo path).

**Q: Can I skip SSL?**
A: Yes. You can run HTTP first. The script has a step to obtain SSL when ready.

**Q: How do I change the API prefix?**
A: Re‑run the script or edit your Nginx site: change `location /api` to your prefix and `sudo systemctl reload nginx`.

**Q: Can I add basic auth to my API quickly?**
A: Yes—add an `auth_basic` / `auth_basic_user_file` block to your API `location` in the Nginx site.

---

## 📄 License

MIT — feel free to fork and adapt for your team.

---

## 🙌 Credits & Contributions

PRs and issues welcome! If this saved you time, a ⭐ on the repo would be amazing.
