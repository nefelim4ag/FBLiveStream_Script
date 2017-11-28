#!/bin/bash -e

GROUP_ID=me
TMP_FILE="$(mktemp -u)"
ACCESS_TOKEN=""

CURL_POST_W(){
        curl -s -X POST -F "access_token=$ACCESS_TOKEN" "$@"
}

CURL_POST_W "https://graph.facebook.com/$GROUP_ID/live_videos" \
        -F "title=PRON" \
        -F "stream_type=AMBIENT" \
        -F "status=UNPUBLISHED" > $TMP_FILE

cleanup(){
        CURL_POST_W "https://graph.facebook.com/$ID" -F "end_live_video=true" | jq
        rm -f $TMP_FILE
}
trap cleanup SIGINT SIGTERM EXIT


jq < $TMP_FILE
ID=$(jq .id -r < $TMP_FILE)
STREAM_URL="$(jq .stream_url -r < $TMP_FILE)"
rm -f $TMP_FILE

{
        readonly FPS=30
        readonly KEY_FRAME_AT=$(($FPS*1))
        readonly THREADS=$(nproc)
        readonly SOURCE_URL='rtsp://hostname'

        echo "---"
        echo "Source URL: $SOURCE_URL"
        echo "Target URL: $STREAM_URL"
        echo "--- START ---"
        ffmpeg  -y \
                -re  -rtsp_flags prefer_tcp  -i "$SOURCE_URL" \
                -f lavfi -i anullsrc=channel_layout=mono:sample_rate=44100 \
                -t 5400 -c:a copy -c:a aac -ac 1 -ar 44100 -b:a 16k \
                -c:v libx264 -pix_fmt yuv420p \
                -preset veryfast \
                -crf "$FPS" -r "$FPS" -g "$KEY_FRAME_AT" \
                -s 1280x720  -minrate 1024k -vb 2048k -maxrate 3072k -bufsize 8192k \
                -threads "$THREADS" \
                -f flv "${STREAM_URL}"
        echo "--- END ---"
} &

sleep 5

CURL_POST_W "https://graph.facebook.com/$ID" -F "status=LIVE_NOW" | jq

wait
#sleep 720

#killall ffmpeg

exit 0
#curl -k -X POST "https://graph.facebook.com/$ID" \
#        -F "access_token=$ACCESS_TOKEN" \
#        -F "fields=dash_preview_url" | jq
