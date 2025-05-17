#!/bin/sh

argocd login argocd-server.argocd.svc.cluster.local:80 --plaintext --insecure --username admin --password frigg

cluster_ready=""
cluster=$1
# sleep 300
sleep 5

# Strip everything after the first hyphen to get "workloadcluster"
# export cluster="${cluster%%-*}"
export repourl=http://gitea-http.gitea.svc.cluster.local:3000/gitea_admin/${cluster}.git
export encRepourl="$(echo "$repourl" | tr -d '\n' | base64)"

if [[ "$cluster" != "preview-"* ]]; then
  echo "Provisioned Cluster is not a preview environment Cluster. Exiting script."
  exit 1
else
  echo "Provisioned Cluster is a preview environment Cluster. Continuing with the script"
  echo "Cluster name:" "$cluster"
fi

echo "Waiting for vcluster '$cluster' to be provisioned..."
# Define the target namespace for the Cluster CRD
# Adjust this if your Cluster CR is not in the 'main' namespace
CLUSTER_CR_NAMESPACE="vcluster" 

cluster_ready="" # Ensure it's reset before the loop

# Loop until the cluster status phase is "Provisioned"
# Using $cluster directly as the name of the Cluster resource.
# Using $CLUSTER_CR_NAMESPACE for the namespace.
while [ -z "$cluster_ready" ]; do
    # Get the cluster resource in JSON format. Suppress errors if not found yet.
    cluster_status_json=$(kubectl get cluster "$cluster" -n "$CLUSTER_CR_NAMESPACE" -o json 2>/dev/null)

    if [ -n "$cluster_status_json" ]; then
        # Extract the phase using jq. If .status.phase is null or not "Provisioned", cluster_ready will be empty.
        current_phase=$(echo "$cluster_status_json" | jq -r '.status.phase // "NotAvailable"')
        if [ "$current_phase" = "Provisioned" ]; then
            cluster_ready="true" # Set to a non-empty string to exit the loop
            echo "Cluster '$cluster' in namespace '$CLUSTER_CR_NAMESPACE' is Provisioned."
        else
            echo "Cluster '$cluster' current phase: '$current_phase'. Waiting..."
        fi
    else
        echo "Cluster resource '$cluster' not found yet in namespace '$CLUSTER_CR_NAMESPACE'. Waiting..."
    fi
    
    if [ -z "$cluster_ready" ]; then
        sleep 20 # Wait before checking again
    fi
done

echo "Vcluster '$cluster' is ready. Proceeding with script."

kubectl config set-cluster in-cluster --server=https://kubernetes.default.svc.cluster.local --certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt --embed-certs=true ;
kubectl config set-credentials clusterctl --token=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) ;
kubectl config set-context in-cluster --cluster in-cluster --user clusterctl --namespace argocd ;
kubectl config use-context in-cluster ;

echo "Print in-clusters current used context: "
kubectl config current-context

WORKLOAD_KUBECONFIG_PATH="$HOME/.kube/$cluster-workloadcluster.yaml"

echo "Fetching and preparing kubeconfig for workload cluster '$cluster'..."
# This kubectl command targets the management cluster to get the secret
kubectl -n vcluster get secret/"$cluster"-kubeconfig -o json \
    | jq -r .data.value \
    | base64 --decode \
    | sed "s|server: https://$cluster.vcluster.svc:443|server: https://$cluster.vcluster:443|" \
    > "$WORKLOAD_KUBECONFIG_PATH"

if [ ! -s "$WORKLOAD_KUBECONFIG_PATH" ]; then
    echo "Error: Failed to create or populate workload kubeconfig at $WORKLOAD_KUBECONFIG_PATH"
    exit 1
fi
echo "Workload kubeconfig for '$cluster' prepared at $WORKLOAD_KUBECONFIG_PATH"
# Verify identity using the workload kubeconfig - this should show an admin user for the workload cluster
echo "Verifying identity on workload cluster '$cluster' using its kubeconfig:"
kubectl --kubeconfig="$WORKLOAD_KUBECONFIG_PATH" auth can-i '*' '*' --all-namespaces
# Attempt a simple read operation on the workload cluster using its kubeconfig
echo "Attempting to list namespaces on workload cluster '$cluster' using its kubeconfig:"
kubectl --kubeconfig="$WORKLOAD_KUBECONFIG_PATH" get ns

# Now, explicitly use the workload cluster's admin kubeconfig to apply the ClusterRoleBinding
echo "Granting 'system:serviceaccount:argo:argocd-workflow' cluster-admin rights on workload cluster '$cluster'"
kubectl --kubeconfig="$WORKLOAD_KUBECONFIG_PATH" apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argo-workflow-sa-mgmt-cluster-admin-binding # Descriptive name
subjects:
- kind: User 
  name: "system:serviceaccount:argo:argocd-workflow" # The SA from the management cluster
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-admin 
  apiGroup: rbac.authorization.k8s.io
EOF

if [ $? -ne 0 ]; then
  echo "Error: Failed to apply ClusterRoleBinding for 'system:serviceaccount:argo:argocd-workflow' on '$cluster'. Exiting."
  exit 1
fi
echo "Permissions granted to 'system:serviceaccount:argo:argocd-workflow' on '$cluster'."


### TEST ###
# echo "Installing ArgoCD in the workload cluster '$cluster'"
# kubectl --kubeconfig="$WORKLOAD_KUBECONFIG_PATH" create namespace argocd
# kubectl --kubeconfig="$WORKLOAD_KUBECONFIG_PATH" apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/core-install.yaml

# echo "Waiting for ArgoCD to be ready on workload cluster '$cluster'..."
# # Add a wait loop for ArgoCD pods if necessary, using $WORKLOAD_KUBECONFIG_PATH
# sleep 60 # Placeholder, replace with a proper readiness check for ArgoCD pods


argocd cluster --kubeconfig="$WORKLOAD_KUBECONFIG_PATH" add kubernetes-admin@kubernetes --name $cluster --label provider=vcluster --upsert -y --cluster-resources

# Allow ArgoCD to manage all Namespaces
argocd cluster set $cluster --name $cluster --namespace '*'

kubectl --kubeconfig="$WORKLOAD_KUBECONFIG_PATH" apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argocd-application-controller-clusterrole
rules:
- apiGroups:
  - '*'
  resources:
  - '*'
  verbs:
  - '*'
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-application-controller-clusterrole-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: argocd-application-controller-clusterrole
subjects:
- kind: ServiceAccount
  name: argocd-application-controller
  namespace: default
EOF

# Install required ArgoCD CRDs on the target cluster
# echo "Installing ArgoCD CRDs on target cluster..."
# kubectl --kubeconfig="$WORKLOAD_KUBECONFIG_PATH" apply -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/crds/application-crd.yaml

# curl -X POST "http://gitea-http.gitea.svc.cluster.local:3000/api/v1/repos/migrate" \
#   -u 'gitea_admin:admin' \
#   -H "Content-Type: application/json" \
#   -d "{
#     "clone_addr": "http://gitea-http.gitea.svc.cluster.local:3000/gitea_admin/preview-repo-template.git",
#     "repo_name": "$cluster",
#     "uid": 1,
#     "private": false,
#     "mirror": false
#   }"

# curl -X POST "http://gitea-http.gitea.svc.cluster.local:3000/api/v1/repos/migrate" \
#   -u 'gitea_admin:admin' \
#   -H "Content-Type: application/json" \
#   -d "{
#     \"clone_addr\": \"https://github.com/PatrickLaabs/preview-repo-template.git\",
#     \"repo_name\": \"$cluster\",
#     \"uid\": 1,
#     \"private\": false,
#     \"mirror\": false
#   }"

# sleep 5

# git clone "http://gitea-http.gitea.svc.cluster.local:3000/gitea_admin/${cluster}.git"

# echo "Configuring repository ${cluster}"
# find ./${cluster}/app-deployments -type f -name '*.yaml' -exec sed -i "s#repoURL: <REPLACE-REPO-URL>#repoURL: ${repourl}#" {} +
# find ./${cluster}/app-deployments -type f -name '*.yaml' -exec sed -i "s#cluster = \"<CLUSTER-NAME>\"#cluster = \"${cluster}\"#" {} +

# find ./basement-deployments -type f -name '*.yaml' -exec sed -i "s#repoURL: <REPLACE-REPO-URL>#repoURL: ${repourl}#" {} +
# find ./basement-deployments -type f -name '*.yaml' -exec sed -i "s#cluster = \"<CLUSTER-NAME>\"#cluster = \"${cluster}\"#" {} +

### Setting Credentials and logging in ###
# echo "Setting Git Configurations"

# cd ${cluster} || { echo "Failed to change directory to ${cluster}"; exit 1; }

# git config user.name PatrickLaabs
# git config user.email patrick.laabs@me.com
# git remote set-url origin http://gitea-http.gitea.svc.cluster.local:3000/gitea_admin/${cluster}.git
# git add -A
# git commit -m "Updating RepoURL for the Applications"
# git push origin main

# echo "encRepourl string: ${encRepourl}"

# # Wait a moment for the permissions to propagate
# sleep 5

# kubectl --kubeconfig="$WORKLOAD_KUBECONFIG_PATH" apply -f - << EOF
# ---
# apiVersion: argoproj.io/v1alpha1
# kind: Application
# metadata:
#   name: argocd-workload-clusters-apps
#   namespace: argocd
# spec:
#   project: default
#   source:
#     repoURL: ${repourl}
#     path: app-deployments
#     targetRevision: main
#   destination:
#     name: in-cluster
#     namespace: argocd
#   syncPolicy:
#     automated:
#       prune: true
#       selfHeal: true
# EOF