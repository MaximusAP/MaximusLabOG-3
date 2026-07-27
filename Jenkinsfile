pipeline {
    agent { label 'docker-slave' }

    options {
        timestamps()
        ansiColor('xterm')
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timeout(time: 20, unit: 'MINUTES')
    }

    environment {
        REGISTRY       = '192.168.2.128:8082'
        IMAGE_NAME     = 'maximuslabog-web'
        NAMESPACE      = 'maximuslabog'
        DEPLOYMENT     = 'maximuslabog-web'
        SERVICE        = 'maximuslabog-web'
        INGRESS_HOST   = 'maximuslabog.lab.local'
        IMAGE_TAG      = "${BUILD_NUMBER}"
        FULL_IMAGE     = "${REGISTRY}/${IMAGE_NAME}:${BUILD_NUMBER}"
        RENDERED_FILE  = 'k8s/rendered-deployment.yaml'
    }

    stages {
        stage('Checkout GitHub') {
            steps {
                deleteDir()
                checkout scm
                sh '''
                    set -eux
                    git log -1 --oneline
                    test -f Dockerfile
                    test -f nginx.conf
                    test -f index.html
                    test -f k8s/k8s-deployment.yaml
                '''
            }
        }

        stage('Tool Validation') {
            steps {
                sh '''
                    set -eux
                    docker --version
                    kubectl version --client
                    curl --version | head -1
                    git --version
                    docker ps >/dev/null
                '''
            }
        }

        stage('Build Image') {
            steps {
                sh '''
                    set -eux
                    docker build --pull -t "$FULL_IMAGE" .
                    docker image inspect "$FULL_IMAGE" >/dev/null
                '''
            }
        }

        stage('Local Smoke Test') {
            steps {
                sh '''
                    set -eux
                    CONTAINER="maximuslabog-smoke-${BUILD_NUMBER}"
                    docker rm -f "$CONTAINER" 2>/dev/null || true
                    docker run -d --name "$CONTAINER" -p 18080:80 "$FULL_IMAGE"

                    cleanup() {
                        docker logs "$CONTAINER" || true
                        docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
                    }
                    trap cleanup EXIT

                    for attempt in $(seq 1 20); do
                        if curl --fail --silent http://127.0.0.1:18080/healthz; then
                            break
                        fi
                        sleep 2
                    done

                    curl --fail --silent http://127.0.0.1:18080/healthz
                    curl --fail --silent http://127.0.0.1:18080/ | grep -qi 'Maximus'
                '''
            }
        }

        stage('Push Image to Nexus') {
            steps {
                withCredentials([
                    usernamePassword(
                        credentialsId: 'nexus-docker-credentials',
                        usernameVariable: 'NEXUS_USER',
                        passwordVariable: 'NEXUS_PASSWORD'
                    )
                ]) {
                    sh '''
                        set +x
                        printf '%s' "$NEXUS_PASSWORD" | docker login "$REGISTRY" \
                            --username "$NEXUS_USER" --password-stdin
                        set -x
                        docker push "$FULL_IMAGE"
                        docker logout "$REGISTRY" || true
                    '''
                }
            }
        }

        stage('Deploy to Kubernetes') {
            steps {
                withCredentials([
                    file(credentialsId: 'kubeconfig-lab', variable: 'KUBECONFIG_FILE'),
                    usernamePassword(
                        credentialsId: 'nexus-docker-credentials',
                        usernameVariable: 'NEXUS_USER',
                        passwordVariable: 'NEXUS_PASSWORD'
                    )
                ]) {
                    sh '''
                        set -eux
                        export KUBECONFIG="$KUBECONFIG_FILE"

                        kubectl cluster-info

                        kubectl create namespace "$NAMESPACE" \
                            --dry-run=client -o yaml | kubectl apply -f -

                        set +x
                        kubectl -n "$NAMESPACE" create secret docker-registry nexus-regcred \
                            --docker-server="$REGISTRY" \
                            --docker-username="$NEXUS_USER" \
                            --docker-password="$NEXUS_PASSWORD" \
                            --dry-run=client -o yaml | kubectl apply -f -
                        set -x

                        sed "s|IMAGE_PLACEHOLDER|$FULL_IMAGE|g" \
                            k8s/k8s-deployment.yaml > "$RENDERED_FILE"

                        kubectl apply -f "$RENDERED_FILE"
                        kubectl -n "$NAMESPACE" rollout status \
                            deployment/"$DEPLOYMENT" --timeout=180s
                    '''
                }
            }
        }

        stage('End-to-End Verification') {
            steps {
                withCredentials([
                    file(credentialsId: 'kubeconfig-lab', variable: 'KUBECONFIG_FILE')
                ]) {
                    sh '''
                        set -eux
                        export KUBECONFIG="$KUBECONFIG_FILE"

                        kubectl -n "$NAMESPACE" get deployment,pods,service,ingress -o wide

                        kubectl -n "$NAMESPACE" wait \
                            --for=condition=Ready pod \
                            -l app=maximuslabog-web \
                            --timeout=120s

                        DEPLOYED_IMAGE=$(kubectl -n "$NAMESPACE" get deployment "$DEPLOYMENT" \
                            -o jsonpath='{.spec.template.spec.containers[0].image}')
                        test "$DEPLOYED_IMAGE" = "$FULL_IMAGE"

                        kubectl -n "$NAMESPACE" port-forward service/"$SERVICE" 18081:80 \
                            >/tmp/maximuslabog-port-forward.log 2>&1 &
                        PF_PID=$!
                        cleanup() { kill "$PF_PID" >/dev/null 2>&1 || true; }
                        trap cleanup EXIT
                        sleep 5

                        curl --fail --silent http://127.0.0.1:18081/healthz
                        curl --fail --silent http://127.0.0.1:18081/ | grep -qi 'Maximus'
                    '''
                }
            }
        }
    }

    post {
        success {
            echo "SUCCESS: ${FULL_IMAGE} deployed to namespace ${NAMESPACE}"
            echo "Application URL: http://${INGRESS_HOST}"
        }

        failure {
            script {
                withCredentials([
                    file(credentialsId: 'kubeconfig-lab', variable: 'KUBECONFIG_FILE')
                ]) {
                    sh '''
                        export KUBECONFIG="$KUBECONFIG_FILE"
                        echo '===== Deployment ====='
                        kubectl -n "$NAMESPACE" describe deployment "$DEPLOYMENT" || true
                        echo '===== Pods ====='
                        kubectl -n "$NAMESPACE" get pods -o wide || true
                        echo '===== Events ====='
                        kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp || true
                        echo '===== Logs ====='
                        kubectl -n "$NAMESPACE" logs deployment/"$DEPLOYMENT" --all-containers --tail=100 || true
                    '''
                }
            }
        }

        always {
            sh '''
                docker rm -f "maximuslabog-smoke-${BUILD_NUMBER}" 2>/dev/null || true
                docker image rm "$FULL_IMAGE" 2>/dev/null || true
            '''
            archiveArtifacts artifacts: 'k8s/rendered-deployment.yaml', allowEmptyArchive: true
        }
    }
}
