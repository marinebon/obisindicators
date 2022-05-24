#!/bin/bash
# This script uses imageMagick's `convert` utility to create an animated .gif from the png outputs 
# of the timeseries subset vignette.
# === add text to the png images
convert dgGEO_to_SEQNUM-1.png -gravity North -pointsize 30 -annotate +0+120 '1960/1969' dgGEO_to_SEQNUM-01.png
convert dgGEO_to_SEQNUM-2.png -gravity North -pointsize 30 -annotate +0+120 '1970/1979' dgGEO_to_SEQNUM-02.png
convert dgGEO_to_SEQNUM-3.png -gravity North -pointsize 30 -annotate +0+120 '1980/1989' dgGEO_to_SEQNUM-03.png
convert dgGEO_to_SEQNUM-4.png -gravity North -pointsize 30 -annotate +0+120 '1990/1999' dgGEO_to_SEQNUM-04.png
convert dgGEO_to_SEQNUM-5.png -gravity North -pointsize 30 -annotate +0+120 '2000/2009' dgGEO_to_SEQNUM-05.png
convert dgGEO_to_SEQNUM-6.png -gravity North -pointsize 30 -annotate +0+120 '2010/2019' dgGEO_to_SEQNUM-06.png

# === put the png images together into an animated .gif
convert -delay 150 dgGEO_to_SEQNUM-0*.png decadal_animation.gif
