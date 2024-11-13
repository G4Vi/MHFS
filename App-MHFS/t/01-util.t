#!perl
use 5.014;
use strict;
use warnings;
use Test2::V0;
use MHFS::Util qw(space2us escape_html escape_html_noquote);

plan 3;

is(space2us('hello world'), 'hello_world');

my $unsafe_chars = q|"'<>/|;
is(${escape_html($unsafe_chars)}, '&quot;&#x27;&lt;&gt;&#x2F;');
is(${escape_html_noquote($unsafe_chars)}, q|"'&lt;&gt;/|);
