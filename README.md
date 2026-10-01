This setup allows a Pi4 to be placed between the laptop and rig. Laptop connects through an OTG/Power Splitter.
The rig is connected to one of the blue-USB connectors. A py-script running in the Pi4 sniffs the CAT responses from the
rig and sets the Key-return voltages, changes bands on the GPA 100.



**How to Run It on a Fresh Setup**

Once you flash your fresh Raspberry Pi OS Lite (64-bit) image and connect via SSH:

1.  **Create the setup file:**
    

**bash**

`nano setup.sh`

Use code with caution.

2.  Copy the full script content provided in the file above, paste it into the window, then save and exit (`Ctrl+O`, `Enter`, `Ctrl+X`).
    
3.  **Make the configuration batch executable:**
    

**bash**

`chmod +x setup.sh`

Use code with caution.

4.  **Run the script with root permissions:**
    

**bash**

`sudo ./setup.sh`

Use code with caution.

5.  **Reboot the system to finish the hardware initialization:**
    

**bash**

`sudo reboot`

**Output Filter for GPIO (DAC)**
                           R1 (1.6 kΩ)
Pin 12 (GPIO 18)  ●--------[  Resistor  ]--------●-------> To Radio Band Input
                                                 |
                                               =====  C1 (1 µF)

                                               |   |  Capacitor
                                                 |
Pin 6 (GND)       ●------------------------------●-------> To Radio Ground

