# Azure Arc endpoint connectivity checker

Usage guide for [`Test-ArcEndpoints.ps1`](./Test-ArcEndpoints.ps1).

Checks Azure public-cloud endpoint connectivity for Arc-enabled machines, SQL Server enabled by Azure Arc, Arc-enabled Kubernetes, and Arc-enabled data services.

> **A connectivity check, not a deployment-readiness certification.** A pass means the direct TCP connection and, where applicable, a validated TLS 1.2 handshake succeeded from the machine running the script. It does not prove that every Arc feature will work.

## Requirements and where to run

- Windows PowerShell 5.1 or PowerShell 7 or later.
- No Azure PowerShell modules, Azure credentials, or administrator elevation required.
- Run from the folder containing `Test-ArcEndpoints.ps1`, or call it by its full path.
- Use your deployment's Azure region, such as `eastus2`. `"East US 2"` is also accepted and normalized to `eastus2`. The script validates the identifier's format, not whether Azure supports that region or a particular service there.

Run on each relevant onboarding host and Arc-managed machine. For Kubernetes and data services, also validate connectivity from the actual agent/data-controller pod egress environment. A successful workstation test does not establish that a server or pod has the same connectivity, DNS, or certificate trust.

The script makes outbound diagnostic connections; it does not install agents or change Azure resources, firewall rules, or cluster configuration.

## Quick start: test all supported scenarios

```powershell
# All is the default scenario.
$results = .\Test-ArcEndpoints.ps1 -Region eastus2

$results |
    Format-Table Scenario, Endpoint, Port, DNS, TCP, TLS, Status -AutoSize
```

The explicit equivalent is:

```powershell
$results = .\Test-ArcEndpoints.ps1 -Region eastus2 -Scenario All
```

**"All" means all four profiles in this script**, including their feature-specific and legacy endpoints. It does not mean every Azure Arc product, cloud, or possible extension.

Concrete hostnames are tested. Wildcards and resource placeholders without actual hostnames are returned as `NeedsHostname`; they are not tested.

Save the raw output in `$results` first. The display, filtering, and export examples below reuse those results without making more network requests. Do not assign `Format-Table` output to `$results`; formatting output is for display, not further processing.

## Select scenarios

| `-Scenario` value | Coverage | Automatically included |
|---|---|---|
| `Servers` | Connected Machine agent, installation, and labeled server features | None |
| `SqlServer` | SQL Server enabled by Azure Arc extension endpoints | `Servers` |
| `Kubernetes` | Arc Kubernetes agent and labeled Kubernetes features | None |
| `DataServices` | Arc data-controller endpoints, including provisioning and telemetry | `Kubernetes` |
| `All` | All four profiles | Both dependency chains |

SQL Server enabled by Arc is distinct from Arc-enabled data services running on Kubernetes. Select the profile that matches the deployment, or use both.

```powershell
# Arc-enabled machines only.
$results = .\Test-ArcEndpoints.ps1 -Region eastus2 -Scenario Servers

# SQL Server enabled by Arc, including its machine requirements.
$results = .\Test-ArcEndpoints.ps1 -Region eastus2 -Scenario SqlServer

# Arc-enabled Kubernetes only.
$results = .\Test-ArcEndpoints.ps1 -Region eastus2 -Scenario Kubernetes

# Arc-enabled data services, including Kubernetes requirements.
$results = .\Test-ArcEndpoints.ps1 -Region eastus2 -Scenario DataServices

# Multiple profiles: machines and Kubernetes.
$results = .\Test-ArcEndpoints.ps1 -Region eastus2 -Scenario Servers,Kubernetes
```

Use scenario selection **before execution** to reduce what is checked. Filtering `$results` afterward changes only what is displayed.

There are no feature-level switches. Read `RequiredWhen` to distinguish always-required endpoints from installation-only, optional-feature, or legacy requirements. For example, a Windows Admin Center endpoint is not relevant if you do not use that feature.

## Show only endpoints that were tested

Include both successful and failed test attempts, excluding unresolved requirements and inventory-only entries:

```powershell
$results |
    Where-Object { $_.Status -in @('Passed', 'Failed') } |
    Format-Table Scenario, Endpoint, Port, DNS, TCP, TLS, Status -AutoSize
```

For a normal run without `-ListOnly`, this shorter filter is equivalent:

```powershell
$results |
    Where-Object Status -ne 'NeedsHostname' |
    Format-Table Scenario, Endpoint, Port, DNS, TCP, TLS, Status -AutoSize
```

The explicit `Passed`/`Failed` filter is safer if you might be displaying results captured with `-ListOnly`.

### Show only failed tests

```powershell
$results |
    Where-Object Status -eq 'Failed' |
    Format-Table Scenario, Endpoint, Port, RequiredWhen, Detail -Wrap
```

`NeedsHostname` is not a connection failure. It is an unverified requirement.

### Show unresolved requirements separately

```powershell
$results |
    Where-Object Status -eq 'NeedsHostname' |
    Format-Table Scenario, Pattern, Port, RequiredWhen -Wrap
```

### Show everything that did not pass

```powershell
$results |
    Where-Object Status -ne 'Passed' |
    Format-Table Scenario, Endpoint, Status, RequiredWhen, Detail -Wrap
```

This includes failures and unresolved requirements. With `-ListOnly` output, it also includes all inventory entries because none were tested.

### Summarize results

```powershell
$results |
    Group-Object Scenario, Status |
    Select-Object Name, Count |
    Format-Table -AutoSize
```

Counts represent requirement rows, not necessarily unique network connections. Shared host/port checks are cached within a run, while each scenario retains its own requirement row.

## Preview requirements without network tests

```powershell
# Full inventory.
$inventory = .\Test-ArcEndpoints.ps1 -Region eastus2 -ListOnly

$inventory |
    Format-Table Scenario, Pattern, Port, RequiredWhen -Wrap

# SQL Server inventory, including machine dependencies.
.\Test-ArcEndpoints.ps1 -Region eastus2 -Scenario SqlServer -ListOnly |
    Format-Table Scenario, Pattern, Port, RequiredWhen -Wrap
```

`-ListOnly` makes no diagnostic network requests. It still validates parameters and expands any supplied hostname mappings. All returned rows have status `InventoryOnly`.

## Wildcards: why they remain in the output

An entry such as `*.his.arc.azure.com` is a firewall/network requirement, not a literal DNS hostname. It cannot be tested directly.

The script keeps these entries so an all-green list of concrete endpoints does not conceal missing coverage. `NeedsHostname` means **"this requirement still needs actual deployment hostnames"**, not "the firewall blocked this connection."

Keep unresolved items in the full results or export, and use the tested-only view for a cleaner console table.

### Supply actual hostnames with `-EndpointMap`

Map the exact inventory pattern to one or more matching FQDNs. Get the actual names from deployment configuration, agent logs, native diagnostics, or documented discovery endpoints.

**The names below are illustrative. Replace every sample value with a real hostname before running network tests.**

```powershell
$map = @{
    '*.his.arc.azure.com' = @(
        'replace-with-actual-host.his.arc.azure.com'
    )
    '*.guestconfiguration.azure.com' = @(
        'replace-with-actual-host.guestconfiguration.azure.com'
    )
    '*.servicebus.windows.net' = @(
        'replace-with-actual-namespace.servicebus.windows.net'
    )
    '*.eastus2.arcdataservices.com' = @(
        'replace-with-actual-host.eastus2.arcdataservices.com'
    )
    '<keyvault-name>.vault.azure.net' = @(
        'replace-with-actual-vault.vault.azure.net'
    )
}

$results = .\Test-ArcEndpoints.ps1 `
    -Region eastus2 `
    -Scenario SqlServer `
    -EndpointMap $map

$results |
    Where-Object { $_.Status -in @('Passed', 'Failed') } |
    Format-Table Scenario, Endpoint, Port, DNS, TCP, TLS, Status -AutoSize
```

Mapping rules:

- Keys must match wildcard/placeholder patterns in the **selected** inventory. Inspect them using `-ListOnly`. A Kubernetes-only map must not include SQL-only keys.
- Values must be actual matching FQDNs, without a scheme, port, path, wildcard, or placeholder.
- Region-specific keys must match `-Region`. For `westus2`, use `*.westus2.arcdataservices.com`, not `*.eastus2.arcdataservices.com`.
- Unmapped patterns remain visible as `NeedsHostname`. A partial map is allowed.
- Passing one hostname does **not** prove the whole wildcard is allowed, or that future service hostnames will work.

The server profile automatically expands `*.login.microsoft.com` to `<region>.login.microsoft.com` for the selected region. You can override that mapping with actual regional hostnames if needed. Other wildcard patterns are not automatically expanded.

Microsoft documents this discovery URL for translating the Service Bus wildcard into concrete endpoints:

```text
https://guestnotificationservice.azure.com/urls/allowlist?api-version=2020-01-01&location=<region>
```

Replace `<region>` with the deployment region. The script does not query this API automatically. Inspect its response and supply relevant concrete hostnames through `-EndpointMap`; returned endpoints can change over time.

## Add deployment-specific endpoints

Use `-AdditionalUri` for concrete endpoints not already covered by the inventory:

```powershell
# Replace with a real deployment endpoint.
$results = .\Test-ArcEndpoints.ps1 `
    -Region eastus2 `
    -Scenario Kubernetes `
    -AdditionalUri 'https://your-actual-registry.azurecr.io/v2/'
```

Multiple URIs can be supplied as a comma-separated array. HTTPS custom ports are supported, for example `https://your-actual-host.example.com:8443/`.

Only the hostname and port are checked, **not the URL path, HTTP response, or service operation**. Additional rows use scenario `Additional`. Supply HTTP only on port 80; HTTPS on port 80 is rejected. Do not put credentials in a URI.

## Adjust timeouts and show progress

```powershell
$results = .\Test-ArcEndpoints.ps1 `
    -Region eastus2 `
    -Scenario Servers `
    -TimeoutSeconds 20 `
    -Verbose
```

The default timeout is 10 seconds; the allowed range is 1-120 seconds. It applies separately to DNS, TCP, and TLS phases, not the whole script. Checks run sequentially, so many slow or unreachable endpoints can make the run take several minutes.

## Export results

Export the raw objects, not formatted tables:

```powershell
# Full results, preserving unresolved requirements.
$results |
    Export-Csv -Path .\ArcEndpointResults.csv -NoTypeInformation -Encoding UTF8

# Only endpoints that were tested, including failed attempts.
$results |
    Where-Object { $_.Status -in @('Passed', 'Failed') } |
    Export-Csv -Path .\ArcEndpointTestedOnly.csv -NoTypeInformation -Encoding UTF8

# JSON retains all result fields.
$results |
    ConvertTo-Json -Depth 4 |
    Set-Content -Path .\ArcEndpointResults.json -Encoding UTF8
```

These commands write to the current directory and overwrite files with the same names. Results can contain deployment hostnames and IP addresses; review them before sharing.

## Understand the result fields

| Field | Meaning |
|---|---|
| `Scenario` | Profile that requires the endpoint, or `Additional` for a caller-supplied URI |
| `Endpoint` | Concrete hostname tested, or unresolved pattern |
| `Pattern` | Original requirement pattern, retained when a mapping supplies a concrete hostname |
| `Port` | Destination TCP port: usually 443; inventory also includes 80 and 8084 |
| `RequiredWhen` | Feature, deployment stage, or legacy-version condition |
| `DNS` | `Passed`, `Failed`, or `NotTested` |
| `Addresses` | IP addresses returned by DNS; not proof that every address was successfully contacted |
| `TCP` | `Passed`, `Failed`, or `NotTested` |
| `TLS` | `Passed`, `Failed`, `NotTested`, or `NotApplicable` for port 80 |
| `Status` | Overall result for that requirement row |
| `Detail` | Failure phase/error, success explanation, or reason the requirement was not tested |

| Status | Interpretation |
|---|---|
| `Passed` | Direct TCP and validated TLS 1.2 succeeded; port 80 checks are TCP-only |
| `Failed` | DNS resolution, TCP connection, or TLS handshake failed or timed out; inspect `Detail` |
| `NeedsHostname` | No actual hostname was supplied for a wildcard or resource placeholder |
| `InventoryOnly` | Returned with `-ListOnly`; no network test attempted |

If DNS fails, TCP and TLS stay `NotTested`. If TCP fails, TLS stays `NotTested`. A TLS failure can indicate certificate trust, hostname mismatch, revocation-check access, protocol/inspection issues, or a timeout; it does not automatically mean the destination TCP port is blocked.

The script enables certificate validation and revocation checking using the testing machine's trust environment. It never bypasses certificate errors.

Connectivity failures are returned as data so the remaining endpoints can be checked. **The script's process exit code is not an aggregate connectivity result.** For automation, inspect the objects explicitly:

```powershell
$failed = @($results | Where-Object Status -eq 'Failed')
$unresolved = @($results | Where-Object Status -eq 'NeedsHostname')

"Failed checks: {0}; unresolved requirements: {1}" -f $failed.Count, $unresolved.Count
```

Review `RequiredWhen` before deciding which failures block your particular deployment.

## Scope and limitations

- **Azure public cloud only.** Azure Government and Azure operated by 21Vianet are not implemented.
- **Direct connections only.** The checker does not use HTTP/HTTPS proxy environment variables, system proxy settings, proxy authentication, or the Arc agent's proxy configuration. Failures on a proxy-only network can be expected and do not establish that the agent's configured proxy path is broken.
- **No Arc gateway validation.** Gateway deployments have different requirements; use native diagnostics.
- **No private-link readiness validation.** DNS may resolve private addresses, but the script does not verify expected ranges, private-link scope assignment, or private DNS configuration.
- **No HTTP/application validation.** It does not test HTTP status codes, URL paths, redirects, authorization, WebSocket upgrades, container image downloads, or actual service functionality.
- **No service-tag/firewall-policy validation.** A successful connection to a current address does not verify that all required service-tag ranges or future service addresses are allowed.
- **Not all extensions or Arc products.** Resource bridge, VMware/SCVMM provisioning, and arbitrary extension dependencies are outside this inventory. Base server coverage is not provisioning coverage for those products.
- **No SQL client connectivity tests.** SQL listener ports such as 1433, database authentication, and local SQL permissions are not checked.
- **Feature and legacy rows remain included.** The script has profile selection, not automatic detection of enabled features or installed versions.
- **Data services target direct connectivity mode.** Microsoft's connectivity documentation states that indirectly connected mode is retired.
- **Static endpoint inventory.** The script does not refresh its endpoint list from Microsoft Learn at runtime. Inventory was reviewed on October 27, 2026; recheck current documentation as services evolve.

## Complementary native diagnostics

On an Arc-enabled machine with a supported Connected Machine agent installed, run:

```powershell
azcmagent check --location eastus2 --extensions all --include-all
```

For a deployment intended to use an Azure Arc private link scope:

```powershell
azcmagent check --location eastus2 --extensions all --include-all --enable-pls-check
```

Native diagnostics provide agent-aware checks, including configured proxy/gateway information. Extension checks require agent version 1.41 or later; other flag availability can depend on the installed agent version.

For an existing Arc-enabled Kubernetes cluster, with Azure CLI, the `connectedk8s` extension, authentication, and cluster access configured:

```powershell
# Replace with the actual resource group and Arc cluster resource name.
az connectedk8s troubleshoot --resource-group 'your-resource-group' --name 'your-cluster'
```

Also test DNS and outbound connectivity from the relevant Kubernetes agent/data-controller pods. The standalone script cannot establish their network path from a separate workstation.

## Built-in help and references

```powershell
Get-Help .\Test-ArcEndpoints.ps1 -Examples
Get-Help .\Test-ArcEndpoints.ps1 -Full
```

- [Consolidated Azure Arc network requirements](https://learn.microsoft.com/azure/azure-arc/network-requirements-consolidated?tabs=azure-cloud)
- [SQL Server enabled by Azure Arc security](https://learn.microsoft.com/sql/sql-server/azure-arc/security-overview)
- [Arc-enabled data services connectivity](https://learn.microsoft.com/azure/azure-arc/data/connectivity)
- [Connected Machine agent: azcmagent check](https://learn.microsoft.com/azure/azure-arc/servers/azcmagent-check)
- [Diagnose Arc-enabled Kubernetes connection issues](https://learn.microsoft.com/azure/azure-arc/kubernetes/diagnose-connection-issues)
