package MHFS::Promise::FakeException;

sub new {
    my ($class, $reason) = @_;
    return bless \$reason, $class;
}

1;
