#!/usr/bin/env bash

# This script is used to interact with the cloud_users table in the user database.
#
# Example interactions:
# ❯ ./scripts/cloud-user.sh find cody
#                   id                  | handle  |    name    |          created_at           |          updated_at           |       last_activity
# --------------------------------------+---------+------------+-------------------------------+-------------------------------+----------------------------
#  18007240-1050-470f-bcc8-952bebf7c3dc | ceedubs | Cody Allen | 2023-04-04 15:13:10.547683+00 | 2023-08-31 13:03:14.111335+00 | 2023-08-31 13:03:14.111335
# (1 row)
#
#
# ❯ ./scripts/cloud-user.sh check ceedubs
#                   id                  | handle  |    name    |          created_at           |          updated_at           |       last_activity
# --------------------------------------+---------+------------+-------------------------------+-------------------------------+----------------------------
#  18007240-1050-470f-bcc8-952bebf7c3dc | ceedubs | Cody Allen | 2023-04-04 15:13:10.547683+00 | 2023-08-31 13:03:14.111335+00 | 2023-08-31 13:03:14.111335
# (1 row)
#
#
# ./scripts/cloud-user.sh add ceedubs
# INSERT 0 1

set -euo pipefail

print_usage() {
  echo "Usage: $0 <cmd> <args>"
  echo "Examples:"
  echo "  $0 find cody"
  echo "  $0 check ceedubs"
  echo "  $0 add ceedubs"
  echo "  $0 session"
  echo "  $0 help"
}

if [ $# -eq 0 ]; then
  print_usage
  exit 1
fi

postgres_url() {

  export NOMAD_ADDR='http://nomad.us-west-2.unison-lang.org:4646'

  CLOUD_ENVIRONMENT=${CLOUD_ENVIRONMENT:-production}

  case "${CLOUD_ENVIRONMENT}" in
    production)
      NOMAD_JOB_NAME="cloud-api"
      NOMAD_TASK_NAME="cloud-api"
      ;;
    staging)
      NOMAD_JOB_NAME="cloud-api-staging"
      NOMAD_TASK_NAME="cloud-api-staging"
      ;;
    *)
      echo "Unknown CLOUD_ENVIRONMENT: ${CLOUD_ENVIRONMENT}"
      exit 1
      ;;
  esac
  nomad exec -task ${NOMAD_TASK_NAME} -job "${NOMAD_JOB_NAME}" /bin/sh -c "echo -n \$CLOUD_POSTGRES"
}

cmd=$1; shift

case $cmd in
    check)
        handle=$1; shift
        postgres_command="SELECT users.id, users.handle, users.name, cloud_users.created_at, cloud_users.updated_at, cloud_users.last_activity FROM users LEFT OUTER JOIN cloud_users ON users.id = cloud_users.user_id WHERE users.handle = '$handle';"
        url="$(postgres_url)"
        psql -c "$postgres_command" "$url"
        ;;
    add)
        handle=$1; shift
        postgres_command="INSERT INTO cloud_users (user_id) SELECT id FROM users WHERE users.handle='$handle';"
        url="$(postgres_url)"
        psql -c "$postgres_command" "$url"
        ;;
    find)
        partialName=$1; shift
        postgres_command="SELECT users.id, users.handle, users.name, cloud_users.created_at, cloud_users.updated_at, cloud_users.last_activity FROM users LEFT OUTER JOIN cloud_users ON users.id = cloud_users.user_id WHERE users.name ILIKE '%$partialName%' OR users.handle ILIKE '%$partialName%' OR users.id::text LIKE '%$partialName%';"
        url="$(postgres_url)"
        psql -c "$postgres_command" "$url"
        ;;
    session)
      url="$(postgres_url)"
      psql "$url"
      ;;
    help)
      print_usage
      ;;
    *)
        echo "Unknown command: $cmd"
        print_usage
        exit 1
        ;;
esac
