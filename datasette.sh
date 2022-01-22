dockerDatasette="datasette"

function buildDatasette() {
  docker build --tag "$dockerDatasette" --pull --file datasette.Dockerfile .
}

function datasette() {
  docker run \
    -v"$(pwd):/wd" \
    -p 8001:8001 \
    -w /wd \
    "$dockerDatasette" \
    "$@"
}

run() {
  local activity_db="garmin.db"
  local wellness_db="wellness.db"
  buildDatasette
  datasette -p 8001 -h 0.0.0.0 -i "$activity_db" "$wellness_db"  "$@"

}

run "$@"
