#!/bin/sh

[ -z "$1" ] && {
	echo "Usage: $0 --switch1 arg --switch2 arg"
	echo
	echo "switches are:"
	echo "		--action convert|clean|start"
	echo "		--crop ..."
	echo "		--logfile ..."
	echo "		--tmpdir ..."
	echo "		--cachefile ..."
	echo "		--inputfile ..."
	echo
	echo "--crop"
	echo "       gimpstyle-crop-coordinates from top leftmost to bottom-right, e.g."
	echo "       start from x=256 and y=58 with 320x200 size"
	echo "       320x200+256+58"
	echo

	exit 1
}

log()
{
	logger -s -- "$0: $*"
	echo "$0: $*" >>"$LOG"
}

uniq_id()		# monoton raising
{
	local up rest
	read -r up rest <'/proc/uptime'
	echo "${up%.*}${up#*.}"
}

### all our defaults:

SCRIPTDIR="$( cd -P -- "$( dirname -- "$0" )" && pwd -P )"
TMPDIR='/home/bastian/ledebot'
[ -d "$TMPDIR" ] || TMPDIR='/run/shm'
LOG="$TMPDIR/log.txt"

DIR_IN="inputgfx-$( uniq_id )"				# 8x8 blocks - original (but converted to monochrome)
DIR_OUT="outputgfx-$( uniq_id )"			# 8x8 blocks - petscii
FILE_IN='image-mono.png'				# convert gfx.jpg -resize "320x200!" -monochrome image-mono.png

DESTINATION="$TMPDIR/output-$( uniq_id ).png"		# resulting imaga

PETSCII_CHARACTERFILE="$SCRIPTDIR/c64_petscii_chars_all.png"
PETSCII_DIR='c64_petscii_chars'				# 8x8 blocks of all petscii-chars, generated from CHARACTERFILE

CACHEFILE="$TMPDIR/cachefile"				# see cache_add()
ACTION=


### parse arguments:

while [ -n "$1" ]; do {
	SWITCH="$1"
	SWITCH_ARG1="$2"
	shift

	case "$SWITCH" in
		'--action')
			case "$SWITCH_ARG1" in
				convert|start|clean)
					ACTION="$SWITCH_ARG1"
					shift
				;;
				*)
					log "invalid --action '$SWITCH_ARG1'"
				;;
			esac
		;;
		'--crop')
			if [ -n "$SWITCH_ARG1" ]; then
				CROP="$SWITCH_ARG1"
			else
				log "invalid --crop '$SWITCH_ARG1'"
			fi
		;;
		'--inputfile')
			if [ -s "$SWITCH_ARG1" ]; then
				FILE_IN_ORIGINAL="$SWITCH_ARG1"
				shift
			else
				log "can not read --inputfile '$SWITCH_ARG1'"
				exit 1
			fi
		;;
		'--cachefile')
			if touch "$SWITCH_ARG1"; then
				CACHEFILE="$SWITCH_ARG1"
				shift
			else
				log "can not write --cachefile to '$SWITCH_ARG1'"
				exit 1
			fi
		;;
		'--logfile')
			if touch "$SWITCH_ARG1"; then
				LOG="$SWITCH_ARG1"
				shift
			else
				log "can not write --logfile to '$SWITCH_ARG1'"
				exit 1
			fi
		;;
		'--tmpdir')
			if [ -d "$SWITCH_ARG1" ]; then
				TMPDIR="$SWITCH_ARG1"
				shift
			else
				log "bad arg for --tmpdir - dir '$SWITCH_ARG1' not found"
				exit 1
			fi
		;;
	esac
} done

[ -f "$FILE_IN_ORIGINAL" ] || exit 1
[ -z "$ACTION" ] && exit 1

true >"$LOG"		# new on every run

STRIP_METADATA='-define png:include-chunk=none'
alias explode='set -f;set +f --'

check_deps()
{
	local path app url

	# TODO: butteraugli
	for app in dssim convert identify ffmpeg; do {
		if path="$( command -v "$app" )"; then
			log "[OK] $app: using '$path'"
		else
			case "$app" in
				dssim) url="https://github.com/kornelski/dssim" ;;
				convert|identify) url="https://github.com/ImageMagick/ImageMagick" ;;
				butteraugli) url="https://github.com/google/butteraugli" ;;
				ffmpeg) url='https://johnvansickle.com/ffmpeg' ;;
			esac

			log "[ERROR] $app: missing - please adjust your path - see: '$url'"
			return 1
		fi
	} done
}

image_into_8x8tiles()
{
	local dir="$1"
	local file="$2"		# results into many: parts-xxx.png

	mkdir -p "$dir"
	cd "$dir" || return 1
	log "[OK] file: '$file' - will crop into 8x8 tiles in '$dir'"

	# is really fast, counter starts with 000
	convert $STRIP_METADATA "$file" -crop 8x8 parts-%03d.png || return 1

	log "[OK] file: '$file' - $( find . -iname 'parts-*' | wc -l ) tiles 8x8 produced"
	cd - >/dev/null || return 1
}

characterset_into_tiles()
{
	[ -f "$PETSCII_CHARACTERFILE" ] || {
		log "[ERROR] missing PETSCII characterfile: '$PETSCII_CHARACTERFILE'"
		return 1
	}

	mkdir -p "$PETSCII_DIR"
	convert $STRIP_METADATA "$PETSCII_CHARACTERFILE" "$PETSCII_DIR/chars.png" || return 1
	image_into_8x8tiles "$PETSCII_DIR" "chars.png" || return 1
}

get_image_resolution()
{
	# shellcheck disable=SC2046
	eval $( identify -format "WIDTH=%[fx:w]; HEIGTH=%[fx:h];\n" "$1" )

	export WIDTH=$WIDTH
	export HEIGTH=$HEIGTH
}

cache_add()
{
	local file="$1"
	local score="$2"
	local score_plain="$3"
	local frame_pet="$4"
	local chksum

	chksum="$( sha256sum "$file" | cut -d' ' -f1 )"

	# format:
	# filehash score_integer score_float /path/to/result-char
	# e31...806 729121 0.729121 c64_petscii_chars/parts-032.png

	echo "$chksum $score $score_plain $frame_pet" >>"$CACHEFILE"
}

pattern_cached()
{
	local file="$1"
	local line chksum

	chksum="$( sha256sum "$file" | cut -d' ' -f1 )"

	line="$( grep -s "$chksum" "$CACHEFILE" )" && {
		explode $line
		export SCORE=$2
		export SCORE_PLAIN=$3
		export FRAME_PET=$4
		log "[OK] cachehit: $FRAME_PET"
	}
}

png2petscii()
{
	mkdir -p "$DIR_OUT"

	compare_pix()
	{
		local file1="$1"
		local file2="$2"
		local out

#		local butter
#		# e.g. 74.168419
#		butter="$( butteraugli "$file1" "$file2" )"
#		[ "$butter" = '0.000000' ] || log "butter: $butter"

		# shellcheck disable=SC2046
		explode $( dssim "$file1" "$file2" )

		out="$1"			# e.g. 20.497861
		export SCORE_PLAIN="$out"	#     = 20497861
		out="${out%.*}${out#*.}"
		out="$( printf '%s' "$out" | sed 's/^0*//' )"

		export SCORE="${out:-0}"

		# smaller = better
		# 0.000000 -> 000000 -> 0
		# 0.756651 -> 756651
		# 0.036651 -> 036651 -> 36651
	}

	F=0
	X=0
	Y=1
	for FRAME in "$DIR_IN/parts-"*; do {
		X=$(( X + 1 ))
		test $X -gt 40 && {
			X=1
			Y=$(( Y + 1 ))
		}

		BEST=999999999
		for FRAME_PET in "$PETSCII_DIR/parts-"*; do {
			CACHE=
			SOLUTION_DIR="$DIR_IN/solutions/$X/$Y"

			if pattern_cached "$FRAME"; then
				CACHE='true'
				BEST=$SCORE
				BEST_PLAIN=$SCORE_PLAIN
				BEST_FILE="$FRAME_PET"

				mkdir -p "$SOLUTION_DIR/$BEST"
				cp "$BEST_FILE" "$SOLUTION_DIR/$BEST/"
				cp "$FRAME" "$SOLUTION_DIR/original.png"

				break
			else
				compare_pix "$FRAME" "$FRAME_PET"	# sets var $SCORE
				test "$SCORE" -lt "$BEST" && {
					BEST=$SCORE
					BEST_PLAIN=$SCORE_PLAIN
					BEST_FILE="$FRAME_PET"

					mkdir -p "$SOLUTION_DIR/$BEST"
					cp "$BEST_FILE" "$SOLUTION_DIR/$BEST/"
					cp "$FRAME" "$SOLUTION_DIR/original.png"

					log "new BEST: $BEST = $BEST_PLAIN - see: $SOLUTION_DIR"
				}
			fi
		} done

		[ "$CACHE" = 'true' ] || cache_add "$FRAME" "$BEST" "$BEST_PLAIN" "$BEST_FILE"

		FILE_OUT="$DIR_OUT/parts-$( printf '%03i' "$F" ).png"
		F=$(( F + 1 ))

		GOOD=bad
		test "$BEST" -le 999999 && GOOD='+++'
		cp "$BEST_FILE" "$FILE_OUT"
		log "$BEST_PLAIN -> $BEST = $GOOD X:$X Y:$Y = $BEST_FILE - $FILE_OUT IN: $FRAME"
	} done

}

image2monochrome320x200()		# TODO: no $FILE_IN and no $DIR_IN
{
	local file="$1"
	local extension workfile

	if [ -e "$file" ]; then
		extension="$( echo "$file" | cut -d'.' -f2 )"
		mkdir -p "$DIR_IN"
		log "[OK] copy '$file' to '$DIR_IN/original.$extension'"

		cp "$file" "$DIR_IN/original.$extension" || return 1

		workfile="original.$extension"
	else
		log "[ERROR] missing an input image file '$file'"
		return 1
	fi
	

	cd "$DIR_IN" || return 1

	get_image_resolution "$workfile"
	log "[OK] converting '$workfile' with ${WIDTH}x${HEIGTH} to 320x200 monochrome"

	convert $STRIP_METADATA "$workfile" -resize '320x200!' -monochrome "$FILE_IN" || return 1

	log "[OK] converted '$file' to '$DIR_IN/$file'"
	cd - >/dev/null || return 1
}

cleanup()
{
	[ -f "$CACHEFILE" ] && log "[OK] keeping cachefile: $CACHEFILE"

	for OBJ in "$DIR_IN" "$DIR_OUT" "$PETSCII_DIR" "$LOG"; do {
		log "[OK] removing '$OBJ'"
		[ -e "$OBJ" ] && rm -fR "$OBJ"
	} done
}

is_video()
{
	case "$( file --mime-type -b "$1" )" in
		'video/'*|'image/gif')
			true
		;;
		*)
			false
		;;
	esac
}

[ "$ACTION" = 'clean' ] && {
	cleanup
	exit 0
}

check_deps || exit 1


### convert video into frames and call ourselfes:

is_video "$FILE_IN_ORIGINAL" && {
	log "convert video into frames 'video-images-xxxxxx.png' in dir $PWD"
	ffmpeg -i "$FILE_IN_ORIGINAL" "video-images-%06d.png" || exit 1
	log "extracted: $( ls -1 "video-images-"* | wc -l ) images"

	[ -n "$CROP" ] && {
		log "apply crop '$CROP' to every file"
		for FILE in *".cropped.png"; do {
			[ -e "$FILE" ] && rm "$FILE"
		} done

		for FILE in "video-images-"*; do {
			convert "$FILE" -crop "$CROP" "$FILE.cropped.png" || exit 1
			mv "$FILE.cropped.png" "$FILE" || exit 1
		} done

		[ -e 'out.mp4' ] && rm 'out.mp4'
		ffmpeg -framerate 20 -pattern_type glob -i "video-images-*" -c:v libx264 -pix_fmt yuv420p 'out.mp4'
		log "[OK] please check resulting animation: '$PWD/out.mp4' and press <enter> or abort with STRG + C"
		read -r NOP && echo "$NOP"
	}

	for FILE in "video-images-"*; do {
		log "$0 --action $ACTION --inputfile '$FILE'"
		$0 --action "$ACTION" --inputfile "$FILE" || exit 1
	} done

	[ -e 'out.mp4' ] && rm 'out.mp4'
	ffmpeg -framerate 20 -pattern_type glob -i "$TMPDIR/output-*.png" -c:v libx264 -pix_fmt yuv420p 'out.mp4'
	log "[OK] please check resulting animation: '$PWD/out.mp4'"

	exit 0
}

[ "$ACTION" = 'convert' ] && {
	cleanup
	image2monochrome320x200 "$FILE_IN_ORIGINAL"
	image_into_8x8tiles "$DIR_IN" "$FILE_IN" || exit 1
	characterset_into_tiles || exit 1
	png2petscii
}

P1="$TMPDIR/pic_stitched_together.png"
P2="$TMPDIR/pic_stitched_together2.png"
X=0
Y=0
X_TILE=0
DEST_X=320
ROW_STARTS=true

for FRAME in $DIR_OUT/parts-*; do {	# append/stitch a complete x-row together
	X=$(( X + 8 ))			# and start again in next row. at the end
					# we stitch together all these rows to a picture
	[ "$ROW_STARTS" = 'true' ] && {
		ROW_STARTS=false
		cp -v "$FRAME" "$P1" || exit 1
		continue
	}

	convert $STRIP_METADATA "$P1" "$FRAME" +append "$P2"		# horizontal: X+Y=XY
	cp                "$P2" "$P1"

	test $X -eq $DEST_X && {
		cp "$P1" "$TMPDIR/tile_$( printf '%03i' "$X_TILE" ).png"
		X_TILE=$(( X_TILE + 1 ))
		Y=$(( Y + 8 ))
		X=0; ROW_STARTS=true
	}
} done

log "[OK] used '$DIR_IN/$FILE_IN' as source"

convert $STRIP_METADATA "$TMPDIR/tile_"* -append "$DESTINATION"		# -append = vertical
rm                      "$TMPDIR/tile_"*

log "[OK] generated PETSCII-look-alike: '$DESTINATION'"
log "[OK] logfile: '$LOG'"

true
