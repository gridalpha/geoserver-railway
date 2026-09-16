# geoserver-railway

[GeoServer](https://geoserver.org/) 3.0.1 packaged for [Railway](https://railway.com),
built on the official `docker.osgeo.org/geoserver` image.

GeoServer is an OGC-compliant server for publishing geospatial data: WMS, WMTS,
WFS, WCS and WPS over PostGIS, GeoPackage, Shapefile, GeoTIFF and friends.

## What this image adds

The upstream image is close to Railway-ready. The things it cannot express as
environment variables are handled here.

**The master password is replaced on first boot.** GeoServer's release data
directory ships `security/masterpw/default/passwd` — a fixed value encrypted under
a key compiled into `URLMasterPasswordProvider` and published in the GeoServer
source tree. Left alone, every deployment in the world shares one `root` account
credential. The entrypoint writes `GEOSERVER_MASTER_PASSWORD` in the plaintext form
that provider reads when `encrypting` is `false`, and stamps a hash of it on the
volume so an operator's later change through the UI is never reverted.

**Admin credentials are applied once, not on every boot.** Upstream's
`update_credentials.sh` rebuilds `users.xml` and `roles.xml` from the shipped
templates whenever `GEOSERVER_ADMIN_PASSWORD` is set — which silently discards
every user, group and role added since. Here the credentials are applied when the
`user:password` pair changes and skipped otherwise, so the variable can stay set
without costing you the user database.

**Tomcat learns about the proxy.** `config_overrides/server.xml` adds a
`RemoteIpValve` trusting Railway's edge (`100.64.0.0/10`, `152.233.0.0/17`,
`fd00::/8`). Without it GeoServer records the load balancer as the client on every
request, and — because a servlet container decides the `Secure` cookie flag from
the socket — ships `JSESSIONID` without `Secure` behind Railway's TLS. The same
file sets `SameSite=Lax` on it.

**Extensions are baked in, not downloaded at boot.** The stock image can fetch
them on every container start; `install-extensions.sh` skips anything it fails to
download, so a bad day at the mirror produces a healthy GeoServer quietly missing
features. Building them in fails the build instead, and pins every jar to the
core's own version.

**The JVM is sized from the cgroup.** Railway hosts report 48 cores and a large
amount of RAM while the container gets a fraction of both, so the baked
`-Xmx1g` under-uses the container and `availableProcessors()` over-sizes every
GeoTools and JAI thread pool. The entrypoint derives `-Xmx` from
`/sys/fs/cgroup/memory.max` and pins `-XX:ActiveProcessorCount` from `cpu.max`.

It also writes a default `controlflow.properties` on first boot, so a single
client cannot monopolise the server, and repairs `POSTGRES_HOST` when a
`${{postgis.RAILWAY_PRIVATE_DOMAIN}}` reference renders empty, which it does on a
service's first-ever deployment.

## Bundled extensions

`control-flow`, `monitor`, `css`, `ysld`, `mbstyle`, `vectortiles`, `importer`,
`wps`, `wps-download`, `csw`, `geopkg-output`, `querylayer`, `sldservice`,
`charts`, `mapml`, `authkey`, `web-resource`, `params-extractor`.

`printing` is left out on purpose. Its zip installs `xercesImpl-2.12.2.jar`, which
wins Tomcat's webapp-first JAXP lookup and does not implement the JAXP 1.5
`accessExternalSchema` property GeoServer's WFS Transaction parser sets, so every
WFS-T write fails with a parser error on an otherwise healthy server. A build-layer
guard fails the image if any extension reintroduces a standalone XML parser.

## Environment variables

Everything has a working default; none of these is required.

| Variable | Default | Purpose |
|---|---|---|
| `GEOSERVER_ADMIN_USER` | `admin` | Web UI administrator |
| `GEOSERVER_ADMIN_PASSWORD` | generated | Applied on change only |
| `GEOSERVER_MASTER_PASSWORD` | generated | The `root` account; replaces the shipped default |
| `PROXY_BASE_URL` | — | `https://<your domain>/geoserver`, so capabilities documents advertise reachable URLs |
| `POSTGRES_JNDI_ENABLED` | `false` | `true` publishes a pooled `java:comp/env/jdbc/postgres` datasource |
| `POSTGRES_HOST` / `_PORT` / `_DB` / `_USERNAME` / `_PASSWORD` | — | The PostGIS connection behind that JNDI resource |
| `SKIP_DEMO_DATA` | `false` | `true` starts with an empty catalog instead of the sample layers |
| `CORS_ENABLED` | `false` | `true` lets browser map clients on other origins read the services |
| `RUN_UNPRIVILEGED` | `false` | `true` runs Tomcat as uid 999 after chowning the volume |
| `EXTRA_JAVA_OPTS` | cgroup-derived | Set it to override the heap and processor count |

A volume belongs at `/opt/geoserver_data`; it holds the catalog, styles, uploaded
data and the GeoWebCache tile cache.

Upstream's full variable reference: <https://github.com/geoserver/docker>.

## Licence

GeoServer is GPL-2.0. This repository only packages it.
