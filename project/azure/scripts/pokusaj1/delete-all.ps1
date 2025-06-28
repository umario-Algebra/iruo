$resourceGroup = "muvodic-irou"
Write-Host "BRISEM SVE iz resource group: $resourceGroup"
az group delete --name $resourceGroup --yes --no-wait
Write-Host "DELETE INITIATED. Sve ce biti uklonjeno."
