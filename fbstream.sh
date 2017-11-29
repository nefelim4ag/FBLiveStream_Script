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

CURL_POST_W(){   curl -s -X POST   -F "access_token=$ACCESS_TOKEN" "$@"; }
CURL_DELETE_W(){ curl -s -X DELETE -F "access_token=$ACCESS_TOKEN" "$@"; }

stream_start(){
        CONF="$1"
        . "$CONF"

        TMP_FILE="$(mktemp)"

        # Get Live URL & etc
        CURL_POST_W "https://graph.facebook.com/$RESOURCE_ID/live_videos" \
                -F "title=$STREAM_NAME" \
                -F "stream_type=AMBIENT" \
                -F "status=UNPUBLISHED" > $TMP_FILE

        jq . $TMP_FILE
        VIDEO_ID="$(jq .id -r $TMP_FILE)"
        STREAM_URL="$(jq .stream_url -r $TMP_FILE)"
        rm -f "$TMP_FILE"

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
}

# Start all streams
for conf in "${CONFIGS[@]}"; do
        stream_start "$conf"
done

systemd-notify --ready

wait

exit 0
