#region Invoke-Get-NPSession_ps1
	<#
		.SYNOPSIS
			Creates a Authenticated Session Token
		
		.DESCRIPTION
			Get-NPSession creates the NPEnv Script Variable used to Authenticate Requests
			$Script:NPEnv
	
		.NOTES
			Additional information about the function.
	#>
	function Get-NPSession
	{
		[CmdletBinding(DefaultParameterSetName = 'Default')]
		param
		(
			[Parameter(ParameterSetName = 'Default')]
			[ValidateSet('http', 'https')]
			[string]$Prefix = 'https',
			[Parameter(ParameterSetName = 'Default',
					   Position = 0)]
			[string]$Computer = $($env:computername),
			[Parameter(ParameterSetName = 'Default',
					   Position = 1)]
			[string]$Port = '4993',
			[switch]$Return,
			[Parameter(ParameterSetName = 'Default')]
			[Parameter(ParameterSetName = 'Creds')]
			[pscredential]$Credentials,
			[Parameter(ParameterSetName = 'Default')]
			[switch]$TrustAllCerts
		)
		
		$APIPath = "api"
		$APIVersion = "v1"
		
		if ($Computer -eq $($env:computername))
		{
			$NPService = Get-Service -Name 'QlikNPrintingWebEngine'
			if ($null -eq $NPService)
			{
				Write-Error -Message "Local Computer Name used and Service in not running locally"
				
				break
			}
		}
		
		if ($Computer -match ":")
		{
			If ($Computer.ToLower().StartsWith("http"))
			{
				$Prefix, $Computer = $Computer -split "://"
			}
			
			if ($Computer -match ":")
			{
				$Computer, $Port = $Computer -split ":"
			}
		}
		$CookieMonster = New-Object System.Net.CookieContainer #[System.Net.CookieContainer]::new()
		$Script:NPEnv = @{
			TrustAllCerts = $TrustAllCerts.IsPresent
			Prefix	      = $Prefix
			Computer	  = $Computer
			Port		  = $Port
			API		      = $APIPath
			APIVersion    = $APIVersion
			URLServerAPI  = ""
			WebRequestSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession # [Microsoft.PowerShell.Commands.WebRequestSession]::new()
		}
		if ($null -ne $Credentials)
		{
			$NPEnv.Add("Credentials", $Credentials)
		}
		
		$NPEnv.URLServerAPI = "$($NPEnv.Prefix)://$($NPEnv.Computer):$($NPEnv.Port)/$($NPEnv.API)/$($NPEnv.APIVersion)"
		$WRS = $NPEnv.WebRequestSession
		$WRS.UserAgent = "Windows"
		$WRS.Cookies = $CookieMonster
		
		switch ($PsCmdlet.ParameterSetName)
		{
			'Default' {
				$WRS.UseDefaultCredentials = $true
				$APIAuthScheme = "ntlm"
				break
			}
			'Creds' {
				$WRS.Credentials = $Credentials
				$APIAuthScheme = "ntlm"
				break
			}
			'Certificate' {
				<#
				#Certificate Base Authentication does not currently work as the APIs cannot handle it.
				#Leaving this here in case this is added in the future.
				#Cert
				$NPrintCert = Get-ChildItem Cert:\LocalMachine\My\ | ?{ $_.Issuer -eq "CN=NPrinting-CA" }
				$UserCert = Get-ChildItem Cert:\CurrentUser\My -Eku "Client Authentication"
				$CertificateCollection = [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
				$CertificateCollection.Add($NPrintCert)
				$CertificateCollection.Add($UserCert)
				$WebRequestSession.Certificates = $CertificateCollection
				#>			
			}
		}
		$URLServerLogin = "$($NPEnv.URLServerAPI)/login/$($APIAuthScheme)"
		Write-Verbose -Message $URLServerLogin
		$AuthToken = Invoke-NPRequest -path "login/$($APIAuthScheme)" -method get
		$token = $NPenv.WebRequestSession.Cookies.GetCookies($NPenv.URLServerAPI) | Where-Object{ $_.name -eq "NPWEBCONSOLE_XSRF-TOKEN" }
		$Header = New-Object 'System.Collections.Generic.Dictionary[String,String]'
		$Header.Add("X-XSRF-TOKEN", $token.Value)
		$NPEnv.header = $Header
		if ($Return -eq $true)
		{
			$AuthToken
		}
	}
	
#endregion

#region Invoke-Invoke-NPRequest_ps1
	function Invoke-NPRequest
	{
		param
		(
			[Parameter(Mandatory = $true,
					   Position = 0)]
			[string]$Path,
			[ValidateSet('Get', 'Post', 'Patch', 'Delete', 'Put')]
			[string]$method = 'Get',
			$Data
		)
		if ($null -eq $NPEnv) { Get-NPSession }
		$URI = "$($NPEnv.URLServerAPI)/$($path)"
		
		$Script:SplatRest = @{
			URI	       = $URI
			WebSession = $($NPEnv.WebRequestSession)
			Method	   = $method
			ContentType = "application/json"
			Headers    = $NPenv.header
		}
		
		if ($PSVersionTable.PSVersion.Major -gt 5 -and $NPEnv.TrustAllCerts)
		{
			$Script:SplatRest.Add("SkipCertificateCheck", $NPEnv.TrustAllCerts)
		}
		else
		{
			if ($NPEnv.TrustAllCerts)
			{
				if (-not ("CTrustAllCerts" -as [type]))
				{
					add-type -TypeDefinition @"
using System;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

public static class CTrustAllCerts {
    public static bool ReturnTrue(object sender,
        X509Certificate certificate,
        X509Chain chain,
        SslPolicyErrors sslPolicyErrors) { return true; }

    public static RemoteCertificateValidationCallback GetDelegate() {
        return new RemoteCertificateValidationCallback(CTrustAllCerts.ReturnTrue);
    }
}
"@
					Write-Verbose -Message "Added Cert Ignore Type"
				}
				
				[System.Net.ServicePointManager]::ServerCertificateValidationCallback = [CTrustAllCerts]::GetDelegate()
				[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
				Write-Verbose -Message "Server Certificate Validation Bypass"
			}
		}
		
		if ("" -eq $NPEnv.WebRequestSession.Cookies.GetCookies($NPEnv.URLServerAPI) -and ($null -ne $NPEnv.Credentials))
		{
			$SplatRest.Add("Credential", $NPEnv.Credentials)
		}
		
		#Convert Data to Json and add to body of request
		if ($null -ne $data)
		{
			if ($Data.GetType().name -like "Array*")
			{
				$jsondata = Convertto-Json @($Data)
			}
			elseif ($Data.GetType().name -ne "string")
			{
				$jsondata = Convertto-Json $Data
			}
			else { $jsondata = $Data }
			
			#Catch All
			if (!(($jsondata.StartsWith('{') -and $jsondata.EndsWith('}')) -or ($jsondata.StartsWith('[') -and $jsondata.EndsWith(']'))))
			{
				$jsondata = $Data | Convertto-Json
			}
			
			$SplatRest.Add("Body", $jsondata)
		}
		
		if ($PSBoundParameters.Debug.IsPresent) { $Global:NPSplat = $SplatRest }
		
		try { $Result = Invoke-RestMethod @SplatRest  }
		catch [System.Net.WebException]{
			$EXCEPTION = $_.Exception
			$EXCEPTION
			Write-Warning -Message "From: $($Exception.Response.ResponseUri.AbsoluteUri) `nResponse: $($Exception.Response.StatusDescription)"
			break
		}
		
		if ($Null -ne $Result)
		{
			if ((($Result | Get-Member -MemberType Properties).count -eq 1 -and ($null -ne $Result.data)))
			{
				
				if ($null -ne $Result.data.items) { $Result.data.items }
				else { $Result.data }
				
			}
			else
			{
				$Result
			}
		}
		else { Write-Error -Message "no Results received" }
		
	}
#endregion

#region Invoke-GetNPFilter_ps1
	Function GetNPFilter ($Property, $Value, $Filter)
	{
		if ($null -ne $Property)
		{
			$Value = $Value.replace('*', '%')
			if ($Filter.StartsWith("?")) { $qt = "&" }
			else { $qt = "?" }
			$Filter = "$($Filter)$($qt)$($Property)=$($Value)"
		}
		$Filter
	}
#endregion

#region Invoke-AddNPProperty_ps1
	
	Function AddNPProperty ($Property, $NPObject, $path)
	{
		$PropertyValues = Get-Variable -Name "NP$($Property)" -ValueOnly -ErrorAction SilentlyContinue
		$NPObject | ForEach-Object{
			$Object = $_
			$ObjPath = "$($path)/$($Object.ID)/$Property"
			$NPObjProperties = $(Invoke-NPRequest -Path $ObjPath -method Get)
			$LookupProperties = $NPObjProperties | ForEach-Object{
				$ObjProperty = $_;
				$ObjectProperty = $PropertyValues | Where-Object{ $_.id -eq $ObjProperty }
				if ($Null -eq $ObjectProperty)
				{
					Write-Verbose "$($ObjProperty) Missing from Internal $($Property) List: Updating"
					& "Get-NP$($Property)" -update
					$PropertyValues = Get-Variable -Name "NP$($Property)" -ValueOnly
					$ObjectProperty = $PropertyValues | Where-Object{ $_.id -eq $ObjProperty }
				}
				$ObjectProperty
			}
			Add-Member -InputObject $Object -MemberType NoteProperty -Name $Property -Value $LookupProperties
		}
	}
	
#endregion

#region Invoke-Get-NPFilters_ps1
	function Get-NPFilters
	{
		param
		(
			[parameter(DontShow)]
			[switch]$Update
		)
		$Script:NPFilters = Invoke-NPRequest -Path "Filters" -method Get
		#The Update Switch is used to refresh the Internal List only
		#It is used when Called from Get-NPUsers and a Property is missing from the Internal List
		#The Internal List is used to speed up operations, by minimizing requests for data we have already received
		if ($Update.IsPresent -eq $false)
		{
			$Script:NPFilters
		}
	}
#endregion

#region Invoke-Get-NPGroups_ps1
	Function Get-NPGroups
	{
		param
		(
			[int32]$limit,
			[parameter(DontShow)]
			[switch]$Update
		)
		$filter = ""
		if ("limit" -in $PSBoundParameters.Keys){ $Filter = GetNPFilter -Filter $Filter -Property "limit" -Value $limit.ToString() } 
		
		$Script:NPGroups = Invoke-NPRequest -Path "groups$Filter" -method Get
		
		#The Update Switch is used to refresh the Internal List only
		#It is used when Called from Get-NPUsers and a Property is missing from the Internal List
		#The Internal List is used to speed up operations, by minimizing requests for data we have already received
		if ($Update.IsPresent -eq $false)
		{
			$Script:NPGroups
		}
	}
	
#endregion

#region Invoke-Get-NPRoles_ps1
	function Get-NPRoles
	{
		param
		(
			[parameter(DontShow)]
			[switch]$Update
		)
		
		$Script:NPRoles = Invoke-NPRequest -Path "roles" -method Get
		
		#The Update Switch is used to refresh the Internal List only
		#It is used when Called from Get-NPUsers and a Property is missing from the Internal List
		#The Internal List is used to speed up operations, by minimizing requests for data we have already received
		if ($Update.IsPresent -eq $false)
		{
			$Script:NPRoles
		}
	}
#endregion

#region Invoke-Get-NPTasks_ps1
	function Get-NPTasks
	{
		param
		(
			$ID,
			[string]$Name,
			[switch]$Executions,
			[parameter(DontShow)]
			[switch]$Update
		)
		$BasePath = "tasks"
		
		if ($Null -ne $ID)
		{
			$Path = "$BasePath/$($ID)"
		}
		else
		{
			$Path = "$BasePath"
		}
		
		$Path = "$($Path)$($Filter)"
		Write-Verbose $Path
		
		#The Update Switch is used to refresh the Internal List only
		#It is used when Called from Get-NPUsers and a Property is missing from the Internal List
		#The Internal List is used to speed up operations, by minimizing requests for data we have already received
		$Script:NPTasks = Invoke-NPRequest -Path $Path -method Get
		
		if ($Executions.IsPresent)
		{
			$NPTasks | ForEach-Object{
				$ExecutionPath = "tasks/$($_.id)/Executions"
				$NPTaskExecutions = Invoke-NPRequest -Path $ExecutionPath -method Get
				Add-Member -InputObject $_ -MemberType NoteProperty -Name "Executions" -Value $NPTaskExecutions
			}
		}
		
		if ($Update.IsPresent -eq $false)
		{
			$Script:NPTasks
		}
		
	}
#endregion

#region Invoke-NPUsers_ps1
	
	<#
	#Avaliable APIs
	    Get-NPUsers
	    get /users
	    get /users/{id}
	    get /users/{id}/filters
	    get /users/{id}/groups
	    get /users/{id}/roles
	
	    Update-NPUser
	    put /users/{id}/filters
	    put /users/{id}/groups
	    put /users/{id}
	    put /users/{id}/roles
	
	    New-NPUser
	    post /users
	
	    Remove-NPUser
	    delete /users/{id}
	
	#>
	
	<#
	#Implemented APIS
	Get-NPUsers
	get /users
	get /users/{id}
	get /users/{id}/filters
	get /users/{id}/groups
	get /users/{id}/roles
	#>
	
	<#
		.SYNOPSIS
			Gets details of the Users in NPrinting
		
		.DESCRIPTION
			A detailed description of the Get-NPUsers function.
		
		.PARAMETER ID
			ID of object to get.
		
		.PARAMETER UserName
			Username of object to get.
		
		.PARAMETER Email
			Email address of object to get.
		
		.PARAMETER roles
			Include Role.
		
		.PARAMETER groups
			Inlcude Groups.
		
		.PARAMETER filters
			Include Filters.
		
		.PARAMETER limit
			number of objects to return (default is 50).
	
		.EXAMPLE
			Get-NPUsers -roles -groups -filters
			Get-NPUsers -UserName Marc -roles -groups -filters
		
		.NOTES
			Additional information about the function.
	#>
	function Get-NPUsers
	{
		[CmdletBinding()]
		param
		(
			[Parameter(ValueFromPipeline = $true)]
			[string]$ID,
			[string]$UserName,
			[string]$Email,
			[switch]$roles,
			[switch]$groups,
			[switch]$filters,
			[int32]$limit
		)
		$BasePath = "Users"
		$Filter = ""
		if ("limit" -in $PSBoundParameters.Keys) { $Filter = GetNPFilter -Filter $Filter -Property "limit" -Value $limit.ToString() }
		if ("UserName" -in $PSBoundParameters.Keys) { $Filter = GetNPFilter -Filter $Filter -Property "UserName" -Value $UserName }
		if ("EMail" -in $PSBoundParameters.Keys) { $Filter = GetNPFilter -Filter $Filter -Property "EMail" -Value $EMail }
		
		if ("ID" -in $PSBoundParameters.Keys) { $Path = "$BasePath/$($ID)" }
		else { $Path = "$BasePath" }
		
		$Path = "$($Path)$($Filter)"
		$NPUsers = Invoke-NPRequest -Path $Path -method Get
		
		if ($roles.IsPresent)
		{
			AddNPProperty -Property "Roles" -NPObject $NPUsers -path $BasePath
		}
		if ($groups.IsPresent)
		{
			AddNPProperty -Property "Groups" -NPObject $NPUsers -path $BasePath
		}
		if ($filters.IsPresent)
		{
			AddNPProperty -Property "Filters" -NPObject $NPUsers -path $BasePath
		}
		$NPUsers
	}
	
#endregion

#region Invoke-NPReports_ps1
	
	#This Function is a mess, it kinda works, but there will be filter scenarios where it is broken.
	#WIP
	function Get-NPReports{
		param
		(
			$ID,
			[string]$Name,
			[parameter(DontShow)]
			[switch]$Update
		)
		$BasePath = "Reports"
		
		if ($Null -ne $ID)
		{
			$Path = "$BasePath/$($ID)"
		}
		else
		{
			$Path = "$BasePath"
		}
		
		$Path = "$($Path)$($Filter)"
	    Write-Verbose $Path
	    
	    #The Update Switch is used to refresh the Internal List only
		#It is used when Called from Get-NPUsers and a Property is missing from the Internal List
		#The Internal List is used to speed up operations, by minimizing requests for data we have already received
		$Script:NPReports = Invoke-NPRequest -Path $Path -method Get
		if ($Update.IsPresent -eq $false)
		{
			$Script:NPReports
		}
		
	}
	
#endregion

#region Invoke-NPApps_ps1
	
	#This Function is a mess, it kinda works, but there will be filter scenarios where it is broken.
	#WIP
	function Get-NPApps
	{
		param
		(
			$ID,
			[string]$Name,
			[parameter(DontShow)]
			[switch]$Update
		)
		$BasePath = "Apps"
		
		if ($Null -ne $ID)
		{
			$Path = "$BasePath/$($ID)"
		}
		else
		{
			$Path = "$BasePath"
		}
		
		$FilterApps = $Script:NPapps
		
		switch ($PSBoundParameters.Keys)
		{
			name{
				if ($Name -match '\*')
				{
					$FilterApps = $FilterApps | Where-Object { $_.name -like $Name }
				}
				else
				{
					$FilterApps = $FilterApps | Where-Object { $_.name -eq $Name }
				}
			}
			ID{ $Path = "$BasePath/$($ID)" }
			Update{ $Path = "$BasePath" }
			Default { $Path = "$BasePath" }
		}
		
		$Path = "$($Path)$($Filter)"
	    Write-Verbose $Path
	    
	    #The Update Switch is used to refresh the Internal List only
		#It is used when Called from Get-NPUsers and a Property is missing from the Internal List
		#The Internal List is used to speed up operations, by minimizing requests for data we have already received
		
		if ($Null -eq $FilterApps)
		{
			$Script:NPapps = Invoke-NPRequest -Path $Path -method Get
			if ($Update.IsPresent -eq $false)
			{
				$Script:NPapps
			}
		}
		else
		{
			if ($Update.IsPresent -eq $false)
			{
				$FilterApps
			}
			
		}
		
	}
	
#endregion

#region Invoke-Add-NPFilterField_ps1
	function Add-NPFilterField
	{
		[CmdletBinding()]
		param
		(
			$NPFilter,
			[Parameter(Mandatory = $true)]
			[string]$ConnectionID,
			[Parameter(Mandatory = $true)]
			[string]$FieldName,
			[ValidateSet('text', 'number', 'expression')]
			[string]$FieldType = "text",
			[Parameter(Mandatory = $true)]
			[string[]]$FieldValue,
			[switch]$Overridevalues
		)
		if ($NPFilter.GetType().name -eq "String")
		{
		$NPFilter = Invoke-NPRequest -Path "filters/$($NPFilter)" -method Get
		}
		
		if ($NPFilter.fields.name -contains "$FieldName")
		{
			$Field = $NPFilter.fields | ?{ $_.name -eq "$FieldName" }
			[System.Collections.ArrayList]$Field.values = $Field.values
		}
		else
		{
			$Field = [PSCustomObject]@{
				connectionId   = $ConnectionID
				name		   = $FieldName
				overrideValues = $Overridevalues.IsPresent
				values		   = New-Object System.Collections.ArrayList
			}
			$NPFilter.fields += $Field
		}
		foreach ($Value in $FieldValue)
		{
			$Field.values.Add(
				$([PSCustomObject]@{
						value = $Value
						type  = $FieldType
					})
			) | out-null
		}
		
		$json = $NPFilter | ConvertTo-Json -Depth 10
		$NPut = Invoke-NPRequest -Path "filters/$($NPFilter.id)" -method Put -Data $json
		Invoke-NPRequest -Path "filters/$($NPFilter.id)" -method Get
	}
	
#endregion

#region Invoke-New-NPFilter_ps1
	function New-NPFilter
	{
		[CmdletBinding()]
		param
		(
			[Parameter(Mandatory = $true)]
			[String]$FilterName,
			[string]$FilterDescription,
			[Parameter(Mandatory = $true)]
			[string]$AppID,
			[bool]$enabled = $true
		)
		
		$NewNPFilter = @{
			appid	    = $AppID
			enabled	    = $enabled
			name	    = $FilterName
			description = $FilterDescription
			fields	    = New-Object System.Collections.ArrayList
		}
		$json = $NewNPFilter | ConvertTo-Json
		$Create = Invoke-NPRequest -Path "filters" -method Post -data $json
		$Filter = ""
		$Filter = GetNPFilter -Property appid -Value $AppID -Filter $Filter
		$Results = Invoke-NPRequest -Path "filters/$Filter" -method get
		$Result = $Results[0]
		return $Result
	}
	
#endregion

#region Invoke-Get-NPConnections_ps1
	function Get-NPConnections
	{
		param
		(
			[parameter(DontShow)]
			[switch]$Update
		)
		
		$Script:NPConnections = Invoke-NPRequest -Path "connections" -method Get
		if ($Update.IsPresent -eq $false)
		{
			$Script:NPConnections
		}
	}
#endregion

	<#	
		===========================================================================
		 Created with: 	SAPIEN Technologies, Inc., PowerShell Studio 2018 v5.5.155
		 Created on:   	2018-12-03 10:21 AM
		 Created by:   	Marc Collins
		 Organization: 	Qlik - Consulting
		 Filename:     	Qlik-NPrinting-CLI.psm1
		-------------------------------------------------------------------------
		 Module Name: Qlik-NPrinting-CLI
		===========================================================================
		Qlik NPrinting CLI - PowerShell Module to work with NPrinting
		The Function "Invoke-NPRequest" can be used to access all the NPrinting API's
	#>
	
	Export-ModuleMember -Function Get-*, Add-*, Invoke-*
	