using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

# Write to the Azure Functions log stream.
Write-Host "PowerShell HTTP trigger function processed a request."

#####
#
# TT 20210225 AzureSubscriptionBudgetCheck
# This script is executed by an Azure Function App
# It checks money spent on last 31 days on subscription(s) and compare it to 
# defined budget
# It can be triggered by any monitoring system to get the results and status
#
# warning and critical threshold can be passed in the GET parameters
#
# used AAD credentials must have billing reader permission subscription(s) 
#
#####

$warning = [int] $Request.Query.Warning
if (-not $warning) {
    $warning = 90
}

$critical = [int] $Request.Query.Critical
if (-not $critical) {
    $critical = 100
}

$subscriptionid = [string] $Request.Query.Subscriptionid
if (-not $subscriptionid) {
    $subscriptionid = ""
}

# init variables
$alertWarning = 0
$alertCritical = 0
$body = ""
$budgetName = $env:BudgetName
$signature = $env:Signature
$maxConcurrentJobs = [int] $env:MaxConcurrentJobs

# connect with SPN account creds
$tenantId = $env:TenantId
$applicationId = $env:AzureSubscriptionBudgetCheckApplicationID
$password = $env:AzureSubscriptionBudgetCheckSecret
$securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
$credential = new-object -typename System.Management.Automation.PSCredential -argumentlist $applicationId, $securePassword
Connect-AzAccount -Credential $credential -Tenant $tenantId -ServicePrincipal

# get token
$azContext = Get-AzContext
$azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
$profileClient = New-Object -TypeName Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient -ArgumentList ($azProfile)
$token = $profileClient.AcquireAccessToken($azContext.Subscription.TenantId)

# create http headers
$headers = @{}
$headers.Add("Authorization", "bearer " + "$($Token.Accesstoken)")
$headers.Add("contenttype", "application/json")

#$subs = Get-AzSubscription -SubscriptionId $subscriptionid | Sort-Object Name
if ($subscriptionid -eq "") {
	$uri = "https://management.azure.com/subscriptions?api-version=2020-01-01"
	$subs = (Invoke-RestMethod -Method Get -Uri $uri -Headers $headers).value | Sort-Object displayName
}
else {
	$uri = "https://management.azure.com/subscriptions/$($subscriptionid)?api-version=2020-01-01"
	$subs = (Invoke-RestMethod -Method Get -Uri $uri -Headers $headers)	
}

# if many subscriptions, too long execution would cause an http timeout from 
# the monitoring system calling the function
# multithreading is required to avoid long execution time if many subscriptions
if ($subs.count -lt $maxConcurrentJobs) {
	$MaxRunspaces = $subs.count
}
else {
	$MaxRunspaces = $maxConcurrentJobs
}
$RunspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxRunspaces)
$RunspacePool.Open()
$Jobs = New-Object System.Collections.ArrayList
foreach ($sub in $subs) {
	$PowerShell = [powershell]::Create()
	$PowerShell.RunspacePool = $RunspacePool
	[void]$PowerShell.AddScript({
	    Param ($headers, $sub, $budgetName, $warning, $critical)

		$out = ""
		$uri = "https://management.azure.com/subscriptions/$($sub.subscriptionId)/providers/Microsoft.Consumption/budgets/$($budgetName)?api-version=2019-10-01"
		$budget = (Invoke-RestMethod -Method Get -Uri $uri -Headers $headers)
		if (!$budget) {
			$out += "CRITICAL - $($sub.displayName): no '$budgetName' budget found in this subscription"
		}
		else {
			$dateStart = (Get-Date).AddMonths(-1).AddDays(-1).ToString("yyyy-MM-dd")
			$dateEnd = (Get-Date).ToString("yyyy-MM-dd")
			$uri = "https://management.azure.com/subscriptions/$($sub.subscriptionId)/providers/Microsoft.Consumption/usageDetails?`$filter=properties%2FusageStart ge %27$dateStart%27 and properties%2FusageEnd le %27$dateEnd%27&api-version=2021-10-01"
			$results = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
			$usage = $results.value
			while ($results.nextLink) {
					$uri = $results.nextLink
					$results = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
					$usage += $results.value
				}
			$spentAmount = [math]::Round(($usage.properties | Measure-Object -Sum cost).Sum)
			$maxAllowed = [math]::Round($budget.properties.Amount)
			$currencyName = $budget.properties.CurrentSpend.Unit
			$diff = $maxAllowed - $spentAmount
			$percent = [math]::Round(100 * $spentAmount / $maxAllowed, 2)
			if ($spentAmount -gt $maxAllowed) {
				$diff = -$diff
				$out += "CRITICAL (spendAmount: $spentAmount > $percent%) - $($sub.displayName): allowed amount has been exceeded by $diff $currencyName"
			}
			else {
				$status = "OK"
				if ($percent -gt $critical) {
					$status = "CRITICAL"
				}
				elseif ($percent -gt $warning) {
					$status = "WARNING"
				}
				$out += "$status (spendAmount: $spentAmount > $percent%) - $($sub.displayName): $diff $currencyName below maximum allowed amount"
			}
		}
		echo $out
	}).AddArgument($headers).AddArgument($sub).AddArgument($budgetName).AddArgument($warning).AddArgument($critical)
	
	$JobObj = New-Object -TypeName PSObject -Property @{
		Runspace = $PowerShell.BeginInvoke()
		PowerShell = $PowerShell  
    }
    $Jobs.Add($JobObj) | Out-Null
}
while ($Jobs.Runspace.IsCompleted -contains $false) {
	$running = ($Jobs.Runspace | where {$_.IsCompleted -eq $false}).count
    Write-Host (Get-date).Tostring() "Still $running jobs running... $subscriptionid"
	Start-Sleep 1
}
foreach ($job in $Jobs) {
	$current = $job.PowerShell.EndInvoke($job.Runspace)
	$job.PowerShell.Dispose()
	if ($current -match "CRITICAL") {
		$alertCritical++
	}
	if ($current -match "WARNING") {
		$alertWarning++
	}
	$body += $current + "`n"
}
if ($subs.count -eq 0) {
	$alertWarning++
	if ($subscriptionId) {
		$body += "Missing permission on $subscriptionid`n"
	}
	else {
		$body += "No permission on any subscription`n"
	}
}
# add ending status and signature to results
$body += "`n$signature`n"
if ($alertCritical) {
    $body = "Status CRITICAL - Allowed amount has been reached on $($alertCritical+$alertWarning) subscription(s)!`n" + $body
}
elseif ($alertWarning) {
    $body = "Status WARNING on $alertWarning subscription(s)`n" + $body
}
else {
    $body = "Status OK - No alert on any $($subs.count) subscription(s)`n" + $body
}
Write-Host $body

# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body = $body
})
