# Verify checksum
curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256"
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check

# Install kubectl
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Cleanup
rm kubectl kubectl.sha256

# Verify installation
kubectl version --client

echo "✅ kubectl installed successfully"
echo ""

# ==============================================
# Install Helm
# ==============================================
echo "📦 Installing Helm..."

# Download Helm installation script
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3

# Make it executable
chmod 700 get_helm.sh

# Install Helm
./get_helm.sh

# Cleanup
rm get_helm.sh

# Verify installation
helm version

echo "✅ Helm installed successfully"
echo ""

# ==============================================
# Create .kube directory
# ==============================================
echo "📁 Creating .kube directory..."
mkdir -p ~/.kube
chmod 700 ~/.kube

echo "✅ .kube directory created"
echo ""

# ==============================================
# Verify installations
# ==============================================
echo "🔍 Verifying installations..."
echo ""
echo "kubectl version:"
kubectl version --client --short 2>/dev/null || kubectl version --client
echo ""
echo "Helm version:"
helm version --short
echo ""

echo "✅ Installation complete!"
echo ""
echo "📋 Next steps:"
echo "1. Configure kubectl to connect to your EKS cluster:"
echo "   aws eks update-kubeconfig --name pip-project-ecommerce-cluster --region ap-south-1"
echo ""
echo "2. Verify cluster access:"
echo "   kubectl get nodes"
echo ""
echo "3. Re-run Terraform apply:"
echo "   cd environments/dev"
echo "   terraform apply -var-file=dev.tfvars"

