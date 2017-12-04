#!/bin/bash -e

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

CONFIGS=(
        $(find /etc/fbstream -type f -name "*.conf")
)

for conf in "${CONFIGS[@]}"; do
        INFO "Find conf: $conf"
done

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

CURL_POST_W(){   curl -s -X POST   -F "access_token=$ACCESS_TOKEN" "$@"; }
CURL_DELETE_W(){ curl -s -X DELETE -F "access_token=$ACCESS_TOKEN" "$@"; }

stream_start(){
        CONF="$1"
        source "$CONF"

        [ -z "$ACCESS_TOKEN" ] && ERRO "ACCESS_TOKEN can't be empty"

        RUN_FILE="/run/fbstream/${STREAM_NAME}_${ACCESS_TOKEN}"

        # Get Live URL & etc
        CURL_POST_W "https://graph.facebook.com/$RESOURCE_ID/live_videos" \
                -F "title=$STREAM_NAME" \
                -F "stream_type=AMBIENT" \
                -F "status=UNPUBLISHED" > $TMP_FILE

        jq . $TMP_FILE
        VIDEO_ID="$(jq .id -r $TMP_FILE)"
        STREAM_URL="$(jq .stream_url -r $TMP_FILE)"
        rm -f "$TMP_FILE"

        {
                echo ACCESS_TOKEN="$ACCESS_TOKEN"
                echo STREAM_NAME="$STREAM_NAME"
                echo VIDEO_ID="$VIDEO_ID"
                echo STREAM_URL="$STREAM_URL"
        } > $RUN_FILE

        # Define auto cleanup on exit
        cleanup(){
                CURL_POST_W "https://graph.facebook.com/$VIDEO_ID" -F "end_live_video=true" | jq .
                CURL_DELETE_W "https://graph.facebook.com/$VIDEO_ID" | jq .

                # Delete all posts
                POSTS=(
                        $(curl -s -X GET "https://graph.facebook.com/$RESOURCE_ID/feed?access_token=$ACCESS_TOKEN" | jq -r '.data[].id')
                )
                for id in "${POSTS[@]}"; do
                        CURL_DELETE_W "https://graph.facebook.com/$id"
                done
        }
        trap cleanup SIGINT SIGTERM EXIT

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
