#!/bin/bash
# Generates a small synthetic media library for the mock Jellyfin server (Tools/MockJellyfin/server.py).
# Every clip shows a running timecode and plays distinct tones per audio track, so engine behaviour,
# track switching, seeking and subtitles can be verified by eye and ear in the simulator.
# Requires ffmpeg with libx264/libx265 (brew install ffmpeg). Output: ~40 MB.
set -eo pipefail
OUT="${1:-$(dirname "$0")/media}"
DUR="${DURATION:-40}"
mkdir -p "$OUT/Movies" "$OUT/Shows/Test Show/Season 01" "$OUT/tmp"
FONT=""
for f in /System/Library/Fonts/Helvetica.ttc /System/Library/Fonts/Supplemental/Arial.ttf; do [ -f "$f" ] && FONT="$f" && break; done

# Sets VIDEO=(...) / VF=(...) for a synthetic test pattern. `testsrc` renders a running frame
# counter/timecode itself, so no drawtext filter (and no font) is needed.
video() { # $1 label (unused without drawtext), $2 size, $3 fps
  VIDEO=(-f lavfi -i "testsrc=size=$2:rate=$3")
  VF=()
}
tone() { TONE=(-f lavfi -i "sine=frequency=$1:sample_rate=48000"); }

srt() { # $1 file, $2 language label
  cat > "$1" <<SRT
1
00:00:01,000 --> 00:00:04,000
[$2] Untertitel eins / subtitle one

2
00:00:05,000 --> 00:00:09,000
[$2] Zweiter Untertitel mit Umlauten: äöü ß

3
00:00:12,000 --> 00:00:16,000
[$2] Dritter Untertitel — <i>kursiv</i>

4
00:00:20,000 --> 00:00:25,000
[$2] Nach dem Seek: 20 s

5
00:00:30,000 --> 00:00:35,000
[$2] Letzter Untertitel bei 30 s
SRT
}
ass() {
  cat > "$1" <<'ASS'
[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,64,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,3,1,2,40,40,60,1
Style: Top,Arial,56,&H0000FFFF,&H000000FF,&H00000000,&H80000000,-1,0,0,0,100,100,0,0,1,3,1,8,40,40,60,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,ASS default style — bottom
Dialogue: 0,0:00:06.00,0:00:10.00,Top,,0,0,0,,{\b1}ASS Top style, yellow, bold{\b0}
Dialogue: 0,0:00:12.00,0:00:17.00,Default,,0,0,0,,{\pos(300,300)}Positioned at 300,300
Dialogue: 0,0:00:21.00,0:00:26.00,Default,,0,0,0,,After seek: 21 s
ASS
}
chapters() {
  cat > "$1" <<CH
;FFMETADATA1
[CHAPTER]
TIMEBASE=1/1000
START=0
END=10000
title=Opening
[CHAPTER]
TIMEBASE=1/1000
START=10000
END=25000
title=Middle
[CHAPTER]
TIMEBASE=1/1000
START=25000
END=${DUR}000
title=Finale
CH
}

srt "$OUT/tmp/de.srt" DE; srt "$OUT/tmp/en.srt" EN; srt "$OUT/tmp/de-forced.srt" "DE forced"; ass "$OUT/tmp/en.ass"; chapters "$OUT/tmp/chapters.txt"

echo "▶ Aurora (2024) — MP4 H.264 1080p + AAC de/en + external SRT (native direct play)"
D="$OUT/Movies/Aurora (2024)"; mkdir -p "$D"
video AURORA 1920x1080 24000/1001; tone 440; T1=("${TONE[@]}"); tone 660
ffmpeg -y -hide_banner -loglevel error "${VIDEO[@]}" "${T1[@]}" "${TONE[@]}" "${VF[@]}" -t "$DUR" \
  -map 0:v -map 1:a -map 2:a -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -profile:v high -level 4.1 \
  -c:a aac -b:a 128k -ac 2 -metadata:s:a:0 language=ger -metadata:s:a:0 title="Deutsch" -metadata:s:a:1 language=eng -metadata:s:a:1 title="English" \
  -movflags +faststart "$D/Aurora (2024).mp4"
cp "$OUT/tmp/de.srt" "$D/Aurora (2024).de.srt"; cp "$OUT/tmp/en.srt" "$D/Aurora (2024).en.srt"

echo "▶ Boreal (2023) — MKV HEVC 1080p + AC3 5.1 de + AAC en + SRT forced/full + ASS + chapters (advanced direct play)"
D="$OUT/Movies/Boreal (2023)"; mkdir -p "$D"
video BOREAL 1920x1080 24; tone 440; T1=("${TONE[@]}"); tone 660
ffmpeg -y -hide_banner -loglevel error "${VIDEO[@]}" "${T1[@]}" "${TONE[@]}" -i "$OUT/tmp/de-forced.srt" -i "$OUT/tmp/de.srt" -i "$OUT/tmp/en.ass" -i "$OUT/tmp/chapters.txt" "${VF[@]}" -t "$DUR" \
  -map 0:v -map 1:a -map 2:a -map 3:s -map 4:s -map 5:s -map_metadata 6 \
  -c:v libx265 -preset veryfast -crf 26 -pix_fmt yuv420p -tag:v hvc1 -x265-params log-level=error \
  -c:a:0 ac3 -b:a:0 384k -filter:a:0 "pan=5.1|FL=c0|FR=c0|FC=c0|LFE=c0|BL=c0|BR=c0" -metadata:s:a:0 language=ger -metadata:s:a:0 title="Deutsch 5.1" \
  -c:a:1 aac -b:a:1 128k -ac:a:1 2 -metadata:s:a:1 language=eng -metadata:s:a:1 title="English" \
  -c:s:0 srt -metadata:s:s:0 language=ger -metadata:s:s:0 title="Forced" -disposition:s:0 forced \
  -c:s:1 srt -metadata:s:s:1 language=ger -metadata:s:s:1 title="Deutsch" \
  -c:s:2 ass -metadata:s:s:2 language=eng -metadata:s:s:2 title="English (ASS)" \
  "$D/Boreal (2023).mkv"

echo "▶ Cascade (2022) — MKV HEVC 720p + DTS 5.1 en + TrueHD 5.1 en + FLAC 2.0 de (advanced, local decode)"
D="$OUT/Movies/Cascade (2022)"; mkdir -p "$D"
video CASCADE 1280x720 25; tone 440; T1=("${TONE[@]}"); tone 550; T2=("${TONE[@]}"); tone 660
ffmpeg -y -hide_banner -loglevel error "${VIDEO[@]}" "${T1[@]}" "${T2[@]}" "${TONE[@]}" "${VF[@]}" -t "$DUR" \
  -map 0:v -map 1:a -map 2:a -map 3:a \
  -c:v libx265 -preset veryfast -crf 26 -pix_fmt yuv420p -tag:v hvc1 -x265-params log-level=error \
  -c:a:0 dca -strict -2 -b:a:0 768k -filter:a:0 "pan=5.1|FL=c0|FR=c0|FC=c0|LFE=c0|BL=c0|BR=c0" -metadata:s:a:0 language=eng -metadata:s:a:0 title="DTS 5.1" \
  -c:a:1 truehd -strict -2 -filter:a:1 "pan=5.1|FL=c0|FR=c0|FC=c0|LFE=c0|BL=c0|BR=c0,aformat=sample_fmts=s32" -metadata:s:a:1 language=eng -metadata:s:a:1 title="TrueHD 5.1" \
  -c:a:2 flac -ac:a:2 2 -metadata:s:a:2 language=ger -metadata:s:a:2 title="FLAC Stereo" \
  "$D/Cascade (2022).mkv"

echo "▶ Dawn HDR (2021) — MKV HEVC Main10 HDR10 + E-AC-3 5.1 de (routed to system player via server remux)"
D="$OUT/Movies/Dawn HDR (2021)"; mkdir -p "$D"
video "DAWN HDR10" 1920x1080 24000/1001; tone 440
ffmpeg -y -hide_banner -loglevel error "${VIDEO[@]}" "${TONE[@]}" "${VF[@]}" -t "$DUR" \
  -map 0:v -map 1:a \
  -c:v libx265 -preset veryfast -crf 26 -pix_fmt yuv420p10le -tag:v hvc1 \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
  -x265-params "log-level=error:hdr10=1:hdr10-opt=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400" \
  -c:a eac3 -b:a 640k -filter:a "pan=5.1|FL=c0|FR=c0|FC=c0|LFE=c0|BL=c0|BR=c0" -metadata:s:a:0 language=ger -metadata:s:a:0 title="Deutsch 5.1" \
  "$D/Dawn HDR (2021).mkv"
# What a Jellyfin remux (video copy, container → fMP4) would deliver:
ffmpeg -y -hide_banner -loglevel error -i "$D/Dawn HDR (2021).mkv" -map 0:v -map 0:a -c copy -movflags +faststart "$OUT/tmp/dawn-remux.mp4"

echo "▶ Broken (2020) — the server will refuse to stream this file (exercises the fallback chain and error UI)"
D="$OUT/Movies/Broken (2020)"; mkdir -p "$D"
cp "$OUT/Movies/Boreal (2023)/Boreal (2023).mkv" "$D/Broken (2020).mkv"

echo "▶ Test Show S01E01–E03 — episodes with intro/outro markers (E01/E02 MKV → advanced, E03 MP4 → native)"
D="$OUT/Shows/Test Show/Season 01"
for n in 1 2; do
  video "TEST SHOW E0$n" 1280x720 25; tone 440
  ffmpeg -y -hide_banner -loglevel error "${VIDEO[@]}" "${TONE[@]}" -i "$OUT/tmp/de.srt" "${VF[@]}" -t "$DUR" \
    -map 0:v -map 1:a -map 2:s -c:v libx264 -preset veryfast -crf 24 -pix_fmt yuv420p \
    -c:a aac -b:a 128k -ac 2 -metadata:s:a:0 language=ger -c:s srt -metadata:s:s:0 language=ger \
    "$D/Test Show S01E0$n.mkv"
done
video "TEST SHOW E03" 1280x720 25; tone 440
ffmpeg -y -hide_banner -loglevel error "${VIDEO[@]}" "${TONE[@]}" "${VF[@]}" -t "$DUR" \
  -map 0:v -map 1:a -c:v libx264 -preset veryfast -crf 24 -pix_fmt yuv420p -c:a aac -b:a 128k -ac 2 -metadata:s:a:0 language=ger \
  -movflags +faststart "$D/Test Show S01E03.mp4"

echo "▶ Artwork"
for name in "Aurora (2024)" "Boreal (2023)" "Cascade (2022)" "Dawn HDR (2021)" "Broken (2020)"; do
  ffmpeg -y -hide_banner -loglevel error -f lavfi -i "color=c=0x$(printf '%06x' $((RANDOM * 256 % 0xFFFFFF))):size=600x900" -frames:v 1 "$OUT/Movies/$name/poster.jpg"
  ffmpeg -y -hide_banner -loglevel error -f lavfi -i "gradients=size=1920x1080:n=3" -frames:v 1 "$OUT/Movies/$name/backdrop.jpg"
done
ffmpeg -y -hide_banner -loglevel error -f lavfi -i "color=c=0x224466:size=600x900" -frames:v 1 "$OUT/Shows/Test Show/poster.jpg"
ffmpeg -y -hide_banner -loglevel error -f lavfi -i "gradients=size=1920x1080:n=2" -frames:v 1 "$OUT/Shows/Test Show/backdrop.jpg"
for n in 1 2 3; do ffmpeg -y -hide_banner -loglevel error -f lavfi -i "color=c=0x446622:size=640x360" -frames:v 1 "$D/Test Show S01E0$n-thumb.jpg"; done
rm -f "$OUT/tmp/de.srt" "$OUT/tmp/en.srt" "$OUT/tmp/de-forced.srt" "$OUT/tmp/en.ass" "$OUT/tmp/chapters.txt"
echo "✔ media written to $OUT"; du -sh "$OUT"
