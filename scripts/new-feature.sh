#!/bin/bash
# Create a new feature branch
if [ -z "$1" ]; then
    echo "Usage: ./scripts/new-feature.sh <feature-name>"
    exit 1
fi

git checkout develop
git pull origin develop
git checkout -b "feature/$1"
echo "✅ Created feature/$1 branch"
echo "   Work on your feature, then run: ./scripts/merge-feature.sh $1"
