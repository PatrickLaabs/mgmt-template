#!/bin/sh

cluster=$1
# Strip everything after the first hyphen to get "workloadcluster"
cluster_base="${cluster%%-*}"
timestamp=$(date +%s)
repo=${cluster_base}
archived_repo=${cluster_base}-${timestamp}
repourl=git@github.com:GITHUB_USERNAME/${archived_repo}.git

argocd login argocd-server.argocd.svc.cluster.local:80 --plaintext --insecure --username admin --password frigg

argocd cluster rm $cluster_base -y || true

# Deleting kubeconfig that has been used by spire-server
# kubectl delete secret $cluster_base-kubeconfig --namespace=spire-system

### Archiving the Repository ###
gh auth login

gh repo clone GITHUB_USERNAME/${repo} && cd ${repo}
sleep 5

gh repo rename ${archived_repo} --yes

gh repo archive GITHUB_USERNAME/${archived_repo} --yes