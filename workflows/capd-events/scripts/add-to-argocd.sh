#!/bin/sh

argocd login argocd-server.argocd.svc.cluster.local:80 --plaintext --insecure --username admin --password frigg

cluster_ready=""
cluster=$1
sleep 300

# Strip everything after the first hyphen to get "workloadcluster"
cluster_base="${cluster%%-*}"

if [[ "$cluster_base" == "mgmt-capd" ]]; then
  echo "Provisioned Cluster is a management-cluster. Exiting script."
  exit 1
else
  echo "Provisioned Cluster is a workload Cluster. Continuing with the script"
  echo "Cluster name:" "$cluster_base"
fi

while [ -z "$cluster_ready" ]
do
    sleep 20
    kubectl get cluster $cluster_base -n default
    cluster_ready=$(kubectl get cluster $cluster_base -o json -n default | jq -r '. | select(.status.phase=="Provisioned")')
done

kubectl config set-cluster in-cluster --server=https://kubernetes.default.svc.cluster.local --certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt --embed-certs=true ;
kubectl config set-credentials clusterctl --token=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) ;
kubectl config set-context in-cluster --cluster in-cluster --user clusterctl --namespace argocd ;
kubectl config use-context in-cluster ;

echo "Print in-clusters current used context: "
kubectl config current-context

# clusterctl get kubeconfig $cluster -n default > $HOME/.kube/vsphere-cluster.yaml
kubectl -n default get secret/$cluster_base-kubeconfig -o json \
    | jq -r .data.value \
    | base64 --decode \
    > $HOME/.kube/capdworkloadcluster-cluster.yaml

# replicate the kubeconfig in-cluster for spire-server usage
#kubectl create secret generic $cluster-kubeconfig \
#  --from-file=$cluster-kubeconfig=$HOME/.kube/vsphere-cluster.yaml \
#  --namespace=spire-system

export KUBECONFIG="$HOME/.kube/config:$HOME/.kube/capdworkloadcluster-cluster.yaml"

kubectl config set-context $cluster_base --cluster $cluster_base --user $cluster_base-admin
kubectl config use-context $cluster_base --cluster $cluster_base --user $cluster_base-admin
sleep 30

argocd cluster add $cluster_base-admin@$cluster_base --name $cluster_base --label provider=capd --upsert -y --cluster-resources --namespace argocd

# Allow ArgoCD to manage all Namespaces
argocd cluster set $cluster_base --name $cluster_base --namespace '*'

kubectl apply -f - <<EOF
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

### Creating Deployment Keys ###
ssh-keygen -t rsa -C "friggs deploykey sets" -N "" -f ~/.ssh/id_rsa

export privateKey="$(cat ~/.ssh/id_rsa)"
export encPrivateKey="$(echo "$privateKey" | base64 | tr -d '\n')"

export publicKey="$(cat ~/.ssh/id_rsa.pub)"
export encPublicKey="$(echo "$publicKey" | base64 | tr -d '\n')"
echo "======= Public Key ======="
echo $publicKey

export repourl=git@github.com:GITHUB_USERNAME/${cluster_base}.git
export encRepourl="$(echo "$repourl" | tr -d '\n' | base64)"

# Create Remote's Repositories for ArgoCD Usage on Github
gh auth login

#gh repo create GITHUB_USERNAME/"${cluster_base}" --private --template=PatrickLaabs/friggs-workload-repo-template
gh repo create GITHUB_USERNAME/"${cluster_base}" --private --template=GITOPS_TEMPLATE_REPO
sleep 10

#gh api \
#  --method PUT \
#  -H "Accept: application/vnd.github+json" \
#  -H "X-GitHub-Api-Version: 2022-11-28" \
#  /orgs/<ORGNAME>/teams/<TEAMSLUG>/repos/<ORGNAME>/${cluster_base} \
#  -f permission='push'

gh ssh-key add ~/.ssh/id_rsa.pub --title "${cluster_base}-frigg-public-key"

gh repo clone GITHUB_USERNAME/"${cluster_base}" && cd ${cluster_base}
sleep 5

echo "Configuring repository ${cluster_base}"
find ./app-deployments -type f -name '*.yaml' -exec sed -i "s#repoURL: <REPLACE-REPO-URL>#repoURL: ${repourl}#" {} +
find ./app-deployments -type f -name '*.yaml' -exec sed -i "s#cluster = \"<CLUSTER-NAME>\"#cluster = \"${cluster_base}\"#" {} +

find ./applicationsets-deployments -type f -name '*.yaml' -exec sed -i "s#repoURL: <REPLACE-REPO-URL>#repoURL: ${repourl}#" {} +
find ./applicationsets-deployments -type f -name '*.yaml' -exec sed -i "s#cluster = \"<CLUSTER-NAME>\"#cluster = \"${cluster_base}\"#" {} +

find ./basement-deployments -type f -name '*.yaml' -exec sed -i "s#repoURL: <REPLACE-REPO-URL>#repoURL: ${repourl}#" {} +
find ./basement-deployments -type f -name '*.yaml' -exec sed -i "s#cluster = \"<CLUSTER-NAME>\"#cluster = \"${cluster_base}\"#" {} +

### Setting Credentials and logging in ###
echo "Setting Git Configurations"

git config user.name "GITHUB_USERNAME"
git config user.email "GITHUB_MAIL"
git remote set-url origin ${repourl}
git add -A
git commit -m "Updating RepoURL for the Applications"
git push origin main

echo "Printing Git Config: "
cat .git/config

### Transforming user-scoped SSH-Key into a repo-scoped Github Deploykey ###
keyID=$(gh ssh-key list | grep "${cluster_base}-frigg-public-key" | awk '{print $5}')
gh ssh-key delete $keyID -y
gh repo deploy-key add ~/.ssh/id_rsa.pub --allow-write --title "${cluster_base}-frigg-deploy-key"

### Add ArgoCD Application ###
kubectl config use-context $cluster_base-admin@$cluster_base

echo "encRepourl string: ${encRepourl}"

kubectl apply -f - << EOF
---
apiVersion: v1
kind: Secret
metadata:
  labels:
    argocd.argoproj.io/secret-type: repo-creds
  name: frigg-ssh-creds-${cluster_base}
  namespace: argocd
data:
  sshPrivateKey: ${encPrivateKey}
  url: ${encRepourl}
type: Opaque
---
apiVersion: v1
kind: Secret
metadata:
  labels:
    argocd.argoproj.io/secret-type: repository
  name: frigg-private-repo-${cluster_base}
  namespace: argocd
data:
  url: ${encRepourl}
type: Opaque
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd-infrastructure-apps
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${repourl}
    path: basement-deployments
    targetRevision: main
  destination:
    name: in-cluster
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd-workload-clusters-apps
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${repourl}
    path: app-deployments
    targetRevision: main
  destination:
    name: in-cluster
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd-workload-clusters-apps
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${repourl}
    path: applicationsets-deployments
    targetRevision: main
  destination:
    name: in-cluster
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF