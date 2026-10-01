#!/bin/bash
# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run as root (sudo ./setup.sh)"
  exit 1
fi

echo "[+] Starting Digimode Interface Setup for Raspberry Pi OS Lite 64..."

# 1. Update and Install System Dependencies
echo "[+] Installing system dependencies..."
apt-get update
apt-get install -y python3-pip python3-serial python3-rpi-lgpio alsa-utils

# 2. Add System Users to Groups
echo "[+] Configuring user permissions..."
usermod -a -G dialout pi 2>/dev/null || true
usermod -a -G tty pi 2>/dev/null || true

# 3. Configure Boot Parameters & Hardware Overlays
echo "[+] Modifying /boot/firmware/config.txt..."
# Remove any existing versions first to avoid duplicates
sed -i '/dtoverlay=dwc2/d' /boot/firmware/config.txt
sed -i '/dtoverlay=pwm/d' /boot/firmware/config.txt

# Add required core overlays
echo "dtoverlay=dwc2,dr_mode=peripheral" >> /boot/firmware/config.txt
echo "dtoverlay=pwm,pin=18,func=2" >> /boot/firmware/config.txt

# 4. Force Load Kernel Modules on Boot
echo "[+] Configuring /etc/modules..."
sed -i '/dwc2/d' /etc/modules
sed -i '/libcomposite/d' /etc/modules
echo "dwc2" >> /etc/modules
echo "libcomposite" >> /etc/modules

# 5. Create the ConfigFS USB Gadget Initialization Script
echo "[+] Deploying USB Composite Gadget Configuration Script..."
cat << 'EOF' > /usr/local/bin/ham-composite-gadget.sh
#!/bin/bash
# Clear any existing state safely
cd /sys/kernel/config/usb_gadget/
if [ -d "ham_interface" ]; then
    echo "[-] Clearing existing gadget allocation..."
    cd ham_interface
    echo "" > UDC 2>/dev/null
    rm -f configs/c.1/acm.usb0
    rm -f configs/c.1/uac2.usb0
    rmdir configs/c.1/strings/0x409/
    rmdir configs/c.1/
    rmdir functions/acm.usb0/
    rmdir functions/uac2.usb0/
    rmdir strings/0x409/
    cd ..
    rmdir ham_interface
fi

# Enable configfs and core gadget architecture
mkdir -p ham_interface && cd ham_interface

# Define Hardware Identity Profiles (Standard Composite IAD Device)
echo 0x1d6b > idVendor   # Linux Foundation Base
echo 0x0104 > idProduct  # Multifunction Composite Profile
echo 0x0200 > bcdUSB     # USB 2.0 Mode
echo 0x0100 > bcdDevice  # Device v1.0.0

# Critical Multi-Interface Classes for Audio + Serial IAD Mapping
echo 0xef > bDeviceClass
echo 0x02 > bDeviceSubClass
echo 0x01 > bDeviceProtocol

# Define Multi-Language Text strings
mkdir -p strings/0x409
echo "000001" > strings/0x409/serialnumber
echo "Raspberry Pi" > strings/0x409/manufacturer
echo "Radio Interface" > strings/0x409/product

# Create Main Configuration Profile Config
mkdir -p configs/c.1/strings/0x409
echo "Audio+Serial" > configs/c.1/strings/0x409/configuration
echo 500 > configs/c.1/MaxPower

# --- FUNCTION 1: Define the Virtual COM Port (Serial CAT) ---
mkdir -p functions/acm.usb0
ln -s functions/acm.usb0 configs/c.1/

# --- FUNCTION 2: Define the Audio Soundcard (UAC2) ---
mkdir -p functions/uac2.usb0
echo 3 > functions/uac2.usb0/c_chmask     # 2-Channel Stereo Capture
echo 48000 > functions/uac2.usb0/c_srate  # 48kHz
echo 3 > functions/uac2.usb0/c_ssize      # 24-bit

echo 3 > functions/uac2.usb0/p_chmask     # 2-Channel Stereo Playback
echo 48000 > functions/uac2.usb0/p_srate  # 48kHz
echo 3 > functions/uac2.usb0/p_ssize      # 24-bit

ln -s functions/uac2.usb0 configs/c.1/

# --- BINDING PHASE: Connect configuration directly to Pi4 controller ---
sleep 2
UDC_NAME=$(ls /sys/class/udc | head -n 1)
if [ -n "$UDC_NAME" ]; then
    echo "$UDC_NAME" > UDC
    echo "[SUCCESS] Gadget bound to controller: $UDC_NAME"
else
    echo "[ERROR] No USB Device Controller found!"
fi
EOF

chmod +x /usr/local/bin/ham-composite-gadget.sh

# 6. Create the Python Radio CAT Watchdog Decoder Script
echo "[+] Deploying Python CAT Parser Watchdog Script..."
cat << 'EOF' > /usr/local/bin/cat-band-decoder.py
#!/usr/bin/env python3
import serial
import re
import time
import os

GADGET_PORT = '/dev/ttyGS0'    # Outbound PC facing virtual interface
HARDWARE_PORT = '/dev/ttyUSB0'  # Inbound physical radio link (CP210x)
BAUD_RATE = 38400
PWM_PERIOD_NS = 500000          # 2kHz Period (1 / 2000s = 500,000 ns)

BAND_VOLTAGES = {
    "160M": 0.23, "80M": 0.46, "60M": 0.69, "40M": 0.92, "30M": 1.15,
    "20M":  1.38, "17M": 1.61, "15M": 1.84, "12M": 2.07, "10M": 2.30, "6M": 2.53
}

def init_hardware_pwm():
    if not os.path.exists("/sys/class/pwm/pwmchip0/pwm0"):
        try:
            with open("/sys/class/pwm/pwmchip0/export", "w") as f:
                f.write("0")
            time.sleep(0.5)
        except Exception as e:
            print(f"[PWM ERROR] Cannot export hardware channel: {e}")
            return False
    try:
        with open("/sys/class/pwm/pwmchip0/pwm0/period", "w") as f:
            f.write(str(PWM_PERIOD_NS))
        with open("/sys/class/pwm/pwmchip0/pwm0/enable", "w") as f:
            f.write("1")
        return True
    except Exception as e:
        print(f"[PWM ERROR] Cannot initialize hardware settings: {e}")
        return False

def set_hardware_voltage(band_name):
    if band_name in BAND_VOLTAGES:
        voltage = BAND_VOLTAGES[band_name]
        duty_cycle_fraction = voltage / 3.3
        duty_ns = int(PWM_PERIOD_NS * duty_cycle_fraction)
        try:
            with open("/sys/class/pwm/pwmchip0/pwm0/duty_cycle", "w") as f:
                f.write(str(duty_ns))
            print(f"[BAND SET] Match: {band_name} -> Hardware Target: {voltage}V ({duty_ns}ns Duty)")
        except Exception as e:
            print(f"[PWM WRITE ERROR] Failed updating hardware: {e}")

def parse_frequency_to_band(freq_hz):
    mhz = freq_hz / 1000000.0
    if 1.8 <= mhz <= 2.0:         return "160M"
    elif 3.5 <= mhz <= 4.0:       return "80M"
    elif 5.2 <= mhz <= 5.5:       return "60M"
    elif 7.0 <= mhz <= 7.3:       return "40M"
    elif 10.1 <= mhz <= 10.15:    return "30M"
    elif 14.0 <= mhz <= 14.35:    return "20M"
    elif 18.068 <= mhz <= 18.168: return "17M"
    elif 21.0 <= mhz <= 21.45:    return "15M"
    elif 24.89 <= mhz <= 24.99:   return "12M"
    elif 28.0 <= mhz <= 29.7:     return "10M"
    elif 50.0 <= mhz <= 54.0:     return "6M"
    return None

def start_bridging_loop():
    print("[INIT] Launching Intercept Bridge Daemon Loop...")
    if not init_hardware_pwm():
        print("[CRITICAL] Aborting daemon: Hardware PWM module unavailable.")
        return

    cat_regex = re.compile(r'FA(\d{11});')

    while True:
        try:
            pc_link = serial.Serial(GADGET_PORT, BAUD_RATE, timeout=0.1)
            radio_link = serial.Serial(HARDWARE_PORT, BAUD_RATE, timeout=0.1)
            
            pc_link.reset_input_buffer()
            radio_link.reset_input_buffer()
            
            buffer = ""
            last_update_time = time.time()

            while True:
                current_time = time.time()

                if pc_link.in_waiting:
                    pc_data = pc_link.read(pc_link.in_waiting)
                    radio_link.write(pc_data)

                if radio_link.in_waiting:
                    radio_data = radio_link.read(radio_link.in_waiting)
                    pc_link.write(radio_data)
                    
                    try:
                        buffer += radio_data.decode('utf-8', errors='ignore')
                        if ";" in buffer:
                            matches = cat_regex.findall(buffer)
                            for match in matches:
                                freq_hz = int(match)
                                band = parse_frequency_to_band(freq_hz)
                                if band:
                                    set_hardware_voltage(band)
                                    last_update_time = current_time
                            buffer = buffer.split(";")[-1]
                            if len(buffer) > 128:
                                buffer = ""
                    except Exception:
                        buffer = ""

                if (current_time - last_update_time) >= 3.0:
                    radio_link.write(b'FA;')
                    print("[WATCHDOG] 3s Idle Timeout. Sending 'FA;' poll to rig...")
                    last_update_time = current_time

                time.sleep(0.001)

        except (serial.SerialException, OSError, TypeError, AttributeError):
            print("[DISCONNECT] Connection dropped. Retrying link mappings in 3s...")
            time.sleep(3)

if __name__ == "__main__":
    start_bridging_loop()
EOF

chmod +x /usr/local/bin/cat-band-decoder.py

# 7. Create Systemd Service Pointers
echo "[+] Installing Core Systemd services..."

# Gadget Initialization Service
cat << 'EOF' > /etc/systemd/system/ham-gadget.service
[Unit]
Description=Initialize Ham Radio USB Composite Gadget (ConfigFS)
After=sys-kernel-config.mount local-fs.target
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/ham-composite-gadget.sh

[Install]
WantedBy=sysinit.target
EOF

# CAT Band Decoder Daemon Service
cat << 'EOF' > /etc/systemd/system/cat-band-decoder.service
[Unit]
Description=Ham Radio CAT Passthrough and Band Decoder Daemon
After=ham-gadget.service
Conflicts=shutdown.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -u /usr/local/bin/cat-band-decoder.py
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# TX Audio Bridge Loop Service (Enforcing Right-channel Routing)
cat << 'EOF' > /etc/systemd/system/ham-audio-tx.service
[Unit]
Description=Ham Radio ALSA Audio Bridge (PC to Radio TX mono-Right)
After=ham-gadget.service
Requires=ham-gadget.service

[Service]
Type=simple
ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/alsaloop -C plug:hw:UAC2Gadget -P plug:hw:1 -t 50000 -c 1
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# RX Audio Bridge Loop Service
cat << 'EOF' > /etc/systemd/system/ham-audio-rx.service
[Unit]
Description=Ham Radio ALSA Audio Bridge (Radio to PC RX)
After=ham-gadget.service
Requires=ham-gadget.service

[Service]
Type=simple
ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/alsaloop -C plug:hw:1 -P plug:hw:UAC2Gadget -t 50000 -c 1
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 8. Reload and Enable System Daemons
echo "[+] Enabling system orchestration sequences..."
systemctl daemon-reload
systemctl enable ham-gadget.service cat-band-decoder.service ham-audio-tx.service ham-audio-rx.service

echo "[SUCCESS] Installation Complete! Please perform a hard system reboot (sudo reboot)."
echo "[NOTE] Ensure the Pi is connected to the PC via its USB-C OTG Data port!"
