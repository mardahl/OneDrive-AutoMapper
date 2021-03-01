#Requires -Version 5.0
<#

.SYNOPSIS
This script will Automap/Sync Unified Group Drives (Office 365 Groups / Teams Files) with the Next Gen OneDrive Client

.DESCRIPTION
The script will iterate through all Unified Groups and map them with the OneDrive client, if permissions are OK for the currently logged on user.
It will only mappe the "Shared Documents" library, because is the only name that is known. you can modify this script to map any library you like if you have the skills.

.EXAMPLE
Just run this script without any parameters in the users context
After configuring it in the "config" section.

.NOTES
NAME: OneDrive-AutoMapper.ps1
VERSION: 2101
You need to have registered an App in Azure AD with the required permissions to have this script work with the Microsoft Graph API.
For this script the following permissions must be assigned during the app registration:
    Application Permissions : Group.Read.All, Directory.Read.All 
    Delegated Permissions   : Sites.Read.All
    DON'T FORGET ADMIN CONSENT!
Log file output to users %TEMP% folder (%temp%\OneDrive-AutoMapper_log.txt)

.COPYRIGHT
Source: https://github.com/mardahl/OneDrive-AutoMapper

@michael_mardahl on Twitter (new followers appreciated) / https://www.iphase.dk
Modifications by cybermoloch@magitekai.com (@cyber_moloch on Twitter), https://github.com/cybermoloch

Some parts of the authentication functions have been heavily modified from their original state, initially provided by Microsoft as samples of Accessing Intune.
Licensed under the MIT license.
Please credit me if you fint this script useful and do some cool things with it.

N.B. This is an updated version of my previous script "AutoMapUnifiedGroupDrives.ps1", you should update to this version.
     But, test test test! if you had the previous version running.
     Use at your own risk, no warranty given!
#>

param
(
    [Parameter(Mandatory = $true)]
    $TenantID,
    [Parameter(Mandatory = $true)]
    $ClientID,
    [Parameter(Mandatory = $true)]
    $ClientSecret
)

####################################################
#
# FUNCTIONS
#
####################################################

Function Get-AuthToken {
    
    <#
    .SYNOPSIS
    This function is used to get an auth_token for the Microsoft Graph API
    .DESCRIPTION
    The function authenticates with the Graph API Interface with client credentials to get an access_token for working with the REST API
    .EXAMPLE
    Get-AuthToken -TenantID "0000-0000-0000" -ClientID "0000-0000-0000" -ClientSecret "sw4t3ajHTwaregfasdgAWREGawrgfasdgAWREGw4t24r"
    Authenticates you with the Graph API interface and creates the AuthHeader to use when invoking REST Requests
    .NOTES
    NAME: Get-AuthToken
    #>

    param
    (
        [Parameter(Mandatory = $true)]
        $TenantID,
        [Parameter(Mandatory = $true)]
        $ClientID,
        [Parameter(Mandatory = $true)]
        $ClientSecret
    )
    
    try {
        # Define parameters for Microsoft Graph access token retrieval
        $resource = "https://graph.microsoft.com"
        $authority = "https://login.microsoftonline.com/$TenantID"
        $tokenEndpointUri = "$authority/oauth2/token"
  
        # Get the access token using grant type client_credentials for Application Permissions
        $content = "grant_type=client_credentials&client_id=$ClientID&client_secret=$ClientSecret&resource=$resource"

        $response = Invoke-RestMethod -Uri $tokenEndpointUri -Body $content -Method Post -UseBasicParsing

        Write-Information "Got new Access Token!"

        # If the accesstoken is valid then create the authentication header
        if ($response.access_token) {
    
            # Creating header for Authorization token
    
            $authHeader = @{
                'Content-Type'  = 'application/json'
                'Authorization' = "Bearer " + $response.access_token
                'ExpiresOn'     = $response.expires_on
            }
    
            return $authHeader
    
        }
    
        else {
    
            Write-Error "Authorization Access Token is null, check that the client_id and client_secret is correct..."
            break
    
        }

    }
    catch {
    
        Out-FatalWebError -Exception $_.Exception -Function "Get-AuthToken"
   
    }

}

####################################################

Function Get-ValidToken {

    <#
    .SYNOPSIS
    This function is used to identify a possible existing Auth Token, and renew it using Get-AuthToken, if it's expired
    .DESCRIPTION
    Retreives any existing Auth Token in the session, and checks for expiration. If Expired, it will run the Get-AuthToken Function to retreive a new valid Auth Token.
    .EXAMPLE
    Get-ValidToken
    Authenticates you with the Graph API interface by reusing a valid token if available - else a new one is requested using Get-AuthToken
    .NOTES
    NAME: Get-ValidToken
    #>

    param
    (
        [Parameter(Mandatory = $true)]
        $TenantID,
        [Parameter(Mandatory = $true)]
        $ClientID,
        [Parameter(Mandatory = $true)]
        $ClientSecret
    )

    #Fixing client_secret illegal char (+), which do't go well with web requests
    $ClientSecret = $($ClientSecret).Replace("+", "%2B")
    
    # Checking if authToken exists before running authentication
    if ($global:authToken) {
    
        # Get current time in (UTC) UNIX format (and ditch the milliseconds)
        $CurrentTimeUnix = $((get-date ([DateTime]::UtcNow) -UFormat +%s)).split((Get-Culture).NumberFormat.NumberDecimalSeparator)[0]
                
        # If the authToken exists checking when it expires (converted to minutes for readability in output)
        $TokenExpires = [MATH]::floor(([int]$authToken.ExpiresOn - [int]$CurrentTimeUnix) / 60)
    
        if ($TokenExpires -le 0) {
    
            Write-Information ("Authentication Token expired " + $TokenExpires + " minutes ago! - Requesting new one...")
            $global:authToken = Get-AuthToken -TenantID $TenantID -ClientID $ClientID -ClientSecret $ClientSecret
    
        }
        else {

            Write-Information ("Using valid Authentication Token that expires in " + $TokenExpires + " minutes...")
        }

    }
    
    # Authentication doesn't exist, calling Get-AuthToken function
    
    else {
       
        # Getting the authorization token
        $global:authToken = Get-AuthToken -TenantID $TenantID -ClientID $ClientID -ClientSecret $ClientSecret
    
    }
    
}
    
####################################################

Function Out-FatalWebError {

    <#
    .SYNOPSIS
    This function will output mostly readable error information for web request related errors.
    .DESCRIPTION
    Unwraps most of the exeptions details and gets the response codes from the web request, afterwards it stops script execution.
    .EXAMPLE
    Out-FatalWebError -Exception $_.Exception -Function "myFunctionName"
    Shows the error message and the name of the function calling it.
    .NOTES
    NAME: Out-FatalWebError
    #>

    param
    (
        [Parameter(Mandatory = $true)]
        $Exception, # Should be the exception trace, you might try $_.Exception
        [Parameter(Mandatory = $true)]
        $Function # Name of the function that calls this function (for readability)
    )

    #Handles errors for all my Try/Catch'es

    $errorResponse = $Exeption.Response.GetResponseStream()
    $reader = New-Object System.IO.StreamReader($errorResponse)
    $reader.BaseStream.Position = 0
    $reader.DiscardBufferedData()
    $responseBody = $reader.ReadToEnd();
    Write-Error "Failed to execute Function : $Function"
    Write-Error "Response content:`n$responseBody"
    Write-Error "Request to $Uri failed with HTTP Status $($Exception.Response.StatusCode) $($Exception.Response.StatusDescription)"
    break

}

####################################################

Function Get-UnifiedGroups() {
    
    <#
    .SYNOPSIS
    This function is used to get all Unified Groups for a user in Office 365 using the Graph API REST interface
    .DESCRIPTION
    The function connects to the Graph API Interface and gets all groups belonging to a UPN
    .EXAMPLE
    Get-UnifiedGroups -UPN user@domain.com
    .NOTES
    NAME: Get-UnifiedGroups
    PREREQUISITES: Requires a global authToken (properly formattet hashtable header) to be set as $authToken 
    #>
       
    param
    (
        [Parameter(Mandatory = $true)]
        $UPN
    )

    #$Resource = "myorganization/groups"
    $Resource = "users/$UPN/memberOf"
    $uri = "https://graph.microsoft.com/$graphApiVersion/$Resource"

    try {
        Return (Invoke-RestMethod -Uri $uri -Headers $authToken -Method Get).Value
    }
    
    catch {
       # Out-FatalWebError -Exception $_.Exception -Function "Get-UnifiedGroups"
    }
}

####################################################

Function Get-UnifiedGroupDrive() {
    
    <#
    .SYNOPSIS
    This function is used to access the files in a specific unified group in Office 365 using the Graph API REST interface
    .DESCRIPTION
    The function connects to the Graph API Interface and gets all files in a unified group
    .EXAMPLE
    Get-UnifiedGroupDrive -groupID "00000000-0000000-0000000"
    .NOTES
    NAME: Get-UnifiedGroupFiles
    PREREQUISITES: Requires a global authToken (properly formattet hashtable header) to be set as $authToken 
    #>

    param
    (
        [Parameter(Mandatory = $true)]
        $GroupID
    )
       
    $Resource = "groups/$GroupID/sites/root"
    $uri = "https://graph.microsoft.com/$graphApiVersion/$Resource"

    try {

        Return (Invoke-RestMethod -Uri $uri -Headers $authToken -Method Get)

    }
    
    catch {
    
        Out-FatalWebError -Exception $_.Exception -Function "Get-UnifiedGroupDrive"
    
    }

    
}

#####################################################

Function Get-UnifiedGroupDriveList() {
    
    <#
    .SYNOPSIS
    This function is used to get the List information of a specific group in Office 365 using the Graph API REST interface
    .DESCRIPTION
    The function connects to the Graph API Interface and gets the List data of the groups site
    .EXAMPLE
    Get-UnifiedGroupDriveList -GroupID "00000000-0000-0000-0000-000000000000"
    Gets the List data of the unified group with id "00000000-0000-0000-0000-000000000000"
    .NOTES
    NAME: Get-UnifiedGroupDriveList
    PREREQUISITES: Requires a global authToken (properly formattet hashtable header) to be set as $authToken 
    #>

    param
    (
        [Parameter(Mandatory = $true)]
        $GroupID
    )
       
    $Resource = "groups/$GroupID/sites/root/lists"


    try {
    
        $uri = "https://graph.microsoft.com/$graphApiVersion/$($Resource)"
        return (Invoke-RestMethod -Uri $uri -Headers $authToken -Method Get).value

    }
    
    catch {
    
        Out-FatalWebError -Exception $_.Exception -Function "Get-GroupDriveListID"
    
    }

    
}

#####################################################

Function Get-CurrentUserODInfo() {

    <#
    .SYNOPSIS
    This function is used to find the OneDrive user email and folder of the currently logged in user, matching a specific Azure AD Tennant ID
    .DESCRIPTION
    The function parses the HKCU registry hive, matching certain propertied with the specified TenantID - Returning userEmail and UserFolder if a match is found
    .EXAMPLE
    Get-CurrentUserODInfo -TenantID "00000000-0000000-0000000"
    .NOTES
    NAME: Get-CurrentUserODInfo
    #>

    param
    (
        [Parameter(Mandatory = $true)]
        $TenantID
    )

    #Get OneDrive Registry Settings
    $ODFBregPath = "Registry::HKEY_CURRENT_USER\Software\Microsoft\OneDrive\Accounts"
    $ODFBaccounts = Get-ChildItem -Path $ODFBregPath

    #resetting ODUserEmail in case script is run multiple times in same session
    $ODuserEmail = $null

    #Find the correct OneDrive Account for this tennant, in case the user has multiple OD accounts.
    foreach ($Account in $ODFBaccounts) {

        if ($Account.Name -match "Business") {

            $ODTenant = Get-ItemProperty -Path "Registry::$($Account.Name)" | Select-Object -ExpandProperty ConfiguredTenantId
        
            if ($ODTenant -eq $TenantID) {

                $ODuserEmail = Get-ItemProperty -Path "Registry::$($Account.Name)" | Select-Object -ExpandProperty UserEmail
                $ODuserFolder = Get-ItemProperty -Path "Registry::$($Account.Name)" | Select-Object -ExpandProperty UserFolder
                $ODuserTenantName = Get-ItemProperty -Path "Registry::$($Account.Name)" | Select-Object -ExpandProperty DisplayName
                #Getting a list of Existing MountPoints that are synced with the OneDrive Client (key might not exist is no drives are syncing, so we silently continue on any error.
                $MountPoints = Get-Item -Path "Registry::$($Account.Name)\Tenants\$ODuserTenantName" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Property
            }
        }
    }

    if ($null -eq $ODuserEmail) {
    
        Write-Error "No configured OneDrive accounts found for the configured Tenant ID! Script will exit now."
        exit 1

    }
    else {
        
        #Building hashtable with our aquired OneDrive info and returning it to the caller.
        $ODinfo = @{
            'Email'       = $ODuserEmail
            'Folder'      = $ODuserFolder
            'TenantName'  = $ODuserTenantName
            'MountPoints' = $MountPoints
        }

        return $ODinfo

    }
}

######################################################

Function Get-GroupODSyncURL() {

    <#
    .SYNOPSIS
    This function is used to find the OneDrive URL used for syncing.
    .DESCRIPTION
    The function parses the groups available to the user to return th e list of URLs to use in the sync.
    .EXAMPLE
    Get-GroupODSyncURL -GroupID '00000000-0000-0000-0000-000000000000' -UPN 'user@contoso.com'
    .NOTES
    NAME: Get-GroupODSyncURL
    #>

    param
    (
        [Parameter(Mandatory = $true)]
        $GroupID,
        [Parameter(Mandatory = $true)]
        $UPN
    )
    #Executing other functions in order to get the ID's we require to build the odopen:// URL.
    $DriveInfo = Get-UnifiedGroupDrive -GroupID $GroupID
    $ListInfo = Get-UnifiedGroupDriveList -GroupID $GroupID

    #Building our odopen:// URL from the information we have gathered, and encoding it correctly so OneDrive wont barf when we feed it.
    $siteid = [System.Web.HttpUtility]::UrlEncode("{$($DriveInfo.id.Split(',')[1])}")
    $webid = [System.Web.HttpUtility]::UrlEncode("{$($DriveInfo.id.Split(',')[2])}")
    $upn = [System.Web.HttpUtility]::UrlEncode($UPN)
    $webURL = [System.Web.HttpUtility]::UrlEncode($DriveInfo.webUrl)
    $webtitle = [System.Web.HttpUtility]::UrlEncode($DriveInfo.DisplayName).Replace("+", "%20")

    # Checking to see if this library is excluded
    foreach ($siteName in $excludeSiteList) {
        if ($DriveInfo.name -eq $siteName) {
            return $false
        }
    }

    #Finding the correct ListID for the "Shared Documents" library
    $sharedDocumentsListId = $ListInfo | Where-Object Name -Match $sharedDocumentsName | Select-Object -ExpandProperty id
    $listid = [System.Web.HttpUtility]::UrlEncode($sharedDocumentsListId)

    #Returning the correctly assembled ODOPEN URL
    return "odopen://sync/?siteId=$siteid&webId=$webid&listId=$listid&userEmail=$upn&webUrl=$webURL&webtitle=$webtitle"

    #If you want a custom suffix for your list titles, then you can use this retunr string instead, remember to outcomment the other one above!
    #$listtitle = [System.Web.HttpUtility]::UrlEncode("Documents")
    #return "odopen://sync/?siteId=$siteid&webId=$webid&listId=$listid&userEmail=$upn&webUrl=$webURL&webtitle=$webtitle&listtitle=$listtitle"

}

######################################################

Function Get-DriveMembers() {
    
    <#
    .SYNOPSIS
    This function is used to access the members list of a specific unified group in Office 365 using the Graph API REST interface
    .DESCRIPTION
    The function connects to the Graph API Interface and gets the members of a specified Group
    .EXAMPLE
    Get-DriveMembers -groupID "00000000-0000000-0000000"
    .NOTES
    NAME: Get-DriveMembers
    PREREQUISITES: Requires a global authToken (properly formattet hashtable header) to be set as $authToken 
    #>

    param
    (
        [Parameter(Mandatory = $true)]
        $GroupID
    )
       
    $Resource = "groups/$GroupID/members"
    $uri = "https://graph.microsoft.com/$graphApiVersion/$Resource"

    try {

        Return (Invoke-RestMethod -Uri $uri -Headers $authToken -Method Get).Value

    }
    
    catch {
    
        Out-FatalWebError -Exception $_.Exception -Function "Get-Drive"
    
    }
    
}

######################################################

function Wait-OneDriveClient () {

    <#
    .SYNOPSIS
    This function will check to see if OneDrive is Running on the local machine
    .DESCRIPTION
    The function poll's for the OneDrive process every second, and will resume script execution, once it's running
    .EXAMPLE
    Wait-OneDriveClient
    .NOTES
    NAME: WaitforOneDrive 
    #>

    [CmdletBinding()]
    param (
        [Parameter(Position = 0)]
        [Int32][ValidateRange(1, 3000)]
        $MaxWaitSec = '300' #maximum number of seconds we are willing to wait for the OneDrive Process. (not an exact counter, might be a bit longer)
    )

    $started = $false
    $wait = 0 #Initial Wait counter

    Do {

        $status = Get-Process OneDrive -ErrorAction SilentlyContinue #Looking for the OneDrive Process

        If (!($status)) { 
            Write-Information 'Waiting for OneDrive to start...'
            Start-Sleep -Seconds 1 
        }
        Else { 
            Write-Information 'OneDrive has started yo!'
            $started = $true 
        }

        $wait++ #increase wait counter

        If ($wait -eq $MaxWaitSec) {
            Write-Information "Failed to find OneDrive Process. Exiting Script!"
            Exit
        }

    }
    Until ( $started )

}
function Mount-OneDriveUnifiedGroups {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        $TenantID,
        #tenant_id can be read from the azure portal of your tenant (a.k.a Directory ID, shown when you do the App Registration)
        #Required credentials - Get the client_id and client_secret from the app when creating it i Azure AD
        #Idealy you would secure this secret in some way, instead of having it here in clear text.
        [Parameter(Mandatory = $true)]
        $ClientID,
        [Parameter(Mandatory = $true)]
        $ClientSecret,
        [Parameter(Mandatory = $false)]
        $CleanupLeftovers = $true,
        #Set to $true to delete leftover folders from previous syncs (if false, nothing wil be synced if the destination folder already exists)
        #Enabling cleanup will also ensure that a folder get's re-added if a user removes it.
        [Parameter(Mandatory = $false)]
        [Int32][ValidateRange(1, 300)]
        $WaitSec = 10, #Seconds to wait between each mount - not having a delay can cause OneDrive to barf when adding multiple sync folders at once. 
        [Parameter(Mandatory = $false)]
        [Array]$ExcludeSiteList,
        #List of site names to exclude from being added to OneDrive
        #Just add the name of the site to this array, and remove the dummy entries.
        # $excludeSiteList = @("DummyDumDum", "Blankorama", "Nonenana")
        [Parameter(Mandatory = $false)]
        $VerbosePreference = 'Continue' #change to SilentlyContinue to dial down the output.
    )
    
    begin {
        #Special params for some advanced modification
        $global:sharedDocumentsName = "Shared Documents" #change if for some reason your tenant displays the shared documents folders with another name
        $global:graphApiVersion = "v1.0" #should be "v1.0"
    }
    
    process {
        Start-Transcript "$env:TEMP\OneDrive-AutoMapper_log.txt" -Force
        # Wait for OneDrive Process
        Wait-OneDriveClient

        # Getting OneDrive data for currently logged in user, and matching it with the configured Tenant ID
        $OneDrive = Get-CurrentUserODInfo -TenantID $TenantID

        # Calling Microsoft to see if they will give us access with the parameters defined in the config section of this script.
        Get-ValidToken -TenantID $TenantID -ClientID $ClientID -ClientSecret $ClientSecret

        # Getting a list of all O365 Unified Groups
        $allUnifiedGroups = $null
        $allUnifiedGroups = Get-UnifiedGroups -UPN $($OneDrive.Email)

        # Getting OneDrive Sync URL's for all Unified Groups

        Write-Information "Mounting OneDrive all Unified Groups in Tenant ($($OneDrive.TenantName)) that is accessible by $($OneDrive.Email)"

        foreach ($Group in $allUnifiedGroups) {

            #Skip if group is not unified
            if (!$($group.groupTypes -like "Unified*")) { Continue } 

            # Validate that the users is not already Syncing the Drive
            if ($($OneDrive.MountPoints) -match [Regex]::Escape("\$($Group.displayName) -")) {
                Write-Information "The site ($($Group.displayName)) is already synced! Skipping..."
                continue #skip this group and go to the next group
            }
    
            Write-Information "Attempting to sync the drive ($($Group.displayName))..."

            # Getting the OneDrive Sync URL for the Group Drive
            $ODsyncURL = Get-GroupODSyncURL -GroupID $Group.id -UPN $OneDrive.Email

            #Skipping this Library if it has been excluded
            if ($ODsyncURL -eq $false) {
                Write-Information "This drive is on the excluded sites list! Skipping..."
                continue #skip this group and go to the next group 
            }
            else {
                Write-Verbose $Group.displayName
                Write-Verbose $ODsyncURL
            }

            # Check for leftover folders, and start sync if none found, else cleanup and start sync.
            $UserHomePath = join-Path -Path $env:HOMEDRIVE -ChildPath $env:HOMEPATH
            $BusinessPath = Join-Path -Path $UserHomePath -ChildPath $($OneDrive.TenantName)

            try {
                $syncFolders = Get-ChildItem $BusinessPath -ErrorAction Stop
                foreach ($folder in $syncFolders) {
                    if (($($folder.Name) -like ("$($Group.displayName) - *")) -and ($CleanupLeftovers -eq $true)) {
                        $localSyncPath = Join-Path -Path $BusinessPath -ChildPath $($folder.Name) -ErrorAction SilentlyContinue
                        "Found existing sync for folder for : $($Group.displayName)"
                        Write-Information "Leftover Folder Found for $localSyncPath"
                        Write-Information '$CleanupLeftovers is set to true - Deleting old folder and starting sync'
                        Remove-Item -Path $localSyncPath -Force -Recurse -ErrorAction SilentlyContinue
                    }
                    elseif ($($folder.Name) -like ("$($Group.displayName) - *")) {
                        Write-Information "Existing folder found for : '$($Group.displayName)'"
                        Write-Information "OneDrive will complain because 'CleanupLeftovers' is not set to True."
                    }
                }
            }
            catch {
                Write-Verbose "No previous sync folders found for this user in path : $BusinessPath"
            }

            Write-Information "The site ($($Group.displayName)) is NOT synced! Adding to OneDrive client..."
            Start-Process $ODsyncURL # Sending site info to the OneDrive client
            Start-Sleep -Seconds $waitSec
    
        }
        Stop-Transcript        
    }
    
    end {
        
    }
}

#####################################################
#
# SCRIPT EXECUTION
#
######################################################

    Mount-OneDriveUnifiedGroups -TenantID $TenantID -ClientID $ClientID -ClientSecret $ClientSecret