#!/usr/bin/env python3
"""
Query a cached Gemini context for NFTBan analysis.

Prerequisites:
    pip install google-genai

Usage:
    export GEMINI_API_KEY="your-api-key"
    python3 query_cache.py "Your question here"

    # Or specify cache ID explicitly:
    python3 query_cache.py --cache-id "cachedContents/abc123" "Your question"

Environment Variables:
    GEMINI_API_KEY - Your Gemini API key (required)
    GEMINI_MODEL - Model to use (default: gemini-2.0-flash-exp)
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
MODEL_NAME = os.getenv("GEMINI_MODEL", "gemini-2.0-flash-exp")

def load_cache_id():
    """Load cache ID from saved file."""
    cache_id_file = os.path.expanduser("~/.nftban_gemini_cache_id")
    if not os.path.exists(cache_id_file):
        return None

    with open(cache_id_file, 'r') as f:
        return f.read().strip()

def query_cached_repo(cache_id, question):
    """Query the cached repository context."""
    if not GEMINI_API_KEY:
        print("❌ Error: GEMINI_API_KEY environment variable not set")
        print("   export GEMINI_API_KEY='your-api-key'")
        sys.exit(1)

    client = genai.Client(api_key=GEMINI_API_KEY)

    print(f"{'='*70}")
    print(f"🤔 QUERY")
    print(f"{'='*70}")
    print(f"{question}")
    print(f"{'='*70}\n")

    print(f"📋 Using cache: {cache_id}")
    print(f"⏳ Generating response...")
    start_time = time.time()

    try:
        response = client.models.generate_content(
            model=MODEL_NAME,
            contents=question,
            config=types.GenerateContentConfig(
                cached_content=cache_id,
                temperature=0.2,  # Lower for factual analysis
            )
        )
    except Exception as e:
        print(f"❌ Query failed: {e}")
        print(f"\n💡 Possible reasons:")
        print(f"   - Cache expired (TTL exceeded)")
        print(f"   - Invalid cache ID")
        print(f"   - API key invalid")
        print(f"\n   Re-upload with: python3 upload_and_cache.py <bundle_file>")
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
    # Parse arguments
    cache_id = None
    question = None

    if "--cache-id" in sys.argv:
        idx = sys.argv.index("--cache-id")
        if idx + 2 >= len(sys.argv):
            print("Usage: python3 query_cache.py --cache-id <id> <question>")
            sys.exit(1)
        cache_id = sys.argv[idx + 1]
        question = sys.argv[idx + 2]
    elif len(sys.argv) >= 2:
        question = sys.argv[1]
        cache_id = load_cache_id()
        if not cache_id:
            print("❌ Error: No cached context found")
            print("   Upload first: python3 upload_and_cache.py <bundle_file>")
            print("   Or specify cache ID: python3 query_cache.py --cache-id <id> <question>")
            sys.exit(1)
    else:
        print("Usage: python3 query_cache.py [--cache-id <id>] <question>")
        print("\nExample queries:")
        print("  python3 query_cache.py 'Find all security vulnerabilities'")
        print("  python3 query_cache.py 'Analyze performance bottlenecks'")
        print("  python3 query_cache.py 'Generate Wiki documentation'")
        sys.exit(1)

    # Query the cache
    query_cached_repo(cache_id, question)
