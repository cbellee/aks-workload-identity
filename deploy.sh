RGNAME=aks-workload-identity-rg
LOCATION='australiaeast'

az group create -n $RGNAME -l $LOCATION

DEP=$(az deployment group create -g $RGNAME -f main.bicep -o json)

OIDCISSUERURL=$(echo $DEP | jq -r '.properties.outputs.aksOidcIssuerUrl.value')

AKSCLUSTER=$(echo $DEP | jq -r '.properties.outputs.aksClusterName.value')
APP1KVNAME=$(echo $DEP | jq -r '.properties.outputs.kvApp1Name.value')
APP2KVNAME=$(echo $DEP | jq -r '.properties.outputs.kvApp2Name.value')
APP3KVNAME=$(echo $DEP | jq -r '.properties.outputs.kvApp3Name.value')
APP4KVNAME=$(echo $DEP | jq -r '.properties.outputs.kvApp4Name.value')
APP5KVNAME=$(echo $DEP | jq -r '.properties.outputs.kvApp5Name.value')

APP1=$(echo $DEP | jq -r '.properties.outputs.idApp1ClientId.value')
APP3=$(echo $DEP | jq -r '.properties.outputs.idApp3ClientId.value')
APP5=$(echo $DEP | jq -r '.properties.outputs.idApp5ClientId.value')

az aks get-credentials -n $AKSCLUSTER -g $RGNAME --overwrite-existing

APP2=$(az ad sp create-for-rbac --name "AksWiApp2" --query "appId" -o tsv)
APP2SPID="$(az ad sp show --id $APP2 --query id -o tsv)"

az deployment group create -g $RGNAME -f kvRbac.bicep -p kvName=$APP2KVNAME appclientId=$APP2SPID

#App4
CSICLIENTID=$(az aks show -g $RGNAME --name $AKSCLUSTER --query addonProfiles.azureKeyvaultSecretsProvider.identity.clientId -o tsv)
CSIOBJECTID=$(az aks show -g $RGNAME --name $AKSCLUSTER --query addonProfiles.azureKeyvaultSecretsProvider.identity.objectId -o tsv)

az deployment group create -g $RGNAME -f kvRbac.bicep -p kvName=$APP4KVNAME appclientId=$CSIOBJECTID

######################
# deploy applications

TENANTID=$(az account show --query tenantId -o tsv)

helm upgrade --install app1 charts/workloadIdApp1 \
    --set azureWorkloadIdentity.tenantId=$TENANTID,azureWorkloadIdentity.clientId=$APP1,keyvaultName=$APP1KVNAME,secretName=arbitrarySecret \
    -n app1 --create-namespace

helm upgrade --install app2 charts/workloadIdApp2 \
    --set azureWorkloadIdentity.tenantId=$TENANTID,azureWorkloadIdentity.clientId=$APP2,keyvaultName=$APP2KVNAME,secretName=arbitrarySecret \
    -n app2 --create-namespace

helm upgrade --install app3 charts/csiApp \
    --set azureKVIdentity.tenantId=$TENANTID,azureKVIdentity.clientId=$APP3,keyvaultName=$APP3KVNAME,secretName=arbitrarySecret \
    -n app3 --create-namespace

helm upgrade --install app4 charts/csiApp \
    --set azureKVIdentity.tenantId=$TENANTID,azureKVIdentity.clientId=$CSICLIENTID,keyvaultName=$APP4KVNAME,secretName=arbitrarySecret \
    -n app4 --create-namespace

helm upgrade --install app5 charts/workloadIdApp2 \
    --set nameOverride=workloadidapp5,azureWorkloadIdentity.tenantId=$TENANTID,azureWorkloadIdentity.clientId=$APP5,keyvaultName=$APP5KVNAME,secretName=arbitrarySecret \
    -n app5 --create-namespace

##################
# check workloads

APP2POD=$(kubectl get pod -n app2 -o=jsonpath='{.items[0].metadata.name}')
kubectl logs $APP2POD -n app2

###########################
# App 2 Federated Identity

APP2SVCACCNT="app2-workloadidapp2"
APP2NAMESPACE="app2"
APP2APPOBJECTID="$(az ad app show --id $APP2 --query id -o tsv)"

# Create federated identity credentials for use from an AKS Cluster Service Account
fedReqUrl="https://graph.microsoft.com/beta/applications/$APP2APPOBJECTID/federatedIdentityCredentials"
fedReqBody=$(jq -n --arg n "kubernetes-$AKSCLUSTER-$APP2NAMESPACE-app2" \
                   --arg i $OIDCISSUERURL \
                   --arg s "system:serviceaccount:$APP2NAMESPACE:$APP2SVCACCNT" \
                   --arg d "Kubernetes service account federated credential" \
             '{name:$n,issuer:$i,subject:$s,description:$d,audiences:["api://AzureADTokenExchange"]}')

echo $fedReqBody | jq -r
az rest --method POST --uri $fedReqUrl --body "$fedReqBody"

##############################
# App 3 VMSS Managed Identity

NODEPOOLNAME=$(echo $DEP | jq -r '.properties.outputs.aksUserNodePoolName.value')
RGNODE=$(echo $DEP | jq -r '.properties.outputs.nodeResourceGroup.value')
APP3RESID=$(echo $DEP | jq -r '.properties.outputs.idApp3Id.value')
VMSSNAME=$(az vmss list -g $RGNODE --query "[?tags.\"aks-managed-poolName\" == '$NODEPOOLNAME'].name" -o tsv)
az vmss identity assign -g $RGNODE -n $VMSSNAME --identities $APP3RESID

############
# Get Pods

APP1POD=$(kubectl get pod -n app1 -o=jsonpath='{.items[0].metadata.name}')
kubectl logs $APP1POD -n app1

APP2POD=$(kubectl get pod -n app2 -o=jsonpath='{.items[0].metadata.name}')
kubectl exec -it $APP2POD -n app2 -- cat /mnt/secrets-store/arbitrarySecret

APP3POD=$(kubectl get pod -n app3 -o=jsonpath='{.items[0].metadata.name}')
kubectl exec -it $APP3POD -n app3 -- cat /mnt/secrets-store/arbitrarySecret

APP4POD=$(kubectl get pod -n app4 -o=jsonpath='{.items[0].metadata.name}')
kubectl exec -it $APP4POD -n app4 -- cat /mnt/secrets-store/arbitrarySecret

APP5POD=$(kubectl get pod -n app5 -o=jsonpath='{.items[0].metadata.name}')
kubectl exec -it $APP5POD -n app5 -- cat /mnt/secrets-store/arbitrarySecret

