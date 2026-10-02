#!/bin/bash
# Builds a synthetic Jellyfin library with one title per row of the PLAYBACK.md test matrix, so any
# Apple TV client (Foyer, Swiftfin, Moonfin, Streamyfin, …) can be measured against the same files.
# Every clip burns its row id into the picture, plays a distinct tone per audio track and carries
# subtitles whose text names language and format, so a screenshot tells what the client chose.
#
# Needs ffmpeg (libx264, libx265, libsvtav1), dovi_tool, mkvmerge and python3 with Pillow.
# Usage: make-matrix-media.sh [OUT]            default OUT: build/client-matrix/media
#        ROWS="M04 M05" make-matrix-media.sh    rebuild selected rows only
set -eo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/../../build/client-matrix/media}"
DUR="${DURATION:-60}"
TMP="$OUT/.tmp"
IMG="$HERE/imaging.py"
mkdir -p "$OUT/Movies" "$OUT/Shows" "$TMP"
want() { [ -z "$ROWS" ] || [[ " $ROWS " == *" $1 "* ]]; }
log() { echo "▶ $*"; }
FF=(ffmpeg -y -hide_banner -loglevel error)
X265_HDR10="hdr10=1:hdr10-opt=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400"
HDR_COLOR=(-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc)

# --- building blocks -------------------------------------------------------------------------

# clip OUT SIZE FPS PIXFMT LABEL -- VIDEO_CODEC_ARGS... -- AUDIO_SPECS... [-- SUBTITLE_SPECS...] [-- EXTRA_ARGS...]
#   audio spec:    codec|channels|lang|title|freq[|default]
#   subtitle spec: file|codec|lang|title[|forced|default]
clip() {
  local out="$1" size="$2" fps="$3" pix="$4" text="$5"; shift 5; shift # --
  local vargs=() aspecs=() sspecs=() extra=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do vargs+=("$1"); shift; done; shift || true
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do aspecs+=("$1"); shift; done; shift || true
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do sspecs+=("$1"); shift; done; shift || true
  extra=("$@")
  local w="${size%x*}" h="${size#*x}"
  python3 "$IMG" label "$TMP/label.png" "$w" "$h" "$text"
  local inputs=(-f lavfi -i "testsrc=size=$size:rate=$fps" -i "$TMP/label.png")
  local maps=(-map "[v]") codecs=() n=2 ai=0 si=0 spec
  for spec in "${aspecs[@]}"; do
    IFS='|' read -r codec ch lang title freq def <<<"$spec"
    inputs+=(-f lavfi -i "sine=frequency=$freq:sample_rate=48000")
    maps+=(-map "$n:a")
    local layout="stereo" pan=""
    [ "$ch" = 6 ] && layout="5.1" && pan="pan=5.1|FL=c0|FR=c0|FC=c0|LFE=c0|BL=c0|BR=c0,"
    [ "$ch" = 2 ] && pan="pan=stereo|FL=c0|FR=c0,"
    case "$codec" in
      truehd) codecs+=(-c:a:$ai truehd -strict -2 -filter:a:$ai "${pan}aformat=sample_fmts=s32") ;;
      dts)    codecs+=(-c:a:$ai dca -strict -2 -b:a:$ai 768k -filter:a:$ai "${pan%,}") ;;
      eac3)   codecs+=(-c:a:$ai eac3 -b:a:$ai 640k -filter:a:$ai "${pan%,}") ;;
      ac3)    codecs+=(-c:a:$ai ac3 -b:a:$ai 448k -filter:a:$ai "${pan%,}") ;;
      flac)   codecs+=(-c:a:$ai flac -filter:a:$ai "${pan%,}") ;;
      *)      codecs+=(-c:a:$ai aac -b:a:$ai 160k -filter:a:$ai "${pan%,}") ;;
    esac
    codecs+=(-metadata:s:a:$ai "language=$lang" -metadata:s:a:$ai "title=$title")
    [ "$def" = default ] && codecs+=(-disposition:a:$ai default) || codecs+=(-disposition:a:$ai 0)
    n=$((n + 1)); ai=$((ai + 1))
  done
  for spec in "${sspecs[@]}"; do
    IFS='|' read -r file scodec lang title f1 f2 <<<"$spec"
    inputs+=(-i "$file"); maps+=(-map "$n:s")
    local disp=""
    for flag in "$f1" "$f2"; do [ -n "$flag" ] && disp="${disp:+$disp+}$flag"; done
    codecs+=(-c:s:$si "$scodec" -metadata:s:s:$si "language=$lang" -metadata:s:s:$si "title=$title" -disposition:s:$si "${disp:-0}")
    n=$((n + 1)); si=$((si + 1))
  done
  # ffmpeg's experimental DTS/TrueHD encoders occasionally crash under load (bus error); retry.
  local attempt
  for attempt in 1 2 3; do
    "${FF[@]}" "${inputs[@]}" -filter_complex "[0:v][1:v]overlay=0:0,format=$pix[v]" -t "$DUR" \
      "${maps[@]}" "${vargs[@]}" "${codecs[@]}" "${extra[@]}" "$out" && return 0
    echo "  ffmpeg failed (attempt $attempt), retrying" >&2
  done
  return 1
}

poster() { # DIR ROW DESCRIPTION
  python3 "$IMG" poster "$1/poster.jpg" "$2" "$3"
}

movie_dir() { # NAME → prints dir
  local d="$OUT/Movies/$1"; mkdir -p "$d"; echo "$d"
}

# Dolby Vision: HEVC elementary stream + generated RPU → MKV (mkvmerge writes the DV configuration)
dolby_vision() { # OUT.mkv SIZE PROFILE(5|8.1) LABEL
  local out="$1" size="$2" profile="$3" text="$4" w="${2%x*}" h="${2#*x}" frames=$((DUR * 24))
  python3 "$IMG" label "$TMP/label.png" "$w" "$h" "$text"
  local xp="log-level=error"
  [ "$profile" = "8.1" ] && xp="$xp:$X265_HDR10"
  "${FF[@]}" -f lavfi -i "testsrc=size=$size:rate=24" -i "$TMP/label.png" \
    -filter_complex "[0:v][1:v]overlay=0:0,format=yuv420p10le[v]" -map "[v]" -t "$DUR" \
    -c:v libx265 -preset ultrafast -crf 30 -x265-params "$xp" -f hevc "$TMP/bl.hevc"
  cat > "$TMP/rpu.json" <<JSON
{ "cm_version": "V40", "profile": "$profile", "length": $frames,
  "level6": { "max_display_mastering_luminance": 1000, "min_display_mastering_luminance": 1,
              "max_content_light_level": 1000, "max_frame_average_light_level": 400 } }
JSON
  dovi_tool generate -j "$TMP/rpu.json" -o "$TMP/rpu.bin" >/dev/null
  dovi_tool inject-rpu -i "$TMP/bl.hevc" --rpu-in "$TMP/rpu.bin" -o "$TMP/dv.hevc" >/dev/null
  "${FF[@]}" -f lavfi -i "sine=frequency=440:sample_rate=48000" -t "$DUR" \
    -filter:a "pan=5.1|FL=c0|FR=c0|FC=c0|LFE=c0|BL=c0|BR=c0" -c:a eac3 -b:a 640k "$TMP/audio.eac3"
  mkvmerge -q -o "$out" --default-duration 0:24p "$TMP/dv.hevc" \
    --language 0:ger --track-name "0:Deutsch 5.1" "$TMP/audio.eac3"
}

# subtitle sources
cat > "$TMP/srt.tpl" <<'SRT'
1
00:00:01,000 --> 00:00:04,000
[@L@] Untertitel eins / subtitle one

2
00:00:05,000 --> 00:00:09,000
[@L@] Zweiter Untertitel mit Umlauten: äöü ß

3
00:00:20,000 --> 00:00:25,000
[@L@] Nach dem Seek: 20 s

4
00:00:40,000 --> 00:00:45,000
[@L@] Bei 40 s
SRT
for l in "DE full:de" "EN full:en" "DE FORCED:de-forced"; do sed "s/@L@/${l%%:*}/" "$TMP/srt.tpl" > "$TMP/${l##*:}.srt"; done
cat > "$TMP/de.ass" <<'ASS'
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
Dialogue: 0,0:00:01.00,0:00:09.00,Default,,0,0,0,,[DE ASS] Standardstil unten
Dialogue: 0,0:00:01.00,0:00:09.00,Top,,0,0,0,,{\b1}[DE ASS] Gelb, fett, oben{\b0}
Dialogue: 0,0:00:20.00,0:00:25.00,Default,,0,0,0,,{\pos(400,300)}[DE ASS] Positioniert bei 400,300
Dialogue: 0,0:00:40.00,0:00:45.00,Default,,0,0,0,,{\c&H0000FF&}[DE ASS] Rot bei 40 s
ASS
python3 "$IMG" pgs "$TMP/de-4k.sup" 3840 2160 DE

H264=(-c:v libx264 -preset veryfast -crf 26 -profile:v high -level 4.1)
HEVC=(-c:v libx265 -preset ultrafast -crf 30 -tag:v hvc1 -x265-params log-level=error)
HEVC_HDR10=(-c:v libx265 -preset ultrafast -crf 30 -tag:v hvc1 "${HDR_COLOR[@]}" -x265-params "log-level=error:$X265_HDR10")
AV1=(-c:v libsvtav1 -preset 12 -crf 45)

# --- rows (numbering follows PLAYBACK.md › Test matrix) --------------------------------------

if want M01; then log "M01 MP4 H.264 1080p + AAC de/en + external SRT"
  D=$(movie_dir "M01 H264 AAC extSRT (2001)")
  clip "$D/M01 H264 AAC extSRT (2001).mp4" 1920x1080 24 yuv420p "M01 · MP4 H.264 · AAC · ext. SRT" -- "${H264[@]}" -- \
    "aac|2|ger|Deutsch|440|default" "aac|2|eng|English|660" -- -- -movflags +faststart
  cp "$TMP/de.srt" "$D/M01 H264 AAC extSRT (2001).de.srt"; cp "$TMP/en.srt" "$D/M01 H264 AAC extSRT (2001).en.srt"
  poster "$D" M01 "MP4 H.264 1080p|AAC de/en|external SRT"
fi

if want M02; then log "M02 MP4 H.264 1080p + AC-3 5.1"
  D=$(movie_dir "M02 H264 AC3 (2002)")
  clip "$D/M02 H264 AC3 (2002).mp4" 1920x1080 24 yuv420p "M02 · MP4 H.264 · AC-3 5.1" -- "${H264[@]}" -- \
    "ac3|6|ger|Deutsch AC-3 5.1|440|default" -- -- -movflags +faststart
  poster "$D" M02 "MP4 H.264 1080p|AC-3 5.1"
fi

if want M03; then log "M03 MKV HEVC 4K SDR + E-AC-3 5.1"
  D=$(movie_dir "M03 HEVC 4K SDR EAC3 (2003)")
  clip "$D/M03 HEVC 4K SDR EAC3 (2003).mkv" 3840x2160 24 yuv420p "M03 · MKV HEVC 4K SDR · E-AC-3" -- "${HEVC[@]}" -- \
    "eac3|6|ger|Deutsch E-AC-3 5.1|440|default"
  poster "$D" M03 "MKV HEVC 2160p SDR|E-AC-3 5.1"
fi

if want M04; then log "M04 MKV HEVC 4K HDR10 + E-AC-3 5.1"
  D=$(movie_dir "M04 HEVC 4K HDR10 EAC3 (2004)")
  clip "$D/M04 HEVC 4K HDR10 EAC3 (2004).mkv" 3840x2160 24 yuv420p10le "M04 · MKV HEVC 4K HDR10 · E-AC-3" -- "${HEVC_HDR10[@]}" -- \
    "eac3|6|ger|Deutsch E-AC-3 5.1|440|default"
  poster "$D" M04 "MKV HEVC 2160p HDR10|E-AC-3 5.1"
fi

if want M05; then log "M05 MP4 (dvh1) Dolby Vision P8.1 4K + E-AC-3"
  D=$(movie_dir "M05 DV P8 4K MP4 (2005)")
  dolby_vision "$TMP/m05.mkv" 3840x2160 8.1 "M05 · MP4 dvh1 · Dolby Vision 8.1"
  "${FF[@]}" -i "$TMP/m05.mkv" -map 0 -c copy -tag:v dvh1 -strict unofficial -movflags +faststart "$D/M05 DV P8 4K MP4 (2005).mp4"
  poster "$D" M05 "MP4 dvh1 2160p|Dolby Vision P8.1|E-AC-3 5.1"
fi

if want M06; then log "M06 MKV Dolby Vision P5 4K + E-AC-3"
  D=$(movie_dir "M06 DV P5 4K MKV (2006)")
  dolby_vision "$D/M06 DV P5 4K MKV (2006).mkv" 3840x2160 5 "M06 · MKV · Dolby Vision P5"
  poster "$D" M06 "MKV 2160p|Dolby Vision P5|E-AC-3 5.1"
fi

if want M07; then log "M07 MKV HEVC 1080p + DTS 5.1"
  D=$(movie_dir "M07 HEVC DTS (2007)")
  clip "$D/M07 HEVC DTS (2007).mkv" 1920x1080 24 yuv420p "M07 · MKV HEVC · DTS 5.1" -- "${HEVC[@]}" -- \
    "dts|6|ger|Deutsch DTS 5.1|440|default"
  poster "$D" M07 "MKV HEVC 1080p|DTS 5.1"
fi

# M08 (DTS-HD MA) cannot be synthesised: ffmpeg only encodes the DTS core. Use a real excerpt if needed.

if want M09; then log "M09 MKV HEVC 1080p SDR + TrueHD 5.1"
  D=$(movie_dir "M09 HEVC TrueHD SDR (2009)")
  clip "$D/M09 HEVC TrueHD SDR (2009).mkv" 1920x1080 24 yuv420p "M09 · MKV HEVC SDR · TrueHD 5.1" -- "${HEVC[@]}" -- \
    "truehd|6|ger|Deutsch TrueHD 5.1|440|default"
  poster "$D" M09 "MKV HEVC 1080p SDR|TrueHD 5.1"
fi

if want M10; then log "M10 MKV HEVC 4K HDR10 + TrueHD 5.1"
  D=$(movie_dir "M10 HEVC 4K HDR10 TrueHD (2010)")
  clip "$D/M10 HEVC 4K HDR10 TrueHD (2010).mkv" 3840x2160 24 yuv420p10le "M10 · MKV HEVC 4K HDR10 · TrueHD" -- "${HEVC_HDR10[@]}" -- \
    "truehd|6|ger|Deutsch TrueHD 5.1|440|default"
  poster "$D" M10 "MKV HEVC 2160p HDR10|TrueHD 5.1"
fi

if want M11; then log "M11 MKV HEVC 1080p + AAC en + styled ASS de"
  D=$(movie_dir "M11 HEVC ASS (2011)")
  clip "$D/M11 HEVC ASS (2011).mkv" 1920x1080 24 yuv420p "M11 · MKV HEVC · ASS styled" -- "${HEVC[@]}" -- \
    "aac|2|eng|English|660|default" -- "$TMP/de.ass|ass|ger|Deutsch (ASS)|default"
  poster "$D" M11 "MKV HEVC 1080p|audio EN|ASS DE styled"
fi

if want M12; then log "M12 MKV HEVC 4K HDR10 + E-AC-3 en + PGS de"
  D=$(movie_dir "M12 HDR10 PGS (2012)")
  clip "$TMP/m12.mkv" 3840x2160 24 yuv420p10le "M12 · MKV 4K HDR10 · PGS" -- "${HEVC_HDR10[@]}" -- \
    "eac3|6|eng|English E-AC-3 5.1|660|default"
  mkvmerge -q -o "$D/M12 HDR10 PGS (2012).mkv" "$TMP/m12.mkv" --language 0:ger --track-name "0:Deutsch (PGS)" "$TMP/de-4k.sup"
  poster "$D" M12 "MKV 2160p HDR10|audio EN|PGS DE"
fi

if want M14; then log "M14 MP4 HEVC 1080p tagged hev1 + AAC"
  D=$(movie_dir "M14 HEVC hev1 MP4 (2014)")
  clip "$D/M14 HEVC hev1 MP4 (2014).mp4" 1920x1080 24 yuv420p "M14 · MP4 HEVC hev1" -- \
    -c:v libx265 -preset ultrafast -crf 30 -tag:v hev1 -x265-params log-level=error -- \
    "aac|2|ger|Deutsch|440|default" -- -- -movflags +faststart
  poster "$D" M14 "MP4 HEVC 1080p|tag hev1|AAC"
fi

if want M15; then log "M15 MKV H.264 + German/English audio + forced/full German + English subtitles"
  D=$(movie_dir "M15 Forced DE (2015)")
  clip "$D/M15 Forced DE (2015).mkv" 1920x1080 24 yuv420p "M15 · Forced DE bei deutschem Ton" -- "${H264[@]}" -- \
    "aac|2|ger|Deutsch|440|default" "aac|2|eng|English|660" -- \
    "$TMP/de-forced.srt|srt|ger|Deutsch (Forced)|forced" "$TMP/de.srt|srt|ger|Deutsch" "$TMP/en.srt|srt|eng|English"
  poster "$D" M15 "audio DE+EN|subs DE forced,|DE full, EN full"
fi

if want M16; then log "M16 MKV HEVC + TrueHD en (default) + E-AC-3 de + DTS en"
  D=$(movie_dir "M16 Multi-Audio (2016)")
  clip "$D/M16 Multi-Audio (2016).mkv" 1920x1080 24 yuv420p "M16 · TrueHD en / E-AC-3 de / DTS en" -- "${HEVC[@]}" -- \
    "truehd|6|eng|English TrueHD 5.1 (440 Hz)|440|default" "eac3|6|ger|Deutsch E-AC-3 5.1 (660 Hz)|660" "dts|6|eng|English DTS 5.1 (880 Hz)|880"
  poster "$D" M16 "3 audio tracks|expect: German E-AC-3|(660 Hz)"
fi

if want M17; then log "M17 two versions: 4K HDR10 MKV + 1080p MP4"
  D=$(movie_dir "M17 Versions (2017)")
  clip "$D/M17 Versions (2017) - 2160p HDR10.mkv" 3840x2160 24 yuv420p10le "M17 · Version 2160p HDR10 MKV" -- "${HEVC_HDR10[@]}" -- \
    "eac3|6|ger|Deutsch E-AC-3 5.1|440|default"
  clip "$D/M17 Versions (2017) - 1080p.mp4" 1920x1080 24 yuv420p "M17 · Version 1080p MP4" -- "${H264[@]}" -- \
    "aac|2|ger|Deutsch|440|default" -- -- -movflags +faststart
  poster "$D" M17 "2 versions:|2160p HDR10 MKV|1080p MP4"
fi

if want M18; then log "M18 MKV AV1 1080p + AAC"
  D=$(movie_dir "M18 AV1 1080p (2018)")
  clip "$D/M18 AV1 1080p (2018).mkv" 1920x1080 24 yuv420p "M18 · MKV AV1 1080p" -- "${AV1[@]}" -- "aac|2|ger|Deutsch|440|default"
  poster "$D" M18 "MKV AV1 1080p|AAC"
fi

if want M19; then log "M19 MKV AV1 4K + AAC"
  D=$(movie_dir "M19 AV1 4K (2019)")
  clip "$D/M19 AV1 4K (2019).mkv" 3840x2160 24 yuv420p "M19 · MKV AV1 2160p" -- "${AV1[@]}" -- "aac|2|ger|Deutsch|440|default"
  poster "$D" M19 "MKV AV1 2160p|AAC"
fi

if want M21; then log "M21 MP4 H.264 1080i (interlaced, top field first)"
  D=$(movie_dir "M21 H264 1080i MP4 (2021)")
  python3 "$IMG" label "$TMP/label.png" 1920 1080 "M21 · MP4 H.264 1080i interlaced"
  "${FF[@]}" -f lavfi -i "testsrc=size=1920x1080:rate=50" -i "$TMP/label.png" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -filter_complex "[0:v][1:v]overlay=0:0,tinterlace=mode=interleave_top,setfield=tff,format=yuv420p[v]" -t "$DUR" \
    -map "[v]" -map 2:a -c:v libx264 -preset veryfast -crf 24 -flags +ilme+ildct -x264-params tff=1 \
    -c:a aac -b:a 160k -ac 2 -metadata:s:a:0 language=ger -movflags +faststart "$D/M21 H264 1080i MP4 (2021).mp4"
  poster "$D" M21 "MP4 H.264 1080i|interlaced TFF"
fi

if want M22; then log "M22 MKV HEVC 1080p 120 fps + AAC"
  D=$(movie_dir "M22 HEVC 120fps (2022)")
  clip "$D/M22 HEVC 120fps (2022).mkv" 1920x1080 120 yuv420p "M22 · MKV HEVC 120 fps" -- "${HEVC[@]}" -- "aac|2|ger|Deutsch|440|default"
  poster "$D" M22 "MKV HEVC 1080p|120 fps"
fi

# Series for resume / skip intro / next episode. Chapters "Intro" and "Credits" let the Intro Skipper
# plugin (chapter analysis) create media segments; a real server with segments shows the skip prompts.
if want SHOW; then log "Matrix Show S01E01–E03 (90 s each, chapters Intro 5–30 s, Credits 70–90 s)"
  S="$OUT/Shows/Matrix Show"; mkdir -p "$S/Season 01"
  cat > "$TMP/chapters.txt" <<CH
;FFMETADATA1
[CHAPTER]
TIMEBASE=1/1000
START=0
END=5000
title=Cold Open
[CHAPTER]
TIMEBASE=1/1000
START=5000
END=30000
title=Intro
[CHAPTER]
TIMEBASE=1/1000
START=30000
END=70000
title=Episode
[CHAPTER]
TIMEBASE=1/1000
START=70000
END=90000
title=Credits
CH
  for n in 1 2 3; do
    ext=mkv; extra=(); [ "$n" = 3 ] && ext=mp4 && extra=(-movflags +faststart)
    python3 "$IMG" label "$TMP/label.png" 1920 1080 "Matrix Show S01E0$n · Intro 5–30 s · Credits 70–90 s"
    "${FF[@]}" -f lavfi -i "testsrc=size=1920x1080:rate=24" -i "$TMP/label.png" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
      -i "$TMP/chapters.txt" -filter_complex "[0:v][1:v]overlay=0:0,format=yuv420p[v]" -t 90 \
      -map "[v]" -map 2:a -map_chapters 3 "${H264[@]}" -c:a aac -b:a 160k -ac 2 -metadata:s:a:0 language=ger "${extra[@]}" \
      "$S/Season 01/Matrix Show S01E0$n.$ext"
  done
  python3 "$IMG" poster "$S/poster.jpg" SHOW "3 episodes|Intro 5–30 s|Credits 70–90 s"
fi

rm -rf "$TMP"
echo "✔ media written to $OUT"; du -sh "$OUT"
