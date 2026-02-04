<#
.SYNOPSIS
    Performs a high-performance, concurrent stress test on a WebDAV server using batched asynchronous requests.
    This version uses System.Net.Http.HttpClient for improved performance and sends requests in parallel.

.DESCRIPTION
    This script sends a specified number of HTTP HEAD requests to a WebDAV server.
    It targets URLs in the format 'evidence/[00-FF]', where '[00-FF]' is a random two-digit hexadecimal value.
    The script requires user credentials for authentication and provides statistics on the results,
    including success/failure counts, status code distribution, and requests per second (RPS).

.PARAMETER TargetBaseUrl
    The base URL of the WebDAV server (e.g., "http://your-webdav-server.com").

.PARAMETER Username
    The username for authenticating with the WebDAV server.

.PARAMETER Password
    The password for authenticating with the WebDAV server.

.PARAMETER RequestCount
    The total number of HEAD requests to send. Defaults to 200,000.

.PARAMETER Concurrency
    The number of requests to send in parallel per batch. Defaults to 100.

.PARAMETER UserAgent
    The custom User-Agent string to send with each request.

.EXAMPLE
    .\WebDAV_HEAD_Stress_Test.ps1 -TargetBaseUrl "http://localhost:8080" -Username "admin" -Password "password123" -RequestCount 1000 -Concurrency 50

    This command runs the stress test against a local WebDAV server, sending 1000 total requests in parallel batches of 50.
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$TargetBaseUrl,

    [Parameter(Mandatory=$true)]
    [string]$Username,

    [Parameter(Mandatory=$true)]
    [string]$Password,

    [int]$RequestCount = 200000,
    [int]$Concurrency = 50,
    [string]$UserAgent = "WebDAV-Stress-Tester/2.0 (PowerShell-HttpClient-Concurrent)"
)

# --- Initialization ---
$global:statistics = @{
    TotalRequests = $RequestCount
    SuccessfulRequests = 0
    FailedRequests = 0
    StatusCodeCounts = [System.Collections.Concurrent.ConcurrentDictionary[string, int]]::new()
}

$global:statistics.StartTime = (Get-Date)

Write-Host "Starting WebDAV HEAD request stress test (Concurrent High-Performance Mode)..."
Write-Host "Target Server: $TargetBaseUrl"
Write-Host "Total Requests: $RequestCount"
Write-Host "Concurrency Level: $Concurrency"
Write-Host "--------------------------------------------------"

$handler = $null
$httpClient = $null
$requestsProcessed = 0

try {
    # --- HttpClient Setup ---
    $handler = New-Object System.Net.Http.HttpClientHandler
    $authString = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${Username}:${Password}"))
    
    $httpClient = New-Object System.Net.Http.HttpClient($handler)
    $httpClient.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Basic", $authString)
    $httpClient.DefaultRequestHeaders.Add("User-Agent", $UserAgent)
    $handler.UseProxy = $false
    $handler.MaxConnectionsPerServer = $Concurrency

    # --- Main Loop (in Batches) ---
    while ($requestsProcessed -lt $RequestCount) {
        $tasks = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
        $batchSize = [System.Math]::Min($Concurrency, $RequestCount - $requestsProcessed)

        for ($i = 0; $i -lt $batchSize; $i++) {
            $randomHex = '{0:X2}' -f (Get-Random -Minimum 0 -Maximum 255)
            $targetUrl = "$($TargetBaseUrl.TrimEnd('/'))/evidence/$randomHex"
            
            $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Head, $targetUrl)
            $tasks.Add($httpClient.SendAsync($request))
            Start-Sleep -Milliseconds 5
        }

        # Wait for the entire batch of tasks to complete
        try {
            [System.Threading.Tasks.Task]::WaitAll($tasks.ToArray())
        }
        catch {
            # Catch the AggregateException to inspect individual task exceptions
            $aggregateException = $_.Exception
            foreach ($ex in $aggregateException.InnerExceptions) {
                Write-Warning "A task failed with exception: $($ex.InnerException.Message)"
            }
        }

        # Process results from the completed batch
        foreach ($task in $tasks) {
            $statusCode = "N/A"
            if ($task.IsFaulted) {
                # This catches exceptions from SendAsync (e.g., network errors, invalid URL)
                $global:statistics.FailedRequests++
                $statusCode = "NetworkError"
            } else {
                $response = $task.Result
                $statusCode = [int]$response.StatusCode
                if ($response.IsSuccessStatusCode) {
                    $global:statistics.SuccessfulRequests++
                } else {
                    $global:statistics.FailedRequests++
                }
                $response.Dispose() # Dispose the response message regardless of success or failure (if not faulted)
            }
            
            # Update status code counts using a thread-safe dictionary
            $global:statistics.StatusCodeCounts.AddOrUpdate($statusCode, 1, {param($key, $oldValue) $oldValue + 1})
        }
        
        $requestsProcessed += $batchSize
        Write-Progress -Activity "Sending HEAD Requests" -Status "Processed $requestsProcessed of $RequestCount" -PercentComplete (($requestsProcessed / $RequestCount) * 100)
    }
}
finally {
    # --- Finalize and Display Statistics ---
    $global:statistics.EndTime = (Get-Date)
    $duration = $global:statistics.EndTime - $global:statistics.StartTime
    $global:statistics.Duration = "{0:N2} seconds" -f $duration.TotalSeconds

    if ($duration.TotalSeconds -gt 0) {
        $global:statistics.RequestsPerSecond = "{0:N2}" -f ($RequestCount / $duration.TotalSeconds)
    }

    if ($httpClient) { $httpClient.Dispose() }
    if ($handler) { $handler.Dispose() }

    Write-Host "`n`n--- Stress Test Results ---"
    Write-Host "Start Time: $($global:statistics.StartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Host "End Time:   $($global:statistics.EndTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Host "Total Duration: $($global:statistics.Duration)"
    Write-Host "Total Requests Sent: $RequestCount"
    Write-Host "Successful Requests (2xx): $($global:statistics.SuccessfulRequests)"
    Write-Host "Failed Requests: $($global:statistics.FailedRequests)"
    Write-Host "Requests Per Second (RPS): $($global:statistics.RequestsPerSecond)"
    Write-Host "`n--- Status Code Distribution ---"

    $global:statistics.StatusCodeCounts.GetEnumerator() | Sort-Object Key | ForEach-Object {
        Write-Host "$($_.Key): $($_.Value) requests"
    }
    Write-Host "--------------------------------------------------"
    Write-Host "Test complete."
}
