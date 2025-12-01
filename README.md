# AutoOps Resolver – PowerShell Edition  

*A workflow automation toolkit built to accelerate server recovery and standardize troubleshooting across large-scale infrastructure.*



---



## Overview



**AutoOps Resolver (PowerShell Edition)** is the original automation system developed to reduce manual effort in handling offline or unhealthy servers.  

It replaces repetitive “first-aid” troubleshooting steps with a consistent, fast, and reliable automated flow directly from the operator’s machine.



This version was the first step toward a more advanced multi-user C#/.NET platform, and served as the foundation for validating automation logic, standardizing recovery steps, and proving the operational impact of automation.



It integrates with:



- **ServiceNow** (ticket context, output formatting)  

- **Redfish** (power management & BMC operations)  

- **Cobbler/PXE** rebuild flows  

- **Network diagnostics tools** (ping, DNS, SSH)  

- **Internal command-line tools (NetBatch, SUM, ipmitool)**  



---



## Technology Stack



### **Languages & Tools**

- **PowerShell 7**

- **Redfish API (curl-based & PowerShell wrapper)**

- **ipmitool / SUM / Redfish tools**

- **NetBatch** (task-based execution)

- **ServiceNow API (via CLI wrappers)**

- **Tampermonkey (optional UI integration)**

- **Windows Terminal / Linux Subsystem Compatibility**



### **External Components**

- Python helpers (optional)

- Bash scripts (used in some flows)

- ServiceNow work-notes CLI (`sn_cli.py`)

- Redfish management utilities



---



## Key Features



### **1. Automated Host Diagnostics**

- Ping/ICMP tests  

- SSH availability checks  

- BMC/Management interface reachability  

- DNS validations for both host and BMC/FQDN  

- MAC/IP verification against server metadata  



### **2. Power Operations (Redfish)**

- Power On  

- Power Reset  

- AC Cycle  

- Boot Mode Configuration  



### **3. Cobbler/PXE Rebuild Automation**

- Legacy PXE restart  

- Rebuild workflow initialization  

- Automatic post-boot validation  



### **4. BMC Tools**

- BMC reset  

- BMC health checks  

- Credential validation  

- Network & firmware state inspection  



### **5. Standardized Operator Workflow**

Each execution follows the same trusted steps:



1. Validate hostname/site  

2. Fetch metadata (BMC, MAC, IP)  

3. Run connectivity & DNS tests  

4. Execute the selected automation  

5. Collect logs/output  

6. Format notes for ServiceNow  



### **6. ServiceNow Integration**

- Saves formatted work-notes  

- Copy/paste-ready troubleshooting summary  

- Consistent documentation for all agents  



---




### **Design Highlights**



- **Modular Function-Based Architecture**  

 Each subsystem (network, Redfish, cobbler, SN notes) is its own module.



- **Configuration-Driven**  

 All site-specific settings stored in a config module.



- **Non-destructive and safe**  

 Fails early on malformed hostnames, wrong sites, unreachable BMC, etc.



- **Reusable core functions**  

 Later used to build the C# Web AutoOps Resolver.



---



## Skills Demonstrated



### **Infrastructure Automation**

- Server bring-up automation  

- Power control using Redfish API  

- Integration with NetBatch job queues  

- BMC-level operations  



### **PowerShell Engineering**

- Advanced functions and modules  

- Parameter validation  

- Parallel command execution  

- Output formatting and pipelines  



### **Systems Troubleshooting**

- Network diagnostics (DNS, ping, SSH)  

- BMC checks and resets  

- Cobbler/PXE rebuild workflows  

- Host metadata verification  



### **Automation Design**

- Modular reusable scripts  

- Input validation + exception safety  

- Clean logging and service outputs  

- Scalable structure used for future web version  



### **ServiceNow & Ops Integration**

- Automated work-notes  

- Standardized troubleshooting  

- Consistent documentation across team  



---



## Getting Started



### **1. Clone the Repository**



```sh

git clone https://github.com/yourusername/autoops-powershell.git

cd autoops-powershell



### **2. Configure Environment Variables**





### ** Set site credentials or metadata paths:**



$env:SITE = "sc"

$env:CREDENTIALS_PATH = "$HOME/.autoops/creds.json"



### **3. Run the Tool**



./AutoOps.ps1 -Server "server123.sc.domain" -Action PowerOn





Supported actions include:



PowerOn



ACCycle



BMCReset



PXERebuild



CheckAll



NetworkCheck



### **4. View Execution Output**





Output is displayed on screen and can optionally be saved to:



./logs/YYYY-MM-DD/



Example Output (simplified)

=== AutoOps – Server Recovery ===



Host: scce01120103

BMC: 10.119.253.180



[Network]

✓ Ping reachable

✓ DNS correct

✓ SSH reachable

✓ BMC reachable via Redfish



[Action: PowerOn]

✓ Redfish: PowerState = On

✓ Boot sequence OK



[Summary]

Server is now online and reachable.

Notes saved for ServiceNow.

.



