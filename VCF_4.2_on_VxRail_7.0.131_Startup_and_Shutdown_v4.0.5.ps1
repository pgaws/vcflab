<#
The goal of this script is twofold:
    1) Gracefully shutdown a defined VCF 4.1 on VxRail 7.0.100 vApp configuration
    2) Orderly power-on a defined VCF 4.1 on VxRail 7.0.100 vApp configuration

Usage:
.\VCF_on_VxRail_Startup_and_Shutdown_v3.1.6.ps1 -ShutdownGuest -ShutdownESXi -EnterMaintenanceMode -Confirm:$false -Verbose -Debug
.\VCF_on_VxRail_Startup_and_Shutdown_v3.1.6.ps1 -PowerOnGuest -Confirm:$false -Verbose -Debug

By: robert.hoey@dell.com
#>



[CmdletBinding(SupportsShouldProcess=$true,DefaultParameterSetName='F')]
Param(
    [Parameter(Mandatory=$true,ValueFromPipeline=$false,ParameterSetName='A')] 
    [Parameter(Mandatory=$false,ValueFromPipeline=$false,ParameterSetName='B')]   
    [Parameter(Mandatory=$false,ValueFromPipeline=$false,ParameterSetName='C')]        
    [Switch]$ShutdownGuest,

    [Parameter(Mandatory=$false,ValueFromPipeline=$false,ParameterSetName='C')] 
    [Parameter(Mandatory=$true,ValueFromPipeline=$false,ParameterSetName='E')]    
    [Switch]$ShutdownESXi,

    [Parameter(Mandatory=$false,ValueFromPipeline=$false,ParameterSetName='B')]
    [Parameter(Mandatory=$false,ValueFromPipeline=$false,ParameterSetName='C')]
    [Parameter(Mandatory=$true,ValueFromPipeline=$false,ParameterSetName='D')]
    [Parameter(Mandatory=$false,ValueFromPipeline=$false,ParameterSetName='E')]
    [Switch]$EnterMaintenanceMode,

    [Parameter(Position=0,Mandatory=$true,ValueFromPipeline=$false,ParameterSetName='F')]  
    [Switch]$PowerOnGuest,

    [Parameter(Mandatory=$false,ValueFromPipeline=$false,ParameterSetName='F')]
    [Switch]$Override
	)


########################################### Define Variables ###########################################

# Set common preference to desired value. The switch "-Confirm:$false" doesn't seem to pass to the script when
# using a GPO unlike other parameters, i.e. -Verbose, or -Debug which default to "$true". 
$ConfirmPreference='None'

# Define the variables for a 'VxRail Appliance Administration' vs a 'VCF on VxRail Appliance' lab pod
$config=@{
    's1-mgmt-vc'=@{'ip'='192.168.10.13';'user'='administrator@vsphere.local';'password'='VMw@r3!123'}
    's1-mgmt-vc.edu.local'=@{'ip'='192.168.10.13';'user'='administrator@vsphere.local';'password'='VMw@r3!123'}
    's1-wld1-vc'=@{'ip'='192.168.10.24';'user'='administrator@vsphere.local';'password'='VMw@r3!123'}
    's1-wld1-vc.edu.local'=@{'ip'='192.168.10.24';'user'='administrator@vsphere.local';'password'='VMw@r3!123'}  	
    'vcluster730-esx01.edu.local'=@{'ip'='192.168.10.51';'user'='root';'password'='VMw@r3!123'}
    'vcluster730-esx02.edu.local'=@{'ip'='192.168.10.52';'user'='root';'password'='VMw@r3!123'}
    'vcluster730-esx03.edu.local'=@{'ip'='192.168.10.53';'user'='root';'password'='VMw@r3!123'}
    'vcluster730-esx04.edu.local'=@{'ip'='192.168.10.54';'user'='root';'password'='VMw@r3!123'}
    'vcluster530-esx01.edu.local'=@{'ip'='192.168.10.61';'user'='root';'password'='VMw@r3!123'}
    'vcluster530-esx02.edu.local'=@{'ip'='192.168.10.62';'user'='root';'password'='VMw@r3!123'}
    'vcluster530-esx03.edu.local'=@{'ip'='192.168.10.63';'user'='root';'password'='VMw@r3!123'}
    'vcluster530-esx04.edu.local'=@{'ip'='192.168.10.64';'user'='root';'password'='VMw@r3!123'}
}

##################################### Check ESXi Host Readiness ###########################################

Function Get-ESXiReadiness
{
	[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High',DefaultParameterSetName='A')]
	Param(
        [Parameter(Position=0,Mandatory=$true,ParameterSetName='A')]
        [String[]]$Server
	)
	END
	{
    # Create an array to hold the result of the VM host startup
    $ready_vm_hosts=New-Object System.Collections.ArrayList
    # Loop through each VM Host and check for readiness
    foreach ($vm_host in $Server)
        {
        # Note readiness
        $status='NotReady'
        # The count is used for ping loop control
        $count=0
        # Keep testing each VM Host unitl it is ready
        Do {
            # Check in VM Host can be reached via IP
            if ((Test-Connection -ComputerName $vm_host -Quiet -Count 1) -ne $false)
                {
                Write-Verbose -Message "Able to ping VM Host '$vm_host'."
                # Since the VM Host is pingable, see if PowerCLI can connect to it.
                if (Connect-VIServer -Server $vm_host -Protocol https -User $config.($vm_host).('user') -Password $config.($vm_host).('password') -Force -ErrorAction SilentlyContinue)
                    {
                    # Check VM Host is connectable via PowerCLI
                    Write-Verbose -Message "Connected to VM Host '$vm_host'."
                    # Check checking for a conection to the VM Host
                    Do {
                        Try {$running_services=(Get-VMHostService -Server $vm_host -Refresh -ErrorAction Stop | Where-Object {$_.Running -eq $true} -ErrorAction SilentlyContinue).Key}
                        Catch {Write-Warning -Message "VM Host '$vm_host' unavailable to list VM Host services at this point in the startup process."}
                        if ($running_services.Count -gt 11)
                            {
                            Write-Verbose -Message "VM Host '$vm_host' READY."   
                            Write-Verbose -Message "VM Host has ($($running_services.Count)) services running: $($running_services -join ', ')."   
                            # Add to hash table that the VM Host is ready for PowerCLI commands
                            $ready_vm_hosts.Add($vm_host) | Out-Null
                            $status='Ready'
                            }
                        else 
                            {
                            Write-Verbose -Message "VM Host '$vm_host' not ready, services are starting."
                            Write-Debug -Message "'VM Host has ($($running_services.Count)/12) required services running: $($running_services -join ', ')."  
                            Start-Sleep -Milliseconds 1500
                            }
                        }
                    While ($running_services.Count -lt 12)
                    # Disconnect from VM Host
                    Disconnect-VIServer -Server $vm_host -Force -Confirm:$false -ErrorAction SilentlyContinue
                    }
                else {
                    # Note VM Host is not connectable via PowerCLI
                    Write-Warning -Message "Unable to Connect to VM Host '$vm_host'."
                    Start-Sleep -Seconds 2
                    }
                }
            else {
                # Note cannot ping VM Host
                ++$count
                $max_count=1000
                Write-Warning -Message "Unable to Ping to VM Host '$vm_host'. Attempt ($count/$max_count)."
                # Throttle the max number of pings attempts just in case the VM host are not powered-on
                if ($count -gt $max_count)
                    {
                    Tee-Object -InputObject "ESXi Hosts Unavailable! VCF on VxRail Startup Script Halted." -LiteralPath "C:\BGInfo\message.txt"
                    Start-Job -ScriptBlock {C:\BGInfo.\bginfo64.exe "C:\BGInfo\Not_Ready.bgi" /timer:0} | Wait-Job | Receive-Job
                    Write-Warning -Message "Exiting script. Reached maximum of '$max_count' attempts waiting for a ping response from VM host '$vm_host'."
                    Write-Output "`n${line}`n`nTo rerun this script:`n`t> Delete the PowerShell_transcript* file on the desktop`n`t> Logoff the jump server`n`t> Logon the jump server`n`n${line}`n"
                    Stop-Transcript
                    exit
                    }
                else {
                    Start-Sleep -Seconds 1
                    }
                }
            }
        While ($status -ne 'Ready')
        }
    Write-Verbose "ALL VM Hosts are READY for VM startup:`n$($ready_vm_hosts -join "`n")"
    }
}

###################################### Define a VM SHutdown Function ######################################

# Function to shut down VMs
Function Shutdown-VM
{
	[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High',DefaultParameterSetName='A')]
	Param(
        [Parameter(Position=0,Mandatory=$true,ParameterSetName='A')]
        [Parameter(Position=0,Mandatory=$true,ParameterSetName='B')]
        [Parameter(Position=0,Mandatory=$true,ParameterSetName='C')]
        [Parameter(Position=0,Mandatory=$true,ParameterSetName='D')]
        [Parameter(Position=0,Mandatory=$true,ParameterSetName='E')]
        [Parameter(Position=0,Mandatory=$true,ParameterSetName='F')]
        [String[]]$Server,

        [Parameter(Mandatory=$true,ParameterSetName='A')]
        [Parameter(Mandatory=$true,ParameterSetName='B')]
        [Parameter(Mandatory=$true,ParameterSetName='E')]
        [Parameter(Mandatory=$true,ParameterSetName='F')]
        [String[]]$Include,

        [Parameter(Mandatory=$true,ParameterSetName='B')]
        [Parameter(Mandatory=$true,ParameterSetName='D')]
        [Parameter(Mandatory=$true,ParameterSetName='E')]
        [String[]]$Exclude,

        [Parameter(Mandatory=$true,ParameterSetName='C')]
        [Parameter(Mandatory=$true,ParameterSetName='D')]
        [Parameter(Mandatory=$true,ParameterSetName='E')]
        [Parameter(Mandatory=$true,ParameterSetName='F')]
        [Switch]$IncludeUndefined
	)
	END
	{
    # Note the nodes being checked for VMs
    Write-Verbose -Message "Checking node(s) '$($Server -join ', ')'."
    # Loop through each node in the cluster
    ForEach ($node in $Server)
        {
        # Loop through each VM in the ordered shutdown list.
        if (Connect-VIServer -Server $config.($node).('ip') -ErrorAction Ignore -Protocol https -User $config.($node).('user') -Password $config.($node).('password') -Force)
            {
            Write-Verbose "Connect PowerCLI to Sever '$($config.($node).('ip'))'."
            # Use cases:
            # [Include] Only shutdown VMs specified
            # [Include + Exclude] Only shutdown VMs specifie except those that are excluded.
            # [IncludeUndefined] Shutdown all VMs since none were specified
            # [Exclude + IncludeUndefined] Shutdown all unspecified VMs except those that were excluded.
            # [Include + IncludeUndefined] Shutdown all included and unspecified VMs. The
            # benefit is that the 'Include' VMs are an ordered list that would be processed first.
            # [Include + Exclude + IncludeUndefined] Shutdown all unspecified VMs except those that were excluded. The
            # benefit is that the 'Include' VMs are an ordered list that would be processed first.

            # Get a list of all VM properties and assign to an array
            $discovered_vms=Get-VM

            # Define a .NET array for holding candidate VMs for shutdown
            $shutdown_candidate_vms=New-Object System.Collections.ArrayList

            # If no VMs are discovered, do not proceed since there is no point.
            if ($discovered_vms.Count -eq 0)
                {
                Write-Warning -Message "No VMs were found on '$node."
                }
            else {
                # If the '-IncludeUndefined' switch included, get a list of 'Undefined VMs', i.e. VMs that should be shutdown, but were not specified.
                # Below are are the only combinations allowed for the 'IncludeUndefined' switch:
                if (($PSBoundParameters.ContainsKey('Include')) -and ($PSBoundParameters.ContainsKey('Exclude')) -and ($PSBoundParameters.ContainsKey('IncludeUndefined')))
                    {
                    # This is ideal for when all VMs are to be shutdown, with a few exceptions, but includeed VMs are ordered and shutdown first, whereas the shutdown order of undefined is irrelevant.
                    $undefined=Compare-Object -ReferenceObject ($Exclude + $Include) -DifferenceObject $($discovered_vms.Name) -PassThru
                    Write-Verbose -Message "Undefined VMs after removing Exclusions and explicity Included VMs '$($undefined -join ',')'."
                    }
                elseif (($PSBoundParameters.ContainsKey('Exclude')) -and ($PSBoundParameters.ContainsKey('IncludeUndefined')))
                    {
                    # This is ideal for when all VMs are to be shutdown, with a few exceptions, and the order they are shutdown in is irrelevant.
                    $undefined=Compare-Object -ReferenceObject $Exclude -DifferenceObject $($discovered_vms.Name) -PassThru
                    Write-Verbose -Message "Undefined VMs after removing Exclusions '$($undefined -join ',')'."
                    }
                elseif (($PSBoundParameters.ContainsKey('Include')) -and ($PSBoundParameters.ContainsKey('IncludeUndefined')))
                    {
                    # This is ideal for when all VMs are to be shutdown, but includeed VMs are ordered and shutdown first, whereas the shutdown order of undefined is irrelevant.
                    $undefined=Compare-Object -ReferenceObject $Include -DifferenceObject $($discovered_vms.Name) -PassThru
                    Write-Verbose -Message "Undefined VMs after removing already included VMs '$($undefined -join ',')'."
                    }
                elseif ($PSBoundParameters.ContainsKey('IncludeUndefined')) 
                    {
                    # This is ideal for when all VMs are to be shutdown and the order they are shutdown in is irrelevant.
                    $undefined=$discovered_vms.Name
                    Write-Verbose -Message "Undefined VMs '$($undefined -join ',')'."
                    }
            
                # Message if invalid VMs are found in the 'Exclude' list
                if ($PSBoundParameters.ContainsKey('Exclude'))
                    {
                    # Loop through each VM on the 'Exclude' list.
                    foreach ($vm_name in $Exclude)
                        {
                        # Note if the VM was not matched on discovered list. This means the VM is either not of this VM Host/vCenter
                        # or is an invalid name. 
                        if ($vm_name -notin $discovered_vms.Name)
                            {
                            Write-Warning -Message "VM '$vm_name' specified in the 'Exclude' parameter was not discovered on '$node'."
                            }
                        else {
                            Write-Verbose -Message "Exclude VM '$vm_name' from the VM shutdown candidate list."
                            }
                        }
                    }
                # Where applicable, add 'Include' VMs to the Shutdown Candidate list.
                if ($PSBoundParameters.ContainsKey('Include'))
                    {
                    # Loop through
                    foreach ($vm_name in $Include)
                        {
                        if ($vm_name -in $discovered_vms.Name)
                            {
                            # If the same VM is on the 'Include' and 'Exclude' list, then exclude it.
                            if (($PSBoundParameters.ContainsKey('Exclude')) -and ($vm_name -in $Exclude))
                                {
                                Write-Warning -Message "VM '$vm_name' is on both the 'Include' and 'Exclude' list. Exclusion takes precedence."
                                }
                            else {
                                Write-Verbose -Message "Include VM '$vm_name' on the VM shutdown candidate list."
                                $shutdown_candidate_vms.Add($vm_name) | Out-Null
                                }
                            }
                        else 
                            {
                            # Warn if a VM was not found on the specified VM Host/vCenter. Could be an invalid VM name as well.
                            Write-Warning -Message "VM '$vm_name' specified in the 'Include' parameter was not discovered on '$node'."
                            }
                        }
                    }
                # Where applicable, add 'IncludeUndefined' VMs to the Shutdown Candidate list.
                if ($PSBoundParameters.ContainsKey('IncludeUndefined'))
                    {
                    # Loop through
                    foreach ($vm_name in $undefined)
                        {
                        # If the same VM is on the 'Include' and 'Exclude' list, then exclude it.
                        if (($PSBoundParameters.ContainsKey('Exclude')) -and ($vm_name -in $Exclude))
                            {
                            Write-Warning -Message "VM '$vm_name' will be excluded from the shutdown candidate list."
                            }
                        else 
                            {
                            Write-Verbose -Message "Include undefined VM '$vm_name' on the VM shutdown candidate list."
                            $shutdown_candidate_vms.Add($vm_name) | Out-Null
                            }
                        }
                    }
                # Note the VMs identified for shutdown
                if ($shutdown_candidate_vms.Count -gt 0)
                    {
                    Write-Verbose -Message "On '$node' shutdown the VM(s) discovered in the following order '$($shutdown_candidate_vms -join ', ')'."
                    }
                else {
                    Write-Verbose -Message "On '$node' no VMs were identified for shutdown."
                   }

                # Loop through all VMs designated for shutdown
                foreach ($vm_name in $shutdown_candidate_vms)
                    {
                    # Get properties for the desired VM 
                    $vm_properties=$discovered_vms | Where-Object {$_.Name -match $vm_name}
                    # Evaluate any VMs that are not powered-off
                    if (($vm_properties.PowerState) -ne 'PoweredOff')
                        {
                        # Check for the presence of VMware tools
                        if ($vm_properties.Guest.ExtensionData.ToolsStatus -eq 'toolsOk')
                            {
                            Write-Verbose "Powered-On VM '$vm_name' has VMware Tools installed."
                            Write-Verbose "Gracefully shutdown guest OS for VM '$vm_name'."
                            # Gracefuly shutdown the guest operating system
                            if ($pscmdlet.ShouldProcess("VM name '$vm_name'",'Shutdown VM guest OS'))
                                {
                                Shutdown-VMGuest -VM $vm_name -Confirm:$false -ErrorAction Ignore | Out-Null
                                }
                            }
                        else {
                            # For VMs without tools installed that are powered-on, power them off.
                            Write-Warning "VM '$vm_name' does not have VMware Tools installed."
                            Write-Warning "Because VMware Tools is not installed, VM '$vm_name' must be powered-off."
                            if ($pscmdlet.ShouldProcess("VM name '$vm_name'",'Power-Off VM (Ungraceful Shutdown)'))
                                {
                                Stop-VM -VM $vm_name -Confirm:$false -ErrorAction Ignore | Out-Null
                                }
                            }
                        # Wait until it is confirmed the VM is in a powered-off state before proceeding.
                        # Get the intial date and time
                        $start_time=Get-Date
                        # Keep checking the power state every 2 seconds and display how long been waiting for power-off.
                        if ($pscmdlet.ShouldProcess("VM name '$vm_name'",'Checking power state'))
                            {
                            Do {
                                # Get the current date and time
                                $current_time=Get-Date
                                $elapsed_seconds=($current_time - $start_time).TotalSeconds
                                Write-Verbose "Power state of '$vm_name' is 'PoweredOn', seconds elapsed '$([Math]::Round($elapsed_seconds,2))'."
                                if ($elapsed_seconds -gt 720)
                                    {
                                    Write-Warning "VM '$vm_name' is taking too long to shutdown, a Stop-VM request will be sent."
                                    Stop-VM -VM $vm_name -Confirm:$false -ErrorAction Ignore | Out-Null
                                    }
                                Start-Sleep -Seconds 5}
                            While (((Get-VM -Name $vm_name).PowerState) -ne 'PoweredOff')
                            Write-Verbose "VM name '$vm_name' is now 'PoweredOff'."
                            }
                        }
                    else {
                        Write-Warning "VM '$vm_name' is already 'Powered-Off'."
                        }
                    }
                }
            # Disconnect from the vCenter
            Write-Verbose "Disconnecting PowerCLI from Server '$($config.($node).('ip'))'."
            Disconnect-VIServer -Server $config.($node).('ip') -Force -Confirm:$false -ErrorAction Ignore
            } else {
            Write-Error "Unable to connect PowerCLI to Server '$($config.($node).('ip'))'."
            exit
            }
        }
    }
}


######################################### Loop through ESXi to Power-On VMs ############################################

Function Start-GuestVM
{
	[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Medium',DefaultParameterSetName='Default')]
	Param(
        [String[]]$Server,
        [String[]]$VM,
        [Switch]$Monitor
	)
	END
	{
    # Convert list of VMs to an ArrayList for more flexibility.
    $VMs=New-Object System.Collections.ArrayList
    $VMs.AddRange($VM)
    $VMs_found=New-Object System.Collections.ArrayList
    # Note the nodes being checked for VMs
    Write-Verbose -Message "Checking node(s) '$($Server -join ', ')' for VM(s) '$($VMs -join ', ')'."
    # Loop through each node in the cluster
    ForEach ($node in $Server)
        {
        # If a server is available on the network try to connect the PowerCli to it
        if ((Test-Connection -ComputerName $node -Quiet -Count 1) -ne $false)
            {
            Write-Verbose "Able to ping Server '$node'."
            # Test PowerCLI connection to server
            if (Connect-VIServer -Server $node -ErrorAction Ignore -Protocol https -User $config.($node).('user') -Password $config.($node).('password') -Force)
                {
                Write-Verbose "Connected PowerCLI to Server '$node'."
                # Loop through each VM to be started
                foreach ($vm_name in $VMs)
                    {
                    # Get VM details on host
                    $vms_on_server=Get-VM -Server $node
                    # Verify VM exists on the current VM Host or vCenter
                    if ($vm_name -in $vms_on_server.Name)
                        {
                        # Make a note this VM has been found.
                        $VMs_found.Add($vm_name) | Out-Null
                        # If the VM is found on the VM Host/vCenter check if it is already powered-on.
                        Write-Verbose -Message "VM '$vm_name' hosted on Server '$node'."
                        if (($vms_on_server | Where-Object {$_.Name -eq $vm_name}).PowerState -ne 'PoweredOn')
                            {
                            Write-Verbose -Message "VM '$vm_name' is 'PoweredOff' and will be 'PoweredOn'."
                            # Power-On the desired VM
                            if ($pscmdlet.ShouldProcess("VM name '$vm_name'",'Power-On'))
                                {
                                # Start the VM
                                $vm_startup_status=Start-VM -VM $vm_name -ErrorAction Ignore
                                if ($vm_startup_status.PowerState -eq 'PoweredOn')
                                    {
                                    Write-Verbose -Message "Powered-On VM '$vm_name'."
                                    }
                                # Set ping related values
                                $timeout=$false 
                                $ping_status=$false
                                $ping_count=0
                                $ping_max=10
                                # The section below is only for VMs where the startup should be monitored until the VM is pingable
                                if ($Monitor -eq $true)
                                    {
                                    Write-Verbose -Message "VM '$vm_name' requires startup monitoring."
                                    # Get the start date and time
                                    $start_time=Get-Date
                                    # Continually check to see if the VMware Tools acquired the VM's IP address
                                    Do {
                                        # Get the VM's properties
                                        $vm_properties=Get-VM -Server $node -Name $vm_name -ErrorAction SilentlyContinue
                                        $vm_ip=$vm_properties.ExtensionData.Guest.IpAddress
                                        $vm_notes=$vm_properties.Notes
                                        # See if VMware Tools has discovered the VM's IP address 
                                        if ($vm_ip -match '\d+.\d+.\d+.\d+')
                                            {
                                            Write-Verbose -Message "VMware Tools discovered IP address '$vm_ip' for VM '$vm_name'."
                                            # Now that the VM has an IP address, check to see if it is pingable
                                            Do {
                                                # Ping the VM. 
                                                if (($ping_status=Test-Connection -ComputerName $vm_ip -Quiet -Count 1) -eq $true)
                                                    {
                                                    Write-Verbose -Message "Able to ping VM '$vm_name' at '$vm_ip'."
                                                    # Note the time it took the VM to become pingable
                                                    $elapsed_seconds=($(Get-Date) - $start_time).TotalSeconds
                                                    Write-Verbose -Message "Seconds from VM '$vm_name' power-on to ping '$([Math]::Round($elapsed_seconds,2))'."
                                                    # Automaically detect if the VM is a vCenter, in which case monitor for PowerCLI connection availability.
                                                    if ($vm_notes -eq 'VMware vCenter Server Appliance')
                                                        {
                                                        Write-Verbose -Message "Detected a vCenter, testing vCenter VM '$vm_name' for PowerCLI connectivity."
                                                        Do {
                                                            # Since the vCenter is pingable, see if PowerCLI can connect to it.
                                                            if ($session=Connect-VIServer -Server $vm_ip -Protocol https -User $config.($vm_name).('user') -Password $config.($vm_name).('password') -Force -ErrorAction SilentlyContinue)
                                                                {
                                                                # Check VM Host is connectable via PowerCLI
                                                                Write-Verbose -Message "Connected PowerCLI to vCenter '$vm_ip'."
                                                                # Note the time it took POwerCLI to become accessible
                                                                $elapsed_seconds=($(Get-Date) - $start_time).TotalSeconds
                                                                Write-Verbose -Message "Seconds from VM '$vm_name' power-on to PowerCLI access '$([Math]::Round($elapsed_seconds,2))'."
                                                                # Check checking for a conection to the VM Host
                                                                if ($out=(Get-VM -Server $vm_ip).Name)
                                                                    {
                                                                    Write-Verbose -Message "vCenter '$vm_name' is Ready for VM startup. Available VMs:`n$($out -join "`n")"
                                                                    Write-Verbose "Disconnecting PowerCLI from Server '$vm_ip' ($vm_name)."
                                                                    Disconnect-VIServer -Server $vm_ip -Force -Confirm:$false -ErrorAction Ignore
                                                                    }
                                                                }
                                                            else {
                                                                # Note VM Host is not connectable via PowerCLI
                                                                Write-Verbose -Message "Waiting for vCenter '$vm_name' PowerCLI connection to become available."
                                                                Start-Sleep -Seconds 3
                                                                }
                                                            }
                                                        While ($session.Name -notmatch '.+')
                                                        }
                                                    }
                                                else {
                                                    Write-Verbose -Message "Unable to ping VM '$vm_name' at '$vm_ip'."
                                                    ++$ping_count
                                                    # If the maximum ping count has been exceeded, stop trying to ping the VM and report it as an issue.
                                                    if ($ping_count -gt $ping_max)
                                                        {
                                                        Write-Warning -Message "Failed '$ping_count' ping attempts which exceeded the maximum value of '$ping_max'."
                                                        Break
                                                        }
                                                    else {
                                                        Start-Sleep -Seconds 3
                                                        }
                                                    }
                                                }
                                            # Keep looping if cannot ping the VM's discovered IP address
                                            While ($ping_status -eq $false)
                                            }
                                        else {
                                            Write-Verbose -Message "Waiting for VMware Tools to discover IP address for VM '$vm_name'."
                                            $elapsed_seconds=($(Get-Date) - $start_time).TotalSeconds
                                            Write-Verbose -Message "Seconds elapsed since VM '$vm_name' power-on '$([Math]::Round($elapsed_seconds,2))'."
                                            Start-Sleep -Seconds 3
                                            # Discontinue monitoring if if takes more than 360 seconds for the VM to acquire an IP address.
                                            if ((($(Get-Date) - $start_time).TotalSeconds) -gt 360) 
                                                {
                                                Write-Warning -Message "Monitoring of VM '$vm_name' timed-out after VM failed to aquire an IP address after 6 minutes."
                                                $timeout=$true
                                                }
                                            }
                                        }
                                    # Keep looping if the VM has yet to acquire and IP address and the VM monitoring has yet to timeout
                                    While ((($vm_ip -notmatch '\d+.\d+.\d+.\d+') -and ($timeout -eq $false)) -or ($ping_count -gt $ping_max)) 
                                    }
                                }
                            }
                        else {
                            Write-Warning -Message "VM '$vm_name' is already 'PoweredOn'."
                            }
                        }
                    else {
                        Write-Warning -Message "VM '$vm_name' not hosted on Server '$node'."
                        }
                    }
                # Once a VM has been found and processed there is no need to check for the VM again on other nodes, so remove from the list of VMs to process.
                if ($VMs.Count -gt 0)
                    {
                    if ($VMs_found.Count -gt 0)
                        {
                        Write-Debug -Message "Removing VM(s) '$($VMs_found -join ', ')' from VM ArrayList '$($VMs -join ', ')'."
                        $VMs_found | ForEach-Object {$VMs.Remove($_)}
                        $VMs_found.Clear()
                        Write-Debug -Message "Updated VM ArrayList contains '$($VMs -join ', ')'."
                        }
                    # Disconnect from the Server
                    Write-Verbose "Disconnecting PowerCLI from Server '$node'."
                    Disconnect-VIServer -Server $node -Force -Confirm:$false -ErrorAction Ignore
                    }
                if ($VMs.Count -eq 0) 
                    {
                    # Stop looping through nodes since all VMs have already been processed.
                    Break
                    }
                }
            else {
                Write-Error "Unable to connect PowerCLI to Server '$node'."
                }
            }
        else {
            Write-Warning -Message "Unable to ping Server '$node'."
            }
        }
    }
}

####################################### Startup ESXi ############################################

Function Exit-MaintenanceModeESXi
{
	[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High',DefaultParameterSetName='Default')]
	Param(
        [String[]]$Server
    )
	END
	{
    # Loop through each VM Host 
    foreach ($vm_host in $Server)
        {
        # If a node is available on the network try to connect the PowerCli to it
        if ((Test-Connection -ComputerName $vm_host -Quiet -Count 1) -ne $false)
            {
            Write-Verbose "Able to ping VM Host '$vm_host'."
            # If a VM Host is available on the network try to connect the PowerCli to it
            if (Connect-VIServer -Server $vm_host -WarningAction SilentlyContinue -Protocol https -User 'root' -Password $config.($vm_host).('password') -Force)
                {
                Write-Verbose "Connected PowerCLI to VM Host '$vm_host'."
                # Exit Maintenance mode
                if ((Get-VMHost -Server $vm_host).ConnectionState -eq 'Maintenance')
                    {
                    Write-Verbose "VM Host '$vm_host' has a ConnectionState of 'Maintenance' mode."
                    Write-Verbose "Setting VM Host '$vm_host' to a ConnectionState of 'Connected'."   
                    if (Set-VMHost -Server $vm_host -State "Connected")
                        {
                        # Keep checking the connection state every few seconds and display how long been waiting.
                        if ($pscmdlet.ShouldProcess("VM Host '$vm_host'",'Checking ConnectionState'))
                            {
                            # Get the initial date and time
                            $start_time=Get-Date
                            Do {
                                # Get the VM Host connection state
                                $connection_state=(Get-VMHost -Server $vm_host).ConnectionState
                                # Get the current date and time
                                $current_time=Get-Date
                                $elapsed_seconds=($current_time - $start_time).TotalSeconds
                                Write-Verbose -Message "Waiting for VM Host '$vm_host' to exit maintenance mode, ConnectionState '$connection_state', seconds elapsed '$([Math]::Round($elapsed_seconds,2))'."
                                Start-Sleep -Seconds 4
                                }
                            While ($((Get-VMHost -Server $vm_host).ConnectionState) -ne 'Connected')   
                            Write-Verbose "VM Host '$vm_host' ConnectionState '$((Get-VMHost -Server $vm_host).ConnectionState)'."            
                            }
                        }
                    else {
                        Throw "VM Host '$vm_host' is unable to exit Maintenace Mode."
                        }
                    }
                else {
                    Write-Warning -Message "VM Host '$vm_host' ConnectionState '$((Get-VMHost -Server $vm_host).ConnectionState)' not 'Maintenance'."
                    }
    ########################
                if ((Get-VMHost -Server $vm_host).ConnectionState -eq 'Connected')
                    {
                    # Check if the the Value is already set to 0.
                    if ((Get-VMHost -Server $vm_host | Get-AdvancedSetting -Name 'VSAN.IgnoreClusterMemberListUpdates').Value -eq 0)
                        {
                        Write-Verbose -Message "'VSAN.IgnoreClusterMemberListUpdates' already set to '0' (Disabled) for VMHost '$vm_host'."
                        }
                    else {
                        # Update ESXi vSAN host membership value to '0' prior to startup
                        Write-Debug -Message "Setting 'VSAN.IgnoreClusterMemberListUpdates' to '0' (Disabled) for VMHost '$vm_host'."
                        Get-VMHost -Server $vm_host | Get-AdvancedSetting -Name 'VSAN.IgnoreClusterMemberListUpdates' | Set-AdvancedSetting -Value 0 -Confirm:$false -OutVariable output | Out-Null
                        # Verify the setting is now '0' (Disabled). 
                        if ($output.Value -eq 0)
                            {
                            Write-Debug -Message "VMHost '$vm_host' advanced setting 'VSAN.IgnoreClusterMemberListUpdates' set to Disabled (0)."
                            }
                        else {
                            Write-Warning -Message "Expecting '0', VMHost '$vm_host' advanced setting 'VSAN.IgnoreClusterMemberListUpdates' set to Disabled (0)'."
                            }
                        }
                    }
    ##########################
                # Disconnect from the VM Host
                Write-Verbose "Disconnecting PowerCLI from VM Host '$vm_host'."
                Disconnect-VIServer -Server $vm_host -Force -Confirm:$false -ErrorAction Ignore
                }
            else {
                Write-Warning "Unable to connect PowerCLI to VM Host '$vm_host'."
                }
            }
        else {
            Write-Warning "Cannot ping VM Host '$vm_host'."
            }
        }
	}
}


####################################### Shutdown ESXi ############################################


Function Shutdown-ESXi
{
	[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High',DefaultParameterSetName='Default')]
	Param(
        [String[]]$Server
    )
	END
	{
    # Loop through each VM Host 
    foreach ($vm_host in $Server)
        {
        # If a node is available on the network try to connect the PowerCli to it
        if ((Test-Connection -ComputerName $vm_host -Quiet -Count 1) -ne $false)
            {
            Write-Verbose "Able to ping VM Host '$vm_host'."
            # If a node is available on the network try to connect the PowerCli to it
            if (Connect-VIServer -Server $vm_host -WarningAction SilentlyContinue -Protocol https -User $config.($vm_host).('user') -Password $config.($vm_host).('password') -Force)
                {
                Write-Verbose "Connected PowerCLI to VM Host '$vm_host'."
                # Check to see if any VMs are power-on which would not allow a host to enter maintenence mode.
                Write-Verbose -Message "Checking for powered-on VMs."
                if ($pscmdlet.ShouldProcess("VM Host '$vm_host'",'Checking for powered-on VMs'))
                    {
                    # Stop the script if any powered-on VMs are detected.
                    if ('PoweredOn' -in ((Get-VM -Server $vm_host).PowerState))
                        {
                        $powered_on_vms=(Get-VM -Server $vm_host | Where-Object {$_.PowerState -eq 'PoweredOn'}).Name
                        Throw "Cannot continue, VMs '$($powered_on_vms -join ',')' powered-on for VM Host '$vm_host'. All VMs must be off prior to entering maintenance mode."
                        }
                    elseif ((Get-VMHost -Server $vm_host).ConnectionState -ne 'Maintenance')
                        {
                        Throw "VM Host '$vm_host' must in Maintenance Mode in order to be shutdown."
                        }
                    else {
                        Write-Verbose -Message "VM Host '$vm_host' will be shutdown since it's in Maintenance Mode with no Powered-On VMs."
                        }
                    }
                # Shutdown the node now that it is maintenace mode.
                if ((Get-VMHost -Server $vm_host).ConnectionState -eq 'Maintenance')
                    {
                    Write-Verbose -Message "Shutdown VM Host '$vm_host'."
                    if (Stop-VMHost -Server $vm_host -Force -Confirm:$False)
                        {
                        Write-Verbose -Message "Shutting down VM Host '$vm_host'."
                        }
                    else {
                        Throw "Failed to Shutdown VM Host '$vm_host'."
                        }
                    }
                # Disconnect from the node
                Write-Verbose "Disconnecting PowerCLI from VM Host '$vm_host'."
                Disconnect-VIServer -Server $vm_host -Force -Confirm:$false -ErrorAction Ignore
                }
            else {
                Write-Warning "Unable to connect PowerCLI to VM Host '$vm_host'."
                }
            }
        else {
            Write-Warning "Cannot ping VM Host '$vm_host'."
            }      
        }  
	}
}


####################################### Shutdown ESXi ############################################


Function Enter-MaintenanceModeESXi
{
	[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High',DefaultParameterSetName='Default')]
	Param(
        [String[]]$Server
    )
	END
	{
    # Loop through each VM Host 
    foreach ($vm_host in $Server)
        {
        # If a node is available on the network try to connect the PowerCli to it
        if ((Test-Connection -ComputerName $vm_host -Quiet -Count 1) -ne $false)
            {
            Write-Verbose "Able to ping VM Host '$vm_host'."
            # If a node is available on the network try to connect the PowerCli to it
            if (Connect-VIServer -Server $vm_host -WarningAction SilentlyContinue -Protocol https -User $config.($vm_host).('user') -Password $config.($vm_host).('password') -Force)
                {
                Write-Verbose "Connected PowerCLI to VM Host '$vm_host'."
                # Check to see if any VMs are power-on which would not allow a host to enter maintenence mode.
                Write-Verbose -Message "Checking for powered-on VMs."
                if ($pscmdlet.ShouldProcess("VM Host '$vm_host'",'Checking for powered-on VMs'))
                    {
                    # Stop the script if any powered-on VMs are detected.
                    if ('PoweredOn' -in ((Get-VM -Server $vm_host).PowerState))
                        {
                        $powered_on_vms=(Get-VM -Server $vm_host | Where-Object {$_.PowerState -eq 'PoweredOn'}).Name
                        Throw "Cannot continue, VMs '$($powered_on_vms -join ',')' powered-on for VM Host '$vm_host'. All VMs must be off prior to entering maintenance mode."
                        }
                    }
########################
                        # Update ESXi vSAN host membership value to '1' prior to shutdown
                        Write-Debug -Message "For VMHost '$vm_host', set 'VSAN.IgnoreClusterMemberListUpdates' to '1' (Enable)."
                        Get-VMHost -Server $vm_host | Get-AdvancedSetting -Name 'VSAN.IgnoreClusterMemberListUpdates' | Set-AdvancedSetting -Value 1 -Confirm:$false -OutVariable output | Out-Null
                        # Verify the setting is now '1' (Enabled). 
                        if ($output.Value -eq 1)
                            {
                            Write-Debug -Message "VMHost '$vm_host' advanced setting 'VSAN.IgnoreClusterMemberListUpdates' set to Enabled (1)."
                            }
                        else {
                            Write-Warning -Message "Expecting '1', VMHost '$vm_host' advanced setting 'VSAN.IgnoreClusterMemberListUpdates' set to Enabled (1)."
                            }
##########################
                Write-Verbose "VM Host '$vm_host' has a ConnectState of '$((Get-VMHost -Server $vm_host).ConnectionState)'."
                Write-Debug "Setting node '$vm_host' to a ConnectState of 'Maintenance', vSAN to 'NoDataMigration'."
                # Keep checking the connection state every few seconds and display how long been waiting.
                if ($pscmdlet.ShouldProcess("VM Host '$vm_host'",'Set ConnectionState to Maintenance with no vSAN data migration'))
                    {
                    if (((Get-VMHost -Server $vm_host).ConnectionState) -ne 'Maintenance')
                        {
                        Write-Verbose -Message "VM Host '$vm_host' needs to be set to 'Maintenance'."
                        if (Set-VMHost -Server $vm_host -State "Maintenance" -VsanDataMigrationMode NoDataMigration)
                            {
                            # Get the initial date and time
                            $start_time=Get-Date
                            # Keep checking the connection state every few seconds and display how long been waiting.
                            Do {
                                # Get the node connection state
                                $connection_state=(Get-VMHost -Server $vm_host).ConnectionState
                                # Get the current date and time
                                $current_time=Get-Date
                                $elapsed_seconds=($current_time - $start_time).TotalSeconds
                                Write-Verbose -Message "Waiting for '$([Math]::Round($elapsed_seconds,2))' seconds for VM Host '$vm_host' to enter maintenance mode."
                                Start-Sleep -Seconds 5}
                            While ($connection_state -ne 'Maintenance')
                            Write-Verbose "VM Host '$vm_host' ConnectionState '$((Get-VMHost -Server $vm_host).ConnectionState)'."  
                            }
                        else
                            {
                            Throw "VM Host '$vm_host' unable to enter Maintenance Mode."
                            }
                        }
                    else {
                        Write-Warning "VM Host '$vm_host' ConnectionState is already set to 'Maintenance'."
                        }
                    }
                # Disconnect from the node
                Write-Verbose "Disconnecting PowerCLI from VM Host '$vm_host'."
                Disconnect-VIServer -Server $vm_host -Force -Confirm:$false -ErrorAction Ignore
                }
            else {
                Write-Warning "Unable to connect PowerCLI to VM Host '$vm_host'."
                }
            }
        else {
            Write-Warning "Cannot ping VM Host '$vm_host'."
            }   
        }     
	}
}


####################################### Disable vCLS, HA, and DRS  ########################################

Function Disable-vCLSDRSHA 
{
	[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High',DefaultParameterSetName='Default')]
	Param(
        [String]$Server,
        [String]$Cluster
    )
	END
	{
	# Loop through each VM in the ordered shutdown list.
	if ($session=Connect-VIServer -Server $config.($Server).('ip') -ErrorAction Ignore -Protocol https -User $config.($Server).('user') -Password $config.($Server).('password') -Force)
		{
        Write-Verbose "Connect PowerCLI to vCenter '$($config.($Server).('ip'))'."
        # Disable HA and DRS for the cluster
        Write-Verbose -Message "Disabling DRS and HA for vCenter '$Server' cluster '$Cluster'."
        Get-Cluster -Server $config.($Server).('ip') -Name $Cluster | Set-Cluster -Server $config.($Server).('ip') -HAEnabled:$false -DrsEnabled:$false -Confirm:$false | Out-Null
        # Loop to ensure DrsEnabled and HaEnabled are set to false.
        'HaEnabled','DrsEnabled' | ForEach-Object {
            Do {
                # Sleep for a few seconds, then try again
                Start-Sleep -Seconds 1
                Write-Verbose -Message "Checking for '$_' to be set to 'false'."
                # Verify DRS and HA are disabled
                $cluster_settings=Get-Cluster -Server $config.($Server).('ip') -Name $Cluster
                Write-Debug -Message "$_ is set to '$($cluster_settings.$_)'."
                }
            While ($cluster_settings.$_ -ne $false)   
            }
        Start-Sleep -Seconds 20
        
        # Get the Domain Id of the cluster i.e. just the 'c10' portion of 'ClusterComputeResource-domain-c10'
        $cluster_domain_id=((Get-Cluster -Server $config.($Server).('ip')).Id -split '-')[-1]
        Write-Debug -Message "The Domain ID for cluster '$Cluster' is '$cluster_domain_id'."
        # Disable vCLS VMs on the cluster.
        Write-Debug -Message "The VMware Cluster Service (vCLS) is being disable. The 'vCLS (1)', 'vCLS (2)', and 'vCLS (3)' VMs will be powered-off and deleted."
        # This operation will power-off and delete the 3 vCLS VMs for a given cluster). The value for the setting should move from 'true' to 'false'
        Get-AdvancedSetting -Server $config.($Server).('ip') -Entity $session -Name "config.vcls.clusters.domain-${cluster_domain_id}.enabled" | Set-AdvancedSetting -Value $false -Confirm:$false | Out-Null
        # While the vCLS value can quickly be changed from true to false it takes time for the vCLA VMs to be powered-off and deleted.
        # Verify the setting is now 'false'
        $vcls_enabled=(Get-AdvancedSetting -Server $config.($Server).('ip') -Entity $session -Name "config.vcls.clusters.domain-${cluster_domain_id}.enabled").Value
        Write-Debug -Message "The vCLS Advanced Setting 'config.vcls.clusters.domain-${cluster_domain_id}.enabled' is set to '$vcls_enabled'."

        #  Verify the 3 vCLS VMs have been powered-off and deleted (Loop)
        Do {
            # Sleep for a few seconds, then try again
            Start-Sleep -Seconds 5
            # Count the number of vCLS VMs in the vCLS folder
            $vcls_remaining=($(Get-Folder -Server $config.($Server).('ip') -Name vCLS).ExtensionData.ChildEntity).Count
            Write-Verbose -Message "vCenter '$Server' cluster '$Cluster' has '$vcls_remaining' vCLS VMs remaining..."
            }
        While (($(Get-Folder -Server $config.($Server).('ip') -Name vCLS).ExtensionData.ChildEntity).Count -ne 0)

		# Disconnect from the vCenter
		Write-Verbose "Disconnecting PowerCLI from vCenter '$($config.($Server).('ip'))'."
		Disconnect-VIServer -Server $config.($Server).('ip') -Force -Confirm:$false -ErrorAction Ignore
		} else {
        Write-Error "Unable to connect PowerCLI to vCenter '$($config.($Server).('ip'))'."
        exit
        }
    }
}


####################################### Enable vCLS, deploy vCLS VMs  ########################################

Function Enable-vCLS
{
	[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High',DefaultParameterSetName='Default')]
	Param(
        [String]$Server,
        [String]$Cluster
    )
	END
	{
	# Loop through each VM in the ordered shutdown list.
	if ($session=Connect-VIServer -Server $config.($Server).('ip') -ErrorAction Ignore -Protocol https -User $config.($Server).('user') -Password $config.($Server).('password') -Force)
		{
        Write-Verbose "Connect PowerCLI to vCenter '$($config.($Server).('ip'))'."

        # Get the Domain Id of the cluster i.e. just the 'c10' portion of 'ClusterComputeResource-domain-c10'
        $cluster_domain_id=((Get-Cluster -Server $config.($Server).('ip')).Id -split '-')[-1]
        Write-Debug -Message "The Domain ID for cluster '$Cluster' is '$cluster_domain_id'."
        # This operation wil power-off and delete the 3 vCLS VMs for a given cluster). The value for the setting should move from 'true' to 'false'
        $advanced_setting=Get-AdvancedSetting -Server $config.($Server).('ip') -Entity $session -Name "config.vcls.clusters.domain-${cluster_domain_id}.enabled"
        if ($advanced_setting.Value -eq $false)
            {
            # Enable vCLS VMs on the cluster.
            Write-Verbose -Message "The 'VMware Cluster Service (vCLS)' Advanced Setting is '$false' and will be set to '$true'."
            Write-Verbose -Message "The 'vCLS (1)', 'vCLS (2)', and 'vCLS (3)' VMs will be deployed and powered-on."
            $advanced_setting | Set-AdvancedSetting -Value $true -Confirm:$false | Out-Null
            # While the vCLS value can quickly be changed from true to false it takes time for the vCLA VMs to be powered-off and deleted.
            # Verify the setting is now 'false'
            $vcls_enabled=(Get-AdvancedSetting -Server $config.($Server).('ip') -Entity $session -Name "config.vcls.clusters.domain-${cluster_domain_id}.enabled").Value
            Write-Debug -Message "The vCLS Advanced Setting 'config.vcls.clusters.domain-${cluster_domain_id}.enabled' is set to '$vcls_enabled'."
            }
        else {
            Write-Verbose -Message "The 'VMware Cluster Service (vCLS)' Advanced Setting is already set to '$true'."
            }
		# Disconnect from the vCenter
		Write-Verbose "Disconnecting PowerCLI from vCenter '$($config.($Server).('ip'))'."
		Disconnect-VIServer -Server $config.($Server).('ip') -Force -Confirm:$false -ErrorAction Ignore
		} else {
        Write-Error "Unable to connect PowerCLI to vCenter '$($config.($Server).('ip'))'."
        exit
        }
    }
}


####################################### Monitor vCLS Deployment  ########################################

Function Watch-vCLSDeployment 
{
	[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High',DefaultParameterSetName='Default')]
	Param(
        [String]$Server,
        [String]$Cluster
    )
	END
	{
	# Loop through each VM in the ordered shutdown list.
	if (Connect-VIServer -Server $config.($Server).('ip') -ErrorAction Ignore -Protocol https -User $config.($Server).('user') -Password $config.($Server).('password') -Force)
		{
        Write-Verbose "Connect PowerCLI to vCenter '$($config.($Server).('ip'))'."
        #  Verify the 3 vCLS VMs have been deoloyed and powered-on
        Write-Verbose -Message "Monitoring vCLS deployment and power-on for cluster '$Cluster'."
        Do {
            # Sleep for a few seconds, then try again
            Start-Sleep -Seconds 5
            # Count the number of vCLS VMs in the vCLS folder
            $vcls_status=Get-VM -Server $config.($Server).('ip') | Where-Object {$_.Name -match 'vCLS'}
            
            Write-Verbose -Message "Cluster '$Cluster' has '$($vcls_status.Count)' vCLS VMs deployed, '$(($vcls_status.PowerState | Where-Object {$_ -eq 'PoweredOn'}).Count)' powered-on."
            }
        While ((Get-VM -Server $config.($Server).('ip') | Where-Object {($_.Name -match 'vCLS') -and ($_.PowerState -eq 'PoweredOn')}).Count -ne 3)               

		# Disconnect from the vCenter
		Write-Verbose "Disconnecting PowerCLI from vCenter '$($config.($Server).('ip'))'."
		Disconnect-VIServer -Server $config.($Server).('ip') -Force -Confirm:$false -ErrorAction Ignore
		} else {
        Write-Error "Unable to connect PowerCLI to vCenter '$($config.($Server).('ip'))'."
        exit
        }
    }
}

####################################### Enable DRS and HA for Cluster  ########################################

Function Enable-DRSandHA 
{
	[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High',DefaultParameterSetName='Default')]
	Param(
        [String]$Server,
        [String]$Cluster
    )
	END
	{
	# Loop through each VM in the ordered shutdown list.
	if (Connect-VIServer -Server $config.($Server).('ip') -ErrorAction Ignore -Protocol https -User $config.($Server).('user') -Password $config.($Server).('password') -Force)
		{
        Write-Verbose "Connect PowerCLI to vCenter '$($config.($Server).('ip'))'."
        # Get the current value for DRS and HA settings
        $cluster_status=Get-Cluster -Server $config.($Server).('ip') -Name $Cluster
        # Loop through each setting and evaluate if it needs to be set to True (On)
        foreach ($setting in ('DrsEnabled','HAEnabled'))
            {
            # Determine if DRS and HA are already enabled, if not then set them
            if ($cluster_status.$setting -eq $true)
                {
                Write-Warning -Message "'$setting' already Enabled for vCenter '$Server' cluster '$Cluster'."
                }
            else {
                # Create a Splat, i.e. a hash table of parmeters and values to pass to a CmdLet for ease of setting the necessary parameters
                $cmdlet_arguments=@{
                    'Server'=$config.($Server).('ip');
                    $setting=$true;
                    'Confirm'=$false;
                    'ErrorAction'='SilentlyContinue';
                    }
                # Enable HA and DRS for the cluster
                Write-Verbose -Message "Setting '$setting' to '$true' for vCenter '$Server' cluster '$Cluster'."
                #if (Get-Cluster -Server $config.($Server).('ip') -Name $Cluster | Set-Cluster -Server $config.($Server).('ip') -HAEnabled:$true -DrsEnabled:$true -Confirm:$false)
                if (Get-Cluster -Server $config.($Server).('ip') -Name $Cluster | Set-Cluster @cmdlet_arguments)
                    {
                    # Loop to ensure DrsEnabled or HaEnabled is set to true.
                    Do {
                        # Sleep for a few seconds, then try again
                        Start-Sleep -Seconds 1
                        Write-Verbose -Message "Checking '$setting' is set to '$true'."
                        # Verify DRS or HA is enabled
                        $cluster_settings=Get-Cluster -Server $config.($Server).('ip') -Name $Cluster
                        Write-Debug -Message "'$setting' is set to '$($cluster_settings.$setting)'."
                        }
                    While ($cluster_settings.$setting -ne $true)    
                    }
                else {
                    Write-Warning -Message "Failed to set '$setting' to '$true' on cluster '$Cluster'."
                    }  
                }
            }
		# Disconnect from the vCenter
		Write-Verbose "Disconnecting PowerCLI from vCenter '$($config.($Server).('ip'))'."
		Disconnect-VIServer -Server $config.($Server).('ip') -Force -Confirm:$false -ErrorAction Ignore
		} else {
        Write-Error "Unable to connect PowerCLI to vCenter '$($config.($Server).('ip'))'."
        exit
        }
    }
}

####################################### Move Mgmt vCenter to Node 1  ########################################

Function Move-MgmtvCenterToFirstNode 
{
	[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High',DefaultParameterSetName='Default')]
	Param(
        [String]$Server,
        [String]$VMHost,
        [String]$VM
    )
	END
	{
	# Loop through each VM in the ordered shutdown list.
	if (Connect-VIServer -Server $config.($Server).('ip') -ErrorAction Ignore -Protocol https -User $config.($Server).('user') -Password $config.($Server).('password') -Force)
		{
        Write-Verbose "Connect PowerCLI to vCenter '$($config.($Server).('ip'))'."

        # Get the VM Host the Managment vCenter VM reside upon.  
        $current_vmhost=(Get-VM -Server $config.($Server).('ip') -Name $VM).VMHost.Name
        Write-Verbose -Message "The Management vCenter '$VM' is on VM Host '$current_vmhost'."
        # Move vCenter VM to Node 1 if it is not already there
        if ($current_vmhost -ne $VMHost)
            {
            Write-Verbose -Message "Moving Management vCenter '$VM' to VM Host '$VMHost'."
            Move-VM -Server $config.($Server).('ip') -VM $VM -Destination $VMHost -Confirm:$false
            }
        else {
            Write-Verbose -Message "Management vCenter '$VM' is already on VM Host '$VMHost'."
            }
            
		# Disconnect from the vCenter
		Write-Verbose "Disconnecting PowerCLI from vCenter '$($config.($Server).('ip'))'."
		Disconnect-VIServer -Server $config.($Server).('ip') -Force -Confirm:$false -ErrorAction Ignore
		} else {
        Write-Error "Unable to connect PowerCLI to vCenter '$($config.($Server).('ip'))'."
        exit
        }
    }
}


####################################### Clear Triggered Alarm ##############################################

Function Clear-TriggeredAlarm 
{
	[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High',DefaultParameterSetName='Default')]
	Param(
        [String]$Server
    )
	END
	{
	# Loop through each VM in the ordered shutdown list.
	if (Connect-VIServer -Server $config.($Server).('ip') -ErrorAction Ignore -Protocol https -User $config.($Server).('user') -Password $config.($Server).('password') -Force)
		{
        Write-Verbose "Connect PowerCLI to vCenter '$($config.($Server).('ip'))'."
        # Clear triggered alarm by toggling it from False to True. 
        # This alarm is likly created by create and deleletion of the vCLS folder as part of the vAPp capture process
        Write-Verbose -Message "Reset then Disable alarm 'vSphere Health detected new issues in your environment' for vCenter '$Server'."
        Get-AlarmDefinition -Name "vSphere Health detected new issues in your environment" | Set-AlarmDefinition -Enabled:$false | Out-Null
        Get-AlarmDefinition -Name "vSphere Health detected new issues in your environment" | Set-AlarmDefinition -Enabled:$true | Out-Null
        Get-AlarmDefinition -Name "vSphere Health detected new issues in your environment" | Set-AlarmDefinition -Enabled:$false | Out-Null
		# Disconnect from the vCenter
		Write-Verbose "Disconnecting PowerCLI from vCenter '$($config.($Server).('ip'))'."
		Disconnect-VIServer -Server $config.($Server).('ip') -Force -Confirm:$false -ErrorAction Ignore
		} else {
        Write-Error "Unable to connect PowerCLI to vCenter '$($config.($Server).('ip'))'."
        exit
        }
    }
}

####################################### Call up Workflows ########################################


# Power-On VCF releated VMs in an orderly fashion.
# Only run the script if no transcript is present or the -Override switch is used.
if ((((Test-Path -Path "${HOME}\Desktop\VCF_On_VxRail_vApp_Startup.txt") -ne $true) -and ($PowerOnGuest -eq $true)) -or 
    (($PowerOnGuest -eq $true) -and ($Override -eq $true)))
    {
    # BGInfo message
    $bginfo_message=@(
        'VCF on VxRail vApp Starting... Please Wait!',
        '    Task [1/8]: VM Hosts PowerCLI ready',
        '    Task [2/8]: VM Hosts exited maintenance mode',
        '    Task [3/8]: Management vCenter PowerCLI ready',
        '    Task [4/8]: Tenant vCenter PowerCLI ready',
        '    Task [5/8]: Guest VMs started',
        '    Task [6/8]: Enabled vCLS',
        '    Task [7/8]: Enabled DRS and HA',
        '    Task [8/8]: Cleared HA alarms',
        'VCF 4.2 on VxRail 7.0.131 Ready!',
        '[vApp v0.02, April 23, 2021]'
    )
    # Start a transcript
    Start-Transcript -Force -IncludeInvocationHeader -Path VCF_On_VxRail_vApp_Startup.txt
    $DebugPreference='Continue'
    $VerbosePreference='Continue'
    Write-Verbose "DebugPreference=${DebugPreference}, VerbosePreference=${VerbosePreference}, ConfirmPreference=${ConfirmPreference}."
    # Update BGInfo Message and Tee so it can be logged
    Tee-Object -InputObject "$($bginfo_message[0] -join ""`n"")" -LiteralPath "C:\BGInfo\message.txt" -Verbose
    Start-Job -ScriptBlock {C:\BGInfo.\bginfo64.exe "C:\BGInfo\Not_Ready.bgi" /timer:0} | Wait-Job | Receive-Job
    # Get the start time
    $prestartup_time=Get-Date
    # Turn off the VMware CEIP nag message
    Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false | Out-Null
    # Make sure all ESXi host are ready to receive PowerCLI commands 
    Get-ESXiReadiness -Server ('vcluster730-esx01.edu.local',
        'vcluster730-esx02.edu.local',
        'vcluster730-esx03.edu.local',
        'vcluster730-esx04.edu.local',
        'vcluster530-esx01.edu.local',
        'vcluster530-esx02.edu.local',
        'vcluster530-esx03.edu.local',
        'vcluster530-esx04.edu.local')
    # Update BGInfo Message and Tee so it can be logged
    Tee-Object -InputObject "$($bginfo_message[0..1] -join ""`n"")" -LiteralPath "C:\BGInfo\message.txt"
    Start-Job -ScriptBlock {C:\BGInfo.\bginfo64.exe "C:\BGInfo\Not_Ready.bgi" /timer:0} | Wait-Job | Receive-Job
    # Exit maintenance mode for all ESXi hosts
    Exit-MaintenanceModeESXi -Server ('vcluster730-esx01.edu.local',
        'vcluster730-esx02.edu.local',
        'vcluster730-esx03.edu.local',
        'vcluster730-esx04.edu.local',
        'vcluster530-esx01.edu.local',
        'vcluster530-esx02.edu.local',
        'vcluster530-esx03.edu.local',
        'vcluster530-esx04.edu.local')
    # Update BGInfo Message and Tee so it can be logged
    Tee-Object -InputObject "$($bginfo_message[0..2] -join ""`n"")" -LiteralPath "C:\BGInfo\message.txt"
    Start-Job -ScriptBlock {C:\BGInfo.\bginfo64.exe "C:\BGInfo\Not_Ready.bgi" /timer:0} | Wait-Job | Receive-Job
    Start-Sleep -Seconds 4
    # Start, then monitor the management vCenter VM which is located on the first VM Host in the management cluster
    # Monitoring continues until vCenter is accessible via PowerCLI
    Start-GuestVM -Server (
        'vcluster730-esx01.edu.local',
        'vcluster730-esx02.edu.local',
        'vcluster730-esx03.edu.local',
        'vcluster730-esx04.edu.local') -VM 's1-mgmt-vc' -Monitor
    # Update BGInfo Message and Tee so it can be logged
    Tee-Object -InputObject "$($bginfo_message[0..3] -join ""`n"")" -LiteralPath "C:\BGInfo\message.txt"
    Start-Job -ScriptBlock {C:\BGInfo.\bginfo64.exe "C:\BGInfo\Not_Ready.bgi" /timer:0} | Wait-Job | Receive-Job
    # Start SDDC Manager
    Start-GuestVM -Server s1-mgmt-vc.edu.local -VM 's1-mgmt-sddcm'
    # Start the tenant vCenter, and monitor it
    Start-GuestVM -Server s1-mgmt-vc.edu.local -VM 's1-wld1-vc' -Monitor
    # Update BGInfo Message and Tee so it can be logged
    Tee-Object -InputObject "$($bginfo_message[0..4] -join ""`n"")" -LiteralPath "C:\BGInfo\message.txt"
    Start-Job -ScriptBlock {C:\BGInfo.\bginfo64.exe "C:\BGInfo\Not_Ready.bgi" /timer:0} | Wait-Job | Receive-Job
    # Start all other VMs without monitoring
    Start-GuestVM -Server s1-mgmt-vc.edu.local -VM (
        's1-mgmt-nsxt1',
        's1-mgmt-nsxt2',
        's1-mgmt-nsxt3',
        's1-mgmt-c1-vrm',
        's1-wld1-nsxt1',
        's1-wld1-nsxt2',
        's1-wld1-nsxt3',
        's1-mgmt-nsxt-edge1',
        's1-mgmt-nsxt-edge2'
        )
    # Now that the tenant vCenter has started, start the VxRail Manager VM in the tenant vCenter
    Start-GuestVM -Server (
        'vcluster530-esx01.edu.local',
        'vcluster530-esx02.edu.local',
        'vcluster530-esx03.edu.local',
        'vcluster530-esx04.edu.local') -VM 's1-wld1-c1-vrm'
    # Update BGInfo Message and Tee so it can be logged
    Tee-Object -InputObject "$($bginfo_message[0..5] -join ""`n"")" -LiteralPath "C:\BGInfo\message.txt"
    Start-Job -ScriptBlock {C:\BGInfo.\bginfo64.exe "C:\BGInfo\Not_Ready.bgi" /timer:0} | Wait-Job | Receive-Job
    # Enable the vCLS for each cluster
    Enable-vCLS -Server 's1-mgmt-vc.edu.local' -Cluster 's1-mgmt-c1' 
    Enable-vCLS -Server 's1-wld1-vc' -Cluster 's1-wld1-c1'
    # Update BGInfo Message and Tee so it can be logged
    Tee-Object -InputObject "$($bginfo_message[0..6] -join ""`n"")" -LiteralPath "C:\BGInfo\message.txt"
    Start-Job -ScriptBlock {C:\BGInfo.\bginfo64.exe "C:\BGInfo\Not_Ready.bgi" /timer:0} | Wait-Job | Receive-Job
    # Montior the deployment of the vCLS VMs for each cluster. This must be complete before enabling DRS and HA
    Watch-vCLSDeployment -Server 's1-mgmt-vc.edu.local' -Cluster 's1-mgmt-c1'
    Watch-vCLSDeployment -Server 's1-wld1-vc' -Cluster 's1-wld1-c1' 
    # Enable DRS and HA for each cluster
    Enable-DRSandHA -Server 's1-mgmt-vc.edu.local' -Cluster 's1-mgmt-c1' 
    Enable-DRSandHA -Server 's1-wld1-vc' -Cluster 's1-wld1-c1'
    # Update BGInfo Message and Tee so it can be logged
    Tee-Object -InputObject "$($bginfo_message[0..7] -join ""`n"")" -LiteralPath "C:\BGInfo\message.txt"
    Start-Job -ScriptBlock {C:\BGInfo.\bginfo64.exe "C:\BGInfo\Not_Ready.bgi" /timer:0} | Wait-Job | Receive-Job
    # Clear triggered alarm
    Clear-TriggeredAlarm -Server 's1-mgmt-vc.edu.local'
    Clear-TriggeredAlarm -Server 's1-wld1-vc'
    # Update BGInfo Message and Tee so it can be logged
    Tee-Object -InputObject "$($bginfo_message[0..8] -join ""`n"")" -LiteralPath "C:\BGInfo\message.txt"
    Start-Job -ScriptBlock {C:\BGInfo.\bginfo64.exe "C:\BGInfo\Not_Ready.bgi" /timer:0} | Wait-Job | Receive-Job
    Start-Sleep -Seconds 3
    # Display BGInfo Ending Message 
    Tee-Object -InputObject "$($bginfo_message[9..10] -join ""`n"")" -LiteralPath "C:\BGInfo\message.txt"
    Start-Job -ScriptBlock {C:\BGInfo.\bginfo64.exe "C:\BGInfo\Ready.bgi" /timer:0} | Wait-Job | Receive-Job
    # Note the time it took to complete startup
    $elapsed_startup_time=($(Get-Date) - $prestartup_time)
    Write-Verbose "vApp Startup took $($elapsed_startup_time.Hours)h $($elapsed_startup_time.Minutes)m $($elapsed_startup_time.Seconds)s."
    # Print a completion message
    $line='#' * $Host.UI.RawUI.WindowSize.Width
    Write-Output "${line}`n`nVCF on VxRail vApp Startup took $($elapsed_startup_time.Hours)h $($elapsed_startup_time.Minutes)m $($elapsed_startup_time.Seconds)s. This window can be closed.`n`n"
    # Stopt the transcript
    Stop-Transcript
    }
# Write to the transcript to note the script has already been run.
elseif ($PowerOnGuest -eq $true)
	{
    Start-Transcript -Force -UseMinimalHeader -Append -Path VCF_On_VxRail_vApp_Startup.txt
    $line='#' * $Host.UI.RawUI.WindowSize.Width
    Write-Output "`n${line}`n`nThe VM Power-On start-up script has already run. To rerun this script:`n`t> Delete the VCF_On_VxRail_vApp_Startup.txt file on the desktop`n`t> Logoff the jump server`n`t> Logon the jump server`n`n${line}`n"      
    Stop-Transcript
    } 

# Shutdown VCF releated VMs in an orderly fashion
if ($ShutdownGuest -eq $true)
	{
    Start-Transcript -Force -UseMinimalHeader -Append -Path VCF_On_VxRail_vApp_Shutdown.txt
    # Turn off the VMware CEIP nag message
    Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false | Out-Null
    # Disable DRS and HA for Management cluster 
    Disable-vCLSDRSHA -Server 's1-mgmt-vc.edu.local' -Cluster 's1-mgmt-c1'
    # Gracefully shutdown VxRail Manager in the Tenant workload domain by connecting to the Tenant vCenter
    Shutdown-VM -Server 's1-wld1-vc.edu.local' -Include 's1-wld1-c1-vrm'
    # Disable DRS and HA for Tenant cluster
    Disable-vCLSDRSHA -Server 's1-wld1-vc.edu.local' -Cluster 's1-wld1-c1'
    # Gracefully shutdown all VMs in the Management workload domain except the Management vCenter by connecting to the Management vCenter
    Shutdown-VM -Server 's1-mgmt-vc.edu.local' -Include (
        #'s1-mgmt-cb',
        's1-mgmt-nsxt-edge2',
        's1-mgmt-nsxt-edge1',
        's1-mgmt-nsxt3',
        's1-mgmt-nsxt2',
        's1-mgmt-nsxt1',
        's1-wld1-nsxt3',
        's1-wld1-nsxt2',
        's1-wld1-nsxt1',
        's1-mgmt-c1-vrm',
        's1-mgmt-sddcm',
        's1-wld1-vc') -Exclude ('s1-mgmt-vc','vCLS (1)','vCLS (2)','vCLS (3)') -IncludeUndefined
    # From Node 1 in the Management cluster shutdown the management vCenter
    Shutdown-VM -Server (
        'vcluster730-esx01.edu.local',
        'vcluster730-esx02.edu.local',
        'vcluster730-esx03.edu.local',
        'vcluster730-esx04.edu.local'
        ) -Include 's1-mgmt-vc'
    Write-Verbose "End of VM Shutdown section."
    Stop-Transcript
    }
# Enter mantenance mode for selected VM Hosts
if ($EnterMaintenanceMode -eq $true)
	{
    Start-Transcript -Force -UseMinimalHeader -Append -Path VCF_On_VxRail_vApp_Shutdown.txt
    # VM Hosts will enter maintenance mode. It will error out if running VMs are found on VM Hosts.
    Enter-MaintenanceModeESXi -Server ('vcluster530-esx04.edu.local',
        'vcluster530-esx03.edu.local',
        'vcluster530-esx02.edu.local',
        'vcluster530-esx01.edu.local',
        'vcluster730-esx04.edu.local',
        'vcluster730-esx03.edu.local',
        'vcluster730-esx02.edu.local',
        'vcluster730-esx01.edu.local'
        )
    Stop-Transcript
    }
    Start-Sleep -Seconds 20
# Shutdown ESXi hosts in an orderly fashion
if ($ShutdownESXi -eq $true)
    {
    Start-Transcript -Force -UseMinimalHeader -Append -Path VCF_On_VxRail_vApp_Shutdown.txt
    # Shutdown all ESXi hosts
    Shutdown-ESXi -Server ('vcluster530-esx04.edu.local',
        'vcluster530-esx03.edu.local',
        'vcluster530-esx02.edu.local',
        'vcluster530-esx01.edu.local',
        'vcluster730-esx04.edu.local',
        'vcluster730-esx03.edu.local',
        'vcluster730-esx02.edu.local',
        'vcluster730-esx01.edu.local'
        )
    # End of shutdown sequence
    Write-Verbose "End of ESXi Shutdown section."
    Stop-Transcript
    }

    #######################
