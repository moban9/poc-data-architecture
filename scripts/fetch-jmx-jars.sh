#!/usr/bin/env bash
# Fetch the Prometheus JMX exporter javaagent into monitoring/jmx/ (the shared
# volume mounted into every JVM at /opt/jmx). The jar is gitignored; this script
# is the reproducible source of truth for the version.
set -euo pipefail

VERSION="${JMX_AGENT_VERSION:-1.0.1}"
BASE="https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent"
DEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../monitoring/jmx" && pwd)"

echo ">> fetching jmx_prometheus_javaagent ${VERSION}"
curl -fsSL -o "${DEST_DIR}/jmx_prometheus_javaagent.jar" \
  "${BASE}/${VERSION}/jmx_prometheus_javaagent-${VERSION}.jar"

sha256sum "${DEST_DIR}/jmx_prometheus_javaagent.jar"
echo ">> done: ${DEST_DIR}/jmx_prometheus_javaagent.jar (version ${VERSION})"
