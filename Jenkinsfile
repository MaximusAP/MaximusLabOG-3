pipeline {
    agent { label 'docker-slave' }

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timeout(time: 20, unit: 'MINUTES')
    }

    environment {
        GIT_REPOSITORY = 'https://github.com/MaximusAP/MaximusLabOG-3.git'
        GIT_BRANCH     = 'master'

        NEXUS_REGISTRY = '192.168.2.128:8082'
        IMAGE_NAME     = 'maximuslabog-web'
        IMAGE_TAG      = "${BUILD_NUMBER}"
        DOCKER_IMAGE   = "${NEXUS_REGISTRY}/${IMAGE_NAME}:${BUILD_NUMBER}"
        LATEST_IMAGE   = "${NEXUS_REGISTRY}/${IMAGE_NAME}:latest"

        K8S_NAMESPACE  = 'maximuslabog'
        K8S_DEPLOYMENT = 'maximuslabog-web'
        K8S_SERVICE    = 'maximuslabog-web'
        APP_LABEL      = 'maximuslabog-web'

        SMOKE_PORT     = '18080'
        VERIFY_PORT    = '18081'
    }

    stages {
        stage('Checkout GitHub') {
            steps {
                deleteDir()

                git branch: "${GIT_BRANCH}",
                    url: "${GIT_REPOSITORY}"

                sh '''
                    set -eux

                    echo "===== Git commit ====="
                    git log -1 --oneline

                    echo "===== Workspace files ====="
                    find . -maxdepth 3 -type f | sort

                    echo "===== Validate required files ====="
                    test -f Dockerfile
                    test -f nginx.conf
                    test -f index.html
                    test -f k8s/k8s-deployment.yaml

                    echo "===== Validate Kubernetes image placeholder ====="
                    grep -q 'IMAGE_PLACEHOLDER' k8s/k8s-deployment.yaml
                    grep -n 'IMAGE_PLACEHOLDER' k8s/k8s-deployment.yaml
                '''
            }
        }

        stage('Tool Validation') {
            steps {
                sh '''
                    set -eux

                    echo "===== Jenkins agent information ====="
                    whoami
                    hostname
                    pwd

                    echo "===== Installed tools ====="
                    git --version
                    docker --version
                    kubectl version --client
                    curl --version | head -1

                    echo "===== Docker daemon connectivity ====="
                    docker ps
                '''
            }
        }

        stage('Build Docker Image') {
            steps {
                sh '''
                    set -eux

                    echo "===== Build Docker image ====="
                    echo "Image: ${DOCKER_IMAGE}"

                    docker build --pull --tag "${DOCKER_IMAGE}" .
                    docker image inspect "${DOCKER_IMAGE}" >/dev/null
                '''
            }
        }

        stage('Local Smoke Test') {
            steps {
                sh '''
                    set -eux

                    CONTAINER_NAME="maximuslabog-smoke-${BUILD_NUMBER}"

                    cleanup_smoke_test() {
                        echo "===== Smoke-test container logs ====="
                        docker logs "${CONTAINER_NAME}" 2>/dev/null || true

                        echo "===== Remove smoke-test container ====="
                        docker rm --force "${CONTAINER_NAME}" >/dev/null 2>&1 || true
                    }

                    trap cleanup_smoke_test EXIT

                    docker rm --force "${CONTAINER_NAME}" >/dev/null 2>&1 || true

                    EXISTING_CONTAINER=$(docker ps \
                        --filter "publish=${SMOKE_PORT}" \
                        --format '{{.ID}}' | head -1)

                    if [ -n "${EXISTING_CONTAINER}" ]; then
                        echo "Port ${SMOKE_PORT} is already allocated by ${EXISTING_CONTAINER}"
                        docker ps --filter "id=${EXISTING_CONTAINER}"
                        exit 1
                    fi

                    echo "===== Start smoke-test container ====="
                    docker run --detach \
                        --name "${CONTAINER_NAME}" \
                        --publish "${SMOKE_PORT}:80" \
                        "${DOCKER_IMAGE}"

                    HEALTHY=false

                    for ATTEMPT in $(seq 1 20); do
                        echo "Health-check attempt: ${ATTEMPT}"

                        if curl --fail --silent --show-error \
                            "http://192.168.2.127:${SMOKE_PORT}/healthz"; then
                            echo
                            HEALTHY=true
                            break
                        fi

                        sleep 2
                    done

                    if [ "${HEALTHY}" != 'true' ]; then
                        echo "Container did not become healthy"
                        exit 1
                    fi

                    HEALTH_HTTP_CODE=$(curl --silent --output /dev/null \
                        --write-out '%{http_code}' \
                        "http://192.168.2.127:${SMOKE_PORT}/healthz")

                    test "${HEALTH_HTTP_CODE}" = '200'

                    WEBSITE_HTTP_CODE=$(curl --silent --output /dev/null \
                        --write-out '%{http_code}' \
                        "http://192.168.2.127:${SMOKE_PORT}/")

                    test "${WEBSITE_HTTP_CODE}" = '200'

                    WEBSITE_SIZE=$(curl --fail --silent --show-error \
                        "http://192.168.2.127:${SMOKE_PORT}/" | wc -c)

                    test "${WEBSITE_SIZE}" -ge 1000
                '''
            }
        }

        stage('Push Image to Nexus') {
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'nexus-docker-credentials',
                        usernameVariable: 'NEXUS_USERNAME',
                        passwordVariable: 'NEXUS_PASSWORD'
                    )
                ]) {
                    sh '''
                        set -eu

                        echo "===== Login to Nexus Docker registry ====="
                        set +x
                        printf '%s' "${NEXUS_PASSWORD}" | docker login \
                            "${NEXUS_REGISTRY}" \
                            --username "${NEXUS_USERNAME}" \
                            --password-stdin
                        set -x

                        echo "===== Push versioned image ====="
                        docker push "${DOCKER_IMAGE}"

                        echo "===== Tag and push latest image ====="
                        docker tag "${DOCKER_IMAGE}" "${LATEST_IMAGE}"
                        docker push "${LATEST_IMAGE}"
                    '''
                }
            }
        }

        stage('Render Kubernetes Manifest') {
            steps {
                withCredentials([
                    file(
                        credentialsId: 'kubeconfig-lab',
                        variable: 'KUBECONFIG_FILE'
                    )
                ]) {
                    sh '''
                        set -eux
                        export KUBECONFIG="${KUBECONFIG_FILE}"

                        echo "===== Verify Kubernetes connectivity ====="
                        kubectl cluster-info
                        kubectl get nodes

                        echo "===== Render Kubernetes manifest ====="
                        sed "s|IMAGE_PLACEHOLDER|${DOCKER_IMAGE}|g" \
                            k8s/k8s-deployment.yaml \
                            > rendered-k8s.yaml

                        echo "===== Confirm rendered image ====="
                        grep -n 'image:' rendered-k8s.yaml

                        if grep -q 'IMAGE_PLACEHOLDER' rendered-k8s.yaml; then
                            echo 'ERROR: IMAGE_PLACEHOLDER still exists'
                            exit 1
                        fi

                        echo "===== Server-side manifest validation ====="
                        kubectl apply \
                            --dry-run=server \
                            -f rendered-k8s.yaml
                    '''
                }
            }
        }

        stage('Deploy to Kubernetes') {
            steps {
                withCredentials([
                    file(
                        credentialsId: 'kubeconfig-lab',
                        variable: 'KUBECONFIG_FILE'
                    ),
                    usernamePassword(
                        credentialsId: 'nexus-docker-credentials',
                        usernameVariable: 'NEXUS_USERNAME',
                        passwordVariable: 'NEXUS_PASSWORD'
                    )
                ]) {
                    sh '''
                        set -eu
                        export KUBECONFIG="${KUBECONFIG_FILE}"

                        echo "===== Create or update namespace ====="
                        kubectl create namespace "${K8S_NAMESPACE}" \
                            --dry-run=client \
                            -o yaml | kubectl apply -f -

                        echo "===== Create or update Nexus pull secret ====="
                        set +x
                        kubectl create secret docker-registry nexus-regcred \
                            --namespace "${K8S_NAMESPACE}" \
                            --docker-server="${NEXUS_REGISTRY}" \
                            --docker-username="${NEXUS_USERNAME}" \
                            --docker-password="${NEXUS_PASSWORD}" \
                            --dry-run=client \
                            -o yaml | kubectl apply -f -
                        set -x

                        echo "===== Apply Kubernetes manifest ====="
                        kubectl apply -f rendered-k8s.yaml

                        echo "===== Wait for deployment rollout ====="
                        kubectl rollout status \
                            deployment/"${K8S_DEPLOYMENT}" \
                            --namespace "${K8S_NAMESPACE}" \
                            --timeout=300s
                    '''
                }
            }
        }

        stage('End-to-End Verification') {
            steps {
                withCredentials([
                    file(
                        credentialsId: 'kubeconfig-lab',
                        variable: 'KUBECONFIG_FILE'
                    )
                ]) {
                    sh '''
                        set -eux
                        export KUBECONFIG="${KUBECONFIG_FILE}"

                        echo "===== Kubernetes resources ====="
                        kubectl get deployment,pods,service,ingress \
                            --namespace "${K8S_NAMESPACE}" \
                            -o wide

                        echo "===== Wait for application pods ====="
                        kubectl wait \
                            --namespace "${K8S_NAMESPACE}" \
                            --for=condition=Ready pod \
                            -l "app=${APP_LABEL}" \
                            --timeout=180s

                        echo "===== Verify deployed image ====="
                        ACTUAL_IMAGE=$(kubectl get deployment "${K8S_DEPLOYMENT}" \
                            --namespace "${K8S_NAMESPACE}" \
                            -o jsonpath='{.spec.template.spec.containers[0].image}')

                        echo "Expected image: ${DOCKER_IMAGE}"
                        echo "Actual image:   ${ACTUAL_IMAGE}"
                        test "${ACTUAL_IMAGE}" = "${DOCKER_IMAGE}"

                        echo "===== Port-forward service ====="
                        kubectl port-forward \
                            --namespace "${K8S_NAMESPACE}" \
                            service/"${K8S_SERVICE}" \
                            "${VERIFY_PORT}:80" \
                            > /tmp/maximus-port-forward.log 2>&1 &

                        PF_PID=$!

                        cleanup_port_forward() {
                            kill "${PF_PID}" >/dev/null 2>&1 || true
                            cat /tmp/maximus-port-forward.log || true
                        }

                        trap cleanup_port_forward EXIT

                        READY=false

                        for ATTEMPT in $(seq 1 20); do
                            if curl --fail --silent --show-error \
                                "http://127.0.0.1:${VERIFY_PORT}/healthz"; then
                                echo
                                READY=true
                                break
                            fi

                            sleep 2
                        done

                        if [ "${READY}" != 'true' ]; then
                            echo 'Service endpoint did not become ready'
                            exit 1
                        fi

                        echo "===== Verify health endpoint ====="
                        curl --fail --silent --show-error \
                            "http://127.0.0.1:${VERIFY_PORT}/healthz"

                        echo "===== Verify website endpoint ====="
                        curl --fail --silent --show-error \
                            "http://127.0.0.1:${VERIFY_PORT}/" | grep -qi 'Maximus'

                        echo "End-to-end verification completed successfully."
                    '''
                }
            }
        }
    }

    post {
        always {
            sh '''
                set +e

                echo "===== Pipeline cleanup ====="
                docker rm --force "maximuslabog-smoke-${BUILD_NUMBER}" \
                    >/dev/null 2>&1 || true

                docker logout "${NEXUS_REGISTRY}" >/dev/null 2>&1 || true

                docker image rm "${LATEST_IMAGE}" >/dev/null 2>&1 || true
                docker image rm "${DOCKER_IMAGE}" >/dev/null 2>&1 || true

                exit 0
            '''

            archiveArtifacts artifacts: 'rendered-k8s.yaml',
                allowEmptyArchive: true,
                fingerprint: true
        }

        success {
            echo """
============================================================
PIPELINE SUCCESS
============================================================
Image:
${DOCKER_IMAGE}

Namespace:
${K8S_NAMESPACE}

Deployment:
${K8S_DEPLOYMENT}
============================================================
"""
        }

        failure {
            echo """
============================================================
PIPELINE FAILED
============================================================
Review the first failed stage in the console output.

Image attempted:
${DOCKER_IMAGE}

Namespace:
${K8S_NAMESPACE}
============================================================
"""
        }
    }
}
