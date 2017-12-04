#!/bin/bash

INFO(){ echo "INFO: $*"; }
ERRO(){ echo "ERRO: $*"; exit 1; }

export VIDEO_ID
export STREAM_URL
export RESOURCE_ID
export TMP_FILE
export ACCESS_TOKEN

export THREADS
export SOURCE_URL
export STREAM_URL

# Check basic binaries
for cmd in curl jq ffmpeg; do
        command -v $cmd &> /dev/null || ERRO "Missing $cmd"
done

[ -d "/etc/fbstream" ] || ERRO "Missing: /etc/fbstream"

CONFIGS=(
        $(find /etc/fbstream -type f -name "*.conf")
)

for conf in "${CONFIGS[@]}"; do
        INFO "Find conf: $conf"
done

GET_MD5SUM(){ echo "$@" | md5sum | cut -d ' ' -f1; }

CURL_GET_W(){    curl -s -X GET "$@"; }
CURL_POST_W(){   curl -s -X POST   -F "access_token=$ACCESS_TOKEN" "$@"; }
CURL_DELETE_W(){ curl -s -X DELETE -F "access_token=$ACCESS_TOKEN" "$@"; }

case "$1" in
        daemon)
                [ -z $NOTIFY_SOCKET ] && ERRO "Must be runned as systemd service"
        ;;
        status)
                [ -d  /run/fbstream ] && grep -R . /run/fbstream
                exit 0
        ;;
        *)
                echo "help:"
                echo "  daemon"
                echo "  status"
                exit 0
        ;;
esac

mkdir -p /run/fbstream/

for conf in "${CONFIGS[@]}"; do
        {
                source $conf
                WORK_DIR=$(GET_MD5SUM $ACCESS_TOKEN)
                WORK_DIR="/run/fbstream/$WORK_DIR"
                mkdir -vp "$WORK_DIR"
        }
done

TMP_FILE="$(mktemp)"

for conf in "${CONFIGS[@]}"; do
        {
                source $conf

                WORK_DIR=$(GET_MD5SUM $ACCESS_TOKEN)
                WORK_DIR="/run/fbstream/$WORK_DIR"

                CURL_GET_W "https://graph.facebook.com/me/live_videos?access_token=$ACCESS_TOKEN" | jq . > "$TMP_FILE"

                LIVE_STREAM_COUNT=$(grep -c stream_url "$TMP_FILE")

                if ((LIVE_STREAM_COUNT > 0)); then
                        LIVE_STREAM_COUNT=$((LIVE_STREAM_COUNT - 1))
                        for i in $(seq 0 $LIVE_STREAM_COUNT); do
                                ID="$(cat $TMP_FILE | jq .data[$i].id -r)"
                                [ "$ID" == "null" ] && continue

                                cat $TMP_FILE | jq .data[$i] -r > "$WORK_DIR/$ID"
                                TITLE="$(jq .title $WORK_DIR/$ID)"
                                STATUS="$(jq .status $WORK_DIR/$ID)"
                                INFO "Found existing live stream: $TITLE | $ID | $STATUS"
                        done

                        INFO "Try GC Old Streams"
                        for ID in $WORK_DIR/*; do
                                [ -f  "$ID" ] || continue
                                TITLE="$(jq .title $ID)"
                                grep -R "$TITLE" $WORK_DIR | cut -d':' -f1 | head -n -1 | \
                                while read -r path; do
                                        ID="$(basename $path)"
                                        INFO "Delete live video: ID"
                                        CURL_DELETE_W "https://graph.facebook.com/$ID" | jq .
                                        rm -v "$path"
                                done
                        done
                fi
        }
done

stream_start(){
        CONF="$1"
        source "$CONF"

        [ -z "$ACCESS_TOKEN" ] && ERRO "ACCESS_TOKEN can't be empty"

        WORK_DIR=$(GET_MD5SUM $ACCESS_TOKEN)
        WORK_DIR="/run/fbstream/$WORK_DIR"

        USE_STREAM=""

        for stream in $WORK_DIR/*; do
                [ -f "$stream" ] || continue
                if grep -q "$STREAM_NAME" "$stream"; then
                        INFO "Use existing: $stream"
                        USE_STREAM="$stream"
                        break;
                fi
        done

        TMP_FILE="$(mktemp)"
        MD5=$(GET_MD5SUM ${STREAM_NAME} ${ACCESS_TOKEN})
        RUN_FILE="/run/fbstream/${MD5}"
        touch "$RUN_FILE"

        if [ -z "$USE_STREAM" ]; then
                # Get Live URL & etc
                CURL_POST_W "https://graph.facebook.com/$RESOURCE_ID/live_videos" \
                        -F "title=$STREAM_NAME" \
                        -F "stream_type=AMBIENT" \
                        -F "status=UNPUBLISHED" > $TMP_FILE
        else
                cat "$USE_STREAM" > "$TMP_FILE"
        fi

        jq . $TMP_FILE
        VIDEO_ID="$(jq .id -r $TMP_FILE)"
        STREAM_URL="$(jq .stream_url -r $TMP_FILE)"
        rm -f "$TMP_FILE"

        {
                echo ACCESS_TOKEN="$ACCESS_TOKEN"
                echo STREAM_NAME="$STREAM_NAME"
                echo VIDEO_ID="$VIDEO_ID"
                echo STREAM_URL="$STREAM_URL"
        } > "$RUN_FILE"

        {
                INFO "--- START ---"
                INFO "Source URL: $SOURCE_URL"
                INFO "Target URL: $STREAM_URL"
                run_stream "$SOURCE_URL" "$STREAM_URL"
                echo "--- END ---"
        } &

        # Mark stream as Active
        sleep 3
        CURL_POST_W "https://graph.facebook.com/$VIDEO_ID" -F "status=LIVE_NOW" | jq .

        wait
}

# Start all streams
for conf in "${CONFIGS[@]}"; do
        stream_start "$conf" &
        sleep 3
done

systemd-notify --ready

post_checker(){
        while :; do
                for conf in "${CONFIGS[@]}"; do
                        sleep 5
                        source "$conf"
                        POSTS=(
                                $(curl -s -X GET "https://graph.facebook.com/$RESOURCE_ID/feed?access_token=$ACCESS_TOKEN" | jq -r '.data[].id')
                        )
                        if (( ${#POSTS[@]} == 0 )); then
                                killall ffmpeg
                                exit 0
                        fi
                done
                sleep 30
        done
}

post_checker &

wait

exit 0

# Define auto cleanup on exit
cleanup(){
        CURL_POST_W "https://graph.facebook.com/$VIDEO_ID" -F "end_live_video=true" | jq .
        CURL_DELETE_W "https://graph.facebook.com/$VIDEO_ID" | jq .

        # Delete all posts
        LIVE_VIDEOS=(
                $(curl -s -X GET "https://graph.facebook.com/$RESOURCE_ID/live_videos?access_token=$ACCESS_TOKEN" | jq -r '.data[].id')
        )
        for id in "${LIVE_VIDEOS[@]}"; do
                CURL_DELETE_W "https://graph.facebook.com/$id"
        done
}
trap cleanup SIGINT SIGTERM EXIT
