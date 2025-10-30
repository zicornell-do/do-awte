#!/usr/bin/env bash
set -euo pipefail

# setup-local.sh
# Sets up a local Kubernetes cluster using kind and installs Argo Workflows via Helm.
# Optionally port-forwards the Argo Server UI.
#
# Requirements:
#   - kind
#   - kubectl
#   - helm
# Optional:
#   - argo CLI (for convenience, but not required; we use kubectl for the example)
#
# Notes:
#   - The script is idempotent where possible. If the cluster exists, it will be reused.
#   - The Argo Server is installed but not exposed via LoadBalancer in kind; use --port-forward to access the UI.

CLUSTER_NAME="awte"
ARGO_NS="argo"
WORKFLOW_NS="argo"
ARGO_VALUES_FILE="deploy/local-values.yaml"
CHART_VERSION=""   # empty means latest
PORT_FORWARD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-name)
      CLUSTER_NAME="$2"; shift; shift;;
    --version)
      CHART_VERSION="$2"; shift; shift;;
    --values)
      ARGO_VALUES_FILE="$2"; shift; shift;;
    -h|--help)
      echo "Usage: $0 [--cluster-name NAME] [--version ARGO_CHART_VERSION] [--values ARGO_VALUES_FILE]"
      exit 0;;
    *)
      echo "Unknown option: $1" >&2; exit 1;;
  esac
done

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required dependency '$1' not found in PATH" >&2
    exit 1
  fi
}

info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }

need kind
need kubectl
need helm

# 1) Create or reuse kind cluster
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  info "kind cluster '${CLUSTER_NAME}' already exists; reusing."
else
  info "Creating kind cluster '${CLUSTER_NAME}'..."
  kind create cluster --name "${CLUSTER_NAME}"
fi

# Ensure kubectl points to the cluster
# Modern kind sets the current-context automatically; no need to override KUBECONFIG.
# Optionally verify the context:
# kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null 2>&1 || true

# 2) Add Argo Helm repo and update
if ! helm repo list | awk '{print $1}' | grep -qx argo; then
  info "Adding Argo Helm repository..."
  helm repo add argo https://argoproj.github.io/argo-helm
else
  info "Argo Helm repository already present."
fi
info "Updating Helm repositories..."
helm repo update

# 3) Create namespace if needed
if kubectl get ns "${ARGO_NS}" >/dev/null 2>&1; then
  info "Namespace '${ARGO_NS}' already exists."
else
  info "Creating namespace '${ARGO_NS}'..."
  kubectl create namespace "${ARGO_NS}"
fi

if kubectl get ns "${WORKFLOW_NS}" >/dev/null 2>&1; then
  info "Namespace '${WORKFLOW_NS}' already exists."
else
  info "Creating namespace '${WORKFLOW_NS}'..."
  kubectl create namespace "${WORKFLOW_NS}"
fi

# 4) Install/upgrade Argo Workflows
info "Installing/Upgrading Argo Workflows via Helm..."
set -x
HELM_EXTRA=( )
if [[ -n "${CHART_VERSION}" ]]; then
  HELM_EXTRA+=( "--version" "${CHART_VERSION}" )
fi

# We enable the server; service type ClusterIP (default).
# Also enable persistence of workflow archive logs to simplify debugging; not strictly required.
helm upgrade --install argo-workflows argo/argo-workflows \
  --namespace "${ARGO_NS}" \
  --values "${ARGO_VALUES_FILE}" \
  --set 'server.extraArgs={"--insecure","--auth-mode=server"}' \
  --set argo-workflows.namespace="${ARGO_NS}" \
  "${HELM_EXTRA[@]}"
set +x

# 5) Wait for pods to be ready
info "Waiting for Argo Workflows components to be Ready..."
kubectl -n "${ARGO_NS}" rollout status deploy/argo-workflows-server --timeout=120s || true
kubectl -n "${ARGO_NS}" rollout status deploy/argo-workflows-workflow-controller --timeout=180s || true

# 6) Create a demo ServiceAccount, grant RBAC, and generate an access token for Argo Server login
info "Ensuring 'demo' ServiceAccount exists in namespace '${ARGO_NS}'..."
if ! kubectl -n "${ARGO_NS}" get sa demo >/dev/null 2>&1; then
  kubectl -n "${ARGO_NS}" create sa demo
else
  info "ServiceAccount 'demo' already exists in '${ARGO_NS}'."
fi

info "Ensuring 'default' ServiceAccount exists in namespace '${ARGO_NS}'..."
if ! kubectl -n "${ARGO_NS}" get sa default >/dev/null 2>&1; then
  kubectl -n "${ARGO_NS}" create sa default
else
  info "ServiceAccount 'default' already exists in '${ARGO_NS}'."
fi

# Bind minimal permissions for using the Argo Server API in the argo namespace
# Prefer Role 'argo-server' in the argo namespace if it exists; otherwise fall back to ClusterRole
if kubectl -n "${ARGO_NS}" get role argo-server >/dev/null 2>&1; then
  if ! kubectl -n "${ARGO_NS}" get rolebinding demo  >/dev/null 2>&1; then
    kubectl -n "${ARGO_NS}" create rolebinding demo \
      --role argo-server \
      --serviceaccount "${ARGO_NS}:demo"
  else
    info "RoleBinding 'demo' already exists in '${ARGO_NS}'."
  fi
else
  if ! kubectl -n "${ARGO_NS}" get rolebinding demo  >/dev/null 2>&1; then
    kubectl -n "${ARGO_NS}" create rolebinding demo \
      --clusterrole argo-server \
      --serviceaccount "${ARGO_NS}:demo"
  else
    info "RoleBinding 'demo' already exists in '${ARGO_NS}'."
  fi
fi

# Allow the 'demo' SA to submit workflows into the workflow namespace as well
if ! kubectl -n "${WORKFLOW_NS}" get rolebinding demo-submit >/dev/null 2>&1; then
  kubectl -n "${WORKFLOW_NS}" create rolebinding demo-submit \
    --clusterrole argo-server \
    --serviceaccount "${ARGO_NS}:demo"
else
  info "RoleBinding 'demo-submit' already exists in '${WORKFLOW_NS}'."
fi

# Create a read-only UI Role in the workflow namespace for viewing workflows and logs
if ! kubectl -n "${WORKFLOW_NS}" get role argo-ui >/dev/null 2>&1; then
  kubectl -n "${WORKFLOW_NS}" apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: argo-ui
  namespace: ${WORKFLOW_NS}
rules:
  - apiGroups:
      - argoproj.io
    resources:
      - eventsources
      - sensors
      - workflows
      - workfloweventbindings
      - workflowtemplates
      - clusterworkflowtemplates
      - cronworkflows
      - workflowtaskresults
    verbs:
      - create
      - delete
      - update
      - patch
      - get
      - list
      - watch
  - apiGroups:
      - ""
    resources:
      - events
      - pods
      - pods/log
    verbs:
      - get
      - list
      - watch
EOF
else
  info "Role 'argo-ui' already exists in '${WORKFLOW_NS}'."
fi

# Bind the UI Role to the 'demo' ServiceAccount in argo namespace
if ! kubectl -n "${WORKFLOW_NS}" get rolebinding demo-ui >/dev/null 2>&1; then
  kubectl -n "${WORKFLOW_NS}" create rolebinding demo-ui \
    --role argo-ui \
    --serviceaccount "${ARGO_NS}:demo"
else
  info "RoleBinding 'demo-ui' already exists in '${WORKFLOW_NS}'."
fi

if ! kubectl -n "${WORKFLOW_NS}" get rolebinding default >/dev/null 2>&1; then
  kubectl -n "${WORKFLOW_NS}" create rolebinding default \
    --role argo-ui \
    --serviceaccount "${ARGO_NS}:default"
else
  info "RoleBinding 'default' already exists in '${WORKFLOW_NS}'."
fi

# Create or fetch an access token for the 'demo' SA (prefers kubectl create token when available)
TOKEN=""
if kubectl -n "${ARGO_NS}" create token demo >/dev/null 2>&1; then
  TOKEN=$(kubectl -n "${ARGO_NS}" create token demo)
else
  info "'kubectl create token' is unavailable; creating a service-account token Secret..."
  # Create the secret if it doesn't already exist
  if ! kubectl -n "${ARGO_NS}" get secret demo-token >/dev/null 2>&1; then
    kubectl -n "${ARGO_NS}" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: demo-token
  annotations:
    kubernetes.io/service-account.name: demo
  namespace: ${ARGO_NS}
type: kubernetes.io/service-account-token
EOF
  fi
  # Wait until token data is populated
  for i in {1..20}; do
    TOKEN=$(kubectl -n "${ARGO_NS}" get secret demo-token -o jsonpath='{.data.token}' 2>/dev/null || true)
    if [[ -n "$TOKEN" ]]; then
      TOKEN=$(echo -n "$TOKEN" | base64 -d)
      break
    fi
    sleep 1
  done
fi

if [[ -z "$TOKEN" ]]; then
  warn "Failed to obtain an access token for service account 'demo'."
else
  info "Generated access token for service account 'demo' (namespace '${ARGO_NS}')."
  echo "------ BEGIN ARGO ACCESS TOKEN (demo) ------"
  echo "$TOKEN"
  echo "------- END ARGO ACCESS TOKEN (demo) -------"
  echo
  echo "To use this token in the Argo Workflows UI prefix it with \"Bearer \"".
  echo
fi

cat <<EONFO
[INFO] Argo Workflows has been installed in the '${ARGO_NS}' namespace on kind cluster '${CLUSTER_NAME}'.

Useful commands:
  - kubectl -n ${ARGO_NS} get pods
  - kubectl -n ${WORKFLOW_NS} get wf
  - kubectl -n ${ARGO_NS} logs deploy/argo-workflows-workflow-controller
  - kubectl -n ${ARGO_NS} port-forward svc/argo-workflows-server 2746:2746  # then open http://localhost:2746
EONFO
