set export
set shell := ["bash", "-uc"]

timeout := "120s"
xp_namespace := "upbound-system"

# targets marked with * are main targets
# List tasks
default:
  just --list --unsorted

# Setup universal crossplane
_setup-crossplane :
  #!/usr/bin/env bash
  kubectl create namespace {{xp_namespace}}
  helm repo add upbound-stable https://charts.upbound.io/stable && helm repo update
  helm upgrade --install uxp --namespace {{xp_namespace}} upbound-stable/universal-crossplane --devel
  kubectl wait --for condition=Available=True --timeout={{timeout}} deployment/crossplane --namespace {{xp_namespace}}

# Setup crossplane configurations
_setup-configurations:
  kubectl apply -f bootstrap/platform/configuration-argocd.yaml
  gum spin --title "Waiting for ArgoCD configuration 🐙" -- kubectl wait --for=condition=healthy --timeout={{timeout}} configuration.pkg.crossplane.io/configuration-argocd && sleep 10

# Setup crossplane providers
_setup-providers:
  #!/usr/bin/env bash
  kubectl apply -f bootstrap/platform/provider-*.yaml

  cat <<EOF | kubectl apply -f -
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRole
  metadata:
    name: external-secrets-admin
  rules:
    - apiGroups:
        - external-secrets.io
      resources:
        - externalsecrets
        - secretstores
        - clustersecretstores
        - pushsecrets
      verbs:
        - '*'
    - apiGroups:
        - generators.external-secrets.io
      resources:
        - acraccesstokens
        - ecrauthorizationtokens
        - fakes
        - gcraccesstokens
        - passwords
        - vaultdynamicsecrets
      verbs:
        - '*'
  EOF

  SA=$(kubectl -n {{xp_namespace}} get sa -o name|grep provider-helm | sed -e "s|serviceaccount\/|{{xp_namespace}}:|g")
  kubectl create clusterrolebinding provider-helm-admin-binding --clusterrole cluster-admin --serviceaccount="${SA}"

  SA=$(kubectl -n {{xp_namespace}} get sa -o name|grep provider-kubernetes | sed -e "s|serviceaccount\/|{{xp_namespace}}:|g")
  kubectl create clusterrolebinding provider-kubernetes-admin-binding --clusterrole cluster-admin --serviceaccount="${SA}"
  kubectl create clusterrolebinding provider-kubernetes-external-secrets-binding --clusterrole external-secrets-admin --serviceaccount="${SA}"
  echo "Added provider-kubernetes and provider-helm Service Account permissions"

# Setup ArgoCD with ingress
_setup-argocd:
  #!/usr/bin/env bash
  kubectl apply -f bootstrap/platform/xargo.yaml
  gum spin --title "Waiting for ArgoCD XR 🐙" -- kubectl wait --timeout=300s --for=condition=Ready xargo/platform-argocd && kubectl wait --for=condition=available=true deployments --all -n argocd
  kubectl apply -f bootstrap/platform/argo-projects.yaml

# *
# Read ArgoCD admin password from initial secret
get-argocd-password:
  #!/usr/bin/env bash
  echo "🐙 ArgoCD admin password: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"

# *
# TODO: switch to external-secret
# Create psql password secret
generate-psql-password secret_name='psqlsecret':
  #!/usr/bin/env bash
  kubectl create secret generic {{secret_name}} --from-literal=password=$(gum input --password)

# *
# Setup development environment
setup: _setup-crossplane _setup-configurations _setup-providers _setup-argocd

# *
# Destroy everything on the development cluster
teardown:
  echo "cleanup logic"
