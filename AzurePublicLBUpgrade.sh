#!/bin/bash

# Author: Jack Stromberg <jackstromberg.com>
# Last Updated: 2021-22-2
# Version: 1.0
# Description: This script will migrate the configuration of your Azure Load Balancer (Basic sku) to
#               a new Azure Load Balancer (Standard sku) while persisting the public IP addresses associated
#               to the frontend configurations of the load balancer.
# Limitation: This script does not support VMs that have Public IPs associated to NICs
#             This could be added by traversing the NICs and upgrading their public IP skus to Standard
# Limitation: This script does not add backend assignments to NAT Rules
# Note: This script assumes the load balancer and public IPs associated to it are in the same resource group
# Example Usage: ./AzurePublicLBUpgrade.sh --oldRgName moo --oldLBName moo --newLBName moo

# Variables needed
oldRgName=${oldRgName:-}
oldLBName=${oldLBName:-}
newLBName=${newLBName:-}
cleanUp=${cleanUp:-true}  # This will delete temporary resources that may be created by new ALB

while [ $# -gt 0 ]; do

   if [[ $1 == *"--"* ]]; then
        param="${1/--/}"
        if [ "$2" == "" ]; then
            exit "$param parameter value is missing"            
        fi
        declare $param="$2"

        # echo $1 $2 // Optional to see the parameter:value result
   fi

  shift
done

if [ "$oldRgName" == "" ]; then
    exit "oldRgName parameter value is missing"
elif [ "$oldLBName" == "" ]; then     
    exit "oldLBName parameter value is missing"    
elif [ "$newLBName" == "" ]; then
    exit "newLBName parameter value is missing"
elif [ "$cleanUp" != "true" ] && [ "$cleanUp" != "false" ]; then
    exit "cleanUp parameter has an incorrect value.  The value should be set to true or false"
fi

# No changed needed below
newRgName=$oldRgName
lb=$(az network lb show -g $oldRgName -n $oldLBName)
newLocation=$(echo $lb | jq -r '.location')

# 1. Check if all frontends have static Public IPs
echo "Checking prerequisites..."
for fe in $(jq -c '.frontendIpConfigurations[]' <<< $lb); do
    publicIpId=$(jq -r '.publicIpAddress.id' <<< $fe)
    publicIpName=${publicIpId##*/}
    # Should probably split and check for RG name

    publicIp=$(az network public-ip show -g $oldRgName -n $publicIpName)
    publicIpAllocationMethod=$(jq -r '.publicIpAllocationMethod' <<< $publicIp)

    if [ "$publicIpAllocationMethod" = "Dynamic" ]; then
        exit "Please update IP address $publicIpName to be static"
    fi
    
done

# 2. Create new Standard LB
echo "Creating new standard load balancer..."
az network lb create --resource-group $newRgName --name $newLBName --sku Standard --location $newLocation

# 3. Create basic Public IPs for basic LB
echo "Moving frontend IP addresses between load balancers..."
for fe in $(jq -c '.frontendIpConfigurations[]' <<< $lb); do
    # Convert public IPs to standard
    publicIpId=$(jq -r '.publicIpAddress.id' <<< $fe)
    publicIpName=${publicIpId##*/}
    publicIp=$(az network public-ip update -g $oldRgName -n $publicIpName --sku Standard)

    # Create new public IP to assign to the basic LB
    basicPip=$(az network public-ip create --resource-group $oldRgName --name $publicIpName-basic --location $newLocation --sku Basic --allocation-method Static)

    # Assign basic PIP to existing LB (which unassigned the new Standard sku VIP)
    lbFeName=$(jq -r '.name' <<< $fe)
    lbUpdate=$(az network lb frontend-ip update -g $oldRgName --lb-name $oldLBName -n $lbFeName --public-ip-address $publicIpName-basic)

    # Assign standard PIP to new LB
    lbUpdate2=$(az network lb frontend-ip update -g $newRgName --lb-name $newLBName -n $lbFeName --public-ip-address $publicIpName)

done

# 4. Rebuild NAT rules
echo "Creating NAT rules..."
for nat in $(jq -c '.inboundNatRules[]' <<< $lb); do
    natRuleName=$(jq -r '.name' <<< $nat)
    protocol=$(jq -r '.protocol' <<< $nat)
    frontendPort=$(jq -r '.frontendPort' <<< $nat)
    backendPort=$(jq -r '.backendPort' <<< $nat)
    floatingIP=$(jq -r '.enableFloatingIp' <<< $nat)
    enableTCPReset=$(jq -r '.enableTcpReset' <<< $nat)
    frontendIpId=$(jq -r '.frontendIpConfiguration.id' <<< $nat)
    frontendIPName=${frontendIpId##*/}
    idleTimeout=$(jq -r '.idleTimeoutInMinutes' <<< $nat)
    rule=$(az network lb inbound-nat-rule create -g $newRgName --lb-name $newLBName -n $natRuleName --frontend-port $frontendPort --backend-port $backendPort --protocol $protocol --enable-tcp-reset $enableTCPReset --frontend-ip-name $frontendIPName --idle-timeout $idleTimeout)
done

# 5. Rebuild Health Probes
echo "Creating health probes..."
for hp in $(jq -c '.probes[]' <<< $lb); do

    name=$(jq -r '.name' <<< $hp)
    protocol=$(jq -r '.protocol' <<< $hp)
    port=$(jq -r '.port' <<< $hp)
    intervalInSeconds=$(jq -r '.intervalInSeconds' <<< $hp)
    requestPath=$(jq -r '.requestPath' <<< $hp)
    numberOfProbes=$(jq -r '.numberOfProbes' <<< $hp)

    if [ "$protocol" = "Http" ]; then
        probe=$(az network lb probe create -g $newRgName --lb-name $newLBName -n $name --port $port --protocol $protocol --interval $intervalInSeconds --path $requestPath --threshold $numberOfProbes)
    else
        probe=$(az network lb probe create -g $newRgName --lb-name $newLBName -n $name --port $port --protocol $protocol --interval $intervalInSeconds --threshold $numberOfProbes)
    fi

done

# 6. Create backend pools
echo "Creating backend pools..."
for bp in $(jq -c '.backendAddressPools[]' <<< $lb); do

    bpName=$(jq -r '.name' <<< $bp)
    bpId=$(jq -r '.id' <<< $bp)
    newBackendPool=$(az network lb address-pool create -g $newRgName --lb-name $newLBName -n $bpName)
    newBackendPoolId=$(jq -r '.id' <<< $newBackendPool)

    NICIDs=()
    # Remove NICs from old LB
    for nic in $(jq -c '.backendIpConfigurations[]' <<< $bp); do

        id=$(jq -r '.id' <<< $nic)

        NICIDs+=("$id")

        IFS='/' # / is set as delimiter
        read -ra ADDR <<< "$id" # break id into array
        ipConfigName="${ADDR[10]}"
        nicName="${ADDR[8]}"
        nicRG="${ADDR[4]}"
        unset IFS

        # Remove VM from old LB
        removedNic=$(az network nic ip-config address-pool remove -g $nicRG --address-pool $bpId --nic-name $nicName --ip-config-name $ipConfigName)

    done

    # Add NICs to new LB
    for nic in "${NICIDs[@]}"; do

        IFS='/' # / is set as delimiter
        read -ra ADDR <<< "$nic" # break id into array
        ipConfigName="${ADDR[10]}"
        nicName="${ADDR[8]}"
        nicRG="${ADDR[4]}"
        unset IFS

        # Add VM to new LB
        addedNic=$(az network nic ip-config address-pool add -g $nicRG --address-pool $newBackendPoolId --nic-name $nicName --ip-config-name $ipConfigName)

    done

done

# 7. Create LB Rules
echo "Creating load balancing rules..."
for lbrule in $(jq -c '.loadBalancingRules[]' <<< $lb); do
    
    name=$(jq -r '.name' <<< $lbrule)
    backendPort=$(jq -r '.backendPort' <<< $lbrule)
    frontendPort=$(jq -r '.frontendPort' <<< $lbrule)
    protocol=$(jq -r '.protocol' <<< $lbrule)
    loadDistribution=$(jq -r '.loadDistribution' <<< $lbrule)
    idleTimeoutInMinutes=$(jq -r '.idleTimeoutInMinutes' <<< $lbrule)
    enableFloatingIp=$(jq -r '.enableFloatingIp' <<< $lbrule)
    backendPoolId=$(jq -r '.backendAddressPool.id' <<< $lbrule)
    backendPoolName=${backendPoolId##*/}
    healthProbeId=$(jq -r '.probe.id' <<< $lbrule)
    healthProbeName=${healthProbeId##*/}

    rule=$(az network lb rule create -g $newRgName --name $name --lb-name $newLBName --backend-port $backendPort --frontend-port $frontendPort --protocol $protocol --load-distribution $loadDistribution --idle-timeout $idleTimeoutInMinutes --floating-ip $enableFloatingIp --backend-pool-name $backendPoolName --probe-name $healthProbeName)
    
done

# 8. Cleanup (Optional)
if [ $cleanUp == true ]
then
    echo "Cleaning up resources..."

    # Cleanup temp IP that gets created with new Standard ALB
    lbUpdate2DeletePIP=$(az network public-ip delete -g $newRgName -n PublicIP$newLBName)

    # Cleanup default backend pool rule that gets created with new Standard ALB
    backendPoolDelete=$(az network lb address-pool delete -g $newRgName --lb-name $newLBName -n "${newLBName}bepool")
fi

echo "Completed!"
