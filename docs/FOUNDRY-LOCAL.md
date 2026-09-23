# Local Microsoft Foundry access

The CPAY pages run in a browser, so they must not call Microsoft Foundry
directly with an API key or Azure credential. Use a local server-side worker
or script for Foundry calls and keep its credentials out of `public/`.

## One-time local authentication

If needed, install the Azure Developer CLI (`azd`) using the official
Microsoft instructions. Run `azd auth login`, then verify the signed-in
account with:

```powershell
azd auth login
azd auth login --check-status
```

The Azure CLI is also supported by the Azure identity libraries:

```powershell
az login
```

Use the same Microsoft account that has access to the Foundry project shown in
the Foundry portal. Verify the Developer CLI installation with:

```powershell
azd version
```

## Project settings

Create a local `.env.local` for the server-side process. Do not put these
values in `public/config.js`, HTML, browser JavaScript, or a committed file:

```text
AZURE_AI_PROJECT_ENDPOINT=https://<resource-name>.services.ai.azure.com/api/projects/<project-name>
AZURE_AI_AGENT_NAME=<agent-name>
```

The project endpoint is available under Foundry → Manage → Project details.
The agent name is the exact name of the hosted agent you want to call.

## Credential model

For local code, use `DefaultAzureCredential` from the Azure Identity SDK. It
can use the `azd` or Azure CLI login without storing an API key:

```ts
import { DefaultAzureCredential } from "@azure/identity";

const credential = new DefaultAzureCredential();
```

For Azure-hosted code, replace it with a managed identity and grant that
identity only the required Foundry project role. Never copy the masked API key
from the portal into this repository or into client-side code.

## Recommended local shape

```text
browser (public/) -> local server-side proxy -> Microsoft Foundry project
                                      |
                              DefaultAzureCredential
```

This repository does not currently contain a Node server or an agent client,
so no Foundry request is wired into the public pages. Add the proxy as a
separate server-side process before exposing Foundry functionality in the UI.
