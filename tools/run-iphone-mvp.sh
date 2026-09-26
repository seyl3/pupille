#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
backend_dir="$repo_root/backend"
postgres_bin="/opt/homebrew/opt/postgresql@17/bin"
postgres_data="/opt/homebrew/var/postgresql@17"

if [[ ! -f "$backend_dir/.env.world.local" ]]; then
  print -u2 "Missing backend/.env.world.local with World RP credentials and staging token"
  exit 1
fi
if [[ ! -f "$backend_dir/.secrets/issuer.pem" ]]; then
  print -u2 "Missing backend/.secrets/issuer.pem. Keep the existing key; changing it invalidates the iPhone's pinned issuer."
  exit 1
fi
if ! "$postgres_bin/pg_isready" -q; then
  "$postgres_bin/pg_ctl" -D "$postgres_data" -l /private/tmp/pupille-postgres.log start
fi
if ! "$postgres_bin/psql" -d pupille -Atqc 'select 1' >/dev/null 2>&1; then
  "$postgres_bin/createdb" pupille
fi

cd "$backend_dir"
export DATABASE_URL="postgres:///pupille"
export PUPILLE_APP_ID="4397GAXGZ4.app.pupille.dev"
export PUPILLE_ISSUER_PRIVATE_KEY_PATH="$backend_dir/.secrets/issuer.pem"
npm run build
npm run migrate
print "Pupille backend ready on port 8787. Keep this terminal open while testing."
exec node --env-file=.env.world.local dist/src/index.js
