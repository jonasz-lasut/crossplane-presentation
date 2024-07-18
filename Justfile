set export
set shell := ["bash", "-uc"]

argocd_port := "30080"
timeout := "120s"

# List tasks
# targets marked with * are main targets
default:
  just --list --unsorted

# Create a kind cluster
_setup-kind cluster_name='crossplane-cluster':
  #!/usr/bin/env bash
  set -euo pipefail

  envsubst < kind-config.yaml | kind create cluster --config - --wait {{timeout}}
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
  if kubectl get namespace argocd > /dev/null 2>&1; then
    echo "Namespace argocd already exists"
  else
    echo "Creating namespace argocd"
    kubectl create namespace argocd
  fi

  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  kubectl wait --for condition=Available=True --timeout={{timeout}} deployment/argocd-server --namespace argocd
  kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort"}}'
  kubectl patch svc argocd-server -n argocd --type merge --type='json' -p='[{"op": "replace", "path": "/spec/ports/0/nodePort", "value": {{argocd_port}}}]'

# Setup ArgoCD application of applications and configure configmap for crossplane tracking
_bootstrap-argocd:
  kubectl apply -f argocd.bootstrap.yaml

# * Setup development environment
setup cluster_name='crossplane-cluster' xp_namespace='crossplane-system': _setup-kind _setup-crossplane _setup-argocd _bootstrap-argocd get-argocd-password

# Read ArgoCD admin password from initial secret
get-argocd-password:
  #!/usr/bin/env bash
  echo ArgoCD admin password: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

# * Destroy development cluster
teardown cluster_name='crossplane-cluster':
  kind delete clusters {{cluster_name}}
