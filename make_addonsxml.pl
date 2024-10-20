#!/usr/bin/perl
use strict; use warnings;

open(my $in, '<', 'plugin.video.mhfs/addon.xml') or die "failed to open addon.xml";
<$in>;
open(my $out, '>', 'App-MHFS/share/public_html/static/kodi/addons.xml');
print $out <<'END_XML_HEADER';
<?xml version="1.0" encoding="UTF-8"?>
<addons>
END_XML_HEADER
while(my $line = <$in>) {
    print $out "  $line";
}
print $out <<'END_XML_FOOTER';
</addons>
END_XML_FOOTER
