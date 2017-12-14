# FBLiveStream
Simple bash script to 24h FB streaming

Use curl to work with FB API, work's with general FB & FB Workplace

Script doing auto restart every hour to pick up possible lose source

If all source faults -> ffmpeg will aborts -> if all source aborted -> script doing auto restart


# Installation

```
git clone https://github.com/Nefelim4ag/FBLiveStream_Script.git
cd FBLiveStream_Script
make install
systemctl enable fbstream
```

# Configuration
See /etc/fbstream/

All working config files must be named like *.conf
