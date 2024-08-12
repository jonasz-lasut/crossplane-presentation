set export
set shell := ["bash", "-uc"]

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
  gum spin --title "Waiting for Nginx Ingress controller ⬇️" -- kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# Setup universal crossplane
_setup-crossplane xp_namespace='upbound-system':
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

# Setup crossplane configurations
_setup-configurations xp_namespace='upbound-system':
  kubectl apply -f bootstrap/crossplane/configuration-argocd.yaml
  gum spin --title "Waiting for ArgoCD configuration 🐙" -- kubectl wait --for=condition=healthy --timeout=60s configuration.pkg.crossplane.io/configuration-argocd && sleep 10

  # Patch out redis HA for local demo
  kubectl get composition xargo.gitops.platform.upbound.io -o json | jq '.spec.pipeline[0].input.resources[0].base.spec.forProvider.values["redis-ha"].enabled = false' | kubectl apply -f -

# Setup crossplane providers
_setup-providers xp_namespace='upbound-system':
  #!/usr/bin/env bash
  kubectl apply -f bootstrap/crossplane/provider-*.yaml

  SA=$(kubectl -n {{xp_namespace}} get sa -o name|grep provider-helm | sed -e "s|serviceaccount\/|{{xp_namespace}}:|g")
  kubectl create clusterrolebinding provider-helm-admin-binding --clusterrole cluster-admin --serviceaccount="${SA}"
  echo "Added provider-helm Service Account permissions"

  echo "Adding provider-kubernetes Service Account permissions"
  SA=$(kubectl -n {{xp_namespace}} get sa -o name|grep provider-kubernetes | sed -e "s|serviceaccount\/|{{xp_namespace}}:|g")
  kubectl create clusterrolebinding provider-kubernetes-admin-binding --clusterrole cluster-admin --serviceaccount="${SA}"
  echo "Added provider-kubernetes Service Account permissions"

# Setup ArgoCD with ingress
_setup-argocd:
  #!/usr/bin/env bash
  kubectl apply -f bootstrap/platform/xargo.yaml
  gum spin --title "Waiting for ArgoCD deployments 🐙" -- kubectl wait --for=condition=available=true deployments --all -n argocd

  # In production setup it would be handled by Kyverno or similar
  kubectl annotate ingress argocd-server -n argocd "nginx.ingress.kubernetes.io/force-ssl-redirect"="true" "nginx.ingress.kubernetes.io/backend-protocol"="HTTPS"

# *
# Setup development environment
setup cluster_name='crossplane-cluster' xp_namespace='upbound-system': _setup-kind _setup-crossplane _setup-configurations _setup-providers _setup-argocd

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
