#!/bin/bash

set -e

echo "==> Bitte gib deine E-Mail-Adresse für Let's Encrypt (Production) an:"
read -rp "Email: " EMAIL

echo "==> K3s Installation ohne Traefik"
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -

echo "==> Kubeconfig kopieren"
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config

echo "==> k9s installieren"
curl -Lo k9s.tgz https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64.tar.gz
tar -xzf k9s.tgz k9s
sudo mv k9s /usr/local/bin/
rm k9s.tgz

echo "==> Ingress-NGINX installieren"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.14.3/deploy/static/provider/cloud/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=Ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

echo "==> Cert-Manager installieren"
kubectl apply --validate=false -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.3/cert-manager.yaml
kubectl wait --namespace cert-manager \
  --for=condition=Ready pod \
  --selector=app.kubernetes.io/instance=cert-manager \
  --timeout=180s

echo "==> Let's Encrypt (Production) ClusterIssuer erstellen"
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: $EMAIL
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - http01:
          ingress:
            class: nginx
EOF

echo "✅ Setup abgeschlossen: k3s, k9s, ingress-nginx, cert-manager + Let's Encrypt (Prod)"
