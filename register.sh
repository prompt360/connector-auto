#!/usr/bin/env bash

set -euo pipefail

# register.sh (bash)
# Creates a Kubernetes Service and Deployment in the "p360-mcp" namespace.
#
# Params:
#   1) short name
#   2) port
#
# Service: connector-<short>-service, listens on 80 -> targetPort <port>
# Deployment: connector-<short>, container listens on <port>

NS="p360-mcp"

# Elevate to a root login shell, then re-run this script.
ORIG_PWD="$(pwd)"
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]:-$0}")"
  exec sudo -i bash -c "cd \"$ORIG_PWD\" && \"$SCRIPT_PATH\" \"$@\""
fi

usage() {
  echo "Usage: $0 <short-name> <port>" >&2
  echo "  short-name: identifier used in resource names (e.g., api)" >&2
  echo "  port:       container's listen port (1-65535)" >&2
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 2 ]]; then
  usage
  exit 1
fi

SHORT_RAW="$1"
PORT="$2"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "Error: kubectl not found in PATH" >&2
  exit 1
fi

# Validate and sanitize short name to DNS-1123 label
SHORT_NAME=$(echo "$SHORT_RAW" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/^-\+//; s/-\+$//')
if [[ -z "$SHORT_NAME" ]]; then
  echo "Error: short-name resolves to empty after sanitization" >&2
  exit 1
fi

# Validate port
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "Error: port must be an integer between 1 and 65535" >&2
  exit 1
fi

NAME="connector-${SHORT_NAME}"
SVC_NAME="connector-${SHORT_NAME}-service"
LABEL_APP="$NAME"
IMAGE="us-central1-docker.pkg.dev/prompt360-dev/images/connector/${SHORT_NAME}:latest"

echo "Namespace: $NS"
echo "Short:     $SHORT_NAME"
echo "Port:      $PORT"
echo "Service:   $SVC_NAME"
echo "Deployment:$NAME"
echo "Image:     $IMAGE"

# Ensure namespace exists
if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
  echo "Creating namespace $NS"
  kubectl create namespace "$NS"
fi

echo "Applying Service $SVC_NAME in $NS"
cat <<EOF | kubectl apply -n ${NS} -f -
apiVersion: v1
kind: Service
metadata:
  name: ${SVC_NAME}
  labels:
    app: ${LABEL_APP}
spec:
  selector:
    app: ${LABEL_APP}
  ports:
    - name: http
      port: 80
      targetPort: ${PORT}
EOF

echo "Applying Deployment $NAME in $NS"
cat <<EOF | kubectl apply -n ${NS} -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${NAME}
  labels:
    app: ${LABEL_APP}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${LABEL_APP}
  template:
    metadata:
      labels:
        app: ${LABEL_APP}
    spec:
      containers:
        - name: ${SHORT_NAME}
          image: ${IMAGE}
          imagePullPolicy: Always
          ports:
            - containerPort: ${PORT}
      restartPolicy: Always
EOF

echo "Waiting for rollout to complete..."
kubectl rollout status deployment/${NAME} -n ${NS}

echo "Done. Resources with label app=${LABEL_APP}:"
kubectl get deploy,svc,pods -n "$NS" -l app="$LABEL_APP"
