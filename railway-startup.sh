#!/bin/bash
#
# Railway wrapper around the official GeoServer image's own launcher.
#
# The image's ENTRYPOINT is ["bash", "/opt/startup.sh"]; the build copies the
# vendor's script to /opt/startup.real.sh and drops this one in its place, so the
# inherited ENTRYPOINT and CMD are untouched. Everything here runs as root, before
# the vendor script's chown + privilege drop.
#
# It does six things Railway needs and environment variables cannot express:
#
#   1. Sizes the JVM from the cgroup rather than from the 48-core, ~1 TB host.
#   2. Repairs POSTGRES_HOST when the ${{postgis.RAILWAY_PRIVATE_DOMAIN}}
#      reference renders empty, which it does on a first-ever deployment.
#   3. Seeds the data directory itself, so steps 4 and 5 cannot be overwritten
#      by the vendor script's own seeding.
#   4. Replaces the master password. The release data directory ships a fixed,
#      publicly known one, so without this every deployment shares a `root`
#      account credential that is published in the GeoServer source tree.
#   5. Applies the admin credentials once and then stops: the vendor's
#      update_credentials.sh rewrites users.xml and roles.xml from templates on
#      every boot, discarding any user or role the operator has since created.
#   6. Writes a default controlflow.properties, which GeoServer's own production
#      guidance calls for and no environment variable provides.
#
set -eo pipefail

log() { echo "[railway] $*"; }
die() { echo "[railway] FATAL: $*" >&2; exit 1; }

DATA_DIR="${GEOSERVER_DATA_DIR%/}"
WAR_DATA="${CATALINA_HOME}/webapps/geoserver/data"

# --- 1. Size the JVM from the cgroup -----------------------------------------
# The image bakes EXTRA_JAVA_OPTS="-Xms256m -Xmx1g"; match that literal exactly so
# a real operator override still wins (an unset test would never fire).
if [ -z "${EXTRA_JAVA_OPTS}" ] || [ "${EXTRA_JAVA_OPTS}" = "-Xms256m -Xmx1g" ]; then
  MEM_MAX="$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)"
  case "${MEM_MAX}" in ''|max|*[!0-9]*) MEM_MAX=2147483648 ;; esac
  HEAP_MB=$(( MEM_MAX * 70 / 100 / 1048576 ))
  [ "${HEAP_MB}" -lt 512 ] && HEAP_MB=512

  CPU_MAX="$(cat /sys/fs/cgroup/cpu.max 2>/dev/null || echo 'max 100000')"
  CPU_QUOTA="${CPU_MAX%% *}"
  CPU_PERIOD="${CPU_MAX##* }"
  case "${CPU_QUOTA}${CPU_PERIOD}" in
    *[!0-9]*) CPUS=0 ;;
    *)        CPUS=$(( (CPU_QUOTA + CPU_PERIOD - 1) / CPU_PERIOD )) ;;
  esac
  [ "${CPUS}" -lt 1 ] && CPUS=0

  EXTRA_JAVA_OPTS="-Xms512m -Xmx${HEAP_MB}m"
  # Railway does not narrow the CPU affinity mask, so availableProcessors() reads
  # the host's 48 cores and every GeoTools/JAI pool is sized for a machine that
  # is not there.
  [ "${CPUS}" -gt 0 ] && EXTRA_JAVA_OPTS="${EXTRA_JAVA_OPTS} -XX:ActiveProcessorCount=${CPUS}"
  export EXTRA_JAVA_OPTS
  log "sized from cgroup: EXTRA_JAVA_OPTS=${EXTRA_JAVA_OPTS}"
else
  log "EXTRA_JAVA_OPTS supplied by the operator; leaving it alone"
fi

# --- 2. Repair an empty cross-service reference -------------------------------
if [ "${POSTGRES_JNDI_ENABLED}" = "true" ]; then
  case "${POSTGRES_HOST}" in
    ''|:*|disabled)
      POSTGRES_HOST="postgis.railway.internal"
      log "POSTGRES_HOST was empty on this deployment; defaulted to ${POSTGRES_HOST}"
      ;;
  esac
  [ -n "${POSTGRES_PORT}" ] || POSTGRES_PORT=5432
  export POSTGRES_HOST POSTGRES_PORT
fi

# --- 3. Seed the data directory ----------------------------------------------
mkdir -p "${DATA_DIR}"

if [ "${SKIP_DEMO_DATA}" != "true" ] && [ ! -f "${DATA_DIR}/global.xml" ]; then
  log "seeding ${DATA_DIR} from the data directory bundled in geoserver.war"
  cp -r "${WAR_DATA}"/* "${DATA_DIR}/"
  [ -f "${DATA_DIR}/global.xml" ] || die "seeding left no global.xml in ${DATA_DIR}"
fi

if [ ! -d "${DATA_DIR}/security" ]; then
  log "seeding security configuration into ${DATA_DIR}"
  cp -r "${WAR_DATA}/security" "${DATA_DIR}/"
fi
[ -d "${DATA_DIR}/security" ] || die "no security directory in ${DATA_DIR}"

# --- 4. Master password (the `root` account) ----------------------------------
# data/release/security/masterpw/default/passwd in the GeoServer source tree is a
# fixed value encrypted under a key compiled into URLMasterPasswordProvider, so it
# is a shared default credential, not a secret. Replace it, storing the
# replacement in the plaintext form the same provider reads when encrypting=false.
MPW_DIR="${DATA_DIR}/security/masterpw/default"
MPW_MARK="${DATA_DIR}/.railway-masterpw"

if [ -z "${GEOSERVER_MASTER_PASSWORD}" ] && [ ! -f "${MPW_MARK}" ]; then
  GEOSERVER_MASTER_PASSWORD="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 28)"
  log "GEOSERVER_MASTER_PASSWORD was not set; generated one and stored it at ${MPW_DIR}/passwd"
fi

if [ -n "${GEOSERVER_MASTER_PASSWORD}" ]; then
  MPW_WANT="$(printf %s "${GEOSERVER_MASTER_PASSWORD}" | sha256sum | cut -d' ' -f1)"
  if [ ! -f "${MPW_MARK}" ] || [ "$(cat "${MPW_MARK}")" != "${MPW_WANT}" ]; then
    log "installing the GeoServer master password"
    mkdir -p "${MPW_DIR}"
    cat > "${MPW_DIR}/config.xml" <<'MPWXML'
<urlProvider>
  <id>railway-masterpw</id>
  <name>default</name>
  <className>org.geoserver.security.password.URLMasterPasswordProvider</className>
  <readOnly>false</readOnly>
  <url>file:passwd</url>
  <encrypting>false</encrypting>
</urlProvider>
MPWXML
    printf %s "${GEOSERVER_MASTER_PASSWORD}" > "${MPW_DIR}/passwd"
    chmod 0600 "${MPW_DIR}/passwd"
    printf %s "${MPW_WANT}" > "${MPW_MARK}"
    # masterpw.info is GeoServer's own "here is your generated password" drop; a
    # stale one from an earlier boot would name a password that no longer works.
    rm -f "${DATA_DIR}/security/masterpw.info"
  else
    log "master password unchanged; leaving the stored value alone"
  fi
fi
# Never leave it in the environment the webapp (and anything it runs) can read.
unset GEOSERVER_MASTER_PASSWORD

# --- 5. Admin credentials, applied once ---------------------------------------
if [ -n "${GEOSERVER_ADMIN_PASSWORD}" ]; then
  ADMIN_USER="${GEOSERVER_ADMIN_USER:-admin}"
  ADM_MARK="${DATA_DIR}/.railway-admin"
  ADM_WANT="$(printf '%s:%s' "${ADMIN_USER}" "${GEOSERVER_ADMIN_PASSWORD}" | sha256sum | cut -d' ' -f1)"

  if [ ! -f "${ADM_MARK}" ] || [ "$(cat "${ADM_MARK}")" != "${ADM_WANT}" ]; then
    log "applying GeoServer admin credentials for user '${ADMIN_USER}'"
    /bin/sh /opt/update_credentials.sh "${ADMIN_USER}" "${GEOSERVER_ADMIN_PASSWORD}"
    USERS_XML="${DATA_DIR}/security/usergroup/default/users.xml"
    grep -q "name=\"${ADMIN_USER}\"" "${USERS_XML}" \
      || die "update_credentials.sh did not write user '${ADMIN_USER}' into ${USERS_XML}"
    printf %s "${ADM_WANT}" > "${ADM_MARK}"
  else
    log "admin credentials unchanged; keeping users.xml and roles.xml as they are"
  fi
fi
# Applied above (or deliberately skipped), so stop the vendor script from
# rewriting users.xml and roles.xml from its templates on this and every boot.
unset GEOSERVER_ADMIN_USER GEOSERVER_ADMIN_PASSWORD
unset GEOSERVER_ADMIN_USER_FILE GEOSERVER_ADMIN_PASSWORD_FILE

# --- 6. Request throttling ----------------------------------------------------
CONTROL_FLOW="${DATA_DIR}/controlflow.properties"
if [ ! -f "${CONTROL_FLOW}" ]; then
  log "writing default request limits to ${CONTROL_FLOW}"
  cat > "${CONTROL_FLOW}" <<'CFPROPS'
# Request throttling for the control-flow extension.
# Written once, on the first boot only: edit it freely, it is never rewritten.
# Reference: https://docs.geoserver.org/latest/en/user/extensions/controlflow/

# Requests queued longer than this (seconds) are rejected rather than piling up.
timeout=60

# Concurrent OWS requests in total, and per service.
ows.global=48
ows.wms.getmap=16
ows.wfs.getfeature=12
ows.wps.execute=4

# Concurrent requests from a single user (by session cookie, else by IP).
user=8
user.ows.wps.execute=2
CFPROPS
fi

# --- 7. Hand over to the image's own launcher ---------------------------------
if [ "${RUN_UNPRIVILEGED}" = "true" ]; then
  # The vendor script drops to this uid with setpriv, which cannot re-open stdio
  # the runtime created as root.
  chown "${RUN_WITH_USER_UID:-999}:${RUN_WITH_USER_GID:-${RUN_WITH_USER_UID:-999}}" \
    /proc/self/fd/1 /proc/self/fd/2 2>/dev/null || true
fi

log "handing over to the GeoServer image launcher"
exec bash /opt/startup.real.sh "$@"
