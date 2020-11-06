#!/bin/bash
set -eu

PWD=$(pwd)
BUILD_ROOT=${PWD}/_build
ISO_ROOT=${BUILD_ROOT}/root
IMAGES_ROOT=${ISO_ROOT}/images

PRODUCT_NAME=Zenko-Base
PRODUCT_LOWERNAME=zenko-base
BUILD_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
BUILD_HOST=$(hostname)

VERSION_SHORT=$(git describe --abbrev=0)
VERSION_FULL=${VERSION_SHORT}-dev
GIT_REVISION=$(git describe --long --always --tags --dirty)
ISO=${BUILD_ROOT}/${PRODUCT_LOWERNAME}-${VERSION_FULL}.iso

DOCKER=docker
DOCKER_OPTS=
DOCKER_SOCKET=${DOCKER_SOCKET:-unix:///var/run/docker.sock}
HARDLINK=hardlink
SKOPEO=skopeo
SKOPEO_OPTS="--override-os linux --insecure-policy"
OPERATOR_TAG=$(grep /operator: deps.txt | awk -F ':' '{print $2}')
SOLUTION_REGISTRY=metalk8s-registry-from-config.invalid/${PRODUCT_LOWERNAME}-${VERSION_FULL}

KUBEDB_SCRIPT_BRANCH_TAG=89fab34cf2f5d9e0bcc3c2d5b0f0599f94ff0dca

export KUBEDB_OPERATOR_TAG=${OPERATOR_TAG}
export KUBEDB_SCRIPT_LOCATION="curl -fsSL https://raw.githubusercontent.com/kubedb/installer/${KUBEDB_SCRIPT_BRANCH_TAG}/"
export KUBEDB_NAMESPACE=SOLUTION_ENV
export KUBEDB_SERVICE_ACCOUNT=kubedb-operator
export KUBEDB_OPERATOR_NAME=operator
export KUBEDB_ENABLE_RBAC=true
export KUBEDB_RUN_ON_MASTER=0
export KUBEDB_ENABLE_VALIDATING_WEBHOOK=false
export KUBEDB_ENABLE_MUTATING_WEBHOOK=false
export KUBEDB_DOCKER_REGISTRY=${SOLUTION_REGISTRY}
export KUBEDB_IMAGE_PULL_POLICY=IfNotPresent
export KUBEDB_ENABLE_ANALYTICS=false
export KUBEDB_ENABLE_STATUS_SUBRESOURCE=false
export KUBEDB_BYPASS_VALIDATING_WEBHOOK_XRAY=false
export KUBEDB_USE_KUBEAPISERVER_FQDN_FOR_AKS=true
export KUBEDB_PRIORITY_CLASS=system-cluster-critical

# grab our dependencies from our deps.txt file as an array
readarray -t DEP_IMAGES < deps.txt

function clean()
{
    echo cleaning
    rm -rf ${BUILD_ROOT}
    rm -rf ca.crt ca.key server.crt server.key
}

function mkdirs()
{
    echo making dirs
    mkdir -p ${ISO_ROOT}
    mkdir -p ${IMAGES_ROOT}
}

function kubedb_yamls()
{
    echo downloading kubedb yamls
    OPERATOR_PATH=${BUILD_ROOT}/operator.yaml

    yamls=(
        service-account
        rbac-list
        user-roles
        appcatalog-user-roles
        psp/operator
        psp/mongodb
        psp/redis
        kubedb-catalog/mongodb
        kubedb-catalog/redis
    )

    envsubst < operator.yaml > ${OPERATOR_PATH}
    echo --- >> ${OPERATOR_PATH}
    for y in "${yamls[@]}"; do
        ${KUBEDB_SCRIPT_LOCATION}deploy/${y}.yaml | envsubst >> ${OPERATOR_PATH}
        echo --- >> ${OPERATOR_PATH}
    done
}

function gen_manifest_yaml()
{
    cat > ${ISO_ROOT}/manifest.yaml <<EOF
apiVersion: solutions.metalk8s.scality.com/v1alpha1
kind: Solution
metadata:
  annotations:
    solutions.metalk8s.scality.com/display-name: ${PRODUCT_NAME}
    solutions.metalk8s.scality.com/git: ${GIT_REVISION}
    solutions.metalk8s.scality.com/development-release: true
    solutions.metalk8s.scality.com/build-timestamp: ${BUILD_TIMESTAMP}
    solutions.metalk8s.scality.com/build-host: ${BUILD_HOST}
  name: ${PRODUCT_LOWERNAME}
spec:
  version: ${VERSION_FULL}
EOF
}

# function copy_yamls()
# {
    # no yamls currently but other dependencies may require them
    # cp -R -f operator/ ${ISO_ROOT}/operator
# }

function copy_image()
{
    IMAGE_NAME=${1##*/}
    FULL_PATH=${IMAGES_ROOT}/${IMAGE_NAME/:/\/}
    mkdir -p ${FULL_PATH}
    ${SKOPEO} ${SKOPEO_OPTS} copy \
        --format v2s2 --dest-compress \
        --src-daemon-host ${DOCKER_SOCKET} \
        docker-daemon:${1} \
        dir:${FULL_PATH}
}

function dedupe()
{
    ${HARDLINK} -c ${IMAGES_ROOT}
}

function build_registry_config()
{
    docker run \
        --name static-oci-registry \
        --mount type=bind,source=${ISO_ROOT}/images,destination=/var/lib/images \
        --mount type=bind,source=${ISO_ROOT},destination=/var/run \
        --rm \
        docker.io/nicolast/static-container-registry:latest \
            python3 static-container-registry.py \
            --name-prefix '{{ repository }}' \
            --server-root '{{ registry_root }}' \
            --omit-constants \
            /var/lib/images > ${ISO_ROOT}/registry-config.inc.j2
    rm ${ISO_ROOT}/static-container-registry.conf -f
}

function build_iso()
{
    mkisofs -output ${ISO} \
        -quiet \
        -rock \
        -joliet \
        -joliet-long \
        -full-iso9660-filenames \
        -volid "${PRODUCT_NAME} ${VERSION_FULL}" \
        --iso-level 3 \
        -gid 0 \
        -uid 0 \
        -input-charset iso8859-1 \
        -output-charset iso8859-1 \
        ${ISO_ROOT}
    sha256sum ${ISO} > ${ISO_ROOT}/SHA256SUM
    echo ISO File at ${ISO}
    echo SHA256 for ISO:
    cat ${ISO_ROOT}/SHA256SUM
}

# run everything in order
clean
mkdirs
kubedb_yamls
gen_manifest_yaml
# copy_yamls
for img in "${DEP_IMAGES[@]}"; do
    # only pull if the image isnt already local
    echo downloading ${img}
    ${DOCKER} image inspect ${img} > /dev/null 2>&1 || ${DOCKER} ${DOCKER_OPTS} pull ${img}
    copy_image ${img}
done
dedupe
build_registry_config
build_iso
echo DONE
