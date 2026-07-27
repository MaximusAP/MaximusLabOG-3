pipeline {
    agent {
        label 'docker-slave'
    }

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(
            logRotator(
                numToKeepStr: '20'
            )
        )
        timeout(
            time: 20,
            unit: 'MINUTES'
        )
        skipDefaultCheckout(true)
    }

    environment {
        // GitHub configuration
        GIT_REPOSITORY = 'https://github.com/MaximusAP/MaximusLabOG.git'
        GIT_BRANCH     = 'master'

        // Nexus Docker registry
        REGISTRY   = '192.168.2.128:8082'
        IMAGE_NAME = 'maximuslabog-web'

        // Kubernetes resources
        NAMESPACE    = 'maximuslabog'
        DEPLOYMENT   = 'maximuslabog-web'
        SERVICE      = 'maximuslabog-web'
        INGRESS_HOST = 'maximuslabog.lab.local'

        // Build-specific image information
        IMAGE_TAG     = "${BUILD_NUMBER}"
        FULL_IMAGE    = "${REGISTRY}/${IMAGE_NAME}:${BUILD_NUMBER}"
        RENDERED_FILE = 'k8s/rendered-deployment.yaml'
    }

    stages {

        stage('Checkout GitHub') {
            steps {
                deleteDir()

                git(
                    branch: "${GIT_BRANCH}",
                    url: "${GIT_REPOSITORY}"
                )

                sh '''
                    set -eux

                    echo "===== Git commit ====="
                    git log -1 --oneline

                    echo "===== Workspace files ====="
                    find . -maxdepth 2 -type f | sort

                    echo "===== Validate application files ====="
                    test -f Dockerfile
                    test -f nginx.conf
                    test -f index.html
                    test -f k8s/k8s-deployment.yaml

                    echo "===== Validate image placeholder ====="

                    if ! grep -q 'IMAGE_PLACEHOLDER' \
                        k8s/k8s-deployment.yaml
                    then
                        echo "ERROR: IMAGE_PLACEHOLDER is missing."
                        echo "Current image entries:"
                        grep -n 'image:' \
                            k8s/k8s-deployment.yaml || true
                        exit 1
                    fi

                    grep -n 'IMAGE_PLACEHOLDER' \
                        k8s/k8s-deployment.yaml

                    echo "GitHub checkout validation completed."
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
                    docker ps >/dev/null

                    echo "Tool validation completed."
                '''
            }
        }

        stage('Build Docker Image') {
            steps {
                sh '''
                    set -eux

                    echo "Building image:"
                    echo "$FULL_IMAGE"

                    docker build \
                        --pull \
                        --tag "$FULL_IMAGE" \
                        .

                    docker image inspect \
                        "$FULL_IMAGE" \
                        >/dev/null

                    echo "Docker image build completed."
                '''
            }
        }

        stage('Local Smoke Test') {
            steps {
                sh '''
                    set -eux

                    CONTAINER_NAME="maximuslabog-smoke-${BUILD_NUMBER}"

                    docker rm \
                        --force \
                        "$CONTAINER_NAME" \
                        >/dev/null 2>&1 || true

                    docker run \
                        --detach \
                        --name "$CONTAINER_NAME" \
                        --publish 18080:80 \
                        "$FULL_IMAGE"

                    cleanup_smoke_test() {
                        echo "===== Smoke-test container logs ====="
                        docker logs "$CONTAINER_NAME" || true

                        docker rm \
                            --force \
                            "$CONTAINER_NAME" \
                            >/dev/null 2>&1 || true
                    }

                    trap cleanup_smoke_test EXIT

                    HEALTHY=false

                    echo "Waiting for the local container..."

                    for attempt in $(seq 1 20)
                    do
                        echo "Health-check attempt: $attempt"

                        if curl \
                            --fail \
                            --silent \
                            http://127.0.0.1:18080/healthz
                        then
                            HEALTHY=true
                            break
                        fi

                        sleep 2
                    done

                    if [ "$HEALTHY" != "true" ]
                    then
                        echo "ERROR: Local container health check failed."
                        exit 1
                    fi

                    echo "===== Test health endpoint ====="

                    curl \
                        --fail \
                        --silent \
                        --show-error \
                        http://127.0.0.1:18080/healthz

                    echo
                    echo "===== Test website content ====="

                    curl \
                        --fail \
                        --silent \
                        --show-error \
                        http://127.0.0.1:18080/ |
                        grep -qi 'Maximus'

                    echo "Local container smoke test completed."
                '''
            }
        }

        stage('Push Image to Nexus') {
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'nexus-credentials',
                        usernameVariable: 'NEXUS_USER',
                        passwordVariable: 'NEXUS_PASSWORD'
                    )
                ]) {
                    sh '''
                        echo "Logging in to Nexus registry: $REGISTRY"

                        set +x

                        printf '%s' "$NEXUS_PASSWORD" |
                        docker login "$REGISTRY" \
                            --username "$NEXUS_USER" \
                            --password-stdin

                        LOGIN_STATUS=$?

                        set -x

                        if [ "$LOGIN_STATUS" -ne 0 ]
                        then
                            echo "ERROR: Nexus Docker login failed."
                            exit "$LOGIN_STATUS"
                        fi

                        echo "Pushing image:"
                        echo "$FULL_IMAGE"

                        docker push "$FULL_IMAGE"

                        docker logout "$REGISTRY" || true

                        echo "Image successfully pushed to Nexus."
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
                        credentialsId: 'nexus-credentials',
                        usernameVariable: 'NEXUS_USER',
                        passwordVariable: 'NEXUS_PASSWORD'
                    )
                ]) {
                    sh '''
                        set -eux

                        export KUBECONFIG="$KUBECONFIG_FILE"

                        echo "===== Kubernetes connection ====="

                        kubectl cluster-info
                        kubectl get nodes -o wide

                        echo "===== Create or update namespace ====="

                        kubectl create namespace "$NAMESPACE" \
                            --dry-run=client \
                            --output yaml |
                        kubectl apply -f -

                        echo "===== Create or update Nexus pull secret ====="

                        set +x

                        kubectl \
                            --namespace "$NAMESPACE" \
                            create secret docker-registry nexus-regcred \
                            --docker-server="$REGISTRY" \
                            --docker-username="$NEXUS_USER" \
                            --docker-password="$NEXUS_PASSWORD" \
                            --dry-run=client \
                            --output yaml |
                        kubectl apply -f -

                        SECRET_STATUS=$?

                        set -x

                        if [ "$SECRET_STATUS" -ne 0 ]
                        then
                            echo "ERROR: Unable to create Nexus registry secret."
                            exit "$SECRET_STATUS"
                        fi

                        echo "===== Render deployment manifest ====="

                        mkdir -p "$(dirname "$RENDERED_FILE")"

                        sed \
                            "s|IMAGE_PLACEHOLDER|$FULL_IMAGE|g" \
                            k8s/k8s-deployment.yaml \
                            > "$RENDERED_FILE"

                        if grep -q 'IMAGE_PLACEHOLDER' "$RENDERED_FILE"
                        then
                            echo "ERROR: Image placeholder was not replaced."
                            exit 1
                        fi

                        echo "Rendered image entry:"

                        grep -n 'image:' "$RENDERED_FILE"

                        echo "===== Validate Kubernetes manifest ====="

                        kubectl apply \
                            --dry-run=server \
                            --filename "$RENDERED_FILE"

                        echo "===== Apply Kubernetes manifest ====="

                        kubectl apply \
                            --filename "$RENDERED_FILE"

                        echo "===== Wait for deployment rollout ====="

                        kubectl \
                            --namespace "$NAMESPACE" \
                            rollout status \
                            deployment/"$DEPLOYMENT" \
                            --timeout=180s

                        echo "Kubernetes deployment completed."
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

                        export KUBECONFIG="$KUBECONFIG_FILE"

                        echo "===== Kubernetes resources ====="

                        kubectl \
                            --namespace "$NAMESPACE" \
                            get deployment,pods,service,ingress \
                            -o wide

                        echo "===== Wait for application pods ====="

                        kubectl \
                            --namespace "$NAMESPACE" \
                            wait \
                            --for=condition=Ready \
                            pod \
                            --selector app=maximuslabog-web \
                            --timeout=120s

                        echo "===== Verify deployed image ====="

                        DEPLOYED_IMAGE=$(
                            kubectl \
                                --namespace "$NAMESPACE" \
                                get deployment "$DEPLOYMENT" \
                                --output jsonpath='{.spec.template.spec.containers[0].image}'
                        )

                        echo "Expected image: $FULL_IMAGE"
                        echo "Deployed image: $DEPLOYED_IMAGE"

                        if [ "$DEPLOYED_IMAGE" != "$FULL_IMAGE" ]
                        then
                            echo "ERROR: Kubernetes is not using the expected image."
                            exit 1
                        fi

                        echo "===== Service port-forward test ====="

                        kubectl \
                            --namespace "$NAMESPACE" \
                            port-forward \
                            service/"$SERVICE" \
                            18081:80 \
                            >/tmp/maximuslabog-port-forward.log 2>&1 &

                        PORT_FORWARD_PID=$!

                        cleanup_port_forward() {
                            kill "$PORT_FORWARD_PID" \
                                >/dev/null 2>&1 || true
                        }

                        trap cleanup_port_forward EXIT

                        PORT_FORWARD_READY=false

                        for attempt in $(seq 1 20)
                        do
                            echo "Port-forward test attempt: $attempt"

                            if curl \
                                --fail \
                                --silent \
                                http://127.0.0.1:18081/healthz
                            then
                                PORT_FORWARD_READY=true
                                break
                            fi

                            sleep 2
                        done

                        if [ "$PORT_FORWARD_READY" != "true" ]
                        then
                            echo "ERROR: Kubernetes service test failed."
                            echo "===== Port-forward log ====="
                            cat /tmp/maximuslabog-port-forward.log || true
                            exit 1
                        fi

                        echo "===== Verify Kubernetes health endpoint ====="

                        curl \
                            --fail \
                            --silent \
                            --show-error \
                            http://127.0.0.1:18081/healthz

                        echo
                        echo "===== Verify Kubernetes website content ====="

                        curl \
                            --fail \
                            --silent \
                            --show-error \
                            http://127.0.0.1:18081/ |
                        grep -qi 'Maximus'

                        echo "End-to-end Kubernetes test completed."
                    '''
                }
            }
        }
    }

    post {
        success {
            echo """
============================================================
DEPLOYMENT SUCCESSFUL
============================================================

Docker image:
${FULL_IMAGE}

Kubernetes namespace:
${NAMESPACE}

Kubernetes deployment:
${DEPLOYMENT}

Application URL:
http://${INGRESS_HOST}

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
${FULL_IMAGE}

Namespace:
${NAMESPACE}

============================================================
"""
        }

        always {
            sh '''
                echo "===== Pipeline cleanup ====="

                docker rm \
                    --force \
                    "maximuslabog-smoke-${BUILD_NUMBER}" \
                    >/dev/null 2>&1 || true

                docker logout "$REGISTRY" \
                    >/dev/null 2>&1 || true

                docker image rm "$FULL_IMAGE" \
                    >/dev/null 2>&1 || true
            '''

            archiveArtifacts(
                artifacts: 'k8s/rendered-deployment.yaml',
                allowEmptyArchive: true
            )
        }
    }
}