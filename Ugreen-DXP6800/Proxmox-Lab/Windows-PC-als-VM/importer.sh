#!/bin/bash

# --- Abfrage der Parameter ---
read -p "VM-ID (z.B. 100): " VMID
read -p "VM-Name (z.B. MeinWindowsServer): " VMNAME
read -p "Pfad zur VHDX-Datei: " VHDXPATH
read -p "Name des ZFS-Zielspeichers (z.B. local-zfs): " STORAGE
read -p "Anzahl der CPU Cores (Default: 2): " CORES
CORES=${CORES:-2}

read -p "Netzwerk-Bridge (Default: vmbr0): " BRIDGE
BRIDGE=${BRIDGE:-vmbr0}

read -p "ISO-Name (z.B. local:iso/win11.iso, leer lassen): " ISOPATH

# Check ob Datei existiert
if [ ! -f "$VHDXPATH" ]; then
    echo "Fehler: Die Datei $VHDXPATH wurde nicht gefunden!"
    exit 1
fi

echo "---------------------------------------------------"
echo "Erstelle VM: $VMNAME (ID: $VMID)"
echo "Konfiguration: i440fx | CPU Host | Intel Net | SATA"
echo "---------------------------------------------------"

# 1. VM Erstellen
qm create $VMID --name "$VMNAME" \
    --memory 4096 --cores $CORES --cpu host \
    --net0 e1000,bridge=$BRIDGE \
    --machine pc --bios ovmf \
    --agent 1 --vga std \
    --ostype win11 \
    --scsihw virtio-scsi-single

# 2. EFI und TPM (Notwendig für UEFI/Windows 11)
echo "[1/4] Erstelle EFI-Disk und TPM-Modul auf $STORAGE..."
qm set $VMID --efidisk0 $STORAGE:0,pre-enrolled-keys=1
qm set $VMID --tpmstate0 $STORAGE:0,version=v2.0

# 3. CD-ROM
if [ -z "$ISOPATH" ]; then
    echo "[2/4] Füge leeres CD-ROM Laufwerk hinzu..."
    qm set $VMID --ide2 media=cdrom
else
    echo "[2/4] Lege ISO $ISOPATH ein..."
    qm set $VMID --ide2 $ISOPATH,media=cdrom
fi

# 4. VHDX Import (ZFS)
echo "[3/4] Importiere VHDX... (Das kann dauern)"
qm importdisk $VMID "$VHDXPATH" $STORAGE

# 5. Disk finden und als SATA0 einbinden
IMPORT_DISK=$(pvesm list $STORAGE | grep "vm-$VMID-disk" | sort | tail -n 1 | awk '{print $1}')

echo "[4/4] Verbinde Disk $IMPORT_DISK als SATA0..."
qm set $VMID --sata0 $IMPORT_DISK,discard=on,ssd=1

# Boot-Reihenfolge
qm set $VMID --boot order=sata0;ide2

echo "---------------------------------------------------"
echo "VM $VMNAME (ID $VMID) wurde erfolgreich erstellt!"
echo "---------------------------------------------------"