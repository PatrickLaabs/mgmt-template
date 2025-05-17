#!/bin/sh

cluster=$1
# Strip everything after the first hyphen to get "workloadcluster"
# cluster_base="${cluster%%-*}"
# timestamp=$(date +%s)
# repo=${cluster}
# archived_repo=${cluster}-${timestamp}
# repourl=git@github.com:GITHUB_USERNAME/${archived_repo}.git

argocd login argocd-server.argocd.svc.cluster.local:80 --plaintext --insecure --username admin --password frigg

argocd cluster rm $cluster -y || true

# Deleting kubeconfig that has been used by spire-server
# kubectl delete secret $cluster_base-kubeconfig --namespace=spire-system

# ### Renaming and Archiving the Repository on Gitea ###
# GITEA_API_URL="http://gitea-http.gitea.svc.cluster.local:3000/api/v1"
# GITEA_OWNER="gitea_admin" # Assuming gitea_admin is the owner
# GITEA_CREDENTIALS="gitea_admin:admin" # Your Gitea admin username and password

# # Original repository name is in $repo (which is $cluster)
# # New name for the repository before archiving is in $archived_repo (which is $cluster-$timestamp)

# echo "Renaming Gitea repository '$repo' to '$archived_repo'..."
# RENAME_PAYLOAD="{\"name\": \"$archived_repo\"}"

# curl -X PATCH "${GITEA_API_URL}/repos/${GITEA_OWNER}/${repo}" \
#   -u "${GITEA_CREDENTIALS}" \
#   -H "Content-Type: application/json" \
#   -d "${RENAME_PAYLOAD}"

# # Check if rename was successful (optional, but good practice)
# # Gitea API usually returns 200 OK on success for PATCH
# # Add error handling here if needed

# echo "Archiving Gitea repository '$archived_repo'..."
# ARCHIVE_PAYLOAD='{"archived": true}' # Note: Gitea expects a boolean for archived

# # The repository is now named $archived_repo
# curl -X PATCH "${GITEA_API_URL}/repos/${GITEA_OWNER}/${archived_repo}" \
#   -u "${GITEA_CREDENTIALS}" \
#   -H "Content-Type: application/json" \
#   -d "${ARCHIVE_PAYLOAD}"

# # Add error handling here if needed

# echo "Gitea repository '$archived_repo' has been renamed and archived."
