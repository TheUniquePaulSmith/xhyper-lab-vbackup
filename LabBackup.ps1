param (
    [Parameter(Mandatory = $true)]
    [String] $DBFilePath,

    [Parameter(Mandatory = $false)]
    [String[]] $excludeVMList,

    [Parameter(Mandatory = $true)]
    [ValidateSet("Install", "Backup", "BackupNewOnly")]
    [String] $Operation
)


Begin {
    $ErrorActionPreference = "Stop"
    $global:db = $null

    # First check and load required modules
    if (!(Get-Module -ListAvailable -Name "Hyper-V")) {
        throw "Hyper-V not detected"
        exit 1;
    }
    else {
        try {
            import-module "Hyper-V"
        }
        catch {
            throw "Unable to load Hyper-V module"
            exit 1;
        }
    }

    if (!(Get-Module -ListAvailable -Name xHyper-VBackup.cmdlets)) {
        try {
            import-module .\xHyper-VBackup.cmdlets.psm1
        }
        catch {
            throw "Unable to load xHyper-VBackup module"
            exit 1;
        }
    }

    function DoFullOrDiffBackup {
        param (
            # Parameter help description
            [Parameter(Mandatory = $true)]
            [Object[]]
            $vms
        )

        # For each VM determine if Full or Differential is needed
        # Sequentially for now
        $vms | ForEach-Object {
            $vm = $_

            #Full path for backup
            $vmFullBackupPath = "$($global:db.BackupFolderPath)\$($vm.Name)\Full"
            $vmDiffBackupPath = "$($global:db.BackupFolderPath)\$($vm.Name)\Diff_$(Get-Date -UFormat "%Y-%m-%d_%H%M%S")"
                
            # Determine if VM is in our DB
            if ($global:db.VMs.VMId -contains $vm.Id) {
                    
                #Grab our VM Config from DB
                $obj = $global:db.VMs | where-object { $_.VMId -eq $vm.Id }
                    
                if ($null -eq $obj.ReferencePoint) {
                    throw "Invalid Configuration, not ReferencePoint found";
                }

                try {

                    # Update the status of our DB item
                    $obj.LastBackup = [DateTime]::Now
                    $obj.LastStatus = "In-Progress"

                    # Create and remember backup snapshot of the VM
                    Write-Output "Creating checkpoint for $($vm.Name)"
                    $checkpoint = New-VmBackupCheckpoint -VmName $vm.Name -ConsistencyLevel CrashConsistent
                    
                    # Find all reference points for VM and use our last saved as differential
                    Write-Output "Getting reference points for $($vm.Name)"
                    $referencePoints = Get-VMReferencePoints -VMName $vm.Name

                    # Match the reference points or throw an error
                    $lastRP = $referencePoints | where-object { $_.InstanceID -eq $obj.ReferencePoint }

                    if ($null -eq $lastRP) {
                        throw "Unable to match up Reference Points, expected $($obj.ReferencePoint), got $lastRP"
                    }

                    # Exports differential backup of the machine 
                    Write-Output "Diff backup of $($vm.Name) to $vmDiffBackupPath"
                    Export-VMBackupCheckpoint -VmName $vm.Name -DestinationPath $vmDiffBackupPath -BackupCheckpoint $checkpoint -ReferencePoint $lastRP

                    # Removes backup snapshot and converts it as reference point for future incremental backups
                    Write-Output "Saving ReferencePoint"
                    $rp = Convert-VmBackupCheckpoint -BackupCheckpoint $checkpoint

                    $obj.ReferencePoint = $rp.InstanceID
                    $obj.LastStatus = "Success"
                }
                catch {
                    Write-Error "Operation Failed! => $_"
                    $obj.LastStatus = "Failed"
                }
            }
            else {
                Write-Output "VM not in DB, performing full backup"

                $obj = New-Object PSObject -Property @{
                    "VMName"         = $vm.Name; 
                    "VMId"           = $vm.Id; 
                    "FirstBackup"    = [DateTime]::Now; 
                    "LastBackup"     = [DateTime]::Now; 
                    "LastStatus"     = "In-Progress";
                    "ReferencePoint" = $null;
                }

                try {
                    # Perform full first backup
                    # Create and remember backup snapshot of the VM
                    Write-Output "Creating checkpoint for $($vm.Name)"
                    $checkpoint = New-VmBackupCheckpoint -VmName $vm.Name -ConsistencyLevel CrashConsistent
                    
                    # Exports that snapshot to dedicated folder
                    Write-Output "Performing full backup of $($vm.Name) to $vmFullBackupPath"
                    Export-VMBackupCheckpoint -VmName $vm.Name -DestinationPath $vmFullBackupPath -BackupCheckpoint $checkpoint
                        
                    # Removes backup snapshot and converts it as reference point for future incremental backups
                    Write-Output "Saving ReferencePoint"
                    $rp = Convert-VmBackupCheckpoint -BackupCheckpoint $checkpoint

                    Write-Output "Updating DB"
                    $obj.ReferencePoint = $rp.InstanceID
                    $obj.LastStatus = "Success"
                    $global:db.VMs += $obj
                    # Update / SaveDB
                    SaveDB -DBFilePath $DBFilePath -Data $global:db

                }
                catch {
                    Write-Error "Operation Failed! => $_"
                    $obj.LastStatus = "Failed"
                    $global:db.VMs += $obj
                        
                    # Update / SaveDB
                    SaveDB -DBFilePath $DBFilePath -Data $global:db
                }
            }
        }



    }

    function LoadDB {
        param (
            [Parameter(Mandatory = $true)]    
            [String] $DBFilePath
        )
    
        if (!(Test-Path $DBFilePath)) {
            throw "Unable to find database"
            exit 1;
        }
    
        try {
            $obj = (get-content -Path $DBFilePath | convertfrom-json)
        }
        catch {
            throw "Unable to load database"
        }    
        return $obj
    }
    
    function SaveDB {
        param (
            [String] $DBFilePath,
            [PSObject] $Data
        )
        
        $Data | ConvertTo-Json | Out-File -FilePath $DBFilePath
        Write-Output "Database saved...";
    }
    
    function DoInstall {
        param (
            [Parameter(Mandatory = $true)]    
            [String] $BackupFolderPath,
            
            [Parameter(Mandatory = $false)]    
            [System.Collections.Generic.List[string]] $excludeVMList
        )
    
        # Check if folder exists
        if (!(Test-Path $BackupFolderPath)) {
            $tmp = [System.IO.DirectoryInfo]::new($BackupFolderPath)
            # Check if root exists
            if (!(Test-Path $tmp.Root)) {
                throw "Invalid Path $BackupFolderPath"
                exit 1;
            }
            else {
                new-item -ItemType Directory -Path $BackupFolderPath | Out-Null
            }
        }
    
        #Validate the DB does not already exist
        if (Test-Path -Path "$BackupFolderPath\db.json")
        {
            throw "DB already exists! Please delete to create new one"
            exit 1;
        }

        # Create initial tracking DB
        $obj = new-object PSObject -Property @{
            "BackupFolderPath" = $BackupFolderPath; 
            "ExcludeVM"        = $excludeVMList;
            "VMs"              = new-object 'System.Collections.Generic.List[PSObject]';
        }
    
        $obj | convertto-json | Out-File -FilePath "$BackupFolderPath\db.json"
    
    }

}

Process {
    
    switch ($Operation) {
        "Install" {
            if ($null -ne $excludeVMList) {
                DoInstall -BackupFolderPath $DBFilePath -excludeVMList $excludeVMList
            }
            else {
                DoInstall -BackupFolderPath $DBFilePath
            }
        }
        
        "Backup" {
            # Load Database
            $global:db = LoadDB -DBFilePath $DBFilePath
            
            # Fix - Type-cast the obj in case it's empty Load Backup List if any
            if ($null -eq $global:db.VMs) {
                $global:db.VMs = new-object 'System.Collections.Generic.List[PSObject]'
            }

            # Get all VMs
            $vms = get-vm

            # Filter unwanted VMs
            # TODO figure out how to handle vms that were backed up and fall into this list
            $vms = $vms | Where-Object { $global:db.ExcludeVM -notcontains $_.Name }

            #Perform the backup
            DoFullOrDiffBackup -vms $vms
            
            # Save Database
            SaveDB -DBFilePath $DBFilePath -Data $global:db
        }

        "BackupNewOnly" {
            # Load Database
            $global:db = LoadDB -DBFilePath $DBFilePath

            # Fix - Type-cast the obj in case it's empty Load Backup List if any
            if ($null -eq $global:db.VMs) {
                $global:db.VMs = new-object 'System.Collections.Generic.List[PSObject]'
            }

            # Get all VMs
            $vms = get-vm

            # Filter unwanted VMs
            # TODO figure out how to handle vms that were backed up and fall into this list
            $vms = $vms | Where-Object { $global:db.ExcludeVM -notcontains $_.Name }

            #Filter to unbacked up VMs only & those with unsuccessful status
            $list1 = $vms | Where-Object { $gloal:db.VMs | Where-Object { $_.LastStatus -ne "Success" } }
            $list2 = $vms | where-object { ($global:db.VMs | ForEach-Object { $_.VMName }) -notcontains $_.Name }
            $vms = ($list1 + $list2)
            
            DoFullOrDiffBackup -vms $vms
        }
    }
    
    
    

}

End {
    Write-Output "Finished..."
}
# http://www.systanddeploy.com/2018/12/create-your-own-powershell.html