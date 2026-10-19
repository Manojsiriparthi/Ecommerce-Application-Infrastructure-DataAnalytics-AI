#!/usr/bin/env bash
# =============================================================================
# pip-project-ecommerce — Interactive Tool Installer
# =============================================================================
# Usage:
#   chmod +x install-tools.sh
#   ./install-tools.sh
#
# The script asks which tools you want, then installs only those.
# Supports Ubuntu 20.04 / 22.04 (Bastion, Jenkins EC2, local dev machine).
#
# Available tools:
#   docker      — Container runtime
#   git         — Version control
#   java        — Java 17 (required for Jenkins)
#   jenkins     — CI/CD server (runs as service, NOT docker container)
#   kubectl     — Kubernetes CLI
#   helm        — Kubernetes package manager
#   terraform   — Infrastructure as Code
#   awscli      — AWS CLI v2
#   trivy       — Container vulnerability scanner (runs via Docker)
#   sonarqube   — SAST code analysis (runs via Docker container)
#   prometheus  — Metrics collection (runs via Docker container)
#   grafana     — Metrics dashboards (runs via Docker container)
#   kind        — Local Kubernetes cluster (for testing only)
#   jq          — JSON processor (lightweight, always useful)
#   yq          — YAML processor (used by CI pipeline)
#
# NOTE: SonarQube, Prometheus, Grafana, Trivy run as Docker containers.
#       You must install Docker first before selecting those tools.
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
header()  { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════${NC}"; echo -e "${BOLD}${BLUE}  $1${NC}"; echo -e "${BOLD}${BLUE}══════════════════════════════════════${NC}"; }

# ── Root check ───────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}Run as root or with sudo:${NC}  sudo ./install-tools.sh"
  exit 1
fi

# ── OS check ─────────────────────────────────────────────────────────────────
if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
  warn "This script is designed for Ubuntu. Other distros may need adjustments."
fi

# =============================================================================
# WELCOME BANNER
# =============================================================================
clear
echo -e "${BOLD}${GREEN}"
echo "  ╔═══════════════════════════════════════════════════╗"
echo "  ║   pip-project-ecommerce — Tool Installer          ║"
echo "  ║   Select only the tools you need for this server  ║"
echo "  ╚═══════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "${YELLOW}Available tools (type the name, separated by spaces or commas):${NC}"
echo ""
echo -e "  ${BOLD}Core:${NC}"
echo "    docker      — Container runtime (install this first)"
echo "    git         — Version control"
echo "    jq          — JSON processor"
echo "    yq          — YAML processor"
echo "    awscli      — AWS CLI v2"
echo ""
echo -e "  ${BOLD}CI/CD Server (Jenkins machine):${NC}"
echo "    java        — Java 17 (required by Jenkins)"
echo "    jenkins     — CI/CD server (systemd service)"
echo "    terraform   — Infrastructure as Code"
echo "    kubectl     — Kubernetes CLI"
echo "    helm        — Kubernetes package manager"
echo "    trivy       — Vulnerability scanner (needs Docker)"
echo ""
echo -e "  ${BOLD}Code Quality (runs as Docker container):${NC}"
echo "    sonarqube   — SAST analysis server (needs Docker)"
echo ""
echo -e "  ${BOLD}Monitoring (run as Docker containers):${NC}"
echo "    prometheus  — Metrics collection (needs Docker)"
echo "    grafana     — Dashboards (needs Docker)"
echo ""
echo -e "  ${BOLD}Local testing only:${NC}"
echo "    kind        — Local Kubernetes cluster"
echo "    argocd      — GitOps CD (Helm on EKS)"
echo ""
echo -e "${CYAN}Examples:${NC}"
echo "  docker git                    → install Docker and Git only"
echo "  java jenkins docker git       → Jenkins server setup"
echo "  docker sonarqube              → SonarQube on this machine"
echo "  docker kubectl helm awscli    → EKS management machine"
echo ""

# ── Read user input ───────────────────────────────────────────────────────────
echo -ne "${BOLD}Which tools do you want to install? ${NC}"
read -r user_input

# Normalise: replace commas with spaces, lowercase, split into array
TOOLS=()
IFS=' ,' read -ra raw_tools <<< "$(echo "$user_input" | tr '[:upper:]' '[:lower:]')"
for t in "${raw_tools[@]}"; do
  [[ -n "$t" ]] && TOOLS+=("$t")
done

if [[ ${#TOOLS[@]} -eq 0 ]]; then
  echo -e "${RED}No tools selected. Exiting.${NC}"
  exit 0
fi

echo ""
echo -e "${BOLD}You selected: ${GREEN}${TOOLS[*]}${NC}"
echo -ne "Confirm installation? [y/N]: "
read -r confirm
[[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "Aborted."; exit 0; }

# =============================================================================
# HELPERS
# =============================================================================
has_tool() { command -v "$1" &>/dev/null; }

selected() {
  local tool="$1"
  for t in "${TOOLS[@]}"; do
    [[ "$t" == "$tool" ]] && return 0
  done
  return 1
}

apt_update_done=false
apt_update() {
  if [[ "$apt_update_done" == false ]]; then
    info "Updating apt package list..."
    apt-get update -y -q
    apt_update_done=true
  fi
}

# =============================================================================
# INSTALL FUNCTIONS
# =============================================================================

install_jq() {
  header "Installing jq"
  apt_update
  apt-get install -y -q jq
  success "jq $(jq --version) installed"
}

install_yq() {
  header "Installing yq"
  YQ_VERSION="v4.40.5"
  curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
    -o /usr/local/bin/yq
  chmod +x /usr/local/bin/yq
  success "yq $(yq --version) installed"
}

install_git() {
  header "Installing Git"
  apt_update
  apt-get install -y -q git
  success "git $(git --version) installed"
}

install_docker() {
  header "Installing Docker"
  if has_tool docker; then
    success "Docker already installed: $(docker --version)"
    return
  fi
  apt_update
  apt-get install -y -q ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y -q
  apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable docker
  systemctl start docker
  # Add ubuntu/ec2-user to docker group so sudo is not needed
  for user in ubuntu ec2-user; do
    id "$user" &>/dev/null && usermod -aG docker "$user" && \
      info "Added $user to docker group (re-login to take effect)"
  done
  success "Docker $(docker --version) installed"
}

install_java() {
  header "Installing Java 17"
  apt_update
  apt-get install -y -q fontconfig openjdk-17-jre
  success "$(java -version 2>&1 | head -1)"
}

install_jenkins() {
  header "Installing Jenkins"
  if ! has_tool java; then
    warn "Java not found. Installing Java first..."
    install_java
  fi
  curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
    | tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null
  echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
    https://pkg.jenkins.io/debian-stable binary/" \
    | tee /etc/apt/sources.list.d/jenkins.list > /dev/null
  apt-get update -y -q
  apt-get install -y -q jenkins
  systemctl enable jenkins
  systemctl start jenkins
  JENKINS_PASS=$(cat /var/lib/jenkins/secrets/initialAdminPassword 2>/dev/null || echo "see /var/lib/jenkins/secrets/initialAdminPassword")
  success "Jenkins installed and started"
  echo -e "  ${YELLOW}Initial admin password:${NC} $JENKINS_PASS"
  echo -e "  ${YELLOW}Access Jenkins at:${NC} http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || hostname -I | awk '{print $1}'):8080"
}

install_awscli() {
  header "Installing AWS CLI v2"
  if has_tool aws; then
    success "AWS CLI already installed: $(aws --version)"
    return
  fi
  apt_update
  apt-get install -y -q unzip curl
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp/
  /tmp/aws/install
  rm -rf /tmp/awscliv2.zip /tmp/aws
  success "AWS CLI $(aws --version) installed"
}

install_kubectl() {
  header "Installing kubectl"
  KUBECTL_VERSION="v1.32.0"
  curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl
  chmod +x /usr/local/bin/kubectl
  success "kubectl $(kubectl version --client --short 2>/dev/null || kubectl version --client) installed"
}

install_helm() {
  header "Installing Helm"
  if has_tool helm; then
    success "Helm already installed: $(helm version --short)"
    return
  fi
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  success "Helm $(helm version --short) installed"
}

install_terraform() {
  header "Installing Terraform"
  if has_tool terraform; then
    success "Terraform already installed: $(terraform version | head -1)"
    return
  fi
  apt_update
  apt-get install -y -q gnupg software-properties-common
  curl -fsSL https://apt.releases.hashicorp.com/gpg \
    | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
    https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/hashicorp.list
  apt-get update -y -q
  apt-get install -y -q terraform
  success "Terraform $(terraform version | head -1) installed"
}

install_trivy() {
  header "Installing Trivy (via Docker)"
  if ! has_tool docker; then
    warn "Docker is required for Trivy. Installing Docker first..."
    install_docker
  fi
  # Pull Trivy image — runs on-demand, no persistent container
  docker pull aquasec/trivy:0.56.2
  # Create a wrapper script so 'trivy' works as a command
  cat > /usr/local/bin/trivy << 'TRIVY_WRAPPER'
#!/usr/bin/env bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$HOME/.trivy-cache:/root/.cache/" \
  aquasec/trivy:0.56.2 "$@"
TRIVY_WRAPPER
  chmod +x /usr/local/bin/trivy
  success "Trivy installed (runs via Docker). Usage: trivy image nginx:latest"
}

install_sonarqube() {
  header "Installing SonarQube (Docker container)"
  if ! has_tool docker; then
    warn "Docker is required. Installing Docker first..."
    install_docker
  fi
  # Set kernel parameter required by Elasticsearch inside SonarQube
  sysctl -w vm.max_map_count=524288
  sysctl -w fs.file-max=131072
  echo "vm.max_map_count=524288" >> /etc/sysctl.conf
  echo "fs.file-max=131072"      >> /etc/sysctl.conf

  docker volume create sonarqube_data    2>/dev/null || true
  docker volume create sonarqube_logs    2>/dev/null || true
  docker volume create sonarqube_extensions 2>/dev/null || true

  # Stop existing container if running
  docker stop sonarqube 2>/dev/null || true
  docker rm   sonarqube 2>/dev/null || true

  docker run -d \
    --name sonarqube \
    --restart unless-stopped \
    -p 9000:9000 \
    -v sonarqube_data:/opt/sonarqube/data \
    -v sonarqube_logs:/opt/sonarqube/logs \
    -v sonarqube_extensions:/opt/sonarqube/extensions \
    -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true \
    sonarqube:community

  success "SonarQube container started"
  echo -e "  ${YELLOW}URL:${NC}      http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || hostname -I | awk '{print $1}'):9000"
  echo -e "  ${YELLOW}Username:${NC} admin"
  echo -e "  ${YELLOW}Password:${NC} admin  (change on first login)"
  echo -e "  ${YELLOW}Wait ~2 minutes for SonarQube to fully start${NC}"
}

install_prometheus() {
  header "Installing Prometheus"
  echo -e "  ${YELLOW}Where do you want to install Prometheus?${NC}"
  echo "    1) Docker container  (standalone server, not on Kubernetes)"
  echo "    2) Helm on EKS       (production — installs kube-prometheus-stack)"
  echo -ne "  Choice [1/2]: "
  read -r prom_choice

  if [[ "$prom_choice" == "2" ]]; then
    # ── Helm on EKS ─────────────────────────────────────────────────────────
    if ! has_tool helm; then
      warn "Helm not found. Installing Helm first..."
      install_helm
    fi
    if ! has_tool kubectl; then
      warn "kubectl not found. Installing kubectl first..."
      install_kubectl
    fi
    info "Adding prometheus-community Helm repo..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update

    info "Installing kube-prometheus-stack (Prometheus + Grafana + Alertmanager)..."
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

    helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
      --namespace monitoring \
      --set prometheus.prometheusSpec.retention=15d \
      --set prometheus.prometheusSpec.resources.requests.memory=512Mi \
      --set prometheus.prometheusSpec.resources.limits.memory=1Gi \
      --set grafana.adminPassword=admin \
      --set grafana.service.type=ClusterIP \
      --set alertmanager.alertmanagerSpec.resources.requests.memory=128Mi \
      --wait --timeout=5m

    success "kube-prometheus-stack installed in namespace: monitoring"
    echo -e "  ${YELLOW}Access Grafana:${NC}"
    echo -e "    kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring"
    echo -e "    Open: http://localhost:3000  |  admin / admin"
    echo -e "  ${YELLOW}Access Prometheus:${NC}"
    echo -e "    kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n monitoring"

  else
    # ── Docker container ─────────────────────────────────────────────────────
    if ! has_tool docker; then
      warn "Docker is required. Installing Docker first..."
      install_docker
    fi
    mkdir -p /opt/prometheus
    cat > /opt/prometheus/prometheus.yml << 'PROM_CONFIG'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "node"
    static_configs:
      - targets: ["host.docker.internal:9100"]
PROM_CONFIG

    docker stop prometheus 2>/dev/null || true
    docker rm   prometheus 2>/dev/null || true

    docker run -d \
      --name prometheus \
      --restart unless-stopped \
      -p 9090:9090 \
      -v /opt/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro \
      prom/prometheus:latest \
      --config.file=/etc/prometheus/prometheus.yml \
      --storage.tsdb.retention.time=15d

    success "Prometheus container started → :9090"
  fi
}

install_grafana() {
  header "Installing Grafana"
  echo -e "  ${YELLOW}Where do you want to install Grafana?${NC}"
  echo "    1) Docker container  (standalone server)"
  echo "    2) Helm on EKS       (already included in kube-prometheus-stack)"
  echo -ne "  Choice [1/2]: "
  read -r graf_choice

  if [[ "$graf_choice" == "2" ]]; then
    info "Grafana is included in kube-prometheus-stack."
    info "Select 'prometheus' and choose option 2 to install both together."
  else
    if ! has_tool docker; then
      warn "Docker is required. Installing Docker first..."
      install_docker
    fi
    docker volume create grafana_data 2>/dev/null || true
    docker stop grafana 2>/dev/null || true
    docker rm   grafana 2>/dev/null || true

    docker run -d \
      --name grafana \
      --restart unless-stopped \
      -p 3000:3000 \
      -v grafana_data:/var/lib/grafana \
      -e GF_SECURITY_ADMIN_PASSWORD=admin \
      -e GF_USERS_ALLOW_SIGN_UP=false \
      grafana/grafana:latest

    success "Grafana container started → :3000  |  admin / admin"
  fi
}

install_kind() {
  header "Installing kind (local Kubernetes)"
  KIND_VERSION="v0.22.0"
  curl -fsSL "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64" \
    -o /usr/local/bin/kind
  chmod +x /usr/local/bin/kind
  success "kind $(kind --version) installed"
}

install_argocd() {
  header "Installing ArgoCD (Helm on EKS)"
  if ! has_tool helm; then
    warn "Helm not found. Installing Helm first..."
    install_helm
  fi
  if ! has_tool kubectl; then
    warn "kubectl not found. Installing kubectl first..."
    install_kubectl
  fi

  info "Adding ArgoCD Helm repo..."
  helm repo add argo https://argoproj.github.io/argo-helm
  helm repo update

  info "Creating argocd namespace..."
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

  info "Installing ArgoCD via Helm (pinned to v2.10.5 / chart 6.7.3)..."
  helm upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --version 6.7.3 \
    --set configs.params."server\.insecure"=true \
    --set server.service.type=ClusterIP \
    --set server.autoscaling.enabled=false \
    --set server.resources.requests.cpu=100m \
    --set server.resources.requests.memory=128Mi \
    --set server.resources.limits.cpu=500m \
    --set server.resources.limits.memory=256Mi \
    --set repoServer.resources.requests.cpu=100m \
    --set repoServer.resources.requests.memory=128Mi \
    --set redis.resources.requests.cpu=50m \
    --set redis.resources.requests.memory=64Mi \
    --wait --timeout=10m

  success "ArgoCD installed in namespace: argocd"

  # Get initial admin password
  ARGO_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" 2>/dev/null | base64 --decode || echo "not ready yet")

  echo ""
  echo -e "  ${YELLOW}Access ArgoCD UI:${NC}"
  echo -e "    kubectl port-forward svc/argocd-server 8080:80 -n argocd"
  echo -e "    Open: http://localhost:8080"
  echo -e "  ${YELLOW}Username:${NC} admin"
  echo -e "  ${YELLOW}Password:${NC} $ARGO_PASS"
  echo ""
  echo -e "  ${YELLOW}Apply the ArgoCD Application to watch your repo:${NC}"
  echo -e "    kubectl apply -f 03-Kubernetes/argocd/ecommerce-app.yaml"
  echo ""
  echo -e "  ${YELLOW}After setup, every merge to main branch auto-deploys to EKS.${NC}"
}

# =============================================================================
# MAIN — run selected installs
# =============================================================================
header "Starting installation"

selected jq          && install_jq
selected yq          && install_yq
selected git         && install_git
selected docker      && install_docker
selected awscli      && install_awscli
selected java        && install_java
selected jenkins     && install_jenkins
selected kubectl     && install_kubectl
selected helm        && install_helm
selected terraform   && install_terraform
selected trivy       && install_trivy
selected sonarqube   && install_sonarqube
selected prometheus  && install_prometheus
selected grafana     && install_grafana
selected kind        && install_kind
selected argocd      && install_argocd

# =============================================================================
# SUMMARY
# =============================================================================
header "Installation Summary"

ALL_TOOLS="jq yq git docker awscli java jenkins kubectl helm terraform trivy sonarqube prometheus grafana kind argocd"

for tool in $ALL_TOOLS; do
  if selected "$tool"; then
    # Check if it actually got installed
    case "$tool" in
      java)       has_tool java       && echo -e "  ${GREEN}✅ java${NC}       $(java -version 2>&1 | head -1)" || echo -e "  ${RED}❌ java       — check errors above${NC}" ;;
      jenkins)    systemctl is-active jenkins &>/dev/null && echo -e "  ${GREEN}✅ jenkins${NC}    running" || echo -e "  ${RED}❌ jenkins    — check errors above${NC}" ;;
      docker)     has_tool docker      && echo -e "  ${GREEN}✅ docker${NC}     $(docker --version)" || echo -e "  ${RED}❌ docker     — check errors above${NC}" ;;
      sonarqube)  docker ps | grep -q sonarqube  && echo -e "  ${GREEN}✅ sonarqube${NC}  container running → :9000" || echo -e "  ${RED}❌ sonarqube  — check errors above${NC}" ;;
      prometheus) docker ps | grep -q prometheus && echo -e "  ${GREEN}✅ prometheus${NC} container running → :9090" || echo -e "  ${RED}❌ prometheus — check errors above${NC}" ;;
      grafana)    docker ps | grep -q grafana    && echo -e "  ${GREEN}✅ grafana${NC}    container running → :3000" || echo -e "  ${RED}❌ grafana    — check errors above${NC}" ;;
      trivy)      has_tool trivy      && echo -e "  ${GREEN}✅ trivy${NC}      Docker wrapper ready" || echo -e "  ${RED}❌ trivy      — check errors above${NC}" ;;
      argocd)     kubectl get pods -n argocd 2>/dev/null | grep -q Running && echo -e "  ${GREEN}✅ argocd${NC}     running in namespace: argocd" || echo -e "  ${YELLOW}⏳ argocd${NC}     pods still starting, check: kubectl get pods -n argocd" ;;
      *)          has_tool "$tool"    && echo -e "  ${GREEN}✅ $tool${NC}" || echo -e "  ${RED}❌ $tool — check errors above${NC}" ;;
    esac
  fi
done

echo ""
echo -e "${BOLD}${GREEN}Done!${NC}"
echo ""
echo -e "${YELLOW}Note:${NC} If you installed Docker, log out and back in for group permissions to take effect."
echo -e "      Or run: ${CYAN}newgrp docker${NC}"
echo ""
