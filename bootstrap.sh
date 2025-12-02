#!/usr/bin/env bash
set -euo pipefail

# Pragmatic bootstrap script for freshly provisioned Ubuntu 24.x machines.
# Tasks: install PostgreSQL/PostGIS, create superuser role/database, ensure swap, lock down UFW.
# Copy to target machine and run like this: 
# > sudo ./bootstrap.sh -r app_user -p 'S3cureP@ss' -d app_db

PG_ROLE=""
PG_PASSWORD=""
PG_DATABASE=""
SWAP_TARGET_BYTES=$((2 * 1024 * 1024 * 1024)) # 2 GiB

usage() {
	cat <<EOF
Usage: sudo ./bootstrap.sh -r <pg_role> -p <pg_password> -d <pg_database>

Required parameters:
	-r  PostgreSQL login role/user to create or update
	-p  Password for the role (will be set even if role exists)
	-d  Database name to create with PostGIS enabled

The script must run as root (sudo) and assumes outbound internet access.
EOF
	exit 1
}

log() {
	echo "[$(date --iso-8601=seconds)] $*"
}

# Escape a value to use as a single-quoted SQL literal: 'foo' -> 'foo', "O'Reilly" -> 'O''Reilly'
sql_escape_literal() {
	local input
	input=$(printf "%s" "$1" | sed "s/'/''/g")
	printf "'%s'" "$input"
}

# Escape a value to use as a double-quoted SQL identifier: foo -> "foo", my"user -> "my""user"
sql_escape_identifier() {
	local input
	input=$(printf "%s" "$1" | sed 's/"/""/g')
	printf '"%s"' "$input"
}

require_root() {
	if [[ $EUID -ne 0 ]]; then
		echo "This script must run as root (use sudo)." >&2
		exit 1
	fi
}

parse_args() {
	while getopts "r:p:d:h" opt; do
		case "$opt" in
			r) PG_ROLE="$OPTARG" ;;
			p) PG_PASSWORD="$OPTARG" ;;
			d) PG_DATABASE="$OPTARG" ;;
			h|*) usage ;;
		esac
	done

	if [[ -z "$PG_ROLE" || -z "$PG_PASSWORD" || -z "$PG_DATABASE" ]]; then
		echo "Missing required parameters." >&2
		usage
	fi
}

install_postgres() {
	log "Refreshing apt cache and installing PostgreSQL/PostGIS packages..."
	apt-get update
	DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-contrib postgis ufw
	systemctl enable --now postgresql
}

# Configure PostgreSQL to:
# - listen on all interfaces (ALTER SYSTEM SET listen_addresses = '*')
# - allow IPv4 connections from anywhere in pg_hba.conf (0.0.0.0/0 md5)
# Paths for config_file and hba_file are derived dynamically via SHOW.
configure_postgres_remote() {
	log "Configuring PostgreSQL for remote access..."

	# Get paths from PostgreSQL itself
	local config_file hba_file
	config_file=$(sudo -u postgres psql -Atc "SHOW config_file" || echo "")
	hba_file=$(sudo -u postgres psql -Atc "SHOW hba_file" || echo "")

	if [[ -z "$config_file" || -z "$hba_file" ]]; then
		log "WARNING: Could not determine config_file or hba_file via psql; skipping remote config."
		return
	fi

	log "PostgreSQL config_file reported as: $config_file"
	log "PostgreSQL hba_file reported as: $hba_file"

	# 1) Use ALTER SYSTEM to set listen_addresses (writes to postgresql.auto.conf)
	log "Setting listen_addresses = '*' via ALTER SYSTEM..."
	sudo -u postgres psql -c "ALTER SYSTEM SET listen_addresses = '*';"

	# 2) Ensure pg_hba.conf has a rule for all IPv4 addresses (for POC; tighten for prod)
	if [[ -f "$hba_file" ]]; then
		if ! grep -q "0.0.0.0/0" "$hba_file"; then
			log "Adding pg_hba.conf rule to allow IPv4 connections from anywhere (md5)..."
			echo "host    all             all             0.0.0.0/0               md5" | sudo tee -a "$hba_file" >/dev/null
		else
			log "pg_hba.conf already contains a rule for 0.0.0.0/0; leaving as-is."
		fi
	else
		log "WARNING: hba_file not found at $hba_file; cannot modify pg_hba.conf."
	fi

	# 3) Reload / restart PostgreSQL so changes take effect
	log "Restarting PostgreSQL to apply remote access settings..."
	systemctl restart postgresql
}

ensure_swap() {
    local swap_file="/swapfile"
	local target_mebibytes=$((SWAP_TARGET_BYTES / 1024 / 1024))

	if swapon --show=NAME --noheadings 2>/dev/null | grep -q .; then
		log "Existing swap detected; skipping swapfile provisioning."
		return
	fi

    log "Resetting swap configuration..."

    # Disable and remove any existing swapfile(s) or partitions
    swapoff -a 2>/dev/null || true

    # Remove any old /swapfile if present
    if [[ -f "$swap_file" ]]; then
        rm -f "$swap_file"
    fi

	log "Allocating new swapfile at $swap_file (${target_mebibytes} MiB)..."

    if ! fallocate -l "$SWAP_TARGET_BYTES" "$swap_file" 2>/dev/null; then
        log "fallocate unavailable; falling back to dd (this may take a bit)."
        dd if=/dev/zero of="$swap_file" bs=1M count=$((SWAP_TARGET_BYTES / 1024 / 1024)) status=progress
    fi

    chmod 600 "$swap_file"
    mkswap "$swap_file"
    swapon "$swap_file"

    # Ensure it persists across reboots
    if ! grep -qF "$swap_file" /etc/fstab; then
        echo "$swap_file none swap sw 0 0" >> /etc/fstab
    fi

	log "Swap setup complete. System now has swap at $swap_file."
}

configure_ufw() {
	log "Configuring uncomplicated firewall (UFW)..."
	ufw --force reset >/dev/null 2>&1 || true

	# Default policies
	ufw default deny incoming
	ufw default allow outgoing

	# Allow SSH so you don't lock yourself out
	ufw allow OpenSSH

	# Allow PostgreSQL
	ufw allow 5432/tcp comment 'PostgreSQL'

	# Enable firewall
	ufw --force enable

	log "UFW enabled: SSH (22/tcp) and PostgreSQL (5432/tcp) allowed; all other incoming traffic denied."
}

ensure_role_and_db() {
	log "Ensuring PostgreSQL SUPERUSER role '$PG_ROLE' and database '$PG_DATABASE' exist..."

	# Prepare escaped values for SQL
	local role_literal password_literal db_literal role_ident db_ident
	role_literal=$(sql_escape_literal "$PG_ROLE")
	password_literal=$(sql_escape_literal "$PG_PASSWORD")
	db_literal=$(sql_escape_literal "$PG_DATABASE")
	role_ident=$(sql_escape_identifier "$PG_ROLE")
	db_ident=$(sql_escape_identifier "$PG_DATABASE")

	# 1) Role: create if missing, otherwise update password (and ensure SUPERUSER)
	if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = $role_literal" | grep -qx 1; then
		log "Role '$PG_ROLE' already exists; updating password and ensuring SUPERUSER..."
		sudo -u postgres psql -c "ALTER ROLE $role_ident WITH LOGIN SUPERUSER PASSWORD $password_literal;"
	else
		log "Creating SUPERUSER role '$PG_ROLE'..."
		sudo -u postgres psql -c "CREATE ROLE $role_ident WITH LOGIN SUPERUSER PASSWORD $password_literal;"
	fi

	# 2) Database: create if missing, otherwise update owner
	if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = $db_literal" | grep -qx 1; then
		log "Database '$PG_DATABASE' already exists; updating owner..."
		sudo -u postgres psql -c "ALTER DATABASE $db_ident OWNER TO $role_ident;"
	else
		log "Creating database '$PG_DATABASE' owned by '$PG_ROLE'..."
		sudo -u postgres psql -c "CREATE DATABASE $db_ident OWNER $role_ident ENCODING 'UTF8';"
	fi

	# 3) Enable PostGIS extensions
	log "Enabling PostGIS extensions on database '$PG_DATABASE'..."
	sudo -u postgres psql -d "$PG_DATABASE" <<'SQL'
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_topology;
SQL

	log "Role and database provisioning complete."
}

main() {
	require_root
	parse_args "$@"

	install_postgres
	configure_postgres_remote
	ensure_role_and_db
	ensure_swap
	configure_ufw

	cat <<EOF

All done!
- PostgreSQL/PostGIS installed and running with remote access enabled
- SUPERUSER role '$PG_ROLE' with dedicated database '$PG_DATABASE' ready
- Swap allocated
- UFW active: SSH (22/tcp) and PostgreSQL (5432/tcp) allowed, everything else incoming denied

Security note:
    * The role '$PG_ROLE' is a PostgreSQL SUPERUSER.
    * pg_hba.conf currently allows connections from any IPv4 address (0.0.0.0/0) using password auth.
      For anything beyond internal POC use, restrict allowed IPs and consider using a non-superuser.
EOF
}

main "$@"
