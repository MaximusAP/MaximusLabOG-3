pipeline {
    agent { label 'docker-slave' }

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timeout(time: 25, unit: 'MINUTES')
        skipDefaultCheckout(true)
    }

    environment {
        GIT_REPOSITORY = 'https://github.com/MaximusAP/MaximusLabOG-3.git'
        GIT_BRANCH     = 'master'

        NEXUS_REGISTRY = '192.168.2.128:8082'
        IMAGE_NAME     = 'maximuslabog-web'
        DOCKER_IMAGE   = "${NEXUS_REGISTRY}/${IMAGE_NAME}:${BUILD_NUMBER}"
        LATEST_IMAGE   = "${NEXUS_REGISTRY}/${IMAGE_NAME}:latest"

        K8S_NAMESPACE  = 'maximuslabog'
        K8S_DEPLOYMENT = 'maximuslabog-web'
        K8S_SERVICE    = 'maximuslabog-web'
        APP_LABEL      = 'maximuslabog-web'

        SMOKE_PORT     = '18080'
        VERIFY_PORT    = '18081'
        RENDERED_FILE  = 'rendered-k8s.yaml'
    }

    stages {
        stage('Checkout') {
            steps {
                deleteDir()

                git branch: "${GIT_BRANCH}",
                    url: "${GIT_REPOSITORY}"

                sh '''
                    set -eux

                    echo '===== Git revision ====='
                    git log -1 --oneline

                    echo '===== Validate required files ====='
                    test -f Dockerfile
                    test -f nginx.conf
                    test -f index.html
                    test -f k8s/k8s-deployment.yaml
                    grep -q 'IMAGE_PLACEHOLDER' k8s/k8s-deployment.yaml
                '''
            }
        }

        stage('Validate Agent') {
            steps {
                sh '''
                    set -eux

                    whoami
                    hostname
                    git --version
                    docker --version
                    kubectl version --client
                    curl --version | head -1
                    docker ps
                '''
            }
        }

        stage('Build Image') {
            steps {
                sh '''
                    set -eux

                    echo "Building ${DOCKER_IMAGE}"
                    docker build --pull --tag "${DOCKER_IMAGE}" .
                    docker image inspect "${DOCKER_IMAGE}" >/dev/null
                '''
            }
        }

        stage('Container Smoke Test') {
            steps {
                sh '''
                    set -eux

                    CONTAINER_NAME="maximuslabog-smoke-${BUILD_NUMBER}"

                    cleanup() {
                        docker logs "${CONTAINER_NAME}" 2>/dev/null || true
                        docker rm --force "${CONTAINER_NAME}" >/dev/null 2>&1 || true
                    }
                    trap cleanup EXIT

                    docker rm --force "${CONTAINER_NAME}" >/dev/null 2>&1 || true

                    docker run --detach \
                        --name "${CONTAINER_NAME}" \
                        --publish "${SMOKE_PORT}:80" \
                        "${DOCKER_IMAGE}"

                    READY=false
                    for ATTEMPT in $(seq 1 20); do
                        if curl --fail --silent --show-error \
                            "http://192.168.2.127:${SMOKE_PORT}/healthz"; then
                            echo
                            READY=true
                            break
                        fi
                        sleep 2
                    done

                    test "${READY}" = 'true'
                    test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
                        "http://192.168.2.127:${SMOKE_PORT}/healthz")" = '200'
                    test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
                        "http://192.168.2.127:${SMOKE_PORT}/")" = '200'
                '''
            }
        }

        stage('Push to Nexus') {
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

                        set +x
                        printf '%s' "${NEXUS_PASSWORD}" | docker login \
                            "${NEXUS_REGISTRY}" \
                            --username "${NEXUS_USERNAME}" \
                            --password-stdin
                        set -x

                        docker push "${DOCKER_IMAGE}"
                        docker tag "${DOCKER_IMAGE}" "${LATEST_IMAGE}"
                        docker push "${LATEST_IMAGE}"
                    '''
                }
            }
        }

        stage('Render Manifest') {
            steps {
                sh '''
                    set -eux

                    sed "s|IMAGE_PLACEHOLDER|${DOCKER_IMAGE}|g" \
                        k8s/k8s-deployment.yaml > "${RENDERED_FILE}"

                    grep -n 'image:' "${RENDERED_FILE}"

                    if grep -q 'IMAGE_PLACEHOLDER' "${RENDERED_FILE}"; then
                        echo 'ERROR: image placeholder was not replaced.'
                        exit 1
                    fi

                    # Syntax-level check only. Live validation happens during kubectl apply.
                    kubectl apply --dry-run=client --validate=false \
                        -f "${RENDERED_FILE}" >/dev/null
                '''
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

                        echo '===== Cluster connectivity ====='
                        kubectl cluster-info
                        kubectl get nodes

                        echo '===== Ensure namespace exists ====='
                        kubectl create namespace "${K8S_NAMESPACE}" \
                            --dry-run=client -o yaml | kubectl apply -f -

                        echo '===== Create/update Nexus pull secret ====='
                        set +x
                        kubectl create secret docker-registry nexus-regcred \
                            --namespace "${K8S_NAMESPACE}" \
                            --docker-server="${NEXUS_REGISTRY}" \
                            --docker-username="${NEXUS_USERNAME}" \
                            --docker-password="${NEXUS_PASSWORD}" \
                            --dry-run=client -o yaml | kubectl apply -f -
                        set -x

                        echo '===== Apply application manifests ====='
                        kubectl apply -f "${RENDERED_FILE}"

                        echo '===== Wait for rollout ====='
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

                        kubectl get deployment,pods,service,ingress \
                            --namespace "${K8S_NAMESPACE}" -o wide

                        kubectl wait \
                            --namespace "${K8S_NAMESPACE}" \
                            --for=condition=Ready pod \
                            -l "app=${APP_LABEL}" \
                            --timeout=180s

                        ACTUAL_IMAGE=$(kubectl get deployment "${K8S_DEPLOYMENT}" \
                            --namespace "${K8S_NAMESPACE}" \
                            -o jsonpath='{.spec.template.spec.containers[0].image}')

                        echo "Expected image: ${DOCKER_IMAGE}"
                        echo "Actual image:   ${ACTUAL_IMAGE}"
                        test "${ACTUAL_IMAGE}" = "${DOCKER_IMAGE}"

                        kubectl port-forward \
                            --namespace "${K8S_NAMESPACE}" \
                            service/"${K8S_SERVICE}" \
                            "${VERIFY_PORT}:80" \
                            >/tmp/maximus-port-forward.log 2>&1 &

                        PF_PID=$!
                        cleanup_pf() {
                            kill "${PF_PID}" >/dev/null 2>&1 || true
                            cat /tmp/maximus-port-forward.log || true
                        }
                        trap cleanup_pf EXIT

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

                        test "${READY}" = 'true'
                        curl --fail --silent --show-error \
                            "http://127.0.0.1:${VERIFY_PORT}/" | grep -qi 'Maximus'

                        echo 'End-to-end verification succeeded.'
                    '''
                }
            }
        }
    }

    post {
        unsuccessful {
            withCredentials([
                file(
                    credentialsId: 'kubeconfig-lab',
                    variable: 'KUBECONFIG_FILE'
                )
            ]) {
                sh '''
                    set +e
                    export KUBECONFIG="${KUBECONFIG_FILE}"

                    echo '===== Kubernetes diagnostics ====='
                    kubectl get all,ingress \
                        --namespace "${K8S_NAMESPACE}" -o wide
                    kubectl get events \
                        --namespace "${K8S_NAMESPACE}" \
                        --sort-by=.lastTimestamp | tail -50
                    kubectl describe deployment "${K8S_DEPLOYMENT}" \
                        --namespace "${K8S_NAMESPACE}"
                    kubectl logs deployment/"${K8S_DEPLOYMENT}" \
                        --namespace "${K8S_NAMESPACE}" \
                        --all-containers=true --tail=100

                    echo '===== Attempt rollback only when deployment exists ====='
                    if kubectl get deployment "${K8S_DEPLOYMENT}" \
                        --namespace "${K8S_NAMESPACE}" >/dev/null 2>&1; then
                        kubectl rollout undo deployment/"${K8S_DEPLOYMENT}" \
                            --namespace "${K8S_NAMESPACE}" || true
                        kubectl rollout status deployment/"${K8S_DEPLOYMENT}" \
                            --namespace "${K8S_NAMESPACE}" \
                            --timeout=180s || true
                    fi
                '''
            }
        }

        always {
            sh '''
                set +e
                docker rm --force "maximuslabog-smoke-${BUILD_NUMBER}" \
                    >/dev/null 2>&1 || true
                docker logout "${NEXUS_REGISTRY}" >/dev/null 2>&1 || true
                docker image rm "${LATEST_IMAGE}" >/dev/null 2>&1 || true
                docker image rm "${DOCKER_IMAGE}" >/dev/null 2>&1 || true
                exit 0
            '''

            archiveArtifacts artifacts: "${RENDERED_FILE}",
                allowEmptyArchive: true,
                fingerprint: true
        }

        success {
            echo "SUCCESS: ${DOCKER_IMAGE} deployed to ${K8S_NAMESPACE}."
        }

        failure {
            echo "FAILED: Review diagnostics above. Attempted image: ${DOCKER_IMAGE}."
        }
    }
}
