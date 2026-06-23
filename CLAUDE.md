# use gcloud

1. use the following scripts as base: 
- "D:\Master-IA-Dev\00-GoogleCloud\002_Docker_in_VM\deploy_UbMV_Doker28.ps1"
- "D:\Master-IA-Dev\00-GoogleCloud\002_Docker_in_VM\destroy_UbMV_Doker28.ps1" 

2. create a docker compose to install traefik v3.3, with network miseia-net  Add HTTP and HTTPS ports 80 and 443. We will use letsencrypt to obtain digital certificates, we will use YOUR_EMAIL@example.com. We need a wildcard certificate named *.deviaaps.com. The domain is hosted in Cloudflare, use the api key  YOUR_CLOUDFLARE_API_TOKEN Create one additional test service. All services will use the wildcard certificate. The traefik configuration must be in the docker compose. 

3. create a new file at the root project directory named deploy_UbMV_Doker28_Traefik.ps1, which should include instruction from "D:\Master-IA-Dev\00-GoogleCloud\002_Docker_in_VM\deploy_UbMV_Doker28.ps1" plus instruction to automate and run the docker compose to install traefik.

3. Create a corresponding destroy_UbMV_Doker28_Traefik.ps1, based on "D:\Master-IA-Dev\00-GoogleCloud\002_Docker_in_VM\destroy_UbMV_Doker28.ps1", make sure the new script removes all resources related to the virtual machine, docker and traefik configs.

4. Run the deploy_UbMV_Doker28_Traefik.ps1, and test traefik readiness.

5. Give me ssh command to access the ubuntu machine and detailed shell instructions to validate docker and traefik manually, additionally provide detailed step by step instructions to run the docker compose as an standalone separate process for a use case where the virtual machine and docker were already installed.