#docker-compose stop
#docker-compose down
#
#echo "Created $(docker volume create --name=sentry-clickhouse)."
#echo "Created $(docker volume create --name=sentry-data)."
#echo "Created $(docker volume create --name=sentry-kafka)."
#echo "Created $(docker volume create --name=sentry-postgres)."
#echo "Created $(docker volume create --name=sentry-redis)."
#echo "Created $(docker volume create --name=sentry-symbolicator)."
#echo "Created $(docker volume create --name=sentry-zookeeper)."

_group="▶ "
_endgroup="◀ "
source .env
cd install

dc="docker-compose --no-ansi"
dcr="$dc run --rm"



# A couple of the config files are referenced from other subscripts, so they
# get vars, while multiple subscripts call ensure_file_from_example.
function ensure_file_from_example {
  if [[ -f "$1" ]]; then
    echo "$1 already exists, skipped creation."
  else
    echo "Creating $1..."
    cp -n $(echo "$1" | sed 's/\.[^.]*$/.example&/') "$1"
    # sed from https://stackoverflow.com/a/25123013/90297
  fi
}
SENTRY_CONFIG_PY='../sentry/sentry.conf.py'
SENTRY_CONFIG_YML='../sentry/config.yml'

ensure_file_from_example $SENTRY_CONFIG_PY
ensure_file_from_example $SENTRY_CONFIG_YML
ensure_file_from_example '../symbolicator/config.yml'
ensure_file_from_example '../sentry/requirements.txt'

echo "${_group}Start generating secret key ..."

if grep -xq "system.secret-key: '!!changeme!!'" $SENTRY_CONFIG_YML ; then
  # This is to escape the secret key to be used in sed below
  # Note the need to set LC_ALL=C due to BSD tr and sed always trying to decode
  # whatever is passed to them. Kudos to https://stackoverflow.com/a/23584470/90297
  SECRET_KEY=$(export LC_ALL=C; head /dev/urandom | tr -dc "a-z0-9@#%^&*(-_=+)" | head -c 50 | sed -e 's/[\/&]/\\&/g')
  sed -i -e 's/^system.secret-key:.*$/system.secret-key: '"'$SECRET_KEY'"'/' $SENTRY_CONFIG_YML
  echo "Secret key written to $SENTRY_CONFIG_YML"
fi

echo "${_endgroup}End generating secret key .."

echo "${_group}Start replacing TSDB ..."

replace_tsdb() {
  if (
    [[ -f "$SENTRY_CONFIG_PY" ]] &&
    ! grep -xq 'SENTRY_TSDB = "sentry.tsdb.redissnuba.RedisSnubaTSDB"' "$SENTRY_CONFIG_PY"
  ); then
    # Do NOT indent the following string as it would be reflected in the end result,
    # breaking the final config file. See getsentry/onpremise#624.
    tsdb_settings="\
SENTRY_TSDB = \"sentry.tsdb.redissnuba.RedisSnubaTSDB\"

# Automatic switchover 90 days after $(date). Can be removed afterwards.
SENTRY_TSDB_OPTIONS = {\"switchover_timestamp\": $(date +%s) + (90 * 24 * 3600)}\
"

    if grep -q 'SENTRY_TSDB_OPTIONS = ' "$SENTRY_CONFIG_PY"; then
      echo "Not attempting automatic TSDB migration due to presence of SENTRY_TSDB_OPTIONS"
    else
      echo "Attempting to automatically migrate to new TSDB"
      # Escape newlines for sed
      tsdb_settings="${tsdb_settings//$'\n'/\\n}"
      cp "$SENTRY_CONFIG_PY" "$SENTRY_CONFIG_PY.bak"
      sed -i -e "s/^SENTRY_TSDB = .*$/${tsdb_settings}/g" "$SENTRY_CONFIG_PY" || true

      if grep -xq 'SENTRY_TSDB = "sentry.tsdb.redissnuba.RedisSnubaTSDB"' "$SENTRY_CONFIG_PY"; then
        echo "Migrated TSDB to Snuba. Old configuration file backed up to $SENTRY_CONFIG_PY.bak"
        return
      fi

      echo "Failed to automatically migrate TSDB. Reverting..."
      mv "$SENTRY_CONFIG_PY.bak" "$SENTRY_CONFIG_PY"
      echo "$SENTRY_CONFIG_PY restored from backup."
    fi

    echo "WARN: Your Sentry configuration uses a legacy data store for time-series data. Remove the options SENTRY_TSDB and SENTRY_TSDB_OPTIONS from $SENTRY_CONFIG_PY and add:"
    echo ""
    echo "$tsdb_settings"
    echo ""
    echo "For more information please refer to https://github.com/getsentry/onpremise/pull/430"
  fi
}

replace_tsdb

echo "${_endgroup}End replacing TSDB"

echo "${_group}Start fetching and updating Docker images ..."

# We tag locally built images with an '-onpremise-local' suffix. docker-compose
# pull tries to pull these too and shows a 404 error on the console which is
# confusing and unnecessary. To overcome this, we add the stderr>stdout
# redirection below and pass it through grep, ignoring all lines having this
# '-onpremise-local' suffix.
$dc pull

# We may not have the set image on the repo (local images) so allow fails
docker pull ${SENTRY_IMAGE} || true;

echo "${_endgroup}End fetching and updating Docker images ..."

echo "${_group}Start building and tagging Docker images ..."

echo ""
$dc build --force-rm
echo ""
echo "Docker images built."

echo "${_endgroup}End building and tagging Docker images ..."


echo "${_group}Start turning things off ..."

if [[ -n "$MINIMIZE_DOWNTIME" ]]; then
  # Stop everything but relay and nginx
  $dc rm -fsv $($dc config --services | grep -v -E '^(nginx|relay)$')
else
  # Clean up old stuff and ensure nothing is working while we install/update
  # This is for older versions of on-premise:
  $dc -p onpremise down -t $STOP_TIMEOUT --rmi local --remove-orphans
  # This is for newer versions
  $dc down -t $STOP_TIMEOUT --rmi local --remove-orphans
fi

echo "${_endgroup}End turning things off ..."


echo "${_group}Start setting up Zookeeper ..."

ZOOKEEPER_SNAPSHOT_FOLDER_EXISTS=$($dcr zookeeper bash -c 'ls 2>/dev/null -Ubad1 -- /var/lib/zookeeper/data/version-2 | wc -l | tr -d '[:space:]'')
if [[ "$ZOOKEEPER_SNAPSHOT_FOLDER_EXISTS" -eq 1 ]]; then
  ZOOKEEPER_LOG_FILE_COUNT=$($dcr zookeeper bash -c 'ls 2>/dev/null -Ubad1 -- /var/lib/zookeeper/log/version-2/* | wc -l | tr -d '[:space:]'')
  ZOOKEEPER_SNAPSHOT_FILE_COUNT=$($dcr zookeeper bash -c 'ls 2>/dev/null -Ubad1 -- /var/lib/zookeeper/data/version-2/* | wc -l | tr -d '[:space:]'')
  # This is a workaround for a ZK upgrade bug: https://issues.apache.org/jira/browse/ZOOKEEPER-3056
  cd ..
  if [[ "$ZOOKEEPER_LOG_FILE_COUNT" -gt 0 ]] && [[ "$ZOOKEEPER_SNAPSHOT_FILE_COUNT" -eq 0 ]]; then
    $dcr -v $(pwd)/zookeeper:/temp zookeeper bash -c 'cp /temp/snapshot.0 /var/lib/zookeeper/data/version-2/snapshot.0'
    $dc run -d -e ZOOKEEPER_SNAPSHOT_TRUST_EMPTY=true zookeeper
  fi
  cd install
fi

echo "${_endgroup}End setting up Zookeeper ..."


echo "${_group}Start downloading and installing wal2json ..."

FILE_TO_USE="../postgres/wal2json/wal2json.so"
ARCH=$(uname -m)
FILE_NAME="wal2json-Linux-$ARCH-glibc.so"

DOCKER_CURL="docker run --rm curlimages/curl"

if [[ $WAL2JSON_VERSION == "latest" ]]; then
    VERSION=$(
        $DOCKER_CURL https://api.github.com/repos/getsentry/wal2json/releases/latest |
        grep '"tag_name":' |
        sed -E 's/.*"([^"]+)".*/\1/'
    )

    if [[ ! $VERSION ]]; then
        echo "Cannot find wal2json latest version"
        exit 1
    fi
else
    VERSION=$WAL2JSON_VERSION
fi

mkdir -p ../postgres/wal2json
if [ ! -f "../postgres/wal2json/$VERSION/$FILE_NAME" ]; then
    mkdir -p "../postgres/wal2json/$VERSION"
    $DOCKER_CURL -L \
        "https://github.com/getsentry/wal2json/releases/download/$VERSION/$FILE_NAME" \
        > "../postgres/wal2json/$VERSION/$FILE_NAME"

    cp "../postgres/wal2json/$VERSION/$FILE_NAME" "$FILE_TO_USE"
fi

echo "${_endgroup}End downloading and installing wal2json ..."


echo "${_group}Start bootstrapping and migrating Snuba ..."

$dcr snuba-api bootstrap --no-migrate --force
$dcr snuba-api migrations migrate --force

echo "${_endgroup}End bootstrapping and migrating Snuba ..."


echo "${_group}Start creating additional Kafka topics ..."

# NOTE: This step relies on `kafka` being available from the previous `snuba-api bootstrap` step
# XXX(BYK): We cannot use auto.create.topics as Confluence and Apache hates it now (and makes it very hard to enable)
EXISTING_KAFKA_TOPICS=$($dcr kafka kafka-topics --list --bootstrap-server kafka:9092 2>/dev/null)
NEEDED_KAFKA_TOPICS="ingest-attachments ingest-transactions ingest-events"
for topic in $NEEDED_KAFKA_TOPICS; do
  if ! echo "$EXISTING_KAFKA_TOPICS" | grep -wq $topic; then
    $dcr kafka kafka-topics --create --topic $topic --bootstrap-server kafka:9092
    echo ""
  fi
done

echo "${_endgroup}End creating additional Kafka topics ..."


echo "${_group}Start ensuring proper PostgreSQL version ..."

# Very naively check whether there's an existing sentry-postgres volume and the PG version in it
if [[ -n "$(docker volume ls -q --filter name=sentry-postgres)" && "$(docker run --rm -v sentry-postgres:/db busybox cat /db/PG_VERSION 2>/dev/null)" == "9.5" ]]; then
  docker volume rm sentry-postgres-new || true
  # If this is Postgres 9.5 data, start upgrading it to 9.6 in a new volume
  docker run --rm \
  -v sentry-postgres:/var/lib/postgresql/9.5/data \
  -v sentry-postgres-new:/var/lib/postgresql/9.6/data \
  tianon/postgres-upgrade:9.5-to-9.6

  # Get rid of the old volume as we'll rename the new one to that
  docker volume rm sentry-postgres
  docker volume create --name sentry-postgres
  # There's no rename volume in Docker so copy the contents from old to new name
  # Also append the `host all all all trust` line as `tianon/postgres-upgrade:9.5-to-9.6`
  # doesn't do that automatically.
  docker run --rm -v sentry-postgres-new:/from -v sentry-postgres:/to alpine ash -c \
    "cd /from ; cp -av . /to ; echo 'host all all all trust' >> /to/pg_hba.conf"
  # Finally, remove the new old volume as we are all in sentry-postgres now
  docker volume rm sentry-postgres-new
fi

echo "${_endgroup}End ensuring proper PostgreSQL version ..."


echo "${_group}Start setting up / migrating database ..."

if [[ -n "${CI:-}" || "${SKIP_USER_PROMPT:-0}" == 1 ]]; then
  $dcr web upgrade --noinput
  echo ""
  echo "Did not prompt for user creation due to non-interactive shell."
  echo "Run the following command to create one yourself (recommended):"
  echo ""
  echo "  docker-compose run --rm web createuser"
  echo ""
else
  $dcr web upgrade
fi

echo "${_endgroup} End setting up / migrating database ..."

echo "${_group}Start migrating file storage ..."

SENTRY_DATA_NEEDS_MIGRATION=$(docker run --rm -v sentry-data:/data alpine ash -c "[ ! -d '/data/files' ] && ls -A1x /data | wc -l || true")
if [[ -n "$SENTRY_DATA_NEEDS_MIGRATION" ]]; then
  # Use the web (Sentry) image so the file owners are kept as sentry:sentry
  # The `\"` escape pattern is to make this compatible w/ Git Bash on Windows. See #329.
  $dcr --entrypoint \"/bin/bash\" web -c \
    "mkdir -p /tmp/files; mv /data/* /tmp/files/; mv /tmp/files /data/files; chown -R sentry:sentry /data"
fi

echo "${_endgroup}End migrating file storage ..."


echo "${_group}Start generating Relay credentials ..."

RELAY_CONFIG_YML="../relay/config.yml"
RELAY_CREDENTIALS_JSON="../relay/credentials.json"

ensure_file_from_example $RELAY_CONFIG_YML

if [[ ! -f "$RELAY_CREDENTIALS_JSON" ]]; then

  # We need the ugly hack below as `relay generate credentials` tries to read
  # the config and the credentials even with the `--stdout` and `--overwrite`
  # flags and then errors out when the credentials file exists but not valid
  # JSON. We hit this case as we redirect output to the same config folder,
  # creating an empty credentials file before relay runs.

  $dcr \
    --no-deps \
    --volume "$(pwd)/$RELAY_CONFIG_YML:/tmp/config.yml" \
    relay --config /tmp credentials generate --stdout \
    > "$RELAY_CREDENTIALS_JSON"

  echo "Relay credentials written to $RELAY_CREDENTIALS_JSON"
fi

echo "${_endgroup}End generating Relay credentials ..."

echo "${_group}Start setting up GeoIP integration ..."

install_geoip() {
  cd ../geoip

  local mmdb='GeoLite2-City.mmdb'
  local conf='GeoIP.conf'
  local result='Done'

  echo "Setting up IP address geolocation ..."
  if [[ ! -f "$mmdb" ]]; then
    echo -n "Installing (empty) IP address geolocation database ... "
    cp "$mmdb.empty" "$mmdb"
    echo "done."
  else
    echo "IP address geolocation database already exists."
  fi

  if [[ ! -f "$conf" ]]; then
    echo "IP address geolocation is not configured for updates."
    echo "See https://develop.sentry.dev/self-hosted/geolocation/ for instructions."
    result='Error'
  else
    echo "IP address geolocation is configured for updates."
    echo "Updating IP address geolocation database ... "
    if ! $dcr geoipupdate; then
      result='Error'
    fi
    echo "$result updating IP address geolocation database."
  fi
  echo "$result setting up IP address geolocation."

  cd ../install
}

install_geoip

echo "${_endgroup}End setting up GeoIP integration ..."

if [[ "$MINIMIZE_DOWNTIME" ]]; then
  echo "${_group}Waiting for Sentry to start ..."

  # Start the whole setup, except nginx and relay.
  $dc up -d --remove-orphans $($dc config --services | grep -v -E '^(nginx|relay)$')
  $dc exec -T nginx service nginx reload

  docker run --rm --network="${COMPOSE_PROJECT_NAME}_default" alpine ash \
    -c 'while [[ "$(wget -T 1 -q -O- http://web:9000/_health/)" != "ok" ]]; do sleep 0.5; done'

  # Make sure everything is up. This should only touch relay and nginx
  $dc up -d

  echo "${_endgroup}"
else
  echo ""
  echo "-----------------------------------------------------------------"
  echo ""
  echo "You're all done! Run the following command to get Sentry running:"
  echo ""
  echo "  docker-compose up -d"
  echo ""
  echo "-----------------------------------------------------------------"
  echo ""
fi




