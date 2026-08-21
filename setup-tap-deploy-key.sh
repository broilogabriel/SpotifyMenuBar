#!/bin/bash
# Provisions the homebrew-tap deploy key used by .github/workflows/release.yml.
#
# The private key is generated inside 1Password and never touches this disk: it
# goes from the vault into the GitHub secret over stdin, inside `op run` so the
# value is masked if anything echoes it. Re-run this to rotate.
set -euo pipefail

ITEM="SpotifyMenuBar homebrew-tap deploy key"
APP_REPO="broilogabriel/SpotifyMenuBar"
TAP_REPO="broilogabriel/homebrew-tap"
SECRET="TAP_DEPLOY_KEY"
VAULT="${OP_VAULT:-}"

if ! op whoami >/dev/null 2>&1; then
    echo "op is not signed in. Run 'op signin', then re-run this script." >&2
    exit 1
fi

if [ -z "${VAULT}" ]; then
    echo "Set OP_VAULT to the vault this key should live in. Available:" >&2
    op vault list >&2
    exit 1
fi

echo "[1/4] SSH key item in 1Password (vault: ${VAULT})..."
if op item get "${ITEM}" --vault "${VAULT}" >/dev/null 2>&1; then
    echo "      item already exists, reusing it"
else
    # --ssh-generate-key makes 1Password generate the pair. Nothing is written
    # here, so there is no local file to forget about deleting.
    op item create --category "SSH Key" --title "${ITEM}" \
        --vault "${VAULT}" --ssh-generate-key >/dev/null
    echo "      generated a new Ed25519 pair in the vault"
fi

echo "[2/4] Registering the public half as a write-enabled deploy key..."
# A public key is not a credential, so argv is fine for it.
PUBKEY="$(op read "op://${VAULT}/${ITEM}/public key")"
if gh repo deploy-key list --repo "${TAP_REPO}" 2>/dev/null | grep -qF "${ITEM}"; then
    echo "      deploy key already present, skipping"
else
    gh api "repos/${TAP_REPO}/keys" \
        -f "key=${PUBKEY}" \
        -f "title=${ITEM}" \
        -F "read_only=false" >/dev/null
    echo "      added"
fi

echo "[3/4] Copying the private half into the ${SECRET} secret..."
# Never argv (visible in ps), never a file. `op run` masks the value in output.
KEY="op://${VAULT}/${ITEM}/private key?ssh-format=openssh" \
op run -- sh -c '
    case "${KEY}" in
        "-----BEGIN OPENSSH PRIVATE KEY-----"*) : ;;
        *)
            echo "      private key is not in OpenSSH format -- refusing to upload" >&2
            echo "      check the ?ssh-format=openssh reference on this item" >&2
            exit 1
            ;;
    esac
    printf "%s\n" "${KEY}" | gh secret set '"${SECRET}"' --repo '"${APP_REPO}"'
'
echo "      set"

echo "[4/4] Verifying..."
gh secret list --repo "${APP_REPO}" | grep -F "${SECRET}"
gh repo deploy-key list --repo "${TAP_REPO}"

cat <<MSG

Done. The private key exists in 1Password and in the GitHub secret, and nowhere
on this machine.

Rotate by deleting the item's key in 1Password and re-running this script, then
removing the stale deploy key from ${TAP_REPO}.

Caveat: GitHub attributes a deploy key to the token that created it. If you
de-authorize this gh token, the deploy key goes with it and releases will start
failing with an SSH permission error. Re-run this script to fix that.
MSG
