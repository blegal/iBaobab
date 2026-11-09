#!/bin/zsh
# Crée, une seule fois, un certificat de signature personnel « iBaobab Local » dans le trousseau de session.
# build.sh signe ensuite chaque build avec lui : la signature reste la même d'un build à l'autre,
# et macOS garde les autorisations accordées (Documents, Bureau, disques, automatisation…)
# au lieu de les redemander après chaque compilation.
#
# Le certificat ne sert que sur ce Mac : il ne remplace pas un certificat Apple Developer
# (les autres Mac affichent toujours l'avertissement de première ouverture).
# Pour l'enlever : Trousseaux d'accès › session › Mes certificats › « iBaobab Local » › Supprimer.
set -euo pipefail
NAME=${1:-iBaobab Local}
KEYCHAIN=$HOME/Library/Keychains/login.keychain-db

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Le certificat « $NAME » existe déjà."
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
# LibreSSL du système : son PKCS#12 est lisible par « security import », celui d'OpenSSL 3+ pas toujours.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -passout "pass:$PASS" -out "$WORK/identity.p12"
# -T : codesign peut utiliser la clé sans demander l'autorisation à chaque build.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Certificat « $NAME » créé. Les prochains ./build.sh l'utiliseront."
echo "Au premier lancement du nouveau build, macOS redemande une dernière fois chaque autorisation."
