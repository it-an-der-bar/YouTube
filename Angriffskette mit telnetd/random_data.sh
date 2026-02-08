#!/bin/bash

NAMESPACE="wordpress-site"
DB_POD=$(kubectl get pods -n $NAMESPACE -l app=mariadb -o jsonpath="{.items[0].metadata.name}")
DB_PASS=$(kubectl get secret wp-secrets -n $NAMESPACE -o jsonpath="{.data.mysql-password}" | base64 --decode)

echo "--- Generiere 100 REALISTISCHE Datensätze (inkl. Hashes) ---"

# Datenbank-Struktur
kubectl exec -i -n $NAMESPACE $DB_POD -- mysql -u wordpress -p"$DB_PASS" <<EOF
USE wordpress;
DROP TABLE IF EXISTS customer_data;
CREATE TABLE IF NOT EXISTS customer_data (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100),
    email VARCHAR(100),
    password_cleartext VARCHAR(100),
    password_hash VARCHAR(100),
    cc_number VARCHAR(25),
    city VARCHAR(50),
    job_title VARCHAR(50)
);
TRUNCATE TABLE customer_data;
EOF

# Holen Daten bei einem Random User generator
echo "Hole 100 Identitäten..."
USER_DATA=$(curl -s "https://randomuser.me/api/?results=100&nat=de&inc=name,email,location" | jq -r '.results[] | "\(.name.first) \(.name.last);\(.email);\(.location.city)"')

passwords=(
    "Sonnenschein1" "Passwort!" "Geheim01" "Admin2024" "Wurstbrot" "K8s-Master" 
    "IchLiebeBier" "12345678" "qwertz123" "hallo123" "Passwort2023" "Sommer2024!" 
    "Master01!" "SuperSafe!" "BierVomFass" "Whisky2024" "CloudComputing!" 
    "LetMeIn" "NoAccess" "Password123" "StarWars2024" "IHeartDocker" "Kubernetes123" 
    "Feierabend!" "GinTonic24" "Password!" "123456789" "qwerty" "football" "welcome"
    "Spring24" "Berlin2024" "Schalke04" "BVB2024!" "Liebe123" "Schatzi99"
)
jobs=(
    "System Admin" "DevOps Engineer" "Barkeeper" "Cloud Architect" "Security Consultant" 
    "Frontend Dev" "Backend Developer" "Fullstack Engineer" "Scrum Master" "Product Owner" 
    "CISO" "CTO" "Head of Infrastructure" "Database Administrator" "Linux Enthusiast" 
    "Network Engineer" "IT-Support" "Junior Developer" "Senior Architect" "Site Reliability Engineer"
    "Data Scientist" "AI Researcher" "Stammgast" "Türsteher" "Braumeister" "Incident Manager"
    "Pentester" "SOC Analyst" "Cloud Native Engineer" "Platform Engineer" "IT-Leiter"
)
echo "Schreibe Daten..."
i=1
while IFS=';' read -r fullname email stadt; do
    PW=${passwords[$RANDOM % ${#passwords[@]}]}
    JOB=${jobs[$RANDOM % ${#jobs[@]}]}
    CC="4$(($RANDOM%900+100)) $(($RANDOM%9000+1000)) $(($RANDOM%9000+1000)) $(($RANDOM%9000+1000))"

    # Generiere einen MD5 Hash für das Passwort
    PW_HASH=$(echo -n "$PW" | openssl md5 | awk '{print $2}')

    SQL="INSERT INTO customer_data (name, email, password_cleartext, password_hash, cc_number, city, job_title) \
         VALUES ('$fullname', '$email', '$PW', '$PW_HASH', '$CC', '$stadt', '$JOB');"

    kubectl exec -n $NAMESPACE $DB_POD -- mysql -u wordpress -p"$DB_PASS" -e "USE wordpress; $SQL"

    if (( $i % 20 == 0 )); then echo "$i/100 eingetragen..."; fi
    ((i++))
done < <(echo "$USER_DATA") 

echo "--- FERTIG! ---"
echo "Check: kubectl exec -it $DB_POD -n $NAMESPACE -- mysql -u wordpress -p'$DB_PASS' -e 'USE wordpress; SELECT * FROM customer_data LIMIT 5;'"
