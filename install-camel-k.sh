#!/bin/bash

export YAKS_IMAGE_NAME="docker.io/yaks/yaks"
export YAKS_VERSION="0.9.0-202203140033"
export DEFAULT_REGISTRY_IMAGE=registry:2
export DEFAULT_REGISTRY_NAME=kind-docker-registry
export DEFAULT_REGISTRY_PORT=5001
export DEFAULT_CLUSTER_NAME=kind
export DEFAULT_NEXUS_NAME=kind-my-nexus
export DEFAULT_NEXUS_PORT=8091
export DOCKER_USER=lordrip
export RUNTIME_VERSION="1.6.0-SNAPSHOT"

# Check for kind being installed
kind > /dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "kind found"
else
  echo "kind was not found, Installing it"
  curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.17.0/kind-linux-amd64
  chmod +x ./kind
  sudo mv ./kind /usr/local/bin/kind
fi

# Reset kind cluster
kind delete cluster
kind create cluster

# Check for kubectl being installed
kubectl version > /dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "kubectl found"
else
  echo "kubectl was not found, Downloading it"
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

  echo "Checking kubectl checksum"
  curl -LO "https://dl.k8s.io/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl.sha256"

  echo "Installing kubectl"
  chmod +x ./kubectl
  sudo mv ./kubectl /usr/local/bin/kubectl
fi

# Check for camel client being installed
kamel > /dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "kamel client found"
else
  echo "kamel client wa not found, please install it to continue"
  echo "you can download it from here: https://github.com/apache/camel-k/releases"

  exit 127
fi

# Ask for docker password to be able to download images
read -r -s -p "Docker registry password: " DOCKER_P

echo "Installing secrets"
kubectl -n default create secret docker-registry external-registry-secret --docker-username $DOCKER_USER --docker-password $DOCKER_P

# Create registry container unless it already exists
echo "Creating and starting registry"
if [ "$(docker inspect -f '{{.State.Running}}' "${DEFAULT_REGISTRY_NAME}" 2>/dev/null || true)" != 'true' ]; then
  docker run \
    -d --restart=no -p "127.0.0.1:${DEFAULT_REGISTRY_PORT}:5000" --name "${DEFAULT_REGISTRY_NAME}" \
    registry:2
else
  docker stop "${DEFAULT_REGISTRY_NAME}"
fi
docker start "${DEFAULT_REGISTRY_NAME}"

echo "Installing kamel operator"
if [[ "$@" == *"dev"* ]]; then
  echo "Installing with dev mode"
  kamel install --skip-operator-setup --olm=false -n default --registry docker.io --organization $DOCKER_USER --registry-secret external-registry-secret --runtime-version $RUNTIME_VERSION

  echo "Removing operator just in case"
  kubectl delete pod -l name=camel-k-operator || true
  echo "Installing generated dev crds"
  find ~/repos/camel-k/config/crd/bases/ -maxdepth 1 -name '*.yaml' -exec kubectl apply -f {} \;
else
  echo "Installing without dev mode.To enable dev mode use 'dev' as parameter"
  kamel install --olm=false -n default --registry docker.io --organization $DOCKER_USER --registry-secret external-registry-secret --wait
fi

echo "Installing kamelets"
find ~/repos/camel-kamelets/kamelets -maxdepth 1 -name '*.kamelet.yaml' -exec kubectl apply -f {} \;

if [[ "$@" == *"yaks"* ]]; then
  echo "Installing yaks"
  yaks install --operator-image $YAKS_IMAGE_NAME:$YAKS_VERSION
else
  echo "Skipping yaks installation. To enable it use 'yaks' as parameter"
fi

echo "Make sure nexus is available"
if [ "$(docker inspect -f '{{.State.Running}}' "${DEFAULT_NEXUS_NAME}" 2>/dev/null || true)" != 'true' ]; then
  docker run \
    -d --restart=no -p "127.0.0.1:${DEFAULT_NEXUS_PORT}:8081" --name "${DEFAULT_NEXUS_NAME}" \
    sonatype/nexus3
else
  docker stop "${DEFAULT_NEXUS_NAME}"
fi
docker start "${DEFAULT_NEXUS_NAME}"

if [[ "$@" == *"knative"* ]]; then
  echo "Install knative serving"
  kubectl apply --filename https://github.com/knative/serving/releases/download/knative-v1.0.0/serving-crds.yaml
  kubectl apply --filename https://github.com/knative/serving/releases/download/knative-v1.0.0/serving-core.yaml
  curl -Lo kourier.yaml https://github.com/knative/net-kourier/releases/download/knative-v1.0.0/kourier.yaml
  kubectl apply -f ~/kourier.yaml
   kubectl patch configmap/config-network \
    --namespace knative-serving \
    --type merge \
    --patch '{"data":{"ingress-class":"kourier.ingress.networking.knative.dev"}}'
  kubectl patch configmap/config-domain \
    --namespace knative-serving \
    --type merge \
    --patch '{"data":{"127.0.0.1.sslip.io":""}}'
  kubectl create clusterrole deployer --verb=get,list,watch,create,delete,patch,update --resource=deployments.apps
  kubectl create clusterrolebinding deployer-srvacct-default-binding --clusterrole=deployer --serviceaccount=default:camel-k-operator
else
  echo "Skipping KNative. To enable it use 'knative' as parameter"
fi

kubectl wait --for=condition=Ready pod -l name=camel-k-operator
kubectl cluster-info
echo "If no operator, run it with "
echo "export WATCH_NAMESPACE=default"
echo "kamel operator"

if [[ "$@" == *"dev"* ]]; then
  echo "If running operator manually: "
  echo "export WATCH_NAMESPACE=default"
  echo "kamel operator"
fi
