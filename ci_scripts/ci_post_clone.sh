#!/bin/sh
# Xcode Cloud post-clone: materialize the gitignored Secrets.xcconfig.
# The example carries real staging values (publishable by design); the prod
# key stays a placeholder here — prod credentials never live in CI.
set -e
cd "$CI_PRIMARY_REPOSITORY_PATH"
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
echo "Secrets.xcconfig written from example."
