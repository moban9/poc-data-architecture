#!/bin/sh
# Create the Polaris `lakehouse` catalog (Iceberg REST) backed by MinIO (S3).
#
# Run once after Polaris is up — wired as the one-shot `polaris-setup` service in
# docker-compose.yml (image alpine/curl, `apk add jq` first). The MinIO bucket
# is created separately by the `bucket-setup` service.
#
# Requires: curl, jq. All values come from env (defaults match compose/.env.example).

set -eu

POLARIS_HOST="${POLARIS_HOST:-http://polaris:8181}"
REALM="${POLARIS_REALM:-POLARIS}"
CLIENT_ID="${POLARIS_CLIENT_ID:-root}"
CLIENT_SECRET="${POLARIS_CLIENT_SECRET:-CHANGE_ME_polaris_root}"
CATALOG="${POLARIS_WAREHOUSE:-lakehouse}"
BUCKET="${MINIO_BUCKET:-lakehouse}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://minio:9000}"
MINIO_REGION="${MINIO_REGION:-us-east-1}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-minioadmin}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-CHANGE_ME_minio}"

echo "→ obtaining root access token (realm=${REALM})..."
TOKEN=""
i=0
while [ "$i" -lt 30 ]; do
  TOKEN_RESPONSE=$(curl -sS -X POST "${POLARIS_HOST}/api/catalog/v1/oauth/tokens" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_id=${CLIENT_ID}" \
    --data-urlencode "client_secret=${CLIENT_SECRET}" \
    --data-urlencode "scope=PRINCIPAL_ROLE:ALL" 2>/dev/null) || true
  TOKEN=$(printf '%s' "$TOKEN_RESPONSE" | jq -r '.access_token // empty' 2>/dev/null || true)
  if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    break
  fi
  i=$((i + 1))
  echo "  … waiting for Polaris to accept auth (${i}/30)"
  sleep 2
done
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "❌ could not obtain access token" >&2; exit 1; }
echo "✅ token obtained"

echo "→ checking for existing catalog '${CATALOG}'..."
EXISTING=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" -H "Polaris-Realm: ${REALM}" "${POLARIS_HOST}/api/management/v1/catalogs/${CATALOG}")
if [ "$EXISTING" = "200" ]; then
  echo "✅ catalog '${CATALOG}' already exists — skipping"
  exit 0
fi

echo "→ creating catalog '${CATALOG}' (S3 → ${MINIO_ENDPOINT}, base s3://${BUCKET})..."
PAYLOAD=$(jq -n \
  --arg name "$CATALOG" \
  --arg base "s3://${BUCKET}" \
  --arg endpoint "$MINIO_ENDPOINT" \
  --arg region "$MINIO_REGION" \
  --arg ak "$MINIO_ACCESS_KEY" \
  --arg sk "$MINIO_SECRET_KEY" \
  '{ catalog: {
       name: $name,
       type: "INTERNAL",
       readOnly: false,
       properties: { "default-base-location": $base },
       storageConfigInfo: {
         storageType: "S3",
         allowedLocations: [$base],
         endpoint: $endpoint,
         endpointInternal: $endpoint,
         pathStyleAccess: true,
         region: $region,
         accessKeyId: $ak,
         secretAccessKey: $sk
       }
     }
   }')

RESPONSE=$(curl --fail-with-body -sS -X POST "${POLARIS_HOST}/api/management/v1/catalogs" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Polaris-Realm: ${REALM}" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -d "$PAYLOAD") || { echo "❌ catalog create failed: ${RESPONSE}" >&2; exit 1; }

echo "✅ catalog '${CATALOG}' created"
printf '%s' "$RESPONSE" | jq .
