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
  kubectl create namespace {{xp_namespace}}
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

  SA=$(kubectl -n {{xp_namespace}} get sa -o name|grep provider-kubernetes | sed -e "s|serviceaccount\/|{{xp_namespace}}:|g")
  kubectl create clusterrolebinding provider-kubernetes-admin-binding --clusterrole cluster-admin --serviceaccount="${SA}"
  echo "Added provider-kubernetes and provider-helm Service Account permissions"

# Setup ArgoCD with ingress
_setup-argocd:
  #!/usr/bin/env bash
  kubectl apply -f bootstrap/platform/xargo.yaml
  gum spin --title "Waiting for ArgoCD XR 🐙" -- kubectl wait --timeout=300s --for=condition=Ready xargo/gitops-argocd && kubectl wait --for=condition=available=true deployments --all -n argocd

  # In production setup it would be handled by Kyverno or similar
  kubectl annotate ingress argocd-server -n argocd "nginx.ingress.kubernetes.io/force-ssl-redirect"="true" "nginx.ingress.kubernetes.io/backend-protocol"="HTTPS"

# *
# Read ArgoCD admin password from initial secret
get-argocd-password:
  #!/usr/bin/env bash
  echo ArgoCD admin password: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

# *
# Create GCP credentials secret
generate-gcp-credentials secret_file xp_namespace='upbound-system' secret_name='emerging-tech-secret':
  #!/usr/bin/env bash
  kubectl create secret generic {{secret_name}} -n {{xp_namespace}} --from-file=creds=./{{secret_file}}

# *
# Create psql password secret
generate-psql-password secret_name='psqlsecret':
  #!/usr/bin/env bash
  kubectl create secret generic {{secret_name}} --from-literal=password=$(gum input --password)

# *
# Setup development environment
setup cluster_name='crossplane-cluster' xp_namespace='upbound-system': _setup-kind _setup-crossplane _setup-configurations _setup-providers _setup-argocd

# *
# Destroy development cluster
teardown cluster_name='crossplane-cluster':
  kind delete clusters {{cluster_name}}
