#!/usr/bin/env bash
# Fetch the Iceberg Kafka Connect SINK plugin jars into compose/connect-plugins/.
#
# There is NO shaded "runtime" jar on Maven Central for the Apache Iceberg Kafka
# Connect sink, so the plain connector jar + its full transitive tree must be
# assembled. This uses coursier (Scala dependency resolver) to resolve them all.
#
# The coordinate list below is what worked end-to-end (Iceberg 1.9.2 + awssdk
# v2 2.29.52 + hadoop-common 3.4.1). Newer avro/jackson/netty were kept by
# coursier's conflict resolution; older hadoop-brought duplicates were skipped.
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/../compose/connect-plugins" && pwd)"
mkdir -p "$PLUGIN_DIR"

CS_BIN="$(command -v cs || echo "$HOME/.local/bin/cs")"
if ! command -v cs >/dev/null 2>&1 && [ ! -x "$CS_BIN" ]; then
  echo "installing coursier..."
  curl -fLo /tmp/cs.gz "https://github.com/coursier/coursier/releases/latest/download/cs-x86_64-pc-linux.gz"
  gunzip -f /tmp/cs.gz && chmod +x /tmp/cs && CS_BIN=/tmp/cs
fi

echo "fetching Iceberg sink jars (this can take a few minutes)..."
"$CS_BIN" fetch \
  org.apache.iceberg:iceberg-kafka-connect:1.9.2 \
  org.apache.iceberg:iceberg-kafka-connect-transforms:1.9.2 \
  org.apache.iceberg:iceberg-kafka-connect-events:1.9.2 \
  org.apache.iceberg:iceberg-parquet:1.9.2 \
  org.apache.iceberg:iceberg-aws:1.9.2 \
  org.apache.iceberg:iceberg-bundled-guava:1.9.2 \
  software.amazon.awssdk:s3:2.29.52 \
  software.amazon.awssdk:sts:2.29.52 \
  software.amazon.awssdk:kms:2.29.52 \
  software.amazon.awssdk:dynamodb:2.29.52 \
  software.amazon.awssdk:apache-client:2.29.52 \
  org.apache.hadoop:hadoop-common:3.4.1 \
  org.slf4j:slf4j-api:2.0.17 \
  org.slf4j:slf4j-simple:2.0.17 \
  --classpath > /tmp/iceberg-cp.txt

tr ':' '\n' < /tmp/iceberg-cp.txt | grep -v '^$' | while read -r jar; do
  [ -f "$jar" ] && cp -n "$jar" "$PLUGIN_DIR/"
done

echo "done — $(ls "$PLUGIN_DIR" | wc -l) jars in $PLUGIN_DIR"
echo "restart the connect container to load them:"
echo "  docker compose -f docker-compose.yml -f monitoring.yml -f traefik.yml up -d connect"
