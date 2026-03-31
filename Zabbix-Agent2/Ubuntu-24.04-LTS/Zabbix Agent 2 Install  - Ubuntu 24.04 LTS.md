# Zabbix Agent2 Install  - Ubuntu 24.04 LTS (minimal server)
---
#### Install:
```bash
wget -q https://raw.githubusercontent.com/DentechNL/fb5cc8a1-6a1d-4427-a214-b914cc47b048/refs/heads/main/Zabbix-Agent2/Ubuntu-24.04-LTS/installAgent2.sh -O installAgent2.sh

chmod +x installProxy.sh

sudo ./installProxy.sh
```

> [!NOTE]
> Use `sudo apt install wget -y` if wget is not installed

---

#### Usage:

1.  Use the installer above only on Ubuntu 24.04 LTS system. 

2.  During the installation process the installer will ask for the IP-address of the main Zabbix server (or the proxy you wish to use for this device). Fill in the IP-address and make sure the device can reach it on **port 10051**.

3.  When the installation is done the installer wil show the PSK identity and the PSK value. Copy these and save them temporarily in notepad or someting like it.

>[!warning]
> Do not share this key with anyone and make sure to delete it at the end of the connection process!

4.  Open the web UI of the main Zabbix server and go to *Monitoring*
5.  Click *Hosts* 
6.  In the upper right corner you will see a button: *Create host*, click this button
7.  Fill in the hostname, this should be the same as the PSK identity
8.  In the section *Host groups* choose: 'Linux servers'
9.  Then in the *Interfaces* section choose 'Agent'
10. Change the Agent IP-address to the address of the device you want to add
11. Change the port to **10051** (this is active monitoring)
12. Choose what device should do the monitoring, this can be the main server or a proxy
13.  Now go to the next tab: *Encryption*
14.  Unselect *No encryption* and select *PSK*
15.  Here you fill in the PSK identity and the PSK value
16.  Click *Add*

**Done!**