run() {
  local db="garmin.db"

  docker run \
    -p 8001:8001 \
    -v"$(pwd):/wd" \
    -w /wd \
    datasetteproject/datasette \
    datasette -p 8001 -h 0.0.0.0 "$db" \
    --load-extension=spatialite "$@"

}

run "$@"
