# Zabbix 7.0 LTS — Server

**Instance:** `zabbix-server` · t3.medium · Ubuntu 24.04 · Public subnet · EIP attached  
**Listens on:** TCP 8080 (Web UI) · TCP 10051 (proxy check-in, agent data)  
**Database:** PostgreSQL 16 (local)

---

## Automated Install

```bash
# 1. SSM into the server
aws ssm start-session --target <zabbix-server-instance-id> \
    --profile sarowar-ostad --region ap-south-1

# 2. Clone repo and run
sudo -s
git clone https://github.com/sarowar-alam/zabbix-monitoring-end-to-end.git
cd zabbix-monitoring-end-to-end
bash 01-zabbix-server/install-server.sh 'YourPassword'
```

The script handles all steps idempotently — safe to re-run.

---

## Manual Install

### Step 1 — System Update

```bash
sudo -s
export DEBIAN_FRONTEND=noninteractive
apt-get update -y && apt-get upgrade -y
```

### Step 2 — Install PostgreSQL

```bash
apt-get install -y postgresql postgresql-contrib
systemctl enable postgresql && systemctl start postgresql
```

### Step 3 — Create Database User and Database

```bash
sudo -u postgres psql <<'PSQL'
CREATE USER zabbix WITH PASSWORD 'YourPassword';
CREATE DATABASE zabbix OWNER zabbix;
PSQL
```

### Step 4 — Add Zabbix 7.0 Repository

```bash
wget -q https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu24.04_all.deb \
     -O /tmp/zabbix-release.deb
dpkg -i /tmp/zabbix-release.deb
apt-get update -y
```

### Step 5 — Install Packages

```bash
apt-get install -y \
  zabbix-server-pgsql \
  zabbix-frontend-php \
  php8.3-pgsql \
  zabbix-nginx-conf \
  zabbix-sql-scripts \
  zabbix-agent \
  zabbix-sender
```

### Step 6 — Import Database Schema

```bash
zcat /usr/share/zabbix-sql-scripts/postgresql/server.sql.gz | sudo -u zabbix psql zabbix
```

### Step 7 — Write `/etc/zabbix/zabbix_server.conf`

Replace the entire file with the content below.  
Substitute `YourPassword` with your actual DB password.

```bash
cat > /etc/zabbix/zabbix_server.conf <<'EOF'
# Zabbix Server 7.0 — /etc/zabbix/zabbix_server.conf

# ── Database ──────────────────────────────────────────────────────────────────
DBHost=localhost
DBName=zabbix
DBUser=zabbix
DBPassword=YourPassword

# ── Network ───────────────────────────────────────────────────────────────────
ListenPort=10051
ListenIP=0.0.0.0

# ── Logging ───────────────────────────────────────────────────────────────────
LogFile=/var/log/zabbix/zabbix_server.log
LogFileSize=0
PidFile=/run/zabbix/zabbix_server.pid
SocketDir=/run/zabbix

# ── Performance ───────────────────────────────────────────────────────────────
StartPollers=5
StartTrappers=5
StartPingers=1
StartDiscoverers=1
CacheSize=8M
HistoryCacheSize=16M
TrendCacheSize=4M

# ── Timeouts & Paths ──────────────────────────────────────────────────────────
Timeout=4
FpingLocation=/usr/bin/fping
Fping6Location=/usr/bin/fping6
LogSlowQueries=3000
SNMPTrapperFile=/var/log/snmptrap/snmptrap.log
StatsAllowedIP=127.0.0.1

# ── Include ───────────────────────────────────────────────────────────────────
Include=/etc/zabbix/zabbix_server.conf.d/*.conf
EOF
```

### Step 8 — Write `/etc/zabbix/nginx.conf`

```bash
PRIVATE_IP=$(hostname -I | awk '{print $1}')

cat > /etc/zabbix/nginx.conf <<EOF
server {
        listen          8080;
        server_name     ${PRIVATE_IP};

        root    /usr/share/zabbix;

        index   index.php;

        location = /favicon.ico {
                log_not_found   off;
        }

        location / {
                try_files       \$uri \$uri/ =404;
        }

        location /assets {
                access_log      off;
                expires         10d;
        }

        location ~ /\.ht {
                deny            all;
        }

        location ~ /(api\/|conf[^\.]|include|locale) {
                deny            all;
                return          404;
        }

        location /vendor {
                deny            all;
                return          404;
        }

        location ~ [^/]\.php(/|$) {
                fastcgi_pass    unix:/var/run/php/zabbix.sock;
                fastcgi_split_path_info ^(.+\.php)(/.+)$;
                fastcgi_index   index.php;

                fastcgi_param   DOCUMENT_ROOT   /usr/share/zabbix;
                fastcgi_param   SCRIPT_FILENAME /usr/share/zabbix\$fastcgi_script_name;
                fastcgi_param   PATH_TRANSLATED /usr/share/zabbix\$fastcgi_script_name;

                include fastcgi_params;
                fastcgi_param   QUERY_STRING    \$query_string;
                fastcgi_param   REQUEST_METHOD  \$request_method;
                fastcgi_param   CONTENT_TYPE    \$content_type;
                fastcgi_param   CONTENT_LENGTH  \$content_length;

                fastcgi_intercept_errors        on;
                fastcgi_ignore_client_abort     off;
                fastcgi_connect_timeout         60;
                fastcgi_send_timeout            180;
                fastcgi_read_timeout            180;
                fastcgi_buffer_size             128k;
                fastcgi_buffers                 4 256k;
                fastcgi_busy_buffers_size       256k;
                fastcgi_temp_file_write_size    256k;
        }
}
EOF

rm -f /etc/nginx/sites-enabled/default
```

### Step 9 — Enable and Start Services

```bash
systemctl enable  zabbix-server zabbix-agent nginx php8.3-fpm
systemctl restart zabbix-server zabbix-agent nginx php8.3-fpm
```

### Step 10 — Verify

```bash
for svc in zabbix-server zabbix-agent nginx php8.3-fpm; do
  systemctl is-active --quiet "$svc" && echo "[OK] $svc" || echo "[!!] $svc FAILED"
done

# Check server log for errors
tail -20 /var/log/zabbix/zabbix_server.log
```

---

## Web Setup Wizard

Open `http://<EIP>:8080` in your browser and complete the 7-step wizard:

| Step | Value |
|------|-------|
| Database type | PostgreSQL |
| Database host | `localhost` |
| Database port | `0` (default 5432) |
| Database name | `zabbix` |
| User | `zabbix` |
| Password | `YourPassword` |
| Zabbix server host | `localhost` |
| Zabbix server port | `10051` |
| Timezone | `Asia/Kolkata` |

**Login:** `Admin` / `zabbix` — **change the password immediately.**

---

## Troubleshooting

```bash
# Server not starting
journalctl -u zabbix-server -n 50

# Database connection refused
sudo -u postgres psql -c "\l"           # list databases
sudo -u postgres psql -c "\du"          # list users

# Nginx port conflict
nginx -t                                 # test config
ss -tlnp | grep 8080                    # check who owns port 8080

# PHP-FPM socket missing
ls -la /var/run/php/zabbix.sock
```

---

## Files in This Directory

| File | Purpose |
|------|---------|
| `install-server.sh` | Automated install script (idempotent) |
| `zabbix_server.conf.template` | Config template with placeholders |
| `nginx.conf.template` | Nginx config template |
