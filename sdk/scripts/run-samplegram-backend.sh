#!/bin/zsh
# Runs a second copy of the unchanged Pupille backend for SampleGram.
# Only configuration differs: SampleGram's App Attest app ID, port 8789 and its own
# database. It shares the World RP settings and the issuer key, so the same verifier
# trusts photos from both apps and can tell them apart by app ID.
set -euo pipefail

repo_root="${0:A:h:h:h}"
backend_dir="$repo_root/backend"
postgres_bin="/opt/homebrew/opt/postgresql@17/bin"
postgres_data="/opt/homebrew/var/postgresql@17"
database="pupille_samplegram"

if [[ ! -f "$backend_dir/.env.world.local" ]]; then
  print -u2 "Missing backend/.env.world.local with World RP credentials and staging token"
  exit 1
fi
if [[ ! -f "$backend_dir/.secrets/issuer.pem" ]]; then
  print -u2 "Missing backend/.secrets/issuer.pem. SampleGram must share Pupille's issuer key."
  exit 1
fi
if ! "$postgres_bin/pg_isready" -q; then
  "$postgres_bin/pg_ctl" -D "$postgres_data" -l /private/tmp/pupille-postgres.log start
fi
if ! "$postgres_bin/psql" -d "$database" -Atqc 'select 1' >/dev/null 2>&1; then
  "$postgres_bin/createdb" "$database"
fi

cd "$backend_dir"
export DATABASE_URL="postgres:///$database"
export PUPILLE_APP_ID="4397GAXGZ4.app.pupille.sample"
export PUPILLE_ISSUER_PRIVATE_KEY_PATH="$backend_dir/.secrets/issuer.pem"
export PORT=8789
[[ -f dist/src/index.js ]] || npm run build
npm run migrate
print "SampleGram backend ready on port 8789 (app ID $PUPILLE_APP_ID). Keep this terminal open."
exec node --env-file=.env.world.local dist/src/index.js
