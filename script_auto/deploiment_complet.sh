#!/bin/bash
set -euo pipefail

echo "🚀 Pipeline complet Packer → K3d → Kubernetes"

# Variables
IMAGE="k3d-registry.localhost:5000/nginx-packer:1.0.0"
NAMESPACE="demo"
CLUSTER="lab"

# 1. Build Packer
echo "🔨 Build image avec Packer..."
cd packer
packer fmt . && packer build .

# 2. Import K3d
echo "📦 Import dans K3d..."
k3d image import $IMAGE -c $CLUSTER

cd ..

# 3. Déploiement Ansible
echo "🎭 Déploiement Kubernetes via Ansible..."
cd ansible
ansible-playbook -i inventory.ini deploy.yml

# 4. Port-forward automatique
echo "🌐 Port-forward 8082..."
pkill -f "port-forward.*nginx-packer-svc" 2>/dev/null || true
sleep 3
kubectl -n $NAMESPACE port-forward svc/nginx-packer-svc 8082:80 >/tmp/web.log 2>&1 &

echo "✅ Déploiement terminé ! http://localhost:8082"
echo "📊 kubectl get all -n demo"
kubectl get all -n $NAMESPACE
