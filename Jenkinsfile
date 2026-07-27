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

                    echo "===== Validate application files ====="

                    test -f Dockerfile
                    test -f nginx.conf
                    test -f index.html
                    test -f "$KUBERNETES_MANIFEST"

                    echo "===== Validate image placeholder ====="

                    grep -q 'IMAGE_PLACEHOLDER' "$KUBERNETES_MANIFEST"
                    grep -n 'IMAGE_PLACEHOLDER' "$KUBERNETES_MANIFEST"

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
                    echo "$FULL_IMAGE"

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

                    echo "===== Remove an existing smoke-test container ====="

                    docker rm \
                        --force \
                        "$CONTAINER_NAME" \
                        >/dev/null 2>&1 || true

                    echo "===== Start smoke-test container ====="

                    docker run \
                        --detach \
                        --name "$CONTAINER_NAME" \
                        --publish "${SMOKE_TEST_PORT}:80" \
                        "$FULL_IMAGE"

                    cleanup_smoke_test() {
                        echo "===== Smoke-test container logs ====="

                        docker logs "$CONTAINER_NAME" || true

                        echo "===== Remove smoke-test container ====="

                        docker rm \
                            --force \
                            "$CONTAINER_NAME" \
                            >/dev/null 2>&1 || true
                    }

                    trap cleanup_smoke_test EXIT

                    HEALTHY=false

                    echo "Waiting for application:"
                    echo "$SMOKE_BASE_URL/healthz"

                    for attempt in $(seq 1 20)
                    do
                        echo "Health-check attempt: $attempt"

                        if curl \
                            --fail \
                            --silent \
                            --show-error \
                            "$SMOKE_BASE_URL/healthz"
                        then
                            echo
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

                    echo
                    echo "===== Test health endpoint ====="

                    curl \
                        --fail \
                        --silent \
                        --show-error \
                        "$SMOKE_BASE_URL/healthz"

                    echo
                    echo "===== Test website endpoint ====="

                    curl \
                        --fail \
                        --silent \
                        --show-error \
                        "$SMOKE_BASE_URL/" |
                        grep -qi 'Maximus'

                    echo "Website content validation passed."
                    echo "Local container smoke test completed."
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

                        echo "===== Push latest image ====="

                        docker tag \
                            "$FULL_IMAGE" \
                            "${REGISTRY}/${IMAGE_NAME}:latest"

                        docker push \
                            "${REGISTRY}/${IMAGE_NAME}:latest"

                        echo "===== Verify local image metadata ====="

                        docker image inspect "$FULL_IMAGE" \
                            --format='Image ID: {{.Id}}'

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

                    echo "===== Validate manifest syntax ====="

                    kubectl \
                        --kubeconfig /dev/null \
                        apply \
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

                        echo "===== Kubernetes cluster information ====="

                        kubectl cluster-info
                        kubectl get nodes -o wide

                        echo "===== Create namespace ====="

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

                        echo "===== Apply Kubernetes resources ====="

                        kubectl apply \
                            --namespace "$NAMESPACE" \
                            -f "$RENDERED_MANIFEST"

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
                            echo "ERROR: No Kubernetes Deployment was found."
                            exit 1
                        fi

                        echo "Deployment resource: $DEPLOYMENT_RESOURCE"

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

                        echo "===== Deployment status ====="

                        kubectl \
                            --namespace "$NAMESPACE" \
                            get "$DEPLOYMENT_RESOURCE" \
                            -o wide

                        echo "===== Deployment image ====="

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
                            echo "ERROR: Deployed image does not match pipeline image."
                            exit 1
                        fi

                        echo "===== Ready pod validation ====="

                        READY_PODS=$(
                            kubectl \
                                --namespace "$NAMESPACE" \
                                get pods \
                                --field-selector=status.phase=Running \
                                --no-headers |
                            wc -l
                        )

                        echo "Running pods: $READY_PODS"

                        if [ "$READY_PODS" -lt 1 ]
                        then
                            echo "ERROR: No running pods were found."
                            exit 1
                        fi

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
                echo "===== Pipeline cleanup ====="

                CONTAINER_NAME="maximuslabog-smoke-${BUILD_NUMBER}"

                docker rm \
                    --force \
                    "$CONTAINER_NAME" \
                    >/dev/null 2>&1 || true

                docker logout "$REGISTRY" \
                    >/dev/null 2>&1 || true

                docker image rm \
                    "${REGISTRY}/${IMAGE_NAME}:latest" \
                    >/dev/null 2>&1 || true

                docker image rm \
                    "$FULL_IMAGE" \
                    >/dev/null 2>&1 || true
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

The application image was built, tested, pushed to Nexus,
deployed to Kubernetes, and verified successfully.

============================================================
"""
        }

        failure {
            echo """
============================================================
PIPELINE FAILED
============================================================

Review the first failed stage in the Jenkins console output.

Image attempted:
${FULL_IMAGE}

Namespace:
${NAMESPACE}

============================================================
"""
        }
    }
}