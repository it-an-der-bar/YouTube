# 🍻 IT an der Bar: Security Demo (Lateral Movement)

Willkommen im offiziellen Repo zum Video! Hier zeigen wir, wie ein Angreifer nach einem initialen Einbruch seitwärts durch das Cluster wandert, um an die "Kronjuwelen" – die Kundendaten – zu gelangen.

## 📺 Das Szenario
In dieser Demo simulieren wir einen erfolgreichen Exploit einer Sicherheitslücke auf einem internen Service. Der Fokus liegt auf der Post-Exploitation: Was passiert, wenn der Angreifer erst einmal Zugriff auf das System hat und wie er die MariaDB-Datenbank plündert.

## 🛠️ Vorbereitung

### 1. Kubernetes Basis (K3s)
Zuerst muss die K3s-Umgebung stehen. Nutze dazu das Setup-Script aus dem Basis-Verzeichnis meines Repos:

$ ./Eigener\ Server/Kubernetes-Basis/setup-k3s.sh

### 2. WordPress & MariaDB Stack
Dieses Script automatisiert das Deployment. Es erstellt den Namespace, generiert sichere Passwörter (18 Zeichen Random), setzt das MariaDB StatefulSet auf und konfiguriert das WordPress-Deployment inklusive Custom php.ini.

$ chmod +x wordpress_generator.sh
$ ./wordpress_generator.sh

### 3. Datenbank mit Demo-Content füllen (The Leak)
Damit die Security-Demo ordentlich "Futter" hat, füllen wir die Datenbank mit 100+ fiktiven, aber extrem realistischen deutschen Identitäten. Enthalten sind Namen, E-Mails, Kreditkartennummern und MD5-Hashes zum Cracken.

$ chmod +x random_data.sh
$ ./random_data.sh

## 🕵️ Demo-Ablauf (Video-Guide)

1. Initial Access: Der Angreifer nutzt eine Schwachstelle im telnetd CVE 2026-24061.
2. Privilege Escalation: Erlangung von weiterführenden Rechten im Container/Namespace.
3. Data Exfiltration:
   - Auslesen der Environment-Variables (DB-Credentials).
   - Zugriff auf die MariaDB via HeidiSQL.
   - Extraktion der Tabelle customer_data.
   - Deface der Website

## 📂 Enthaltene Dateien
- wordpress_generator.sh: K8s-Infrastruktur Generator.
- random_data.sh: Datengenerator (nutzt randomuser.me & jq).

---
Serviert von IT an der Bar - Infrastruktur verstehen, Sicherheit genießen. Prost! 🍻