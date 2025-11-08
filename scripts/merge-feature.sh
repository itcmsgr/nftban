#!/bin/bash
# Merge feature branch to develop
if [ -z "$1" ]; then
    echo "Usage: ./scripts/merge-feature.sh <feature-name>"
    exit 1
fi

current_branch=$(git branch --show-current)
if [ "$current_branch" != "feature/$1" ]; then
    git checkout "feature/$1"
fi

git checkout develop
git pull origin develop
git merge "feature/$1" --no-ff -m "Merge feature/$1 into develop"
git push origin develop
echo "✅ Merged feature/$1 to develop"
echo "   Delete feature branch? (y/n)"
read -r response
if [ "$response" = "y" ]; then
    git branch -d "feature/$1"
    git push origin --delete "feature/$1" || true
    echo "✅ Deleted feature/$1"
fi
