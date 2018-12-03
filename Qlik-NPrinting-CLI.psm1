﻿<#
    .NOTES
    --------------------------------------------------------------------------------
     Code generated by:  SAPIEN Technologies, Inc., PowerShell Studio 2018 v5.5.155
     Generated on:       2018-12-03 12:47 PM
     Generated by:       Marc Collins
     Organization:       Qlik - Consulting
    --------------------------------------------------------------------------------
    .DESCRIPTION
        Script generated by PowerShell Studio 2018
#>


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
		$CookieMonster = [System.Net.CookieContainer]::new()
		$Script:NPEnv = @{
			TrustAllCerts = $TrustAllCerts.IsPresent
			Prefix	      = $Prefix
			Computer	  = $Computer
			Port		  = $Port
			API		      = $APIPath
			APIVersion    = $APIVersion
			URLServerAPI  = ""
			WebRequestSession = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
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
			$jsondata = $data | ConvertTo-Json
			$SplatRest.Add("Body", $jsondata)
		}
		
		try { $Result = Invoke-RestMethod @SplatRest }
		catch [System.Net.WebException]{
			$EXCEPTION = $_.Exception
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

#region Invoke-Add-NPProperty_ps1
	
	Function Add-NPProperty ($Property,$NPObject,$path) {
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
			[parameter(DontShow)]
			[switch]$Update
		)
		$Script:NPGroups = Invoke-NPRequest -Path "groups" -method Get
		
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
	