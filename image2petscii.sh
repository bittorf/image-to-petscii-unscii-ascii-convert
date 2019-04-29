#!/bin/sh

# TODO:
# - stats
#   - wieviel verschiedene genutzte chars pro frame
#   - wieviel gesamtpunkte (ähnlichkeit) pro frame
# - HTML-Ausgabe mit jeder entscheidung
# add charset 'dirart'

show_usage_and_die()
{
	echo
	echo "Usage: $0 --switch1 arg --switch2 arg"
	echo
	echo "switches are:"
	echo "		--action convert|clean|start"
	echo "		--charset petscii_lower|petscii_upper|petscii_all"
	echo "		--crop ..."
	echo "		--logfile ..."
	echo "		--tmpdir ..."
	echo "		--cachefile ..."
	echo "		--inputfile ..."
	echo "		--algo dssim|butteraugli"
	echo "		--animation_already_unpacked"
	echo "		--myid ..."
	echo "		--logappend"
	echo "		--ignorecache"
	echo "		--debug"
	echo "		--help"
	echo
	echo "--crop"
	echo "		gimpstyle-crop-coordinates from top leftmost to bottom-right, e.g."
	echo "		start from x=256 and y=58 with 320x200 size"
	echo "		320x200+256+58"
	echo
	echo "--charset"
	echo "		lower: https://www.c64-wiki.de/wiki/Zeichen#Zeichensatz_1"
	echo "		upper: https://www.c64-wiki.de/wiki/Zeichen#Zeichensatz_2"
	echo "		all:   both are used (which is the default)"
	echo "		all:   http://sta.c64.org/cbm64pet.html"
	echo

	exit 1
}

[ -z "$1" ] && show_usage_and_die

log()
{
	local message="$1"
	local debug="$2"	# debug or 'alert'
	local txt="$0: ${debug}${debug:+|}$message"

	if [ "$debug" = 'debug' ]; then
		[ -n "$DEBUG" ] && logger -s -- "$txt"
	else
		logger -s -- "$txt"
	fi

	echo "$txt" >>"$LOG"
}

uniq_id()		# monoton raising
{
	local up rest
	read -r up rest <'/proc/uptime'
	echo "${up%.*}${up#*.}"
}

### all our defaults:

DEBUG=
SCRIPTDIR="$( cd -P -- "$( dirname -- "$0" )" && pwd -P )"
TMPDIR='/home/bastian/ledebot'
[ -d "$TMPDIR" ] || TMPDIR='/run/shm'
LOG="$TMPDIR/log.txt"

MYID="id$$"
FILE_IN='image-mono.png'				# convert gfx.jpg -resize "320x200!" -monochrome image-mono.png

CHARSET='petscii_all'
PETSCII_DIR='c64_petscii_chars'				# 8x8 blocks of all petscii-chars, generated from CHARACTERFILE

IGNORECACHE=
ALGO='dssim'
CACHEFILE=
CACHEFILE_PRE="$TMPDIR/cachefile"			# see cache_add() and pattern_cached()
ACTION=
UNPACK_ANIMATION='true'
LOGAPPEND=

### parse arguments:

while [ -n "$1" ]; do {
	SWITCH="$1"
	SWITCH_ARG1="$2"
	shift

	case "$SWITCH" in
		'--help')
			show_usage_and_die
		;;
		'--action')
			case "$SWITCH_ARG1" in
				convert|start|clean)
					ACTION="$SWITCH_ARG1"
					shift
				;;
				*)
					log "invalid --action '$SWITCH_ARG1'"
					show_usage_and_die
				;;
			esac
		;;
		'--logappend')
			LOGAPPEND='true'
		;;
		'--debug')
			DEBUG='true'
		;;
		'--ignorecache')
			IGNORECACHE='true'
		;;
		'--myid')
			case "$SWITCH_ARG1" in
				'')
					log "invalid --myid '$SWITCH_ARG1'"
					show_usage_and_die
				;;
				*)
					MYID="$SWITCH_ARG1"
					shift
				;;
			esac
		;;
		'--algo')
			case "$SWITCH_ARG1" in
				'dssim')
					ALGO='dssim'
					shift
				;;
				*)
					log "invalid --algo"
					show_usage_and_die
				;;
			esac
		;;
		'--charset')
			case "$SWITCH_ARG1" in
				'petscii_lower'|'petscii_upper'|'petscii_all')
					CHARSET="$SWITCH_ARG1"
					shift
				;;
				*)
					log "invalid --charset"
					show_usage_and_die
				;;
			esac
		;;
		'--crop')
			if [ -n "$SWITCH_ARG1" ]; then
				CROP="$SWITCH_ARG1"
				shift
			else
				log "invalid --crop '$SWITCH_ARG1'"
				show_usage_and_die
			fi
		;;
		'--animation_already_unpacked')
			UNPACK_ANIMATION=
		;;
		'--inputfile')
			if [ -s "$SWITCH_ARG1" ]; then
				FILE_IN_ORIGINAL="$SWITCH_ARG1"
				shift
			else
				log "can not read --inputfile '$SWITCH_ARG1'"
				show_usage_and_die
			fi
		;;
		'--cachefile')
			if touch "$SWITCH_ARG1"; then
				CACHEFILE="$SWITCH_ARG1"
				shift
			else
				log "can not write --cachefile to '$SWITCH_ARG1'"
				show_usage_and_die
			fi
		;;
		'--logfile')
			if touch "$SWITCH_ARG1"; then
				LOG="$SWITCH_ARG1"
				shift
			else
				log "can not write --logfile to '$SWITCH_ARG1'"
				show_usage_and_die
			fi
		;;
		'--tmpdir')
			if [ -d "$SWITCH_ARG1" ]; then
				TMPDIR="$SWITCH_ARG1"
				shift
			else
				log "bad arg for --tmpdir - dir '$SWITCH_ARG1' not found"
				show_usage_and_die
			fi
		;;
	esac
} done

[ -f "$FILE_IN_ORIGINAL" ] || show_usage_and_die
[ -z "$ACTION" ] && show_usage_and_die
[ -z "$CACHEFILE" ] && CACHEFILE="$CACHEFILE_PRE-$ALGO-$CHARSET"

# new file on every run, but not on self-call see --logappend
[ -z "$LOGAPPEND" ] && true >"$LOG"

UNIQ_ID="$( uniq_id )"
[ -n "$MYID" ] && UNIQ_ID="${MYID}_${UNIQ_ID}"

DIR_IN="$TMPDIR/inputgfx-${UNIQ_ID}"				# 8x8 blocks - original (but converted to monochrome)
DIR_OUT="$TMPDIR/outputgfx-${UNIQ_ID}"				# 8x8 blocks - petscii

DESTINATION="$TMPDIR/output-${UNIQ_ID}-${CHARSET}.png"	# resulting image
STRIP_METADATA='-define png:include-chunk=none'		# used for imagemagick/convert
alias explode='set -f;set +f --'

[ -n "$DEBUG" ] && {
	log "CACHEFILE: $CACHEFILE"
	log "FILE_IN_ORIGINAL: $FILE_IN_ORIGINAL"
	log "ACTION: $ACTION"
	log "DIR_IN: $DIR_IN"
	log "DIR_OUT: $DIR_OUT"
	log "DESTINATION: $DESTINATION"

	read -r NOP && echo "$NOP"
}

cpu_load_acceptable()
{
	local load rest i=-1

	read -r load rest </proc/loadavg

	# count cpu's, e.g. 4 -> i=3
	for _ in /sys/devices/system/cpu/cpu[0-9]*; do i=$(( i + 1 )); done

	case "$load" in
		[0-1].*)
			# always allow load of 0...1.x
			true
		;;
		[0-$i].*)
			# for e.g. 4 cpu's accept a load of 0...3.x
			true
		;;
		*)
			test "${load%.*}" -le $i
		;;
	esac
}

check_deps()
{
	local path app url

	# TODO: butteraugli

	for app in dssim convert identify ffmpeg; do {
		if path="$( command -v "$app" )"; then
			log "[OK] $app: using '$path'" debug
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
	log "[OK] file: '$file' - will crop into 8x8 tiles in '$dir'" debug

	# is really fast, counter starts with 000
	# shellcheck disable=SC2086
	convert $STRIP_METADATA "$file" -crop 8x8 parts-%03d.png || {
		log "image_into_8x8tiles() error $? - convert $STRIP_METADATA '$file' -crop 8x8 parts-%03d.png" alert
		return 1
	}

	log "[OK] file: '$file' - $( find . -iname 'parts-*' | wc -l ) tiles 8x8 produced" debug
	cd - >/dev/null || return 1
}

characterset_into_tiles()
{
	local charset="$1"
	local charfile dir

	case "$charset" in
		'petscii_lower')
			charfile="$SCRIPTDIR/c64_petscii_chars_lower.png"
		;;
		'petscii_upper')
			charfile="$SCRIPTDIR/c64_petscii_chars_upper.png"
		;;
		'petscii_all'|*)
			charfile="$SCRIPTDIR/c64_petscii_chars_all.png"
		;;
	esac

	chardir="${PETSCII_DIR}-${charset}"

	if mkdir "$chardir" 2>/dev/null; then
		[ -f "$charfile" ] || {
			log "missing PETSCII characterfile: '$charfile'" alert
			return 1
		}

		# shellcheck disable=SC2086
		convert $STRIP_METADATA "$charfile" "$chardir/chars.png" || {
			log "error $? - convert $STRIP_METADATA '$charfile' '$chardir/chars.png'" alert
			return 1	# any2png
		}

		image_into_8x8tiles "$chardir" 'chars.png' || {
			log "error $? - mage_into_8x8tiles '$chardir' chars.png" alert
			return 1
		}
	else
		# already done
		true
	fi
}

get_image_resolution()
{
	WIDTH=
	HEIGTH=

	# shellcheck disable=SC2046
	eval $( identify -format "WIDTH=%[fx:w]; HEIGTH=%[fx:h];\n" "$1" )

	export WIDTH=$WIDTH
	export HEIGTH=$HEIGTH

	test "$WIDTH" -eq "$WIDTH"
}

cache_add()
{
	local file="$1"			# e.g. cachefile-dssim-petscii_lower
	local score="$2"
	local score_plain="$3"
	local frame_pet="$4"		# full path - see png2petscii()
	local chksum

	[ -f "$file" ] || {
		log "cache_add() not a file: '$file'" alert
		return 1
	}

	[ -f "$frame_pet" ] || {
		log "cache_add() not a frame_pet: '$frame_pet'" alert
		return 1
	}

	chksum="$( sha256sum "$file" | cut -d' ' -f1 )"		# TODO: only store 8 x 8 bit = 8 HEX-Bytes = 16 chars (not 64!)

	# format:
	# filehash score_integer score_float /path/to/result-char
	# e31...806 729121 0.729121 c64_petscii_chars/parts-032.png

	echo "$chksum $score $score_plain $frame_pet" >>"$CACHEFILE"
}

pattern_cached()
{
	local file="$1"
	local line chksum

	[ -n "$IGNORECACHE" ] && return 1

	chksum="$( sha256sum "$file" | cut -d' ' -f1 )"

	line="$( grep -s "$chksum" "$CACHEFILE" )" && {
		# shellcheck disable=SC2086
		explode $line

		export SCORE="$2"
		export SCORE_PLAIN="$3"
		export FRAME_PET_CACHED="$4"

		log "[OK] cachehit: $FRAME_PET_CACHED" debug
	}
}

strip_leading_zeros()
{
	local out

	out="$( echo "$1" | sed 's/^0*//' )"
	echo "${out:-0}"
}

dec2hex()
{
	printf "%x\n" "$( strip_leading_zeros "$1" )"
}

hex2bin()
{
	local list_hex="$1"
	local hex octal

	for hex in $list_hex; do {
		octal="$( printf "%o" "0x$hex" )"
		eval printf "\\\\$octal"
	} done
}

compare_pix()
{
	local file1="$1"
	local file2="$2"
	local out

#	local butter
#	# e.g. 74.168419
#	butter="$( butteraugli "$file1" "$file2" )"
#	[ "$butter" = '0.000000' ] || log "butter: $butter"

	# shellcheck disable=SC2046
	explode $( dssim "$file1" "$file2" || {
			log "[dssim:$?] - dssim '$file1' '$file2'" alert
			echo "99.999999 $file2"
		}
	)

	out="$1"			# e.g. 20.497861
	export SCORE_PLAIN="$out"

	out="${out%.*}${out#*.}"
	out="$( strip_leading_zeros "$out" )"
	export SCORE="${out:-0}"	# e.g. 20497861

	# smaller = better
	# 0.000000 -> 000000 -> 0
	# 0.756651 -> 756651
	# 0.036651 -> 036651 -> 36651
}

png2petscii()
{
	local f=0
	local x=0
	local y=1
	local frame frame_pet file_out
	local cache solution_dir good decimal
	local best best_plain best_file

	mkdir -p "$DIR_OUT"

	for frame in "$DIR_IN/parts-"*; do {
		[ -f "$frame" ] || {
			log "png2petscii() not a frame: '$frame'" alert
			continue
		}

		x=$(( x + 1 ))
		[ $x -gt 40 ] && {
			x=1
			y=$(( y + 1 ))
		}

		best=999999999
		decimal=
		for frame_pet in "${PETSCII_DIR}-${CHARSET}/parts-"*; do {
			[ -f "$frame_pet" ] || {
				log "png2petscii() not a frame_pet: '$frame_pet'" alert
				continue
			}

			cache=
			solution_dir="$DIR_IN/solutions/$x/$y"
			# e.g. .../inputgfx-000001_3471764694/solutions/1/10/0/parts-160.png
			#                                                            ^^^ = decimal value

			if pattern_cached "$frame"; then		# sets var SCORE|SCORE_PLAIN|FRAME_PET_CACHED
				cache='true'
				best=$SCORE
				best_plain=$SCORE_PLAIN
				best_file="$FRAME_PET_CACHED"
				decimal="$( basename "$best_file" | cut -d'-' -f2 | cut -d'.' -f1 )"	# e.g. 160

				mkdir -p "$solution_dir/$best"
				cp "$best_file" "$solution_dir/$best/"
				cp "$frame" "$solution_dir/original.png"

				break
			else
				compare_pix "$frame" "$frame_pet"	# sets var SCORE|SCORE_PLAIN

				[ "$SCORE" -lt "$best" ] && {
					best=$SCORE
					best_plain=$SCORE_PLAIN
					best_file="$frame_pet"
					decimal="$( basename "$frame_pet" | cut -d'-' -f2 | cut -d'.' -f1 )"

					mkdir -p "$solution_dir/$best"
					cp "$best_file" "$solution_dir/$best/"
					cp "$frame" "$solution_dir/original.png"

					log "new BEST: $best = $best_plain - see: $solution_dir/ - frame_pet: $frame_pet decimal: $decimal"
				}
			fi
		} done

		[ "$cache" = 'true' ] || cache_add "$frame" "$best" "$best_plain" "$best_file"

		file_out="$DIR_OUT/parts-$( printf '%03i' "$f" ).png"
		f=$(( f + 1 ))

		good='bad'
		test "$best" -le 999999 && good='+++'

		[ -e "$best_file" ] && {
			cp "$best_file" "$file_out"
			dec2hex "$decimal" >"$file_out.hex"
		}

		log "${best_plain:-empty_best_plain} -> $best = $good x:$x y:$y = ${best_file:-empty_best_file} - $file_out IN: $frame" debug
	} done
}

image2monochrome320x200()		# TODO: no $FILE_IN and no $DIR_IN
{
	local file="$1"
	local extension workfile

	if [ -f "$file" ]; then
		extension="$( echo "$file" | cut -d'.' -f2 )"
		case "$extension" in
			*.tar)
				return 1
			;;
		esac

		mkdir -p "$DIR_IN"
		log "[OK] copy '$file' to '$DIR_IN/original.$extension'"

		cp "$file" "$DIR_IN/original.$extension" || {
			log "image2monochrome320x200() failed: cp '$file' '$DIR_IN/original.$extension'" alert
			return 1
		}

		workfile="original.$extension"
	else
		log "[ERROR] missing an input image file '$file'"
		return 1
	fi
	

	cd "$DIR_IN" || return 1

	get_image_resolution "$workfile" || return 1
	log "[OK] converting '$workfile' with ${WIDTH}x${HEIGTH} to 320x200 monochrome" debug

	# shellcheck disable=SC2086
	convert $STRIP_METADATA "$workfile" -resize '320x200!' -monochrome "$FILE_IN" || {
		log "image2monochrome320x200() error $? - convert $STRIP_METADATA '$workfile' -resize '320x200!' -monochrome '$FILE_IN'" alert
		return 1
	}

	log "[OK] converted '$file' to '$DIR_IN/$file'" debug
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
	if [ -n "$UNPACK_ANIMATION" ]; then
		# convert video into frames
		log "convert video into frames 'video-images-xxxxxx.png' in dir $PWD"
		ffmpeg -i "$FILE_IN_ORIGINAL" "video-images-%06d.png" || {
			log "convert-error $? - ffmpeg -i '$FILE_IN_ORIGINAL' 'video-images-%06d.png'" alert
			exit 1
		}
	else
		log "using already unpacked frames 'video-images-xxxxxx.png' in dir $PWD"
	fi

	I=0; for FILE in 'video-images-0'*; do I=$(( I + 1 )); done
	log "extracted: $I images"

	[ -n "$CROP" ] && {
		# remove old trash
		log "apply crop '$CROP' to every file"
		for FILE in *".cropped.png"; do {
			[ -e "$FILE" ] && rm "$FILE"
		} done

		# crop all images
		for FILE in "video-images-"*; do {
			convert "$FILE" -crop "$CROP" "$FILE.cropped.png" || {
				log "error $? - convert '$FILE' -crop '$CROP' $FILE.cropped.png" alert
				exit 1
			}

			mv "$FILE.cropped.png" "$FILE" || {
				log "error $? - mv '$FILE.cropped.png' '$FILE'" alert
				exit 1
			}
		} done

		# join all images to video
		[ -e 'out.mp4' ] && rm 'out.mp4'
		ffmpeg -framerate 20 -pattern_type glob -i "video-images-*" -c:v libx264 -pix_fmt yuv420p 'out.mp4'
		log "[OK] please check resulting animation: '$PWD/out.mp4' and press <enter> or abort with STRG + C"
		read -r NOP && echo "$NOP"
	}

	[ $I -gt 0 ] && {
		ANIM=1
		while [ -d "$TMPDIR/animation-$ANIM" ]; do ANIM=$(( ANIM + 1 )); done
		TMPDIR="$TMPDIR/animation-$ANIM" && mkdir "$TMPDIR"
	}

	# call outself for each file
	for FILE in 'video-images-'*; do {
		ID="$( echo "$FILE" | cut -d'-' -f3 | cut -d'.' -f1 )"	# e.g. 000123
		while ! cpu_load_acceptable; do log "no more forks:$( uptime )"; sleep 30; done

		(
			$0	--action "$ACTION" \
				--inputfile "$FILE" \
				--cachefile "$CACHEFILE" \
				--logfile "$LOG" \
				--charset "$CHARSET" \
				--tmpdir "$TMPDIR" \
				--myid "$ID" \
				--logappend $( test -n "$IGNORECACHE" && echo '--ignorecache' )
		) &

		sleep 1
	} done

	J=0
	while [ $J -lt $I ]; do {
		# e.g. /home/bastian/ledebot/output-000013_3467670820-petscii_lower.png
		J=0; for FILE in "$TMPDIR/output-"*".png"; do J=$(( J + 1 )); done
		log "waiting for jobs to finish, have $J frames but should be $I"
		sleep 10
	} done

	# join all resulting images to video
	ffmpeg -framerate 20 -pattern_type glob -i "$TMPDIR/output-*.png" -c:v libx264 -pix_fmt yuv420p "$PWD/animation-${UNIQ_ID}-${CHARSET}.mp4"
	mv "animation-${UNIQ_ID}-${CHARSET}.mp4" "$TMPDIR"
	log "[OK] please check resulting animation: '$TMPDIR/animation-${UNIQ_ID}-${CHARSET}.mp4'"

	exit 0
}

[ "$ACTION" = 'convert' ] && {
	# cleanup	# FIXME!
	image2monochrome320x200 "$FILE_IN_ORIGINAL" || exit 1
	image_into_8x8tiles "$DIR_IN" "$FILE_IN" || exit 1
	characterset_into_tiles "$CHARSET" || exit 1
	png2petscii
}

join_chars_into_frame()
{
	local x=0
	local y=0
	local x_tile=0
	local dest_x=320
	local row_starts='true'
	local frame file p1 p2 list_hex=

	p1="$TMPDIR/pic_stitched_together1-${UNIQ_ID}.png"
	p2="$TMPDIR/pic_stitched_together2-${UNIQ_ID}.png"

	for frame in "$DIR_OUT/parts-"*".png"; do {	# append/stitch a complete x-row together
		x=$(( x + 8 ))				# and start again in next row. at the end
							# we stitch together all these rows to a picture
		# written during png2petscii()
		[ -f "$frame.hex" ] && list_hex="$list_hex $( cat "$frame.hex" )"

		[ "$row_starts" = 'true' ] && {
			row_starts='false'
			cp -v "$frame" "$p1" || {
				log "error $? - cp '$frame' '$p1'" alert
				return 1
			}

			continue
		}

		# shellcheck disable=SC2086
		convert $STRIP_METADATA "$p1" "$frame" +append "$p2"		# horizontal: X+Y=XY
		cp                "$p2" "$p1"

		[ $x -eq $dest_x ] && {
			file="$TMPDIR/tile_${UNIQ_ID}_$( printf '%03i' "$x_tile" ).png"	# 0-999
			cp "$p1" "$file"

			x_tile=$(( x_tile + 1 ))
			y=$(( y + 8 ))
			x=0
			row_starts='true'
		}
	} done

	log "[OK] used '$DIR_IN/$FILE_IN' as source"

	# shellcheck disable=SC2086
	convert $STRIP_METADATA "$TMPDIR/tile_${UNIQ_ID}_"* -append "$DESTINATION"		# -append = vertical
	rm                      "$TMPDIR/tile_${UNIQ_ID}_"*
	rm "$p1" "$p2"
	rm -fR "$DIR_OUT"

	[ -n "$list_hex" ] && {
		echo          "$list_hex" >"$DESTINATION.hex"
		hex2bin       "$list_hex" >"$DESTINATION.hex.plain.bin"
		hex2bin "00 20 $list_hex" >"$DESTINATION.hex.bin"
	}

	log "[OK] generated PETSCII-look-alike-files: '$DESTINATION'*"
}

join_chars_into_frame

log "[OK] see logfile: '$LOG'"
true
