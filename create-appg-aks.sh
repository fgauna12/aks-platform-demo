#!/bin/bash

set -e

if [ -z "$1" ]
  then
    echo "Please provide the name of the cluster"
    exit 1
fi

echo "Creating cluster with base name $1"

CLUSTER_NAME="azaks-$1-sbx"
RESOURCE_GROUP_NAME="rg-$CLUSTER_NAME-sbx"
VNET_NAME="vnet-$CLUSTER_NAME-sbx"
IDENTITY_NAME="$CLUSTER_NAME-identity"

echo $'\n=== Creating resource group'
# Create the resource group
az group create -n $RESOURCE_GROUP_NAME -l eastus --tags customer=Internal owner=facundo@boxboat.com aks-start-stop=true

echo $'\n=== Creating virtual network'
# Create the virtual network and first subnet for AKS
az network vnet create -n $VNET_NAME -g $RESOURCE_GROUP_NAME -l eastus --subnet-name aks --address-prefixes 10.0.0.0/16 --subnet-prefixes 10.0.0.0/24

echo $'\n=== Adding subnet'
# Create the subnet for the application gateway
az network vnet subnet create -g $RESOURCE_GROUP_NAME -n appg --vnet-name $VNET_NAME --address-prefixes 10.0.1.0/24

echo $'\n=== Creating managed identity'
# Create a managed identity
IDENTITY_RESULT=$(az identity create --name $IDENTITY_NAME --resource-group $RESOURCE_GROUP_NAME)

PRINCIPAL_ID=$(echo $IDENTITY_RESULT | jq -r '.principalId')
IDENTITY_ID=$(echo $IDENTITY_RESULT | jq -r '.id')

echo $'\n=== Waiting for 1 minute'
sleep 1m

echo $'\n=== Granting \'Network Contributor\' role assignments to the managed identity'
# Grant network contributor role to the managed identity
az role assignment create --role "Network Contributor" --assignee $PRINCIPAL_ID  

AKS_SUBNET=$(az network vnet subnet show -g $RESOURCE_GROUP_NAME --vnet-name $VNET_NAME -n aks --query "id" -o tsv)

echo $'\n=== Creating AKS cluster'
az aks create -n $CLUSTER_NAME \
       -g $RESOURCE_GROUP_NAME \
       -l eastus \
       --network-plugin azure \
       --generate-ssh-keys \
       --vnet-subnet-id $AKS_SUBNET \
       --enable-managed-identity \
       --assign-identity $IDENTITY_ID \
       --dns-service-ip 10.1.0.10 \
       --service-cidr 10.1.0.0/24 \
       --node-count 1

az aks get-credentials -n $CLUSTER_NAME -g $RESOURCE_GROUP_NAME

IS_IP_AVAILABLE=$(az network vnet check-ip-address --name $VNET_NAME -g $RESOURCE_GROUP_NAME --ip-address 10.0.0.100 | jq -r '.available')

if [[ "$IS_IP_AVAILABLE" -ne 'yes' ]]
then 
  echo "Private static ip address not available in the vnet"
  exit 1
fi

echo $'\n=== Creating NGINX configuration file'
cat << EOF > internal-ingress.yaml
controller:
  service:
    loadBalancerIP: 10.0.0.100
    annotations:
      service.beta.kubernetes.io/azure-load-balancer-internal: "true"
EOF

echo $'\n=== Creating Kubernetes namespace for ingress'
# Create a namespace for your ingress resources
kubectl create namespace ingress

echo $'\n=== Adding NGINX Helm chart repository'
# Add the ingress-nginx repository
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx

echo $'\n=== Installing NGINX ingress controller'
# Use Helm to deploy an NGINX ingress controller
helm install nginx-ingress ingress-nginx/ingress-nginx \
    --namespace ingress \
    -f internal-ingress.yaml \
    --set controller.replicaCount=2 \
    --set controller.nodeSelector."beta\.kubernetes\.io/os"=linux \
    --set defaultBackend.nodeSelector."beta\.kubernetes\.io/os"=linux \
    --set controller.admissionWebhooks.patch.nodeSelector."beta\.kubernetes\.io/os"=linux

exit 0
