=== idea ===
* 2018 or 2017 breakpoint/revision
* C64-X-Party 2018 erster code

=== screen ===
320x200 = 40 x 25 chars = 1000 bytes (vermutlich aber mit weniger bits moeglich)

=== titten+links kommen hier hin ===

http://widerscreen.fi/numerot/2017-1-2/unplanned-blocky-puzzles-creating-petscii-for-the-commodore-64/
http://kofler.dot.at/c64/
http://www.ponomarenko.info/tid2013.htm
https://images.guide/

=== overview ===
use a fixed set of chars and convert an
animation to it. with simple compression
we should make it to 80.000 bytes = 80 frames = 3.5 secs.


=== steps ===

* choose a frame and strip it to 320 x 200 monochrome.
  * convert image.jpg +dither -colors 1 -depth 1 image-mono.png && cp image-mono.png big.png
  * convert big.png -crop 8x8 parts-%03d.png
* generate x,y.png with 8x8
* have also all petscii chars in a raw format 8x8 -> png
  * convert big.png -crop 8x8 parts-%03d.png

* loop {
    * choose a "random" set?
    * construct new image from random set:
        * for x in 1...40; do
            for y in 1...25; do
              compare dithered with all petscii-chars and get score ->dssim|butteraugli
              remember to best 3(?) chars or choose a random out of 5 best?
          done
          done
	* compare to whole dithered picture with all variations from above
          40*25 !5 = ???
    * re-construct full picture
    * start (dssim + butteraugli) and get score for all permutations
  }

