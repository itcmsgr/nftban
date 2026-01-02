#!/usr/bin/env python3
"""
Upload bundled NFTBan repository to Gemini API and create explicit cache.

Prerequisites:
    pip install google-genai

Usage:
    export GEMINI_API_KEY="your-api-key"
    python3 upload_and_cache.py /tmp/nftban_bundle.txt

Environment Variables:
    GEMINI_API_KEY - Your Gemini API key (required)
    GEMINI_MODEL - Model to use (default: gemini-2.0-flash-exp)
    CACHE_TTL_HOURS - Cache TTL in hours (default: 24)
"""

import os
import sys
import time

try:
    from google import genai
    from google.genai import types
except ImportError:
    print("❌ Error: google-genai not installed")
    print("   Install with: pip install google-genai")
    sys.exit(1)

# Configuration
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
MODEL_NAME = os.getenv("GEMINI_MODEL", "gemini-2.5-flash")  # Latest flash model with caching support
CACHE_TTL_HOURS = int(os.getenv("CACHE_TTL_HOURS", "24"))

SYSTEM_INSTRUCTION = """You are a Senior Software Architect with expertise in:
- Linux system security and hardening
- Bash scripting and systemd service design
- Go backend development (netlink, nftables manipulation)
- Firewall architecture (nftables/iptables)
- Privilege separation and least-privilege patterns
- Performance optimization and code quality

When analyzing code:
1. Focus on architectural patterns and design decisions
2. Identify security vulnerabilities (privilege escalation, command injection, race conditions)
3. Highlight performance bottlenecks (O(n²) algorithms, redundant I/O, lock contention)
4. Suggest refactoring to eliminate code duplication
5. Generate SEO-optimized documentation with clear examples
6. Provide specific file paths and line numbers for all findings

The provided XML bundle contains the entire NFTBan codebase.
Use the <file path="..."> tags to reference specific files in your analysis.

Always structure your responses as:
- Summary (2-3 sentences)
- Findings (with severity, file:line, and code examples)
- Recommendations (with specific fixes and estimated effort)
"""

def upload_and_cache_repo(bundle_path):
    """Upload repo bundle and create explicit cache."""
    if not GEMINI_API_KEY:
        print("❌ Error: GEMINI_API_KEY environment variable not set")
        print("   export GEMINI_API_KEY='your-api-key'")
        sys.exit(1)

    print(f"{'='*70}")
    print(f"🚀 Gemini API Upload & Cache")
    print(f"{'='*70}")
    print(f"   Bundle: {bundle_path}")
    print(f"   Model: {MODEL_NAME}")
    print(f"   Cache TTL: {CACHE_TTL_HOURS}h")
    print(f"{'='*70}\n")

    print(f"🔑 Initializing Gemini API client...")
    client = genai.Client(api_key=GEMINI_API_KEY)

    print(f"📤 Uploading {bundle_path} to Gemini Files API...")
    try:
        # New API - file must be a keyword argument
        uploaded_file = client.files.upload(file=bundle_path)
    except Exception as e:
        print(f"❌ Upload failed: {e}")
        sys.exit(1)

    print(f"   File ID: {uploaded_file.name}")
    print(f"   Size: {uploaded_file.size_bytes / 1024 / 1024:.2f} MB")

    print(f"\n⏳ Waiting for file processing...")
    start_time = time.time()
    while uploaded_file.state.name == "PROCESSING":
        elapsed = int(time.time() - start_time)
        print(f"   Status: {uploaded_file.state.name} ({elapsed}s)")
        time.sleep(2)
        uploaded_file = client.files.get(name=uploaded_file.name)

    if uploaded_file.state.name != "ACTIVE":
        print(f"❌ File upload failed: {uploaded_file.state.name}")
        sys.exit(1)

    print(f"✅ File processed in {int(time.time() - start_time)}s")

    print(f"\n💾 Creating Explicit Cache (TTL: {CACHE_TTL_HOURS}h)...")
    try:
        cache = client.caches.create(
            model=MODEL_NAME,
            config=types.CreateCachedContentConfig(
                display_name="NFTBan_Architecture_Context",
                system_instruction=SYSTEM_INSTRUCTION,
                contents=[uploaded_file],
                ttl=str(CACHE_TTL_HOURS * 60 * 60) + "s",
            )
        )
    except Exception as e:
        print(f"❌ Cache creation failed: {e}")
        sys.exit(1)

    print(f"✅ Cache created!")
    print(f"\n{'='*70}")
    print(f"📋 CACHE DETAILS")
    print(f"{'='*70}")
    print(f"   Cache ID: {cache.name}")
    print(f"   Model: {MODEL_NAME}")
    print(f"   TTL: {CACHE_TTL_HOURS} hours")
    print(f"   Expires: {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(time.time() + CACHE_TTL_HOURS * 3600))}")
    print(f"{'='*70}\n")

    # Save cache ID to file for reuse
    cache_id_file = os.path.expanduser("~/.nftban_gemini_cache_id")
    with open(cache_id_file, 'w') as f:
        f.write(cache.name)
    print(f"💾 Cache ID saved to: {cache_id_file}")
    print(f"   Use this for subsequent queries\n")

    return cache

def query_cached_repo(cache_name, question):
    """Query the cached repository context."""
    if not GEMINI_API_KEY:
        print("❌ Error: GEMINI_API_KEY environment variable not set")
        sys.exit(1)

    client = genai.Client(api_key=GEMINI_API_KEY)

    print(f"\n{'='*70}")
    print(f"🤔 QUERY")
    print(f"{'='*70}")
    print(f"{question}")
    print(f"{'='*70}\n")

    print(f"⏳ Generating response...")
    start_time = time.time()

    try:
        response = client.models.generate_content(
            model=MODEL_NAME,
            contents=question,
            config=types.GenerateContentConfig(
                cached_content=cache_name,
                temperature=0.2,  # Lower for factual analysis
            )
        )
    except Exception as e:
        print(f"❌ Query failed: {e}")
        sys.exit(1)

    elapsed = time.time() - start_time

    print(f"✅ Response generated in {elapsed:.1f}s\n")
    print(f"{'='*70}")
    print(f"📊 GEMINI ANALYSIS")
    print(f"{'='*70}\n")
    print(response.text)
    print(f"\n{'='*70}\n")

    return response.text

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 upload_and_cache.py <bundle_file>")
        print("Example: python3 upload_and_cache.py /tmp/nftban_bundle.txt")
        sys.exit(1)

    bundle_path = sys.argv[1]

    if not os.path.exists(bundle_path):
        print(f"❌ Error: Bundle file not found: {bundle_path}")
        sys.exit(1)

    # Upload and cache
    cache = upload_and_cache_repo(bundle_path)

    # Example query
    example_question = """Analyze the security architecture of NFTBan's systemd services.

Focus on:
1. Services running as root - are they justified?
2. NoNewPrivileges=false instances - are they safe?
3. ReadWritePaths for privileged services - are they minimal?
4. ProtectSystem settings - are they appropriate?

Provide specific file references and recommend fixes."""

    print(f"{'='*70}")
    print(f"🧪 RUNNING EXAMPLE QUERY")
    print(f"{'='*70}\n")

    answer = query_cached_repo(cache.name, example_question)

    print(f"\n💡 Next steps:")
    print(f"   1. Cache ID saved to ~/.nftban_gemini_cache_id")
    print(f"   2. Query using: python3 query_cache.py 'Your question'")
    print(f"   3. Cache expires in {CACHE_TTL_HOURS} hours")
