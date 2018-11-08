#!/bin/sh

ARG1="$1"
ARG2="$2"
ARG3="$3"

[ -z "$ARG1" ] && {
	echo "Usage: $0 <convert|start> <file1> <file2>"
	echo "       $0 <convert> <imagefile> <c64_characterfile>"
	echo "       $0 <start>"
	echo "       $0 clean"

	exit 1
}

TMPDIR='/home/bastian/ledebot'
[ -f "$TMPDIR" ] || TMPDIR='/run/shm' 

LOG="$TMPDIR/log.txt" && >"$LOG"	# new on every run
DIR_IN='inputgfx'
FILE_IN_ORIGINAL="$ARG2"
FILE_IN='image-mono.png'		# convert gfx.jpg -resize "320x200!" -monochrome image-mono.png
DIR_OUT='outputgfx'

PETSCII_DIR='c64_petscii_chars'
PETSCII_CHARACTERFILE="$ARG3"

alias explode='set -f;set +f --'

log()
{
	logger -s -- "$0: $*"
	echo "$0: $*" >>"$LOG"
}

check_deps()
{
	local path app url

	for app in dssim convert identify butteraugli; do {
		if path="$( command -v "$app" )"; then
			log "[OK] $app: using '$path'"
		else
			case "$app" in
				dssim) url="https://github.com/kornelski/dssim" ;;
				convert|identify) url="https://github.com/ImageMagick/ImageMagick" ;;
				butteraugli) url="https://github.com/google/butteraugli" ;;
			esac

			log "[ERROR] $app: missing - please adjust your path - see: '$url'"
			return 1
		fi
	} done
}

image_into_8x8tiles()
{
	local dir="$1"
	local file="$2"

	mkdir -p "$dir"
	cd "$dir" || return 1
	log "[OK] file: '$file' - will crop into 8x8 tiles in '$dir'"

	# is really fast, counter starts with 000
	convert "$file" -crop 8x8 parts-%03d.png

	log "[OK] file: '$file' - $( find . -iname 'parts-*' | wc -l ) tiles 8x8 produced"
	cd - >/dev/null || return 1
}

characterset_into_tiles()
{
	[ -f "$PETSCII_CHARACTERFILE" ] || {
		log "[ERROR] missing PETSCII characterfile"
		return 1
	}

	mkdir -p "$PETSCII_DIR"
	convert "$PETSCII_CHARACTERFILE" "$PETSCII_DIR/chars.png" || return 1
	image_into_8x8tiles "$PETSCII_DIR" "chars.png" || return 1
}

get_image_resolution()
{
	eval $( identify -format "WIDTH=%[fx:w]; HEIGTH=%[fx:h];\n" "$1" )

	export WIDTH=$WIDTH
	export HEIGTH=$HEIGTH
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

		explode $( dssim "$file1" "$file2" )

		out="$1"			# e.g. 20.497861
		export SCORE_PLAIN="$out"	#     = 20497861
		out="${out%.*}${out#*.}"
		out="$( printf '%s' "$out" | sed 's/^0*//' )"

		export SCORE="${out:-999999999}"
		# smaller = better
		# 0.000000 -> 000000 -> 0
		# 0.756651 -> 756651
		# 0.036651 -> 036651 -> 36651
	}

	F=0
	X=0
	Y=1
	for FRAME in $DIR_IN/parts-*; do {
		X=$(( X + 1 ))
		test $X -gt 40 && {
			X=1
			Y=$(( Y + 1 ))
		}

		BEST=999999999
		for FRAME_PET in chars2/parts-*; do {
			compare_pix "$FRAME" "$FRAME_PET"	# sets var $SCORE
			test "$SCORE" -lt "$BEST" && {
				BEST=$SCORE
				BEST_PLAIN=$SCORE_PLAIN
				BEST_FILE="$FRAME_PET"
				log "new BEST: $BEST/$BEST_PLAIN"
			}
		} done

		# fake it and take the original:
		# BEST_FILE="$FRAME"

		FILE_OUT="$DIR_OUT/parts-$( printf '%03i' "$F" ).png"
		F=$(( F + 1 ))

		GOOD=bad
		test "$BEST" -le 999999 && GOOD='+++'
		cp "$BEST_FILE" "$FILE_OUT"
		log "X:$X Y:$Y BEST: $BEST/$BEST_PLAIN - $GOOD = $BEST_FILE - $FILE_OUT IN: $FRAME"
	} done

}

image2monochrome320x200()
{
	local file="$1"
	local extension workfile

	if [ -e "$file" ]; then
		extension="$( echo "$file" | cut -d'.' -f2 )"
		cp "$file" "$DIR_IN/original.$extension" || return 1
		workfile="original.$extension"
	else
		log "[ERROR] missing an input image file '$file'"
		return 1
	fi
	

	cd "$DIR_IN" || return 1

	get_image_resolution "$workfile"
	log "[OK] converting '$workfile' with ${WIDTH}x${HEIGTH} to 320x200 monochrome"
	convert "$workfile" -resize "320x200!" -monochrome "$FILE_IN" || return 1
	log "[OK] converted '$file' to '$DIR_IN/$file'"

	cd - >/dev/null || return 1
}

[ "$ARG1" = 'clean' ] && {
	for OBJ in "$DIR_IN" "$DIR_OUT" "$PETSCII_DIR" "$LOG"; do {
		log "[OK] removing '$OBJ'"
		[ -e "$OBJ" ] && rm -fR "$OBJ"
	} done
	
	exit 0
}

check_deps || exit 1
image_into_8x8tiles "$DIR_IN" "$FILE_IN" || exit 1
image2monochrome320x200 "$FILE_IN_ORIGINAL" || exit 1
characterset_into_tiles || exit 1

[ "$ARG1" = 'convert' ] && {
	image2monochrome320x200 "$FILE_IN_ORIGINAL"
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
#		log "new row"
		ROW_STARTS=false
		cp -v "$FRAME" "$P1" || exit 1
		continue
	}

#	log "X-append: $FRAME - X: $X"
	convert  "$P1" "$FRAME" +append "$P2"		# horizontal: X+Y=XY
	cp "$P2" "$P1"

	test $X -eq $DEST_X && {
		cp "$P1" "$TMPDIR/tile_$( printf '%03i' "$X_TILE" ).png"
		X_TILE=$(( X_TILE + 1 ))
		Y=$(( Y + 8 ))
#		log "x: $X -> 0 - Y: $Y"
		X=0; ROW_STARTS=true
	}
} done

log "[OK] used '$DIR_IN/$FILE_IN' as source"

convert "$TMPDIR/tile_"* -append $TMPDIR/output.png		# -append = vertical
rm      "$TMPDIR/tile_"*

log "[OK] generated PETSCII-look-alike: '$TMPDIR/tileall.png'"
log "[OK] logfile: '$LOG'"
