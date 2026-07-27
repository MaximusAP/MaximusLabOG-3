pipeline {
    agent {
        label 'docker-slave'
    }

    options {
        skipDefaultCheckout(true)
        timestamps()
        disableConcurrentBuilds()

        buildDiscarder(
            logRotator(
                numToKeepStr: '10',
                artifactNumToKeepStr: '5'
            )
        )

        timeout(
            time: 20,
            unit: 'MINUTES'
        )
    }

    environment {
        GIT_REPOSITORY = 'https://github.com/MaximusAP/MaximusLabOG-3.git'
        GIT_BRANCH = 'master'

        REGISTRY = '192.168.2.128:8082'
        IMAGE_NAME = 'maximuslabog-web'

        NEXUS_CREDENTIALS_ID = 'nexus-credentials'
        KUBECONFIG_CREDENTIALS_ID = 'kubeconfig-lab'

        NAMESPACE = 'maximuslabog'
        IMAGE_PULL_SECRET = 'nexus-regcred'

        DOCKER_HOST_IP = '192.168.2.127'
        SMOKE_TEST_PORT = '18080'

        KUBERNETES_MANIFEST = 'k8s/k8s-deployment.yaml'
        RENDERED_MANIFEST = 'rendered-k8s.yaml'

        FULL_IMAGE = "${REGISTRY}/${IMAGE_NAME}:${BUILD_NUMBER}"
        LATEST_IMAGE = "${REGISTRY}/${IMAGE_NAME}:latest"
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
                    find . -maxdepth 3 -type f | sort

                    echo "===== Validate required files ====="

                    test -f Dockerfile
                    test -f nginx.conf
                    test -f index.html
                    test -f "$KUBERNETES_MANIFEST"

                    echo "===== Validate Kubernetes image placeholder ====="

                    grep -q 'IMAGE_PLACEHOLDER' "$KUBERNETES_MANIFEST"
                    grep -n 'IMAGE_PLACEHOLDER' "$KUBERNETES_MANIFEST"

                    echo "Checkout validation completed."
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

                    echo "Tool validation completed."
                '''
            }
        }

        stage('Build Docker Image') {
            steps {
                sh '''
                    set -eux

                    echo "===== Build Docker image ====="
                    echo "Image: $FULL_IMAGE"

                    docker build \
                        --pull \
                        --tag "$FULL_IMAGE" \
                        .

                    docker image inspect "$FULL_IMAGE" >/dev/null

                    echo "Docker image build completed."
                '''
            }
        }

        stage('Local Smoke Test') {
            steps {
                sh '''
                    set -eux

                    CONTAINER_NAME="maximuslabog-smoke-${BUILD_NUMBER}"
                    SMOKE_BASE_URL="http://${DOCKER_HOST_IP}:${SMOKE_TEST_PORT}"

                    cleanup_smoke_test() {
                        echo "===== Smoke-test container logs ====="

                        docker logs "$CONTAINER_NAME" || true

                        echo "===== Remove smoke-test container ====="

                        docker rm \
                            --force \
                            "$CONTAINER_NAME" \
                            >/dev/null 2>&1 || true
                    }

                    echo "===== Remove an existing named container ====="

                    docker rm \
                        --force \
                        "$CONTAINER_NAME" \
                        >/dev/null 2>&1 || true

                    echo "===== Check whether port is already allocated ====="

                    EXISTING_CONTAINER=$(
                        docker ps \
                            --filter "publish=${SMOKE_TEST_PORT}" \
                            --format '{{.ID}}' |
                        head -1
                    )

                    if [ -n "$EXISTING_CONTAINER" ]
                    then
                        echo "Port ${SMOKE_TEST_PORT} is being used by:"
                        docker ps --filter "id=$EXISTING_CONTAINER"

                        echo "Removing the container using the smoke-test port."

                        docker rm \
                            --force \
                            "$EXISTING_CONTAINER"
                    fi

                    echo "===== Start smoke-test container ====="

                    docker run \
                        --detach \
                        --name "$CONTAINER_NAME" \
                        --publish "${SMOKE_TEST_PORT}:80" \
                        "$FULL_IMAGE"

                    trap cleanup_smoke_test EXIT

                    echo "Waiting for:"
                    echo "${SMOKE_BASE_URL}/healthz"

                    HEALTHY=false

                    for attempt in $(seq 1 20)
                    do
                        echo "Health-check attempt: $attempt"

                        if curl \
                            --fail \
                            --silent \
                            --show-error \
                            "${SMOKE_BASE_URL}/healthz"
                        then
                            echo
                            HEALTHY=true
                            break
                        fi

                        sleep 2
                    done

                    if [ "$HEALTHY" != "true" ]
                    then
                        echo "ERROR: Local health check failed."
                        exit 1
                    fi

                    echo
                    echo "===== Validate health endpoint ====="

                    HEALTH_HTTP_CODE=$(
                        curl \
                            --silent \
                            --output /dev/null \
                            --write-out '%{http_code}' \
                            "${SMOKE_BASE_URL}/healthz"
                    )

                    echo "Health endpoint HTTP status: $HEALTH_HTTP_CODE"

                    if [ "$HEALTH_HTTP_CODE" != "200" ]
                    then
                        echo "ERROR: Health endpoint did not return HTTP 200."
                        exit 1
                    fi

                    echo "===== Validate website endpoint ====="

                    WEBSITE_HTTP_CODE=$(
                        curl \
                            --silent \
                            --output /dev/null \
                            --write-out '%{http_code}' \
                            "${SMOKE_BASE_URL}/"
                    )

                    echo "Website HTTP status: $WEBSITE_HTTP_CODE"

                    if [ "$WEBSITE_HTTP_CODE" != "200" ]
                    then
                        echo "ERROR: Website did not return HTTP 200."
                        exit 1
                    fi

                    echo "===== Validate downloaded website size ====="

                    WEBSITE_SIZE=$(
                        curl \
                            --fail \
                            --silent \
                            --show-error \
                            "${SMOKE_BASE_URL}/" |
                        wc -c
                    )

                    echo "Website response size: $WEBSITE_SIZE bytes"

                    if [ "$WEBSITE_SIZE" -lt 1000 ]
                    then
                        echo "ERROR: Website response appears unexpectedly small."
                        exit 1
                    fi

                    echo "Local container smoke test completed successfully."
                '''
            }
        }

        stage('Push Image to Nexus') {
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: "${NEXUS_CREDENTIALS_ID}",
                        usernameVariable: 'NEXUS_USERNAME',
                        passwordVariable: 'NEXUS_PASSWORD'
                    )
                ]) {
                    sh '''
                        set -eux

                        echo "===== Login to Nexus Docker registry ====="

                        echo "$NEXUS_PASSWORD" |
                            docker login \
                                "$REGISTRY" \
                                --username "$NEXUS_USERNAME" \
                                --password-stdin

                        echo "===== Push versioned image ====="

                        docker push "$FULL_IMAGE"

                        echo "===== Tag and push latest image ====="

                        docker tag \
                            "$FULL_IMAGE" \
                            "$LATEST_IMAGE"

                        docker push "$LATEST_IMAGE"

                        echo "Nexus image push completed."
                    '''
                }
            }
        }

        stage('Render Kubernetes Manifest') {
            steps {
                sh '''
                    set -eux

                    echo "===== Render Kubernetes manifest ====="

                    sed \
                        "s|IMAGE_PLACEHOLDER|${FULL_IMAGE}|g" \
                        "$KUBERNETES_MANIFEST" \
                        > "$RENDERED_MANIFEST"

                    echo "===== Confirm rendered image ====="

                    grep -n 'image:' "$RENDERED_MANIFEST"

                    if grep -q 'IMAGE_PLACEHOLDER' "$RENDERED_MANIFEST"
                    then
                        echo "ERROR: IMAGE_PLACEHOLDER still exists."
                        exit 1
                    fi

                    echo "===== Client-side manifest validation ====="

                    kubectl apply \
                        --dry-run=client \
                        --validate=false \
                        -f "$RENDERED_MANIFEST" \
                        >/dev/null

                    echo "Manifest rendering completed."
                '''
            }
        }

        stage('Deploy to Kubernetes') {
            steps {
                withCredentials([
                    file(
                        credentialsId: "${KUBECONFIG_CREDENTIALS_ID}",
                        variable: 'KUBECONFIG_FILE'
                    ),

                    usernamePassword(
                        credentialsId: "${NEXUS_CREDENTIALS_ID}",
                        usernameVariable: 'NEXUS_USERNAME',
                        passwordVariable: 'NEXUS_PASSWORD'
                    )
                ]) {
                    sh '''
                        set -eux

                        export KUBECONFIG="$KUBECONFIG_FILE"

                        echo "===== Kubernetes cluster validation ====="

                        kubectl cluster-info
                        kubectl get nodes -o wide

                        echo "===== Create or update namespace ====="

                        kubectl create namespace "$NAMESPACE" \
                            --dry-run=client \
                            -o yaml |
                            kubectl apply -f -

                        echo "===== Create or update Nexus image-pull secret ====="

                        kubectl \
                            --namespace "$NAMESPACE" \
                            create secret docker-registry "$IMAGE_PULL_SECRET" \
                            --docker-server="$REGISTRY" \
                            --docker-username="$NEXUS_USERNAME" \
                            --docker-password="$NEXUS_PASSWORD" \
                            --dry-run=client \
                            -o yaml |
                            kubectl apply -f -

                        echo "===== Apply Kubernetes manifest ====="

                        kubectl apply \
                            --namespace "$NAMESPACE" \
                            -f "$RENDERED_MANIFEST"

                        echo "===== Identify deployment resource ====="

                        DEPLOYMENT_RESOURCE=$(
                            kubectl \
                                --namespace "$NAMESPACE" \
                                get \
                                -f "$RENDERED_MANIFEST" \
                                -o name |
                            grep '^deployment.apps/' |
                            head -1
                        )

                        if [ -z "$DEPLOYMENT_RESOURCE" ]
                        then
                            echo "ERROR: No Deployment resource was found."
                            exit 1
                        fi

                        echo "Deployment: $DEPLOYMENT_RESOURCE"

                        echo "===== Wait for rollout ====="

                        kubectl \
                            --namespace "$NAMESPACE" \
                            rollout status \
                            "$DEPLOYMENT_RESOURCE" \
                            --timeout=300s

                        echo "Kubernetes deployment completed."
                    '''
                }
            }
        }

        stage('End-to-End Verification') {
            steps {
                withCredentials([
                    file(
                        credentialsId: "${KUBECONFIG_CREDENTIALS_ID}",
                        variable: 'KUBECONFIG_FILE'
                    )
                ]) {
                    sh '''
                        set -eux

                        export KUBECONFIG="$KUBECONFIG_FILE"

                        echo "===== Kubernetes resources ====="

                        kubectl \
                            --namespace "$NAMESPACE" \
                            get deployments,pods,services,ingresses \
                            -o wide

                        echo "===== Identify deployment ====="

                        DEPLOYMENT_RESOURCE=$(
                            kubectl \
                                --namespace "$NAMESPACE" \
                                get \
                                -f "$RENDERED_MANIFEST" \
                                -o name |
                            grep '^deployment.apps/' |
                            head -1
                        )

                        if [ -z "$DEPLOYMENT_RESOURCE" ]
                        then
                            echo "ERROR: No Deployment resource was found."
                            exit 1
                        fi

                        echo "===== Validate deployed image ====="

                        DEPLOYED_IMAGE=$(
                            kubectl \
                                --namespace "$NAMESPACE" \
                                get "$DEPLOYMENT_RESOURCE" \
                                -o jsonpath='{.spec.template.spec.containers[0].image}'
                        )

                        echo
                        echo "Expected image: $FULL_IMAGE"
                        echo "Deployed image: $DEPLOYED_IMAGE"

                        if [ "$DEPLOYED_IMAGE" != "$FULL_IMAGE" ]
                        then
                            echo "ERROR: Deployed image does not match the pipeline image."
                            exit 1
                        fi

                        echo "===== Validate ready replicas ====="

                        DESIRED_REPLICAS=$(
                            kubectl \
                                --namespace "$NAMESPACE" \
                                get "$DEPLOYMENT_RESOURCE" \
                                -o jsonpath='{.spec.replicas}'
                        )

                        READY_REPLICAS=$(
                            kubectl \
                                --namespace "$NAMESPACE" \
                                get "$DEPLOYMENT_RESOURCE" \
                                -o jsonpath='{.status.readyReplicas}'
                        )

                        READY_REPLICAS=${READY_REPLICAS:-0}

                        echo
                        echo "Desired replicas: $DESIRED_REPLICAS"
                        echo "Ready replicas: $READY_REPLICAS"

                        if [ "$READY_REPLICAS" -lt "$DESIRED_REPLICAS" ]
                        then
                            echo "ERROR: Not all deployment replicas are ready."
                            exit 1
                        fi

                        echo "===== Pod status ====="

                        kubectl \
                            --namespace "$NAMESPACE" \
                            get pods \
                            -o wide

                        echo "===== Recent Kubernetes events ====="

                        kubectl \
                            --namespace "$NAMESPACE" \
                            get events \
                            --sort-by='.lastTimestamp' |
                            tail -20 || true

                        echo "End-to-end Kubernetes verification completed."
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

                CONTAINER_NAME="maximuslabog-smoke-${BUILD_NUMBER}"

                docker rm \
                    --force \
                    "$CONTAINER_NAME" \
                    >/dev/null 2>&1

                docker logout "$REGISTRY" \
                    >/dev/null 2>&1

                docker image rm \
                    "$LATEST_IMAGE" \
                    >/dev/null 2>&1

                docker image rm \
                    "$FULL_IMAGE" \
                    >/dev/null 2>&1

                exit 0
            '''

            archiveArtifacts(
                artifacts: 'rendered-k8s.yaml',
                allowEmptyArchive: true,
                fingerprint: true
            )
        }

        success {
            echo """
============================================================
PIPELINE SUCCESSFUL
============================================================

Git repository:
${GIT_REPOSITORY}

Docker image:
${FULL_IMAGE}

Nexus registry:
${REGISTRY}

Kubernetes namespace:
${NAMESPACE}

The application image was built, smoke-tested, pushed to
Nexus, deployed to Kubernetes, and verified successfully.

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
    }
}
