#requires -Version 5.1
<#
.SYNOPSIS
Checks Azure public-cloud endpoints for Arc machines, SQL Server and Kubernetes.
.DESCRIPTION
Profiles: Servers, SqlServer, Kubernetes, DataServices, or All (default).
SqlServer includes Servers; DataServices includes Kubernetes.
Feature-specific endpoints are included and labeled RequiredWhen. A failed
optional-feature endpoint does not by itself mean the base deployment will fail.

Checks DNS, direct outbound TCP, and TLS 1.2 with certificate/hostname validation.
No Azure modules, credentials, elevation, or deployment changes are required.
Wildcard patterns and resource placeholders without actual names return
NeedsHostname, never Passed. A supplied hostname tests only that hostname.

IMPORTANT: This is not a deployment-readiness certification. Run on each actual
onboarding host, managed machine, and Kubernetes/data-controller egress path.
It does not use HTTP_PROXY/HTTPS_PROXY or system proxy settings, test WebSockets,
HTTP routes/redirects, image pulls, authentication, service tags, or extension-
specific dependencies beyond those listed. DNS may resolve private endpoints,
but private-link configuration and expected address ranges are not validated.
Arc gateway deployments have different requirements; use native diagnostics.
Azure Government/China, resource bridge, VMware/SCVMM provisioning, and arbitrary
extensions are outside this inventory. Add deployment-specific URLs with
AdditionalUri. This is not a test of SQL client connections (for example 1433).

Endpoint inventory reviewed 2026-10-27:
https://learn.microsoft.com/azure/azure-arc/network-requirements-consolidated?tabs=azure-cloud
https://learn.microsoft.com/azure/azure-arc/data/connectivity
https://learn.microsoft.com/sql/sql-server/azure-arc/security-overview

For Servers/SqlServer, also use the installed agent's native diagnostics:
  azcmagent check --location eastus2 --extensions all --include-all
For private link, also add --enable-pls-check.
For Kubernetes, use az connectedk8s troubleshoot and test from the agent pods.
Indirectly connected Arc data services are retired; DataServices targets direct mode.
.PARAMETER Scenario
One or more workload profiles. Dependencies are included automatically.
.PARAMETER Region
Azure public-cloud region identifier. Spaces are removed: East US 2 -> eastus2.
.PARAMETER EndpointMap
Hashtable mapping an inventory wildcard/placeholder to actual FQDNs.
For example: @{ '*.eastus2.arcdataservices.com' = @('actual.eastus2.arcdataservices.com') }
Use names from your deployment/agent logs/native diagnostics, not invented names.
For Service Bus, the documented discovery API is:
https://guestnotificationservice.azure.com/urls/allowlist?api-version=2020-01-01&location=<region>
This script does not call that API automatically.
.PARAMETER AdditionalUri
Additional concrete HTTP/HTTPS URIs (including custom ports). Only their hosts
and ports are tested, not their paths. Do not include credentials in a URI.
.PARAMETER ListOnly
Returns the selected inventory without making network requests.
.PARAMETER TimeoutSeconds
Timeout per DNS, TCP, and TLS phase, not for the entire script.
.EXAMPLE
$results = .\Test-ArcEndpoints.ps1 -Region eastus2
$results | Format-Table Scenario, Endpoint, Port, DNS, TCP, TLS, Status -AutoSize
.EXAMPLE
.\Test-ArcEndpoints.ps1 -Region eastus2 -Scenario SqlServer -ListOnly |
    Format-Table Scenario, Pattern, Port, RequiredWhen -Wrap
.EXAMPLE
$map = @{
    '*.eastus2.arcdataservices.com' = @('actual-from-your-deployment.eastus2.arcdataservices.com')
    '<keyvault-name>.vault.azure.net' = @('your-actual-vault.vault.azure.net')
}
$results = .\Test-ArcEndpoints.ps1 -Region eastus2 -Scenario SqlServer -EndpointMap $map
$results | Where-Object Status -ne Passed | Format-Table Endpoint, Status, Detail -Wrap
.OUTPUTS
PSCustomObject. Status: InventoryOnly, NeedsHostname, Passed, or Failed.
Failures are data, allowing remaining checks to run. Inspect Status; the process
exit code is not an aggregate connectivity result. No overall readiness is inferred.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Region,

    [ValidateNotNullOrEmpty()]
    [ValidateSet('All', 'Servers', 'SqlServer', 'Kubernetes', 'DataServices')]
    [string[]]$Scenario = @('All'),

    [hashtable]$EndpointMap = @{},

    [uri[]]$AdditionalUri = @(),

    [ValidateRange(1, 120)]
    [int]$TimeoutSeconds = 10,

    [switch]$ListOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EndpointMap = $EndpointMap.Clone()
$regionName = ($Region -replace '\s', '').ToLowerInvariant()
if ($regionName -notmatch '^[a-z0-9]+$') {
    throw 'Region must be an Azure region identifier such as eastus2.'
}

function New-ArcEndpoint {
    param(
        [string]$Workload,
        [string]$Pattern,
        [string]$RequiredWhen,
        [int]$Port = 443
    )
    [pscustomobject]@{
        Scenario = $Workload
        Pattern = $Pattern
        Port = $Port
        RequiredWhen = $RequiredWhen
    }
}

function Test-ArcDirectEndpoint {
    param(
        [string]$Endpoint,
        [int]$Port,
        [int]$TimeoutMilliseconds
    )
    $result = [ordered]@{
        DNS = 'NotTested'
        Addresses = ''
        TCP = 'NotTested'
        TLS = 'NotTested'
        Status = 'Failed'
        Detail = ''
    }
    $client = $null
    $stream = $null
    $phase = 'DNS'
    try {
        $dnsTask = [System.Net.Dns]::GetHostAddressesAsync($Endpoint)
        if (-not $dnsTask.Wait($TimeoutMilliseconds)) {
            throw [TimeoutException]::new('DNS resolution timed out.')
        }
        $addresses = $dnsTask.GetAwaiter().GetResult()
        if ($addresses.Count -eq 0) { throw "No IP addresses returned for $Endpoint." }
        $result.DNS = 'Passed'
        $result.Addresses = ($addresses | ForEach-Object { $_.IPAddressToString }) -join ';'

        $phase = 'TCP'
        $client = [System.Net.Sockets.TcpClient]::new()
        $connectTask = $client.ConnectAsync($addresses, $Port)
        if (-not $connectTask.Wait($TimeoutMilliseconds)) {
            throw [TimeoutException]::new('TCP connection timed out.')
        }
        $null = $connectTask.GetAwaiter().GetResult()
        $result.TCP = 'Passed'

        # Port 80 entries are TCP-only; no HTTP response or content is validated.
        if ($Port -eq 80) {
            $result.TLS = 'NotApplicable'
            $result.Detail = 'Direct TCP succeeded. HTTP response/content was not tested.'
        }
        else {
            $phase = 'TLS'
            # Use default certificate/hostname validation; never bypass trust errors.
            $stream = [System.Net.Security.SslStream]::new($client.GetStream(), $false)
            $tlsTask = $stream.AuthenticateAsClientAsync(
                $Endpoint, $null,
                [System.Security.Authentication.SslProtocols]::Tls12, $true
            )
            if (-not $tlsTask.Wait($TimeoutMilliseconds)) {
                throw [TimeoutException]::new('TLS handshake timed out.')
            }
            $null = $tlsTask.GetAwaiter().GetResult()
            $result.TLS = 'Passed'
            $result.Detail = 'Direct TCP and TLS 1.2 succeeded; certificate validation and revocation checking enabled.'
        }
        $result.Status = 'Passed'
    }
    catch {
        $result[$phase] = 'Failed'
        $result.Detail = '{0}: {1}' -f $phase, $_.Exception.GetBaseException().Message
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $client) { $client.Dispose() }
    }
    [pscustomobject]$result
}

$inventory = @(
    New-ArcEndpoint Servers 'download.microsoft.com' 'Windows agent installation / automatic updates'
    New-ArcEndpoint Servers 'packages.microsoft.com' 'Linux agent installation / automatic updates'
    New-ArcEndpoint Servers 'login.microsoftonline.com' 'Always'
    New-ArcEndpoint Servers '*.login.microsoft.com' 'Always: regional authentication'
    New-ArcEndpoint Servers 'pas.windows.net' 'Always'
    New-ArcEndpoint Servers 'management.azure.com' 'Connect / disconnect'
    New-ArcEndpoint Servers '*.his.arc.azure.com' 'Always: hybrid identity; private-link capable'
    New-ArcEndpoint Servers '*.guestconfiguration.azure.com' 'Always: extensions / guest configuration; private-link capable'
    New-ArcEndpoint Servers 'guestnotificationservice.azure.com' 'Always: notifications'
    New-ArcEndpoint Servers '*.guestnotificationservice.azure.com' 'Always: notifications'
    New-ArcEndpoint Servers '*.servicebus.windows.net' 'Always: notifications; also SSH / Windows Admin Center'
    New-ArcEndpoint Servers '*.waconazure.com' 'Windows Admin Center'
    New-ArcEndpoint Servers 'dc.services.visualstudio.com' 'Optional legacy telemetry: agent versions before 1.24'
    New-ArcEndpoint Servers 'www.microsoft.com' 'ESU certificate updates: /pkiops/certs (path not tested)' 80
    New-ArcEndpoint Servers 'www.microsoft.com' 'ESU certificate updates: /pkiops/certs (path not tested)'
    New-ArcEndpoint Servers 'dls.microsoft.com' 'Hotpatch / Windows Server Azure Benefits / pay-as-you-go'

    New-ArcEndpoint SqlServer "*.$regionName.arcdataservices.com" 'SQL Server data processing / telemetry / performance monitoring'
    New-ArcEndpoint SqlServer '<keyvault-name>.vault.azure.net' 'SQL Server Microsoft Entra authentication'
    New-ArcEndpoint SqlServer 'graph.microsoft.com' 'SQL Server Microsoft Entra authentication'
    New-ArcEndpoint SqlServer '*.ingest.monitor.azure.com' 'Custom SQL data collection to Azure Monitor Logs'
    New-ArcEndpoint SqlServer "san-af-$regionName-prod.azurewebsites.net" 'Legacy extension versions through 2024-02-13 only'

    New-ArcEndpoint Kubernetes 'management.azure.com' 'Core: registration'
    New-ArcEndpoint Kubernetes "$regionName.dp.kubernetesconfiguration.azure.com" 'Core: agent data plane'
    New-ArcEndpoint Kubernetes 'login.microsoftonline.com' 'Core: authentication'
    New-ArcEndpoint Kubernetes "$regionName.login.microsoft.com" 'Core: regional authentication'
    New-ArcEndpoint Kubernetes 'login.windows.net' 'Core: authentication'
    New-ArcEndpoint Kubernetes 'mcr.microsoft.com' 'Core: agent container images'
    New-ArcEndpoint Kubernetes '*.data.mcr.microsoft.com' 'Core: container image downloads'
    New-ArcEndpoint Kubernetes 'dl.k8s.io' 'Azure CLI onboarding: kubectl download'
    New-ArcEndpoint Kubernetes 'gbl.his.arc.azure.com' 'Core: identity endpoint discovery'
    New-ArcEndpoint Kubernetes '*.his.arc.azure.com' 'Core: managed identity certificates'
    New-ArcEndpoint Kubernetes 'guestnotificationservice.azure.com' 'Cluster Connect / Custom Locations'
    New-ArcEndpoint Kubernetes '*.guestnotificationservice.azure.com' 'Cluster Connect / Custom Locations'
    New-ArcEndpoint Kubernetes 'sts.windows.net' 'Cluster Connect / Custom Locations'
    New-ArcEndpoint Kubernetes '*.servicebus.windows.net' 'Cluster Connect / Custom Locations; WebSockets also required'
    New-ArcEndpoint Kubernetes 'graph.microsoft.com' 'Azure RBAC'
    New-ArcEndpoint Kubernetes '*.arc.azure.net' 'Azure portal cluster management'
    New-ArcEndpoint Kubernetes "$regionName.obo.arc.azure.com" 'Cluster Connect with Azure RBAC' 8084
    New-ArcEndpoint Kubernetes 'linuxgeneva-microsoft.azurecr.io' 'Kubernetes extensions'
    New-ArcEndpoint Kubernetes 'gcs.prod.monitoring.core.windows.net' 'IoT Operations / Secret Store / Certificate Management'
    New-ArcEndpoint Kubernetes '*.prod.microsoftmetrics.com' 'IoT Operations / Secret Store / Certificate Management'
    New-ArcEndpoint Kubernetes '*.prod.hot.ingest.monitor.core.windows.net' 'IoT Operations / Secret Store / Certificate Management'
    New-ArcEndpoint Kubernetes '*.prod.warm.ingest.monitor.core.windows.net' 'IoT Operations / Secret Store / Certificate Management'

    New-ArcEndpoint DataServices 'arcdataservicesrow1.azurecr.io' 'Direct-mode data controller provisioning'
    New-ArcEndpoint DataServices 'arcdataservicesrow2.azurecr.io' 'Direct-mode data controller provisioning'
    New-ArcEndpoint DataServices '*.blob.core.windows.net' 'Direct-mode data controller provisioning'
    New-ArcEndpoint DataServices '*.ods.opinsights.azure.com' 'Azure Monitor: log / metric upload'
    New-ArcEndpoint DataServices '*.oms.opinsights.azure.com' 'Azure Monitor: log / metric upload'
    New-ArcEndpoint DataServices '*.monitoring.azure.com' 'Azure Monitor: log / metric upload'
    New-ArcEndpoint DataServices "*.$regionName.arcdataservices.com" 'Direct-mode inventory / billing / telemetry'
    New-ArcEndpoint DataServices "san-af-$regionName-prod.azurewebsites.net" 'Legacy extension versions through 2024-02-13 only'
)

$selected = @($Scenario)
if ($selected -contains 'All') {
    $selected = @('Servers', 'SqlServer', 'Kubernetes', 'DataServices')
}
if ($selected -contains 'SqlServer') { $selected += 'Servers' }
if ($selected -contains 'DataServices') { $selected += 'Kubernetes' }
$inventory = @($inventory | Where-Object { $_.Scenario -in $selected })

# Treat the documented regional login pattern as unresolved except for the
# selected region; an explicit map can supply other deployment regions.
$regionalLoginPattern = '*.login.microsoft.com'
if ($regionalLoginPattern -in $inventory.Pattern -and -not $EndpointMap.ContainsKey($regionalLoginPattern)) {
    $EndpointMap[$regionalLoginPattern] = @("$regionName.login.microsoft.com")
}

# Validate all caller input before initiating network traffic.
foreach ($key in $EndpointMap.Keys) {
    if ($key -notin $inventory.Pattern -or ($key -notmatch '[*<]')) {
        throw "Unknown wildcard/placeholder '$key' for the selected scenarios. Use -ListOnly to inspect patterns."
    }
    $names = @($EndpointMap[$key])
    if ($names.Count -eq 0) { throw "No hostnames supplied for '$key'." }
    $matchPattern = $key -replace '<keyvault-name>', '*'
    foreach ($name in $names) {
        if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name) -or
            $name -match '[*<>]' -or $name -notlike $matchPattern -or
            [Uri]::CheckHostName($name) -ne [UriHostNameType]::Dns) {
            throw "Invalid hostname '$name' for '$key'. Use an actual matching FQDN without a scheme, port, path, or wildcard."
        }
    }
}
foreach ($uri in $AdditionalUri) {
    if ($null -eq $uri -or -not $uri.IsAbsoluteUri -or
        $uri.Scheme -notin @('http', 'https') -or $uri.UserInfo -or
        $uri.Host -match '[*<>]' -or
        ($uri.Scheme -eq 'http' -and $uri.Port -ne 80) -or
        ($uri.Scheme -eq 'https' -and $uri.Port -eq 80)) {
        throw 'AdditionalUri must be a concrete HTTPS URI (not port 80), or HTTP on port 80, without credentials.'
    }
    $inventory += New-ArcEndpoint Additional $uri.DnsSafeHost "Deployment-specific: $($uri.AbsolutePath) (path not tested)" $uri.Port
}

if (-not $ListOnly) {
    Write-Warning 'Direct-path checks only; proxies and Arc gateway are not used. Feature-specific and legacy endpoints are included; interpret RequiredWhen. NeedsHostname means incomplete coverage, not success.'
}

$cache = @{}
foreach ($entry in $inventory) {
    $targets = @($entry.Pattern)
    $unresolved = $entry.Pattern -match '[*<]'
    if ($unresolved -and $EndpointMap.ContainsKey($entry.Pattern)) {
        $targets = @($EndpointMap[$entry.Pattern] | Select-Object -Unique)
        $unresolved = $false
    }
    foreach ($target in $targets) {
        $result = [ordered]@{
            Scenario = $entry.Scenario
            Endpoint = $target
            Pattern = $entry.Pattern
            Port = $entry.Port
            RequiredWhen = $entry.RequiredWhen
            DNS = 'NotTested'
            Addresses = ''
            TCP = 'NotTested'
            TLS = 'NotTested'
            Status = 'InventoryOnly'
            Detail = 'No network test requested.'
        }
        if (-not $ListOnly) {
            if ($unresolved) {
                $result.Status = 'NeedsHostname'
                $result.Detail = 'Supply actual deployment FQDNs in -EndpointMap. Wildcards/placeholders cannot be tested.'
            }
            else {
                $cacheKey = '{0}:{1}' -f $target, $entry.Port
                if (-not $cache.ContainsKey($cacheKey)) {
                    Write-Verbose "Checking $cacheKey"
                    $cache[$cacheKey] = Test-ArcDirectEndpoint -Endpoint $target -Port $entry.Port `
                        -TimeoutMilliseconds ($TimeoutSeconds * 1000)
                }
                foreach ($property in $cache[$cacheKey].PSObject.Properties) {
                    $result[$property.Name] = $property.Value
                }
                if ($entry.Pattern -match '[*<]') {
                    $result.Detail += ' Only the supplied hostname was checked, not the entire pattern.'
                }
            }
        }
        [pscustomobject]$result
    }
}
