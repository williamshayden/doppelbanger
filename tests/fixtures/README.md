# Generated audio fixtures

`generated-stereo-sine.mp3` is a synthetic one-second 440 Hz stereo tone. It
contains no third-party recording or musical work.

Regenerate it with FFmpeg 8 or newer:

```sh
ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=1" \
  -ac 2 -codec:a libmp3lame -b:a 128k generated-stereo-sine.mp3 -y
```
