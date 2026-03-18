# Zabbix Proxy Install  - Ubuntu 24.04 LTS (minimal server)
---
#### Preparation:

Change the hostname of the device using this command:

```bash
sudo hostnamectl set-hostname <new hostname>
```

Reboot the device to make sure the hostname is changed:

```bash
sudo reboot
```

You can check this by using this command:

```bash
hostname
```

---
#### Install:
```bash
wget -q https://raw.githubusercontent.com/DentechNL/fb5cc8a1-6a1d-4427-a214-b914cc47b048/main/Proxy-Install/Ubuntu-24.04-LTS/installProxy.sh -O installProxy.sh

chmod +x installProxy.sh

sudo ./installProxy.sh
```

> [!NOTE]
> Use `sudo apt install wget -y` if wget is not installed

---

#### Usage:

1.  Use the installer above on a clean Ubuntu 24.04 LTS system. 

2.  During the installation process the installer will ask for the IP-address of the main Zabbix server. Fill in the IP-address and make sure the proxy can reach it on **port 10051**.

3.  When the installation is done the installer wil show the PSK identity and the PSK value. Copy these and save them temporarily in notepad or someting like it.

>[!warning]
> Do not share this key with anyone and make sure to delete it at the end of the connection process!

4.  Open the web UI of the main Zabbix server and go to *Administration*
5.  Click *Proxies* 
6.  In the upper right corner you will see a button: *Create proxy*, click this button
7.  Fill in the proxy name, this should be the same as the PSK identity
8.  Make sure the Proxy mode is *active*
9.  For the *Proxy address* you fill in the IP-address of the proxy
10.  Now go to the next tab: *Encryption*
11.  Unselect *No encryption* and select *PSK*
12.  Here you fill in the PSK identity and the PSK value
13.  Click *Add*

**Done!**







