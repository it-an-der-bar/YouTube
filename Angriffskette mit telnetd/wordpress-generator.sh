#!/bin/bash

# --- Hilfsfunktion für Zufallspasswörter ---
generate_password() {
    openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 18
}

echo "--- WordPress & MariaDB Deployment Setup ---"

# --- Abfragen ---
read -p "Namespace [wordpress-site]: " NAMESPACE
NAMESPACE=${NAMESPACE:-wordpress-site}

read -p "Ingress URL (z.B. wp.dein-domain.de): " INGRESS_URL

read -p "MariaDB Root Passwort [Auto-Generated]: " DB_ROOT_PW
DB_ROOT_PW=${DB_ROOT_PW:-$(generate_password)}

read -p "WordPress DB Passwort [Auto-Generated]: " WP_DB_PW
WP_DB_PW=${WP_DB_PW:-$(generate_password)}

# --- Verzeichniserstellung ---
mkdir -p ./manifest-wordpress

# --- 1. Namespace & Secrets ---
cat <<EOF > ./manifest-wordpress/00-base.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: $NAMESPACE
---
apiVersion: v1
kind: Secret
metadata:
  name: wp-secrets
  namespace: $NAMESPACE
type: Opaque
stringData:
  mysql-root-password: $DB_ROOT_PW
  mysql-password: $WP_DB_PW
EOF

# --- 2. ConfigMap für php.ini (Anpassungen) ---
cat <<EOF > ./manifest-wordpress/01-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: wp-php-config
  namespace: $NAMESPACE
data:
  custom-php.ini: |
    upload_max_filesize = 64M
    post_max_size = 64M
    memory_limit = 256M
    max_execution_time = 300
EOF

# --- 3. MariaDB StatefulSet ---
cat <<EOF > ./manifest-wordpress/02-mariadb.yaml
apiVersion: v1
kind: Service
metadata:
  name: mariadb
  namespace: $NAMESPACE
spec:
  ports:
    - port: 3306
  selector:
    app: mariadb
  clusterIP: None
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mariadb
  namespace: $NAMESPACE
spec:
  selector:
    matchLabels:
      app: mariadb
  serviceName: "mariadb"
  replicas: 1
  template:
    metadata:
      labels:
        app: mariadb
    spec:
      containers:
      - name: mariadb
        image: mariadb:10.6
        env:
        - name: MYSQL_ROOT_PASSWORD
          valueFrom: { secretKeyRef: { name: wp-secrets, key: mysql-root-password } }
        - name: MYSQL_DATABASE
          value: wordpress
        - name: MYSQL_USER
          value: wordpress
        - name: MYSQL_PASSWORD
          valueFrom: { secretKeyRef: { name: wp-secrets, key: mysql-password } }
        ports:
        - containerPort: 3306
        volumeMounts:
        - name: mysql-data
          mountPath: /var/lib/mysql
  volumeClaimTemplates:
  - metadata:
      name: mysql-data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 5Gi
EOF

# --- 4. WordPress Deployment ---
cat <<EOF > ./manifest-wordpress/03-wordpress.yaml
apiVersion: v1
kind: Service
metadata:
  name: wordpress
  namespace: $NAMESPACE
spec:
  ports:
    - port: 80
  selector:
    app: wordpress
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wordpress
  namespace: $NAMESPACE
spec:
  selector:
    matchLabels:
      app: wordpress
  template:
    metadata:
      labels:
        app: wordpress
    spec:
      containers:
      - name: wordpress
        image: wordpress:latest
        env:
        - name: WORDPRESS_DB_HOST
          value: mariadb
        - name: WORDPRESS_DB_USER
          value: wordpress
        - name: WORDPRESS_DB_PASSWORD
          valueFrom: { secretKeyRef: { name: wp-secrets, key: mysql-password } }
        - name: WORDPRESS_DB_NAME
          value: wordpress
        ports:
        - containerPort: 80
        volumeMounts:
        - name: wp-data
          mountPath: /var/www/html
        - name: php-config
          mountPath: /usr/local/etc/php/conf.d/custom.ini
          subPath: custom-php.ini
      volumes:
      - name: wp-data
        emptyDir: {} # Für Produktion durch PVC ersetzen!
      - name: php-config
        configMap:
          name: wp-php-config
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: wordpress-ingress
  namespace: $NAMESPACE
spec:
  ingressClassName: nginx
  rules:
  - host: $INGRESS_URL
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: wordpress
            port:
              number: 80
EOF

echo "Manifeste wurden in ./manifest-wordpress erstellt."
read -p "Sollen die Manifeste jetzt auf den Cluster angewendet werden? (y/n): " APPLY
if [[ $APPLY == "y" ]]; then
    kubectl apply -f ./manifest-wordpress/
fi
