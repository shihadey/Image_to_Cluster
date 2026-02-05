1) Préparer l’arborescence (dans ton repo)
```
mkdir -p packer/www ansible/k8s scripts
```



2.1) Installer K3d


```
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
```

//Création du cluster Kuber -> Certainement inutile car le cluster est créé plus tard dans e processus.
```
k3d cluster create lab \
  --servers 1 \
  --agents 2
```


2.2) Installer Packer

```
PACKER_VERSION=1.11.2
curl -fsSL -o /tmp/packer.zip \
  "https://releases.hashicorp.com/packer/${PACKER_VERSION}/packer_${PACKER_VERSION}_linux_amd64.zip"
sudo unzip -o /tmp/packer.zip -d /usr/local/bin
rm -f /tmp/packer.zip
```

2.3) Installer Ansible + collection Kuber

```
python3 -m pip install --user ansible kubernetes PyYAML jinja2
export PATH="$HOME/.local/bin:$PATH"
ansible-galaxy collection install kubernetes.core
```


--------------------------
3) Packer : build + push de l’image Nginx custom

3.1) Création du fichier index.html

```
cat > packer/www/index.html <<'EOF'
<!doctype html>
<html>
  <head><meta charset="utf-8"><title>Packer + K3d</title></head>
  <body>
    <h1>✅ Nginx déployé via Packer + Ansible sur K3d</h1>
    <p>Build time: __BUILD_TIME__</p>
  </body>
</html>
EOF
```

3.2) Template Packer (Docker builder)

Créer packer/nginx.pkr.hcl :

```
cat > packer/nginx.pkr.hcl <<'EOF'
packer {
  required_plugins {
    docker = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/docker"
    }
  }
}

variable "repository" {
  type    = string
  default = "k3d-registry.localhost:5000/nginx-packer"
}

variable "tag" {
  type    = string
  default = "1.0.0"
}

source "docker" "nginx" {
  image  = "nginx:alpine"
  commit = true
}

build {
  sources = ["source.docker.nginx"]

  provisioner "shell" {
    inline = [
      "mkdir -p /usr/share/nginx/html",
      "date -Iseconds > /tmp/build_time.txt"
    ]
  }

  provisioner "file" {
    source      = "www/index.html"
    destination = "/usr/share/nginx/html/index.html"
  }

  provisioner "shell" {
    inline = [
      "BT=$(cat /tmp/build_time.txt)",
      "awk -v bt=\"$BT\" '{gsub(/__BUILD_TIME__/, bt)}1' /usr/share/nginx/html/index.html > /tmp/index.html && mv /tmp/index.html /usr/share/nginx/html/index.html"
    ]
  }

  post-processor "docker-tag" {
    repository = var.repository
    tags       = [var.tag]
  }
}
EOF
```

3.3) Build de l'image customisée

```
cd packer
packer init .
packer fmt .
packer validate .
packer build .
```

3.4) Import de l'image dans le K3d

```
k3d image import k3d-registry.localhost:5000/nginx-packer:1.0.0 -c lab
```

--------------------------------
4) Déploiement du service dans Kubernetes via Ansible
4.1) Manifests en templates Jinja2

Créer ansible/k8s/deployment.yml.j2 :

```
cd ..
```

```
cat > ansible/k8s/deployment.yml.j2 <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-packer
  labels:
    app: nginx-packer
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-packer
  template:
    metadata:
      labels:
        app: nginx-packer
      namespace: {{ namespace }}
      labels:
        app: nginx-packer
    spec:
      containers:
        - name: nginx
          image: {{ image }}
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
EOF
```

Créer ansible/k8s/service.yml.j2 :

```
cat > ansible/k8s/service.yml.j2 <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: nginx-packer-svc
  namespace: {{ namespace }}
spec:
  selector:
    app: nginx-packer
  ports:
    - port: 80
      targetPort: 80
EOF
```

4.2) Inventory + playbook

Créer ansible/inventory.ini :

```
cat > ansible/inventory.ini <<'EOF'
[local]
localhost ansible_connection=local
EOF
```


Créer ansible/deploy.yml :

```
cat > ansible/deploy.yml <<'EOF'
- name: Deploy Nginx (Packer-built) to K3d via Ansible
  hosts: local
  gather_facts: false
  vars:
    namespace: demo
    image: "k3d-registry.localhost:5000/nginx-packer:1.0.0"

  tasks:
    - name: Ensure namespace exists
      kubernetes.core.k8s:
        state: present
        definition:
          apiVersion: v1
          kind: Namespace
          metadata:
            name: "{{ namespace }}"

    - name: Apply Deployment
      kubernetes.core.k8s:
        state: present
        namespace: "{{ namespace }}"
        definition: "{{ lookup('template', 'k8s/deployment.yml.j2') }}"

    - name: Apply Service
      kubernetes.core.k8s:
        state: present
        namespace: "{{ namespace }}"
        definition: "{{ lookup('template', 'k8s/service.yml.j2') }}"
EOF
```

4.3) Lancer le déploiement du service

```
cd ansible
ansible-playbook -i inventory.ini deploy.yml
cd ..
```

------------------------------------
5) Vérification

5.1) Forward du port du service
```
kubectl -n demo port-forward svc/nginx-packer-svc 8080:80 >/tmp/web.log 2>&1 &
```

Dans l'onglet <PORT> dans GitHub votre port 8080 est actif.
Vous pouvez lui donner une visibilité Public si vous souhaitez diffuser ce lien à l'extérieur.

6) Déploiment auto via script shell
```
nano script_auto/deploiment_complet.sh
```
**Y inserer le contenu suivant**
```
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

```
**Lancement du script**
```
chmod +x script_auto/deploiment_complet.sh && ./script_auto/deploiment_complet.sh
```


CD/CI pipeline
```
mkdir -p .github/workflows
cd .github/workflows
nano ci-cd.yml
```
```
name: Packer → K3d Pipeline

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]
  workflow_dispatch:  # Permet lancement manuel

jobs:
  deploy:
    runs-on: ubuntu-latest
    
    steps:
    - uses: actions/checkout@v4
    
    - name: Install K3d
      run: |
        curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
        
    - name: Install Packer
      run: |
        PACKER_VERSION=1.11.2
        curl -fsSL -o /tmp/packer.zip \
          "https://releases.hashicorp.com/packer/${PACKER_VERSION}/packer_${PACKER_VERSION}_linux_amd64.zip"
        sudo unzip -o /tmp/packer.zip -d /usr/local/bin
        rm -f /tmp/packer.zip
        
    - name: Install Ansible
      run: |
        sudo apt update
        sudo apt install -y ansible python3-pip
        pip3 install kubernetes PyYAML jinja2
        ansible-galaxy collection install kubernetes.core
        
    - name: Create K3d cluster
      run: |
        k3d cluster create lab --servers 1 --agents 2
        
    - name: Build Packer → Deploy
      run: |
        cd packer
        packer init .
        packer fmt .
        packer validate .
        packer build .
        k3d image import k3d-registry.localhost:5000/nginx-packer:1.0.0 -c lab
        cd ../ansible
        ansible-playbook -i inventory.ini deploy.yml
        
    - name: Test
      run: |
        sleep 10
        kubectl wait --for=condition=available deployment/nginx-packer --timeout=120s -n demo
        echo "✅ Déploiement réussi !"

```
```
cd ../..
git add .github/workflows/ci-cd.yml
git commit -m "Add CI/CD pipeline Packer→K3d"
git push
```


