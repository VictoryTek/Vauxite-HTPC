#!/usr/bin/env bash

set -oue pipefail

GITHUB_URL="https://github.com/bikass/kora"
if [ -z "$GITHUB_URL" ]; then
  echo "Error: GITHUB_URL is not set."
  exit 1
fi

REPO_NAME=$(basename "$GITHUB_URL" .git)
CLONE_DIR="/tmp/clone/$REPO_NAME"

echo "Preparing directory for cloning..."
mkdir -p "$CLONE_DIR"
cd "$CLONE_DIR"
echo "Directory created."

git clone "$GITHUB_URL"

echo "Repo cloned. Copying files..."

if [ -f "./$REPO_NAME/install.sh" ]; then
  chmod +x "./$REPO_NAME/install.sh"
  ./"$REPO_NAME/install.sh" -t default -c standard
else
  # Remove .github folder if it exists
  if [ -d "./$REPO_NAME/.github" ]; then
    rm -rf "./$REPO_NAME/.github"
  fi

  # Copy all subfolders (except .github) to /usr/share/icons/
  for folder in "./$REPO_NAME/"*/; do
    if [ -d "$folder" ]; then
      cp -r "$folder" /usr/share/icons/
    fi
  done
fi

echo "Folders copied. Cleaning up!"
rm -drf "$CLONE_DIR"
echo "Cloned repo deleted."

echo "Script finished. Theme installation complete."