#!/usr/bin/env bash

# Copyright 2020 TiKV Project Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# See the License for the specific language governing permissions and
# limitations under the License.

#
# This command runs tikv-operator in Kubernetes.
#

set -o errexit
set -o nounset
set -o pipefail

ROOT=$(unset CDPATH && cd $(dirname "${BASH_SOURCE[0]}")/.. && pwd)
cd $ROOT

source "${ROOT}/hack/lib.sh"

function usage() {
    cat <<'EOF'
This commands run tikv-operator in Kubernetes.

Usage: hack/local-up-operator.sh [-hd]

    -h      show this message and exit
    -i      install dependencies only

Environments:

    PROVIDER              Kubernetes provider. Defaults: kind.
    CLUSTER               the name of e2e cluster. Defaults to kind for kind provider.
    KUBECONFIG            path to the kubeconfig file, defaults: ~/.kube/config
    KUBECONTEXT           context in kubeconfig file, defaults to current context
    NAMESPACE             Kubernetes namespace in which we run our tikv-operator.
    IMAGE_REPO            image repo
    IMAGE_TAG             image tag
    SKIP_IMAGE_BUILD      skip build and push images

EOF
}

installOnly=false
while getopts "h?i" opt; do
    case "$opt" in
    h|\?)
        usage
        exit 0
        ;;
    i)
      installOnly=true
        ;;
    esac
done

PROVIDER=${PROVIDER:-kind}
CLUSTER=${CLUSTER:-}
KUBECONFIG=${KUBECONFIG:-~/.kube/config}
KUBECONTEXT=${KUBECONTEXT:-}
NAMESPACE=${NAMESPACE:-tikv-operator}
IMAGE_REPO=${IMAGE_REPO:-localhost:5000/tikv}
IMAGE_TAG=${IMAGE_TAG:-latest}
SKIP_IMAGE_BUILD=${SKIP_IMAGE_BUILD:-}

hack::ensure_kubectl
hack::ensure_kind
hack::ensure_helm

if [[ "$installOnly" == "true" ]]; then
    exit 0
fi

function hack::create_namespace() {
    local ns="$1"
    $KUBECTL_BIN create namespace $ns
    for ((i=0; i < 30; i++)); do
        local phase=$(kubectl get ns $ns -ojsonpath='{.status.phase}')
        if [ "$phase" == "Active" ]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

function hack::wait_for_deploy() {
    local ns="$1"
    local name="$2"
    local retries="${3:-300}"
    echo "info: waiting for pods of deployment $ns/$name are ready (retries: $retries, interval: 1s)"
    for ((i = 0; i < retries; i++)) {
        read a b <<<$($KUBECTL_BIN --context $KUBECONTEXT -n $ns get deploy/$name -ojsonpath='{.spec.replicas} {.status.readyReplicas}{"\n"}')
        if [[ "$a" -gt 0 && "$a" -eq "$b" ]]; then
            echo "info: all pods of deployment $ns/$name are ready (desired: $a, ready: $b)"
            return 0
        fi
        echo "info: pods of deployment $ns/$name (desired: $a, ready: $b)"
        sleep 1
    }
    echo "info: timed out waiting for pods of deployment $ns/$name are ready"
    return 1
}

function hack::cluster_exists() {
    local c="$1"
    for n in $($KIND_BIN get clusters); do
        if [ "$n" == "$c" ]; then
            return 0
        fi
    done
    return 1
}

echo "info: checking clusters"

if [ "$PROVIDER" == "kind" ]; then
    if [ -z "$CLUSTER" ]; then
        CLUSTER=kind
    fi
    if ! hack::cluster_exists "$CLUSTER"; then
        echo "error: kind cluster '$CLUSTER' not found, please create it or specify the right cluster name with CLUSTER environment"
        exit 1
    fi
else
    echo "erorr: only kind PROVIDER is supported"
    exit 1
fi

if [ -z "$KUBECONTEXT" ]; then
    KUBECONTEXT=$(kubectl config current-context)
    echo "info: KUBECONTEXT is not set, current context $KUBECONTEXT is used"
fi

if [ -z "$SKIP_IMAGE_BUILD" ]; then
    echo "info: building docker images"
    IMAGE_REPO=$IMAGE_REPO IMAGE_TAG=$IMAGE_TAG make image
else
    echo "info: skip building docker images"
fi

echo "info: loading images into cluster"
images=(
    $IMAGE_REPO/tikv-operator:${IMAGE_TAG}
)
for n in ${images[@]}; do
    echo "info: loading image $n"
    $KIND_BIN load docker-image --name $CLUSTER $n
done

RELEASE_NAME=tikv-operator-dev
echo "info: uninstall tikv-operator"
$HELM_BIN -n "$NAMESPACE" uninstall ${RELEASE_NAME} || true

echo "info: create namespace '$NAMESPACE' if absent"
if ! $KUBECTL_BIN get ns "$NAMESPACE" &>/dev/null; then
    hack::create_namespace "$NAMESPACE"
fi

echo "info: installing crds"
$KUBECTL_BIN apply -f manifests/crd.v1beta1.yaml

echo "info: deploying tikv-operator"
helm_args=(
    install
    --namespace "$NAMESPACE"
    --set-string image.repository=${IMAGE_REPO}/tikv-operator
    --set-string image.tag=${IMAGE_TAG}
    --set image.args={-v=4}
    ${RELEASE_NAME}
    ./charts/tikv-operator
)
 
echo "$HELM_BIN ${helm_args[@]}"
$HELM_BIN ${helm_args[@]} 

deploys=(
    tikv-operator-dev
)
for deploy in ${deploys[@]}; do
    echo "info: waiting for $NAMESPACE/$deploy to be ready"
    hack::wait_for_deploy "$NAMESPACE" "$deploy"
done
