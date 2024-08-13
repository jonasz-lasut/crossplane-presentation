# Crossplane as a Universal Control Plane

## Requirements
- docker
- [devbox](https://www.jetify.com/devbox/docs/quickstart/)
- GCP account, project and service account with enough permissions to deploy databases

## Step by step guide
To start working on the project install of the dependencies using `devbox install`, after that you can open interactive shell with `devbox shell`.
After doing that all of the tools specified in devbox.json are available for the demo.

[just](https://github.com/casey/just) is used as task runner, to setup the local environment all you need to do is to run `just setup`.
This will create a local KinD cluster with Crossplane and ArgoCD installed. ApplicationSet for ArgoCD will also be created, pointing to the sources configured in `bootstrap/platform/xargo.yaml`.

You can access ArgoCD dashboard at ingress configured in `bootstrap/platform/xargo.yaml` (by default argocd.localhost) using username `admin` and password `$ just get-argocd-password`.

Create GCP provider secret as documented in https://docs.crossplane.io/latest/getting-started/provider-gcp/#create-a-kubernetes-secret-with-the-gcp-credentials.
You can use `just generate-gcp-credentials <credentials-file-name>` to create it.
