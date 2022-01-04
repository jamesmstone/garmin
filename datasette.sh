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
  local db="garmin.db"
  buildDatasette
  datasette -p 8001 -h 0.0.0.0 -i "$db"  "$@"

}

run "$@"
