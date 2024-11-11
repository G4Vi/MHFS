package MHFS::Promise::FakeException v0.7.0;
use 5.014;

sub new {
    my ($class, $reason) = @_;
    return bless \$reason, $class;
}

1;
