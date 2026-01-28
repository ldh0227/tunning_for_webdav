import asyncio
import aiohttp
import argparse
import random
import time
from collections import Counter
import sys
import base64

async def fetch_head(session, semaphore, url, stats):
    async with semaphore:
        start_time = time.perf_counter()
        try:
            async with session.head(url) as response:
                status = str(response.status)
                stats['successful_requests'] += 1
        except aiohttp.ClientError:
            status = 'NetworkError'
            stats['failed_requests'] += 1
        except asyncio.TimeoutError:
            status = 'Timeout'
            stats['failed_requests'] += 1
        finally:
            stats['status_code_counts'][status] += 1
            end_time = time.perf_counter()
            stats['total_time_per_request'].append(end_time - start_time)

async def main():
    parser = argparse.ArgumentParser(description="High-performance WebDAV HEAD request stress test using Python aiohttp.")
    parser.add_argument("--target_base_url", required=True, help="The base URL of the WebDAV server (e.g., http://localhost:8000).")
    parser.add_argument("--username", required=True, help="The username for authenticating with the WebDAV server.")
    parser.add_argument("--password", required=True, help="The password for authenticating with the WebDAV server.")
    parser.add_argument("--request_count", type=int, default=200000, help="The total number of HEAD requests to send.")
    parser.add_argument("--concurrency", type=int, default=100, help="The number of concurrent requests to send.")
    parser.add_argument("--user_agent", default="WebDAV-Stress-Tester/1.0 (Python-aiohttp)", help="The custom User-Agent string.")

    args = parser.parse_args()

    # --- Initialization ---
    stats = {
        'total_requests': args.request_count,
        'successful_requests': 0,
        'failed_requests': 0,
        'status_code_counts': Counter(),
        'total_time_per_request': []
    }

    print("Starting WebDAV HEAD request stress test (Python aiohttp)...")
    print(f"Target Server: {args.target_base_url}")
    print(f"Total Requests: {args.request_count}")
    print(f"Concurrency Level: {args.concurrency}")
    print("--------------------------------------------------")

    start_overall_time = time.perf_counter()

    # Basic Authentication Header
    auth_header = aiohttp.BasicAuth(args.username, args.password)
    
    # aiohttp client session setup
    # Note: ClientTimeout for the entire session. Individual request timeouts can also be set.
    timeout = aiohttp.ClientTimeout(total=None, connect=5, sock_connect=5, sock_read=None) # connect timeout of 5 seconds

    headers = {'User-Agent': args.user_agent}

    # Using aiohttp.TCPConnector for more control over connection limits if needed, 
    # but the semaphore controls request concurrency well.
    # connector = aiohttp.TCPConnector(limit_per_host=args.concurrency) 

    async with aiohttp.ClientSession(
        timeout=timeout,
        headers=headers,
        auth=auth_header,
        # connector=connector # Use if finer control over TCP connections is needed
    ) as session:
        semaphore = asyncio.Semaphore(args.concurrency)
        tasks = []
        for i in range(args.request_count):
            random_hex = f"{random.randint(0, 255):02X}"
            target_url = f"{args.target_base_url.rstrip('/')}/evidence/{random_hex}"
            tasks.append(fetch_head(session, semaphore, target_url, stats))
            
            # Simple progress update
            if (i + 1) % 10000 == 0:
                sys.stdout.write(f"\rProgress: {i + 1}/{args.request_count} requests processed. Pausing for 1 sec...")
                sys.stdout.flush()
                time.sleep(1) # Pause for 1 second
            elif (i + 1) % 1000 == 0 or (i + 1) == args.request_count:
                sys.stdout.write(f"\rProgress: {i + 1}/{args.request_count} requests processed.")
                sys.stdout.flush()

        await asyncio.gather(*tasks)

    end_overall_time = time.perf_counter()
    overall_duration = end_overall_time - start_overall_time

    # --- Finalize and Display Statistics ---
    print("\n\n--- Stress Test Results ---")
    print(f"Total Duration: {overall_duration:.2f} seconds")
    print(f"Total Requests Sent: {stats['total_requests']}")
    print(f"Successful Requests (2xx): {stats['successful_requests']}")
    print(f"Failed Requests: {stats['failed_requests']}")

    rps = stats['total_requests'] / overall_duration if overall_duration > 0 else 0
    print(f"Requests Per Second (RPS): {rps:.2f}")

    print("\n--- Status Code Distribution ---")
    for status, count in sorted(stats['status_code_counts'].items()):
        print(f"{status}: {count} requests")
    print("--------------------------------------------------")
    print("Test complete.")

if __name__ == "__main__":
    # Ensure aiohttp is installed
    try:
        import aiohttp
    except ImportError:
        print("Error: 'aiohttp' library not found. Please install it using: pip install aiohttp")
        sys.exit(1)
    
    asyncio.run(main())
