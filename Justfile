set export
set shell := ["bash", "-uc"]

argocd_port := "30080"
timeout := "120s"

# targets marked with * are main targets
# List tasks
default:
  just --list --unsorted

# Create a kind cluster
_setup-kind cluster_name='crossplane-cluster':
  #!/usr/bin/env bash
  set -euo pipefail

  envsubst < bootstrap/cluster/config.yaml | kind create cluster --config - --wait {{timeout}}
  kubectl config use-context kind-{{cluster_name}}

# Setup universal crossplane
_setup-crossplane xp_namespace='crossplane-system':
  #!/usr/bin/env bash
  if kubectl get namespace {{xp_namespace}} > /dev/null 2>&1; then
    echo "Namespace {{xp_namespace}} already exists"
  else
    echo "Creating namespace {{xp_namespace}}"
    kubectl create namespace {{xp_namespace}}
  fi

  helm repo add upbound-stable https://charts.upbound.io/stable && helm repo update
  helm upgrade --install uxp --namespace {{xp_namespace}} upbound-stable/universal-crossplane --devel
  kubectl wait --for condition=Available=True --timeout={{timeout}} deployment/crossplane --namespace {{xp_namespace}}
    
# Setup ArgoCD and patch service to nodePort {{argocd_port}}
_setup-argocd:
  #!/usr/bin/env bash
  kubectl apply -f bootstrap/crossplane/configuration-argocd.yaml
  gum spin --title "Waiting for ArgoCD configuration 🐙" -- kubectl wait --for=condition=healthy --timeout=60s configuration.pkg.crossplane.io/configuration-argocd
  kubectl apply -f bootsrap/platform/xargo.yaml

# *
# Setup development environment
setup cluster_name='crossplane-cluster' xp_namespace='crossplane-system': _setup-kind _setup-crossplane _setup-argocd

# Read ArgoCD admin password from initial secret
get-argocd-password:
  #!/usr/bin/env bash
  echo ArgoCD admin password: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

# *
# Destroy development cluster
teardown cluster_name='crossplane-cluster':
  kind delete clusters {{cluster_name}}

# *
# Serve MARP presentation
serve-presentation:
  #!/usr/bin/env bash
  marp --html=true --server docs/presentation/
