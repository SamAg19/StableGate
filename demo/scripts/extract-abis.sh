#!/bin/bash
# Run from repo root: bash demo/scripts/extract-abis.sh
set -e
OUT=out
DEST=demo/abis

mkdir -p $DEST

jq '.abi' $OUT/MembershipNFT.sol/MembershipNFT.json         > $DEST/MembershipNFT.json
jq '.abi' $OUT/LPMembershipNFT.sol/LPMembershipNFT.json     > $DEST/LPMembershipNFT.json
jq '.abi' $OUT/PermissionedCSMMHook.sol/PermissionedCSMMHook.json > $DEST/PermissionedCSMMHook.json

echo "ABIs extracted to $DEST"
