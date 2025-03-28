#!perl
use 5.014;
use strict;
use warnings;
use Test2::V0;
use Feature::Compat::Try;
use MHFS::Util qw(space2us escape_html escape_html_noquote shell_escape get_printable_utf8 read_text_file_lossy read_text_file write_text_file write_text_file_lossy);

plan 17;

is(space2us('hello world'), 'hello_world');

my $unsafe_chars = q|"'<>/|;
is(${escape_html($unsafe_chars)}, '&quot;&#x27;&lt;&gt;&#x2F;');
is(${escape_html_noquote($unsafe_chars)}, q|"'&lt;&gt;/|);

is(shell_escape(q|it's|), q|it'"'"'s|);

is(MHFS::Util::ParseIPv4('8.8.8.8'), 8 | (8 << 8) | (8 << 16) | (8 << 24));

{
    my $result = MHFS::Util::surrogatepairtochar("\x{D83C}", "\x{DF84}");
    is(ord($result), 0x1F384, "Converting surrogate pair for $result (U+1F384)");
}
{
    my $result = MHFS::Util::surrogatepairtochar("\x{D800}", "\x{DC00}");
    is(ord($result), 0x10000, 'First possible surrogate pair combination');
}
{
    my $result = MHFS::Util::surrogatepairtochar("\x{DBFF}", "\x{DFFF}");
    is(ord($result), 0x10FFFF, 'Last possible surrogate pair combination');
}

{
    my $result = MHFS::Util::surrogatecodepointpairtochar(0xD83C, 0xDF84);
    is(ord($result), 0x1F384, "Converting surrogate pair for $result (U+1F384)");
}
{
    my $result = MHFS::Util::surrogatecodepointpairtochar(0xD800, 0xDC00);
    is(ord($result), 0x10000, 'First possible surrogate pair combination');
}
{
    my $result = MHFS::Util::surrogatecodepointpairtochar(0xDBFF, 0xDFFF);
    is(ord($result), 0x10FFFF, 'Last possible surrogate pair combination');
}

{
    my $result = get_printable_utf8('A'.chr(0xFF).'B');
    is($result, 'A'.chr(0xFFFD).'B', 'Valid invalid valid');
}
{
    my $result = get_printable_utf8("A\xED\xA0\xBC\xED\xBE\x84B");
    is($result, 'A'.chr(0x1F384).'B', 'Valid low surrogate high surrogate valid');
}

{
    my $fname = 'test_read_text_file.txt';
    if(open(my $fh, '>:raw', $fname)) {
        print $fh 'A'.chr(0xFF).'B';
        close($fh);
        my $text = read_text_file_lossy($fname);
        is($text,  'A'.chr(0xFFFD).'B', 'read_text_file_lossy Valid invalid valid');
        my $message = 'read_text_file throws on invalid file';
        try {
            read_text_file($fname);
            fail($message);
        } catch ($e) {
            pass($message);
        }
        unlink($fname);
    }
}

{
    my $fname = 'test_write_text_file.txt';
    my $message = 'write_text_file throws on invalid text';
    my $input = "A\x{D800}B";
    try {
        write_text_file($fname, $input);
        fail($message);
    } catch ($e) {
        pass($message);
    }
    unlink($fname);
    try {
        write_text_file_lossy($fname, $input);
        my $text = read_text_file($fname);
        is($text,  'A'.chr(0xFFFD).'B', 'write_text_file_lossy Valid invalid valid');
    } catch ($e) {
        fail("write_text_file_lossy does not crash");
    }
    unlink($fname);
}
