#!/bin/bash

set -e

echo "Creating cluster with base name $1"

CLUSTER_NAME="azaks-rancher-nonprod"
RESOURCE_GROUP_NAME="rg-$CLUSTER_NAME-mgnt"
VNET_NAME="vnet-$CLUSTER_NAME-mgnt"
IDENTITY_NAME="$CLUSTER_NAME-identity"

echo $'\n=== Creating resource group'
# Create the resource group
az group create -n $RESOURCE_GROUP_NAME -l eastus --tags customer=Internal owner=facundo@boxboat.com aks-start-stop=true

echo $'\n=== Creating virtual network'
# Create the virtual network and first subnet for AKS
az network vnet create -n $VNET_NAME -g $RESOURCE_GROUP_NAME -l eastus --subnet-name aks --address-prefixes 10.1.0.0/16 --subnet-prefixes 10.1.0.0/24

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
       --dns-service-ip 10.2.0.10 \
       --service-cidr 10.2.0.0/24

az aks get-credentials -n $CLUSTER_NAME -g $RESOURCE_GROUP_NAME

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
    --set controller.replicaCount=2 \
    --set controller.nodeSelector."beta\.kubernetes\.io/os"=linux \
    --set defaultBackend.nodeSelector."beta\.kubernetes\.io/os"=linux \
    --set controller.admissionWebhooks.patch.nodeSelector."beta\.kubernetes\.io/os"=linux

exit 0
