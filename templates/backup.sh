#!/bin/bash
#set -e # stop on error
# https://stackoverflow.com/questions/35800082/how-to-trap-err-when-using-set-e-in-bash
set -eE
# Abort when using unset variable
# https://www.davidpashley.com/articles/writing-robust-shell-scripts/
set -u

export PASSPHRASE=$(cat /root/duplicity-secrets/duplicity-passphrase)
export AWS_ACCESS_KEY_ID={{ duplicity_aws_access_key_id }}
export AWS_SECRET_ACCESS_KEY=$(cat /root/duplicity-secrets/aws-secret-access-key)

BACKUP_NAME={{ ansible_hostname }}
BACKUP_TARGET=boto3+s3://{{ duplicity_s3_bucket }}
DATE=$(date +'%Y-%m-%d')
POSTGRES_BACKUPS_PATH=/root/postgres-backups

# Matrix notifications
# It may be a good idea to create a bot user for this purpose:
# docker exec -it synapse register_new_matrix_user -c /etc/synapse/homeserver.yaml http://localhost:8008
# Then log in with the bot to get an access token:
# curl -L -d '{"type":"m.login.password", "user":"@foo:example.com", "password":"foo"}' "https://matrix.example.com/_matrix/client/r0/login"
# Create a room with the bot and your user in it:
# curl -L -d '{"name": "<hostname> duplicity", "invite": ["@youruser:example.com"], "is_direct": false}' "https://matrix.example.com/_matrix/client/r0/createRoom?access_token=foo"
MATRIX_API={{ duplicity_matrix_api_url }}
MATRIX_ROOM_ID={{ duplicity_matrix_room_id }}
MATRIX_TOKEN={{ duplicity_matrix_token }}

TIME_STARTED=$(systemctl show -p ExecMainStartTimestamp --value duplicity-backup.service)

notify_and_exit () {
  MESSAGE="$1
$(journalctl -b --since "$TIME_STARTED" -u duplicity-backup)"
  MESSAGE_STRINGIFIED=$(jq -nc --arg str "$MESSAGE" '$str')
  echo "Sending error notification to matrix room"
  echo $MESSAGE_STRINGIFIED
  curl --silent -L -d "{\"msgtype\": \"m.text\", \"body\": ${MESSAGE_STRINGIFIED}}" "${MATRIX_API}/rooms/${MATRIX_ROOM_ID}/send/m.room.message?access_token=${MATRIX_TOKEN}" #>/dev/null
  exit 1
}

trap 'notify_and_exit "Duplicity backup script failed on line $LINENO"' ERR

echo "Removing old database dumps on disk"
rm -rf "${POSTGRES_BACKUPS_PATH}"
mkdir -p ${POSTGRES_BACKUPS_PATH}
pushd ${POSTGRES_BACKUPS_PATH}

echo "Creating host database dump"
sudo -i -u postgres pg_dumpall | bzip2 > "${POSTGRES_BACKUPS_PATH}/${DATE}.sql.bz2"

echo "Running duplicity for backup $BACKUP_NAME on $DATE"

duplicity                                             \
  --full-if-older-than 2W                             \
  --name "${BACKUP_NAME}"                             \
  --asynchronous-upload                               \
  --s3-use-glacier                                    \
  --s3-endpoint-url "{{ duplicity_s3_endpoint_url }}" \
  --s3-region-name "{{ duplicity_s3_region_name }}"   \
  --include "${POSTGRES_BACKUPS_PATH}"                \
  --exclude '/**'                                     \
  / "${BACKUP_TARGET}"

echo "Pruning old backups"
duplicity \
  remove-all-but-n-full 2 \
  --name "${BACKUP_NAME}" \
  --force \
  --s3-endpoint-url "{{ duplicity_s3_endpoint_url }}" \
  --s3-region-name "{{ duplicity_s3_region_name }}" \
  ${BACKUP_TARGET}

popd
unset PASSPHRASE
unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY

echo "Done!"
