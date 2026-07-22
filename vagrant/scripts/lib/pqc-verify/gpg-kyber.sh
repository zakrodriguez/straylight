GPG=/opt/gnupg-pqc/bin/gpg
HOMEDIR=/opt/gnupg-pqc/home
EMAIL=pqc@yourlab.local
if [ ! -x "$GPG" ]; then
    echo "FAIL: /opt/gnupg-pqc/bin/gpg missing — run pqc-gnupg.yml"
    exit 0
fi
if ! sudo $GPG --homedir $HOMEDIR --list-keys --with-colons $EMAIL | awk -F: '/^sub/ && $4 == "8" {found=1} END {exit !found}'; then
    echo "FAIL: no Kyber subkey for $EMAIL"
    exit 0
fi
echo "PASS: GnuPG 2.5+ with Kyber subkey present"

nonce="pqc-validate-$(date +%s)-$$"
plain=$(mktemp /tmp/gpg-pqc-validate-plain.XXXXXX)
cipher=$(mktemp /tmp/gpg-pqc-validate-cipher.XXXXXX.gpg)
echo "$nonce" > $plain
rm -f $cipher
sudo $GPG --homedir $HOMEDIR --batch --pinentry-mode loopback --passphrase '' \
    --trust-model always --no-auto-key-locate \
    -e -r $EMAIL -o $cipher $plain 2>/dev/null
if [ ! -s $cipher ]; then
    echo "FAIL: gpg encrypt produced no output"
    rm -f $plain $cipher
    exit 0
fi
decoded=$(sudo $GPG --homedir $HOMEDIR --batch --pinentry-mode loopback --passphrase '' --decrypt $cipher 2>/dev/null)
if [ "$decoded" = "$nonce" ]; then
    echo "PASS: ML-KEM encrypt -> decrypt round-trip recovered plaintext"
else
    echo "FAIL: round-trip mismatch"
fi
rm -f $plain $cipher
