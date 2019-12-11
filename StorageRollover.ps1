
Param
(
    [Parameter (Mandatory = $true)]
    [string] $depSuffix
)

$connectionName = "AzureRunAsConnection"
try
{
    # Get the connection "AzureRunAsConnection "
    $servicePrincipalConnection=Get-AutomationConnection -Name $connectionName         

    "Logging in to Azure..."
     Add-AzureRmAccount `
        -ServicePrincipal `
        -TenantId $servicePrincipalConnection.TenantId `
        -ApplicationId $servicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint 
}
catch {
    if (!$servicePrincipalConnection)
    {
        $ErrorMessage = "Connection $connectionName not found."
        throw $ErrorMessage
    } else{
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
}
$RGName = "crmri"+$depSuffix
$VaultName = "crmrikv"+$depSuffix


#region Functions

function ParseConnectionString([string] $connString)
{
    $parts = $connString.Split(';')

    $key = ""
    $startPrefix = "AccountKey="
    $startPrefixLen = $startPrefix.Length
    foreach($part in $parts)
    {
        if($part.StartsWith($startPrefix))
        {
            $key = $part.Substring($startPrefixLen)
            break
        }
    }
    if($key -eq "")
    {
        throw "No Key is parsed in the input connectionString"
    }
    return $key
}

function GetStorageAccountKeyType([string] $StorageAccountName, [string] $SecretName) {

    $secretvalue = Get-AzureKeyVaultSecret -VaultName $VaultName -Name $SecretName
    $key = ParseConnectionString($secretvalue.SecretValueText)
    #Write-Output("Key: $key from Keyvault: SecretName: $SecretName")

    $SAKeys = Get-AzureRmStorageAccountKey -ResourceGroupName $RGName -Name $StorageAccountName

    $KeyType = -1
    for($i = 0 ; $i -lt 2; $i++)
    {
        $SAKey = $SAKeys[$i].Value
        #Write-Output("Key$i : $SAKey from actualy Storage Account: $StorageAccountName")
        if($SAKey -eq $key)
        {
            $KeyType = $i
            break
        }
    }
    return $KeyType
}

function RotateStorageAccountKeys([int] $keyType, [string] $KeyName, [string] $StorageAccountName, [string] $SecretName)
{
    #regenerate The new Keys for the respective KeyName for a particular Storage Account
    New-AzureRmStorageAccountKey -ResourceGroupName $RGName -Name $StorageAccountName -KeyName "$KeyName" -Verbose

    # get the Keys for the Storage Account
    $SAKeys = Get-AzureRmStorageAccountKey -ResourceGroupName $RGName -Name $StorageAccountName

    $prefixconnString = "DefaultEndpointsProtocol=https;AccountName=" + $StorageAccountName + ";AccountKey="
    $suffixconnString = ";EndpointSuffix=core.windows.net"
    if($SAKeys[$keyType] -eq $null)
    {
       throw " index is not present in SAKeys List"
    }

    $secretvalue = ConvertTo-SecureString ($prefixconnString + $SAKeys[$keyType].Value + $suffixconnString) -AsPlainText -Force
    Write-Output ("$KeyName  is regenerated for $StorageAccountName  new Key : "+ $SAKeys[$keyType].Value+ "`n")

    $secret = Set-AzureKeyVaultSecret -VaultName $VaultName -Name $SecretName -SecretValue $secretvalue
    Write-Output ("$StorageAccountName Storage Account Key Updated to KeyVault for Secret: $SecretName `n")
}

#endregion


#region MainExceution

    # key value pair contains mapping for storage account with its respective secretname in KV
    $map = New-Object 'system.collections.generic.dictionary[string,string]'
    $map["cistorage"+$depSuffix] = "ciStorageAccountConnectionString"
    $map["crmridtfstorage"+$depSuffix] = "dtfStorageAccountConnectionString"
    $map["crmristorage"+$depSuffix] = "storageAccountConnectionString"
    $map["marsstorage"+$depSuffix] = "marsStorageAccountConnectionString"
    $map["plsstorage"+$depSuffix] = "plsStorageAccountConnectionString"
    foreach ($StorageAccountName in $map.keys)
    {
        #Rolling over only Storage accounts, Sf refixed storage accounts will be replaced by Managed Disks
         if(!$StorageAccountName.StartsWith('sf','CurrentCultureIgnoreCase') )
        {
            $SecretName = $map[$StorageAccountName]
            $keyType = GetStorageAccountKeyType -StorageAccountName $StorageAccountName -SecretName $SecretName
            # keyType 1 means, we are using Secondary key in KV, which was replace by StorageRollOverPhase1
            # if KeyType is 0 , it means either Phase1 failed to rotate to secondary Key or the Deployment ran , which replaced the KV to Primary Secrets
            # effectively undoing the Phase1
            # Rotate the Primary Key only if KeyType is 1, meaning the Phase 1 is done
            
            if($keyType -eq 0)
            {
                #RotatePrimaryKey
                 RotateStorageAccountKeys -keyType 1 -KeyName "key2" -StorageAccountName $StorageAccountName -SecretName $SecretName
                 Write-Output ("Rotation completed for $StorageAccountName for SecretName: $SecretName`n")
            }

            elseif($keyType -eq 1)
            {
                #RotatePrimaryKey
                 RotateStorageAccountKeys -keyType 0 -KeyName "key1" -StorageAccountName $StorageAccountName -SecretName $SecretName
                 Write-Output ("Rotation completed for $StorageAccountName for SecretName: $SecretName`n")
            }
            else
            {
                $ErrorMessage = ("Rotation Not completed for " + $StorageAccountName + " KeyType for SecretName: " + $SecretName + " is key" + $keyType)
                Write-Error -Message $ErrorMessage
            }
        
        }
    }

#endregion



