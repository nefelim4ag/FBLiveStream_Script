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
                [ -d  /run/fbstream ] || ERRO "FBStream not running"
                for live_video_id in /run/fbstream/*/*; do
                        [ -f "$live_video_id" ] || continue
                        echo "${live_video_id}:"
                        jq . "$live_video_id"
                done
                exit 0
        ;;
        reset)
                for conf in "${CONFIGS[@]}"; do
                        {
                                source $conf
                                # Delete all live videos
                                LIVE_VIDEOS=(
                                        $(CURL_GET_W "https://graph.facebook.com/$RESOURCE_ID/live_videos?access_token=$ACCESS_TOKEN" | jq -r '.data[].id')
                                )
                                for id in "${LIVE_VIDEOS[@]}"; do
                                        CURL_DELETE_W "https://graph.facebook.com/$id"
                                done
                        }
                done
                exit 0
        ;;
        *)
                echo "help:"
                echo "  daemon - start script as a daemon"
                echo "  status - show status/info files"
                echo "  reset  - delete all live streams"
                exit 0
        ;;
esac

find /run/fbstream/ -type f -delete -cmin +120

mkdir -p /run/fbstream/

for conf in "${CONFIGS[@]}"; do
        {
                source $conf
                WORK_DIR=$(GET_MD5SUM $ACCESS_TOKEN)
                WORK_DIR="/run/fbstream/$WORK_DIR"
                mkdir -vp "$WORK_DIR"
        }
done

for conf in "${CONFIGS[@]}"; do
        {
                TMP_FILE="$(mktemp)"
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

auto_restart(){
        sleep 3600
        killall ffmpeg
}

auto_restart &

wait

exit 0

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

# Define auto cleanup on exit
cleanup(){
        CURL_POST_W "https://graph.facebook.com/$VIDEO_ID" -F "end_live_video=true" | jq .
        CURL_DELETE_W "https://graph.facebook.com/$VIDEO_ID" | jq .

        # Delete all live videos
        LIVE_VIDEOS=(
                $(curl -s -X GET "https://graph.facebook.com/$RESOURCE_ID/live_videos?access_token=$ACCESS_TOKEN" | jq -r '.data[].id')
        )
        for id in "${LIVE_VIDEOS[@]}"; do
                CURL_DELETE_W "https://graph.facebook.com/$id"
        done
}
trap cleanup SIGINT SIGTERM EXIT
