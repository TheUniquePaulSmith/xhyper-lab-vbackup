# Introduction
This repo is used to perform ["Hyper-V WMI Based Backup with resilient change tracking"](https://docs.microsoft.com/en-us/virtualization/hyper-v-on-windows/reference/hypervbackupapproaches#hyper-v-wmi-based-backup) that was introduced in Windows Server 2016. It's designed to be ran in a lab setting where backup of VMs can be scheduled via Task Scheduler with this script.

This repository contains a submodule of ["machv"](https://github.com/machv/xhyper-vbackup) who improved Taylor Brown's original xHyper-VBackup Powershell Module. The PowerShell script "LabBackup.ps1" uses machv's script to do all the heavy lifting. This script uses JSON as "database" storage of configuration information and state tracking for VMs.

I consider the state of this script to be "alpha" as i'm still developing core functionality, but am i'm currently using it for my own lab backup :) 

# Requirements
- Windows Server 2016 with Hyper-V installed
- Hyper-V PowerShell Module
- Locally ran on Hyper-V Server

# Quick Start
**DBFilePath**, when used for install is path to folder, when used for Backup operations is full path to db.json file location


## **Install**
The script uses JSON PowerShell objects as database reference for tracking purposes. The install just bootstraps config information to be used by this script.
It's installed by running:
```powershell
.\LabBackup.ps1 -DBFilePath "B:\Backup" -Operation Install
```

By default all VMs get backed up, optionally if you want to exclude VMs from being backed-up, add an array of VM Names:
```powershell
.\LabBackup.ps1 -DBFilePath "B:\Backup" -Operation Install -excludeVMList @("VMName1", "VMName2", "VMName3")
```

To later add VMs to the exclude list just edit the db.json manually and add them.

## **Full & Diff Backup**
New VMs will have full backup, while existing backed up VMs will have differential backup performed:
```powershell
.\LabBackup.ps1 -DBFilePath "B:\Backup\db.json" -Operation Backup
```

## **New Only**
If you want to perform full backup of new VMs only
```powershell
.\LabBackup.ps1 -DBFilePath "B:\Backup\db.json" -Operation BackupNewOnly
```

# TODOs
Known issues and potential roadmap of tasks I'm thinking of implementing:
- Allow concurrent backup executions
- Better command controls like modify exclude list
- Implement restore backup commands
- Program better failure and error logic handling
- Implement file logging and better logging events
- Logic to detect deduplicated target storage and trigger deduplication
- Allow for per VM backup destinations on different volumes\drives
- Fix issues with RCT & Checkpoints not being cleaned up on script failure
- Logic to handling status
- Fix Parameter naming convention and usage
- Logic to detect sufficient drive space prior to backup
- Notification and alerting