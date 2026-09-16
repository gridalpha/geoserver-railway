# GeoServer 3.0.1 for Railway.
#
# Pinned, not floating: docker.osgeo.org publishes no `latest`, and every floating
# tag it does publish points somewhere other than the current stable release —
# `stable-latest` resolves to 2.28.4, `3.0-latest` to 3.0.0 and `3.0.x` to a
# nightly 3.0.0-SNAPSHOT, while geoserver.org/download names 3.0.1 as the stable
# line. GeoServer also owns its data directory format, so the tag must not cross a
# minor boundary on its own.
FROM docker.osgeo.org/geoserver:3.0.1

USER root

# ---------------------------------------------------------------------------
# Extensions, baked at build time.
#
# The image can download these on every container start, which makes each cold
# boot depend on SourceForge and fails open — install-extensions.sh skips an
# extension it could not fetch and GeoServer then starts without it, green and
# quietly short of features. Doing it here instead fails the build loudly, costs
# nothing at boot, and pins each jar to the core's own version: the image's baked
# STABLE_PLUGIN_URL already points at the release-matched extension directory for
# whatever GEOSERVER_VERSION it carries.
# ---------------------------------------------------------------------------
# `printing` is deliberately absent: its zip carries xercesImpl-2.12.2.jar, which
# wins the webapp-first JAXP service lookup and does not implement the JAXP 1.5
# property `accessExternalSchema` that GeoServer's WFS Transaction parser sets.
# With it installed, every WFS-T insert, update and delete answers
# "Property 'http://javax.xml.XMLConstants/property/accessExternalSchema' is not
# recognized." while the rest of the server reads perfectly healthy. The guard in
# the next layer stops any future extension reintroducing it.
ENV STABLE_EXTENSIONS="control-flow,monitor,css,ysld,mbstyle,vectortiles,importer,wps,wps-download,csw,geopkg-output,querylayer,sldservice,charts,mapml,authkey,web-resource,params-extractor"

RUN set -eux; \
    INSTALL_EXTENSIONS=true bash /opt/install-extensions.sh; \
    libs="${ADDITIONAL_LIBS_DIR%/}"; \
    want="$(printf '%s' "$STABLE_EXTENSIONS" | tr ',' '\n' | grep -c .)"; \
    got="$(ls -1 "$libs"/geoserver-*-plugin.zip | wc -l)"; \
    echo "extensions requested=$want downloaded=$got"; \
    test "$want" = "$got"; \
    rm -f "$libs"/geoserver-*-plugin.zip; \
    gslib="${GEOSERVER_LIB_DIR%/}"; \
    for jar in gs-control-flow gs-vectortiles; do \
      ls -1 "$gslib/$jar-${GEOSERVER_VERSION}.jar"; \
    done; \
    if ls -1 "$gslib"/xercesImpl*.jar "$gslib"/xml-apis*.jar 2>/dev/null | grep -q .; then \
      echo "an extension installed a standalone XML parser; it breaks WFS-T" >&2; \
      ls -1 "$gslib"/xercesImpl*.jar "$gslib"/xml-apis*.jar 2>/dev/null >&2; \
      exit 1; \
    fi; \
    echo "gs-* jars now in the webapp: $(ls -1 "$gslib"/gs-*.jar | wc -l)"

# ---------------------------------------------------------------------------
# Tomcat configuration.
#
# server.xml adds a RemoteIpValve for Railway's edge ranges, which recovers the
# real client IP and the forwarded scheme — and, through the scheme, the `Secure`
# flag Tomcat otherwise omits from JSESSIONID behind a TLS-terminating proxy.
# The image's startup script runs envsubst over anything in /opt/config_overrides
# and copies it over the catalina conf, so this file keeps the vendor's own
# ${WEBAPP_CONTEXT} and ${POSTGRES_*} placeholders.
# ---------------------------------------------------------------------------
COPY config_overrides/server.xml /opt/config_overrides/server.xml

# ---------------------------------------------------------------------------
# Launcher shim.
#
# The inherited ENTRYPOINT is ["bash", "/opt/startup.sh"]. Copy the vendor's
# script aside and overwrite that path rather than declaring an ENTRYPOINT of our
# own, which would empty the inherited CMD, and rather than deleting the original,
# which Railway's runtime has been seen to restore.
# ---------------------------------------------------------------------------
RUN cp /opt/startup.sh /opt/startup.real.sh
COPY railway-startup.sh /opt/startup.sh

RUN set -eux; \
    bash -n /opt/startup.sh; \
    bash -n /opt/startup.real.sh; \
    grep -q '\[railway\]' /opt/startup.sh; \
    grep -q 'handle_geoserver_admin_credentials' /opt/startup.real.sh; \
    chmod +x /opt/startup.sh /opt/startup.real.sh; \
    command -v openssl; \
    command -v sha256sum; \
    ls -1 "${GEOSERVER_LIB_DIR%/}"/jasypt-*.jar

EXPOSE 8080
