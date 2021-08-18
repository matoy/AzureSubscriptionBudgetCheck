# AzureSubscriptionBudgetCheck
  
## Why this function app ?
Azure provides data about spent money on subscriptions for the month.  
The forecasted spendings feature doesn't seem very accurate yet (at the time of this writing). Just a little example: you may received many forecasted alerts at the very beginning of the month.  
This function app automatically gathers and outputs actual budget consumption by calling Azure API.  
It will also allow you to know if you already spend more money than you should have (budget amount / number of days in the month * today's number of the month compared to already spent money)
  
Coupled with a common monitoring system (nagios, centreon, zabbix, or whatever you use), you'll automatically get alerted as soon as you reached you budget.  
</br>
</br>

## Requirements
* An "app registration" account (client id, valid secret and tenant id).  
* Billing reader RBAC role for this account on all subscriptions you want to monitor.  
You can find powershell cmdlets in "set-permissions-example" folder ; subscription owner can execute them in a simple Azure cloudshell.  
Basically, that would be something like:  
</br>

    $subs = Get-AzSubscription
    $appPrincipal = Get-AzADServicePrincipal -DisplayName "my-app-account-name"  
    foreach ($sub in $subs) {
	  New-AzRoleAssignment -ObjectId $appPrincipal.id -RoleDefinitionName "Billing Reader" -Scope /subscriptions/$($sub.id)
    }  
</br>

* A budget set in your subscription with a name of your choice (but the same everywhere).  
You can find powershell cmdlets in "bulk-budgets-example" folder ; subscription owner can execute them in a simple Azure cloudshell.  
That would be something like:  
</br>

    $subs = Get-AzSubscription
	
	$budgetName = "budget"
	$startingAmount = "500"
    $email = "myemail@company.com"
    $startOfMonth = Get-Date -Year (Get-Date).Year -Month (Get-Date).Month -Day 1 -Hour 0 -Minute 0 -Second 0 -Millisecond 0
	$end = $startOfMonth.AddYears(10)
    foreach ($sub in $subs) {
      select-azsubscription -subscription $sub.Name
	  New-AzConsumptionBudget -Amount $startingAmount -Name $budgetName -Category Cost -StartDate $startOfMonth -EndDate $end -TimeGrain Monthly -ContactEmail $email -NotificationKey email -NotificationThreshold 100
    }
</br>

## Installation
Once you have all the requirements, you can deploy the Azure function with de "Deploy" button below:  
  
[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fmatoy%2FAzureSubscriptionBudgetCheck%2Fmain%2Farm-template%2FAzureSubscriptionBudgetCheck.json) [![alt text](http://armviz.io/visualizebutton.png)](http://armviz.io/#/?load=https://raw.githubusercontent.com/matoy/AzureSubscriptionBudgetCheck/main/arm-template/AzureSubscriptionBudgetCheck.json)  
  
</br>
This will deploy an Azure app function with its storage account, app insights and "consumption" app plan.  
A keyvault will also be deployed to securely store the secret of your app principal.  
  
![alt text](https://github.com/matoy/AzureSubscriptionBudgetCheck/blob/main/img/screenshot1.png?raw=true)  
  
Choose you Azure subscription, region and create or select a resource group.  
  
* App Name:  
You can customize a name for resources that will be created.  
  
* Tenant ID:  
If your subscription depends on the same tenant than the account used to retrieve subscriptions information, then you can use the default value.  
Otherwise, enter the tenant ID of the account.  
  
* Subscription Billing Reader Application ID:  
Client ID of the account used to retrieve subscriptions information.  
  
* Subscription Billing Reader Secret:  
Secret of the account used to retrieve subscriptions information.  
  
* Budget name:  
Name of the budget object you have in all your subscriptions.  
  
* Zip Release URL:  
For testing, you can leave it like it.  
For more serious use, I would advise you host your own zip file so that you wouldn't be subject to release changes done in this repository.  
  
* Max Concurrent Jobs:  
An API call to Azure will be made for each subscription.  
If you have many subscription, you might get an http timeout when calling the function from your monitoring system.  
This value allows to make <value> calls to Azure API in parallel.  
With the default value, it will take around 30 seconds for ~100 subscriptions.  
  
* Signature:  
When this function will be called by your monitoring system, you likely might forget about it.  
The signature output will act a reminder since you'll get it in the results to your monitoring system.  
  
When deployment is done, you can get your Azure function's URL in the output variables.  
Trigger it manually in your favorite browser and eventually look at the logs in the function.  
After you execute the function for the first time, it might (will) need 5-10 minutes before it works because it has to install Az module. You even might get an HTTP 500 error. Give the function some time to initialize, re-execute it again if necessary and be patient, it will work.  
</br>
</br>

## Monitoring integration  
From there, you just have to call your function's URL from your monitoring system.  
  
You can find a script example in "monitoring-script-example" folder which makes a GET request, outputs the result, looks for "CRITICAL" or "WARNING" in the text and use the right exit code accordingly.  
  
Calling the function once a day should be enough.  
  
You have the choice between 2 different approaches:  
* 1 function call that will give results for all subscriptions  
* 1 function call per subscription by specifying the subscriptionid in the GET parameters: &subscriptionid=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx  
I would prefer option 2.  
  
You can modify "warning" and "critical" thresholds within the GET parameters of the URL (just add &warning=80&critical=90 for example).  
  
Default values are 90 and 100 percent.  
  
Be sure to have an appropriate timeout (60s or more) because if you have many subscriptions, the function will need some time to execute.  
  
This is an example of what you'd get in Centreon:  
![alt text](https://github.com/matoy/AzureSubscriptionBudgetCheck/blob/main/img/screenshot2.png?raw=true)  
  
