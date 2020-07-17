package ExampleModule;
use strict; use warnings;



sub main {
    my ($request) = @_;
    $request->SendLocalBuf(encode_utf8('Hello from ExampleModule'), "text/html; charset=utf-8");
}

sub routes {
    return ['/ExampleModule', \&main];
}



1;