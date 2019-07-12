# OneDrive-AutoMapper

A scripted solution for fully automating the sync of Document Libraries to the OneDrive desktop client.

BLOG Post here: https://www.iphase.dk/auto-mapping-office-365-group-drives-with-onedrive/

**This script will do the following:**
- Get info on the current user executing the script
- Access the Microsoft Graph to find all Shared Document Libraries of the "Unified Group" type.
- Validate if the current user has access to the Document libraries.
- Check agains a list of excluded sites
- Add the validated libraries documents to the OneDrive client.

*This saves you the time and hassel of having the users go to each Sharepoint Library and click on the "sync" button.

**This script can be deployed using:**
- Group Policy Login script (User context)
- ConfigMgr
- Intune 
-- will only run once though, so evaluate your need and read this: https://www.iphase.dk/hacking-intune-management-extension/
