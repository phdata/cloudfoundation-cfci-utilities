# cloudfoundation-cfci-utilities
phData cloudfoundation cfci(CloudFoundation Continuous Integration) build scripts, Refer to our documentation at https://docs.customer.phdata.io/docs/cloudfoundation/ to know more about this tool

# Release Notes
## 1.2.3
### Changes
* Changes to support continuous deployments for lambda functions.
### Upgrade Notes
* Add yq to requirments.txt in cloudfoundation repository

## 1.2.2
* Changes to support sceptre 2.4.0

## 1.2.1
* Adding authorized approvers option for deployments through gitlab+jenkins solution (Not supported for other build tools as of today) 

## 1.2.0
* Adding support for gitlab as source control tool and jenkins as build tool
* But fixes related to stack dependencies 


## 1.0.0
* Initial Release for cloudfoundation scripts supporting github, gitlab integration.
